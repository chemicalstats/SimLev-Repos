# DependenceCore – Port von r/src/dependence_core.cpp (.dcc_filter, chol_small)
# sowie aus r/src/research_core.cpp .kendall_tau_core, .quantile_reg_core (mit
# allen Hilfsroutinen) und .hmm_forward_backward.
#
# Die Rechenreihenfolge folgt 1:1 dem C++-Code (einfache Schleifen in double).
# `std::sort` (libstdc++-Introsort, nicht stabil) ist in `_std_sort!` exakt
# nachgebildet, weil die Auswahl der Basisbeobachtungen in `qr_pick` bei
# gleichen Residuen von der Reihenfolge abhängt. Die `long double`-Rechnung in
# Kendalls Tau läuft über `BigFloat` mit 64 Bit Mantisse (x87-Genauigkeit,
# korrekt gerundet wie `fsqrt`/`fdiv`).
module DependenceCore

import ..SimLev
using Dates

export dcc_filter, chol_small, kendall_tau_core, quantile_reg_core, hmm_forward_backward, QuantileRegError

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

# ─────────────────────────────────────────────────────────────────────────────
# std::sort (libstdc++ 13, Introsort) mit Vergleichsfunktion; 0-basierte
# Positionen, Zugriff a[p + 1]
# ─────────────────────────────────────────────────────────────────────────────

const _S_THRESHOLD = 16

@inline _swap!(a, i, j) = (t = a[i+1]; a[i+1] = a[j+1]; a[j+1] = t; nothing)

"Sortiert `a` an Ort und Stelle exakt wie `std::sort(a.begin(), a.end(), less)`."
function _std_sort!(a::AbstractVector, less)
    n = length(a)
    n == 0 && return a
    _introsort_loop!(a, 0, n, (8 * sizeof(Int) - leading_zeros(n) - 1) * 2, less)
    _final_insertion_sort!(a, 0, n, less)
    a
end

function _introsort_loop!(a, first, last, depth, less)
    while last - first > _S_THRESHOLD
        if depth == 0
            _partial_sort!(a, first, last, less)
            return
        end
        depth -= 1
        cut = _unguarded_partition_pivot!(a, first, last, less)
        _introsort_loop!(a, cut, last, depth, less)
        last = cut
    end
end

function _move_median_to_first!(a, result, x, y, z, less)
    if less(a[x+1], a[y+1])
        if less(a[y+1], a[z+1])
            _swap!(a, result, y)
        elseif less(a[x+1], a[z+1])
            _swap!(a, result, z)
        else
            _swap!(a, result, x)
        end
    elseif less(a[x+1], a[z+1])
        _swap!(a, result, x)
    elseif less(a[y+1], a[z+1])
        _swap!(a, result, z)
    else
        _swap!(a, result, y)
    end
end

function _unguarded_partition!(a, first, last, pivot, less)
    while true
        while less(a[first+1], a[pivot+1])
            first += 1
        end
        last -= 1
        while less(a[pivot+1], a[last+1])
            last -= 1
        end
        first < last || return first
        _swap!(a, first, last)
        first += 1
    end
end

function _unguarded_partition_pivot!(a, first, last, less)
    mid = first + div(last - first, 2)
    _move_median_to_first!(a, first, first + 1, mid, last - 1, less)
    _unguarded_partition!(a, first + 1, last, first, less)
end

function _push_heap!(a, first, hole, top, value, less)
    parent = div(hole - 1, 2)
    while hole > top && less(a[first+parent+1], value)
        a[first+hole+1] = a[first+parent+1]
        hole = parent
        parent = div(hole - 1, 2)
    end
    a[first+hole+1] = value
end

function _adjust_heap!(a, first, hole, len, value, less)
    top = hole
    second = hole
    while second < div(len - 1, 2)
        second = 2 * (second + 1)
        if less(a[first+second+1], a[first+second])
            second -= 1
        end
        a[first+hole+1] = a[first+second+1]
        hole = second
    end
    if (len & 1) == 0 && second == div(len - 2, 2)
        second = 2 * (second + 1)
        a[first+hole+1] = a[first+second]
        hole = second - 1
    end
    _push_heap!(a, first, hole, top, value, less)
end

function _make_heap!(a, first, last, less)
    len = last - first
    len < 2 && return
    parent = div(len - 2, 2)
    while true
        value = a[first+parent+1]
        _adjust_heap!(a, first, parent, len, value, less)
        parent == 0 && return
        parent -= 1
    end
end

function _partial_sort!(a, first, last, less)
    _make_heap!(a, first, last, less)
    while last - first > 1
        last -= 1
        value = a[last+1]
        a[last+1] = a[first+1]
        _adjust_heap!(a, first, 0, last - first, value, less)
    end
end

function _unguarded_linear_insert!(a, last, less)
    val = a[last+1]
    nxt = last - 1
    while less(val, a[nxt+1])
        a[last+1] = a[nxt+1]
        last = nxt
        nxt -= 1
    end
    a[last+1] = val
end

function _insertion_sort!(a, first, last, less)
    first == last && return
    for i in (first+1):(last-1)
        if less(a[i+1], a[first+1])
            val = a[i+1]
            for k in i:-1:(first+1)
                a[k+1] = a[k]
            end
            a[first+1] = val
        else
            _unguarded_linear_insert!(a, i, less)
        end
    end
end

function _final_insertion_sort!(a, first, last, less)
    if last - first > _S_THRESHOLD
        _insertion_sort!(a, first, first + _S_THRESHOLD, less)
        for i in (first+_S_THRESHOLD):(last-1)
            _unguarded_linear_insert!(a, i, less)
        end
    else
        _insertion_sort!(a, first, last, less)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# DCC-Filter
# ─────────────────────────────────────────────────────────────────────────────

"Cholesky einer kleinen symmetrischen Matrix (zeilenweise, k × k) in `L`; `false`, wenn nicht positiv definit."
function chol_small(A::Vector{Float64}, L::Vector{Float64}, k::Int)
    fill!(L, 0.0)
    for i in 0:(k-1)
        for j in 0:i
            s = A[i*k+j+1]
            for m in 0:(j-1)
                s -= L[i*k+m+1] * L[j*k+m+1]
            end
            if i == j
                s <= 1e-14 && return false
                L[i*k+i+1] = sqrt(s)
            else
                L[i*k+j+1] = s / L[j*k+j+1]
            end
        end
    end
    true
end

"`.dcc_filter(Z, a, b, Qbar, keep)` → RList `nll`, `R`, `ok`."
function dcc_filter(Z, a::Real, b::Real, Qbar, keep::Bool)
    Zm = _fmat(Z)
    Qb = _fmat(Qbar)
    a = Float64(a); b = Float64(b)
    n, k = size(Zm)
    np_ = div(k * (k - 1), 2)
    Q = zeros(k * k); R = zeros(k * k); L = zeros(k * k); y = zeros(k)
    for i in 0:(k-1), j in 0:(k-1)
        Q[i*k+j+1] = Qb[i+1, j+1]
    end
    out = fill(SimLev.NA, keep ? n : 0, keep ? np_ : 0)
    nll = 0.0
    ok = true
    for t in 0:(n-1)
        if t > 0
            for i in 0:(k-1), j in 0:(k-1)
                Q[i*k+j+1] = (1.0 - a - b) * Qb[i+1, j+1] + a * Zm[t, i+1] * Zm[t, j+1] + b * Q[i*k+j+1]
            end
        end
        for i in 0:(k-1), j in 0:(k-1)
            R[i*k+j+1] = Q[i*k+j+1] / sqrt(Q[i*k+i+1] * Q[j*k+j+1])
        end
        if !chol_small(R, L, k)
            ok = false
            break
        end
        logdet = 0.0; quad = 0.0; zz = 0.0
        for i in 0:(k-1)
            s = Zm[t+1, i+1]
            for m in 0:(i-1)
                s -= L[i*k+m+1] * y[m+1]
            end
            y[i+1] = s / L[i*k+i+1]
            quad += y[i+1] * y[i+1]
            zz += Zm[t+1, i+1] * Zm[t+1, i+1]
            logdet += 2.0 * SimLev.RLibm.log(L[i*k+i+1])
        end
        nll += 0.5 * (logdet + quad - zz)
        if keep
            p = 1
            for i in 0:(k-1), j in (i+1):(k-1)
                out[t+1, p] = R[i*k+j+1]
                p += 1
            end
        end
    end
    ok || (nll = 1e10)
    SimLev.RList("nll" => nll, "R" => out, "ok" => ok)
end

# ─────────────────────────────────────────────────────────────────────────────
# Kendalls Tau-b (Knight 1966)
# ─────────────────────────────────────────────────────────────────────────────

function _merge_count!(y::Vector{Float64}, buf::Vector{Float64}, lo::Int, hi::Int)
    hi - lo < 2 && return Int64(0)
    mid = div(lo + hi, 2)
    s = _merge_count!(y, buf, lo, mid) + _merge_count!(y, buf, mid, hi)
    i = lo; j = mid; k = lo
    while i < mid && j < hi
        if y[j+1] < y[i+1]
            buf[k+1] = y[j+1]; k += 1; j += 1
            s += mid - i
        else
            buf[k+1] = y[i+1]; k += 1; i += 1
        end
    end
    while i < mid
        buf[k+1] = y[i+1]; k += 1; i += 1
    end
    while j < hi
        buf[k+1] = y[j+1]; k += 1; j += 1
    end
    for t in lo:(hi-1)
        y[t+1] = buf[t+1]
    end
    s
end

"`.kendall_tau_core(x, y)`: Kendalls Tau-b in O(n log n)."
function kendall_tau_core(x, y)
    x = _fvec(x); y = _fvec(y)
    n = length(x)
    n < 2 && return SimLev.NA
    o = collect(0:(n-1))
    _std_sort!(o, (a, b) -> x[a+1] < x[b+1] || (x[a+1] == x[b+1] && y[a+1] < y[b+1]))
    ys = Float64[y[o[i]+1] for i in 1:n]
    buf = zeros(n)
    n1 = Int64(0); n3 = Int64(0); tx = Int64(1); txy = Int64(1)
    for i in 1:(n-1)
        if x[o[i+1]+1] == x[o[i]+1]
            tx += 1
            if y[o[i+1]+1] == y[o[i]+1]
                txy += 1
            else
                n3 += div(txy * (txy - 1), 2); txy = 1
            end
        else
            n1 += div(tx * (tx - 1), 2); n3 += div(txy * (txy - 1), 2); tx = 1; txy = 1
        end
    end
    n1 += div(tx * (tx - 1), 2); n3 += div(txy * (txy - 1), 2)
    swaps = _merge_count!(ys, buf, 0, n)
    n2 = Int64(0); ty = Int64(1)
    for i in 1:(n-1)
        if ys[i+1] == ys[i]
            ty += 1
        else
            n2 += div(ty * (ty - 1), 2); ty = 1
        end
    end
    n2 += div(ty * (ty - 1), 2)
    n0 = div(Int64(n) * (n - 1), 2)
    # long double: (long double) n0 - n1 - n2 + n3 - 2.0L * swaps, sqrtl, Division
    setprecision(BigFloat, 64) do
        ld(v) = BigFloat(v; precision = 64)
        num = ((ld(n0) - ld(n1)) - ld(n2)) + ld(n3)
        num = num - ld(2) * ld(swaps)
        den = sqrt(ld(n0 - n1) * ld(n0 - n2))
        iszero(den) && return SimLev.NA
        Float64(num / den)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Quantilsregression
# ─────────────────────────────────────────────────────────────────────────────

# Matrizen zeilenweise als Vector (A[i * p + j + 1]), wie im C++-Code.

function _gauss!(A::Vector{Float64}, b::Vector{Float64}, p::Int)
    for c in 0:(p-1)
        piv = c
        for r in (c+1):(p-1)
            abs(A[r*p+c+1]) > abs(A[piv*p+c+1]) && (piv = r)
        end
        abs(A[piv*p+c+1]) < 1e-300 && return false
        if piv != c
            for k in 0:(p-1)
                A[c*p+k+1], A[piv*p+k+1] = A[piv*p+k+1], A[c*p+k+1]
            end
            b[c+1], b[piv+1] = b[piv+1], b[c+1]
        end
        for r in (c+1):(p-1)
            f = A[r*p+c+1] / A[c*p+c+1]
            for k in c:(p-1)
                A[r*p+k+1] -= f * A[c*p+k+1]
            end
            b[r+1] -= f * b[c+1]
        end
    end
    for i in (p-1):-1:0
        s = b[i+1]
        for k in (i+1):(p-1)
            s -= A[i*p+k+1] * b[k+1]
        end
        b[i+1] = s / A[i*p+i+1]
    end
    true
end

_solve_general!(A, b, p) = _gauss!(copy(A), b, p)

function _solve_spd!(A::Vector{Float64}, b::Vector{Float64}, p::Int)
    A = copy(A)
    Lm = zeros(p * p)
    ok = true
    i = 0
    while i < p && ok
        for j in 0:i
            s = A[i*p+j+1]
            for k in 0:(j-1)
                s -= Lm[i*p+k+1] * Lm[j*p+k+1]
            end
            if i == j
                if s <= 0.0
                    ok = false
                    break
                end
                Lm[i*p+i+1] = sqrt(s)
            else
                Lm[i*p+j+1] = s / Lm[j*p+j+1]
            end
        end
        i += 1
    end
    if ok
        for i in 0:(p-1)
            s = b[i+1]
            for k in 0:(i-1)
                s -= Lm[i*p+k+1] * b[k+1]
            end
            b[i+1] = s / Lm[i*p+i+1]
        end
        for i in (p-1):-1:0
            s = b[i+1]
            for k in (i+1):(p-1)
                s -= Lm[k*p+i+1] * b[k+1]
            end
            b[i+1] = s / Lm[i*p+i+1]
        end
        return true
    end
    _gauss!(A, b, p)
end

@inline function _fit_i(X::Matrix{Float64}, i::Int, b, p::Int)
    fit = 0.0
    for j in 1:p
        fit += X[i, j] * b[j]
    end
    fit
end

function _qr_objective(y::Vector{Float64}, X::Matrix{Float64}, b, tau::Float64)
    n, p = size(X)
    acc = 0.0
    for i in 1:n
        r = y[i] - _fit_i(X, i, b, p)
        acc += r * (tau - (r < 0.0 ? 1.0 : 0.0))
    end
    acc
end

function _qr_pick(y::Vector{Float64}, X::Matrix{Float64}, beta)
    n, p = size(X)
    r = Float64[abs(y[i] - _fit_i(X, i, beta, p)) for i in 1:n]
    ord = collect(0:(n-1))
    _std_sort!(ord, (a, b) -> r[a+1] < r[b+1])
    pick = Int[]          # 0-basiert
    Q = Float64[]
    v = zeros(p)
    idx = 0
    while idx < n && length(pick) < p
        i = ord[idx+1]
        idx += 1
        nv = 0.0; n0 = 0.0
        for j in 1:p
            v[j] = X[i+1, j]; n0 += v[j] * v[j]
        end
        for q in 0:(length(pick)-1)
            d = 0.0
            for j in 0:(p-1)
                d += Q[q*p+j+1] * v[j+1]
            end
            for j in 0:(p-1)
                v[j+1] -= d * Q[q*p+j+1]
            end
        end
        for j in 1:p
            nv += v[j] * v[j]
        end
        nv <= 1e-10 * max(n0, 1e-300) && continue
        nv = sqrt(nv)
        for j in 1:p
            push!(Q, v[j] / nv)
        end
        push!(pick, i)
    end
    pick
end

function _invert_small(A::Vector{Float64}, p::Int)
    A = copy(A)
    Inv = zeros(p * p)
    for i in 0:(p-1)
        Inv[i*p+i+1] = 1.0
    end
    for c in 0:(p-1)
        piv = c
        for r in (c+1):(p-1)
            abs(A[r*p+c+1]) > abs(A[piv*p+c+1]) && (piv = r)
        end
        abs(A[piv*p+c+1]) < 1e-300 && return nothing
        if piv != c
            for k in 0:(p-1)
                A[c*p+k+1], A[piv*p+k+1] = A[piv*p+k+1], A[c*p+k+1]
                Inv[c*p+k+1], Inv[piv*p+k+1] = Inv[piv*p+k+1], Inv[c*p+k+1]
            end
        end
        d = A[c*p+c+1]
        for k in 0:(p-1)
            A[c*p+k+1] /= d
            Inv[c*p+k+1] /= d
        end
        for r in 0:(p-1)
            if r != c && A[r*p+c+1] != 0.0
                f = A[r*p+c+1]
                for k in 0:(p-1)
                    A[r*p+k+1] -= f * A[c*p+k+1]
                    Inv[r*p+k+1] -= f * Inv[c*p+k+1]
                end
            end
        end
    end
    Inv
end

function _qr_subgrad_lp(X::Matrix{Float64}, G::Vector{Int}, v::Vector{Float64}, tau::Float64)
    p = size(X, 2)
    o = copy(G)
    lessrow(a, b) = begin
        for j in 1:p
            X[a+1, j] != X[b+1, j] && return X[a+1, j] < X[b+1, j]
        end
        a < b
    end
    _std_sort!(o, lessrow)
    A = Float64[]; U = Float64[]
    for t in 0:(length(o)-1)
        same = t > 0
        j = 0
        while j < p && same
            same = X[o[t+1]+1, j+1] == X[o[t]+1, j+1]
            j += 1
        end
        if same
            U[end] += 1.0
            continue
        end
        for j in 1:p
            push!(A, X[o[t+1]+1, j])
        end
        push!(U, 1.0)
    end
    m = length(U); nv = m + p
    w = copy(v); sgn = zeros(p)
    S = 0.0
    for i in 0:(p-1)
        si = abs(v[i+1])
        for q in 0:(m-1)
            w[i+1] -= (tau - 1.0) * U[q+1] * A[q*p+i+1]
            si += U[q+1] * abs(A[q*p+i+1])
        end
        sgn[i+1] = w[i+1] >= 0.0 ? 1.0 : -1.0
        S = max(S, si)
    end
    ftol = 1e-9 * max(S, 1e-300)
    col(k, i) = k < m ? A[k*p+i+1] : (k - m == i ? sgn[i+1] : 0.0)
    basis = Int[m + i for i in 0:(p-1)]
    upper = zeros(Bool, nv); inb = zeros(Bool, nv)
    for i in 0:(p-1)
        inb[m+i+1] = true
    end
    B = zeros(p * p); rhs = zeros(p); xB = zeros(p); pi_ = zeros(p); al = zeros(p)
    maxit = 50 * nv + 1000
    obj_old = Inf; stall = 0
    for it in 0:(maxit-1)
        for i in 0:(p-1), r in 0:(p-1)
            B[i*p+r+1] = col(basis[r+1], i)
        end
        Bi = _invert_small(B, p)
        Bi === nothing && return false
        for i in 0:(p-1)
            rhs[i+1] = w[i+1]
            for q in 0:(m-1)
                upper[q+1] && (rhs[i+1] -= U[q+1] * A[q*p+i+1])
            end
        end
        obj = 0.0
        for r in 0:(p-1)
            s = 0.0
            for i in 0:(p-1)
                s += Bi[r*p+i+1] * rhs[i+1]
            end
            xB[r+1] = s
            basis[r+1] >= m && (obj += s)
        end
        obj <= ftol && return true
        if obj < obj_old - 1e-12 * S
            stall = 0
        else
            stall += 1
        end
        obj_old = min(obj_old, obj)
        for i in 0:(p-1)
            s = 0.0
            for r in 0:(p-1)
                basis[r+1] >= m && (s += Bi[r*p+i+1])
            end
            pi_[i+1] = s
        end
        bland = stall > 2 * p + 10
        ent = -1; dir = 0.0; dbest = 0.0
        for q in 0:(m-1)
            inb[q+1] && continue
            d = 0.0
            for i in 0:(p-1)
                d -= pi_[i+1] * A[q*p+i+1]
            end
            gain = upper[q+1] ? d : -d
            if gain > 1e-11 && gain > dbest
                ent = q; dir = upper[q+1] ? -1.0 : 1.0; dbest = gain
                bland && break
            end
        end
        ent < 0 && return false
        amax = 0.0
        for r in 0:(p-1)
            s = 0.0
            for i in 0:(p-1)
                s += Bi[r*p+i+1] * A[ent*p+i+1]
            end
            al[r+1] = dir * s
            amax = max(amax, abs(s))
        end
        ptol = 1e-12 * max(amax, 1.0)
        tmax = U[ent+1]; leave = -1; to_upper = false
        for r in 0:(p-1)
            k = basis[r+1]
            if al[r+1] > ptol
                lim = max(xB[r+1], 0.0) / al[r+1]
            elseif al[r+1] < -ptol && k < m
                lim = max(U[k+1] - xB[r+1], 0.0) / -al[r+1]
            else
                continue
            end
            if lim < tmax || (lim == tmax && leave >= 0 && k < basis[leave+1])
                tmax = lim; leave = r; to_upper = al[r+1] < 0.0
            end
        end
        if leave < 0
            upper[ent+1] = !upper[ent+1]
            continue
        end
        k = basis[leave+1]
        inb[k+1] = false
        k < m && (upper[k+1] = to_upper)
        basis[leave+1] = ent; inb[ent+1] = true; upper[ent+1] = false
    end
    false
end

"Rückgabe (Status, Ecke oder `nothing`)."
function _qr_polish(y::Vector{Float64}, X::Matrix{Float64}, beta, tau::Float64)
    n, p = size(X)
    pick = _qr_pick(y, X, beta)
    length(pick) < p && return 0, nothing
    A = zeros(p * p); b = zeros(p)
    for a in 0:(p-1)
        b[a+1] = y[pick[a+1]+1]
        for j in 0:(p-1)
            A[a*p+j+1] = X[pick[a+1]+1, j+1]
        end
    end
    _solve_general!(A, b, p) || return 0, nothing
    f_mm = _qr_objective(y, X, beta, tau); f_v = _qr_objective(y, X, b, tau)
    f_v <= f_mm || return 0, nothing
    out = copy(b)
    inh = zeros(Bool, n)
    for a in 1:p
        inh[pick[a]+1] = true
    end
    g = zeros(p)
    yscale = 0.0
    for i in 1:n
        yscale = max(yscale, abs(y[i]))
    end
    Z = Int[]
    for i in 1:n
        inh[i] && continue
        ri = y[i] - _fit_i(X, i, b, p)
        if abs(ri) <= 1e-12 * (1.0 + yscale)
            push!(Z, i - 1)
            continue
        end
        psi = tau - (ri < 0.0 ? 1.0 : 0.0)
        for j in 1:p
            g[j] += psi * X[i, j]
        end
    end
    if !isempty(Z)
        G = vcat(pick, Z)
        v = Float64[-g[j] for j in 1:p]
        return (_qr_subgrad_lp(X, G, v, tau) ? 2 : 1), out
    end
    At = zeros(p * p); lam = zeros(p)
    for a in 0:(p-1), j in 0:(p-1)
        At[j*p+a+1] = A[a*p+j+1]
    end
    for j in 1:p
        lam[j] = -g[j]
    end
    _solve_general!(At, lam, p) || return 1, out
    for a in 1:p
        (lam[a] < tau - 1.0 - 1e-9 || lam[a] > tau + 1e-9) && return 1, out
    end
    2, out
end

"Rückgabe (Status, letzte Ecke oder `nothing`)."
function _qr_exchange(y::Vector{Float64}, X::Matrix{Float64}, tau::Float64, h::Vector{Int})
    n, p = size(X)
    out = nothing
    length(h) != p && return 0, out
    h = copy(h)
    yscale = 0.0
    for i in 1:n
        yscale = max(yscale, abs(y[i]))
    end
    A = zeros(p * p); D = zeros(p * p); b = zeros(p); r = zeros(n); g = zeros(p); lam = zeros(p); c = zeros(n); e = zeros(p)
    inh = zeros(Bool, n)
    f_old = Inf
    maxit = 20 * n + 100
    for it in 0:(maxit-1)
        for a in 0:(p-1)
            b[a+1] = y[h[a+1]+1]
            for j in 0:(p-1)
                A[a*p+j+1] = X[h[a+1]+1, j+1]
            end
        end
        _solve_general!(A, b, p) || return 0, out
        for cl in 0:(p-1)
            fill!(e, 0.0); e[cl+1] = 1.0
            _solve_general!(A, e, p) || return 0, out
            for j in 0:(p-1)
                D[j*p+cl+1] = e[j+1]
            end
        end
        fill!(inh, false)
        for a in 1:p
            inh[h[a]+1] = true
        end
        f = 0.0; fscale = yscale
        for i in 1:n
            fit = _fit_i(X, i, b, p)
            r[i] = y[i] - fit
            fscale = max(fscale, abs(fit))
            f += r[i] * (tau - (r[i] < 0.0 ? 1.0 : 0.0))
        end
        f > f_old + 1e-12 * (1.0 + abs(f_old)) && return 0, out
        out = copy(b); f_old = f
        ztol = 1e-12 * (1.0 + fscale)
        fill!(g, 0.0)
        Z = Int[]
        for i in 1:n
            inh[i] && continue
            if abs(r[i]) <= ztol
                push!(Z, i - 1)
                continue
            end
            psi = tau - (r[i] < 0.0 ? 1.0 : 0.0)
            for j in 1:p
                g[j] += psi * X[i, j]
            end
        end
        for a in 0:(p-1)
            s = 0.0
            for j in 0:(p-1)
                s += D[j*p+a+1] * g[j+1]
            end
            lam[a+1] = -s
        end
        nz = length(Z)
        K = zeros(nz * p)
        for z in 0:(nz-1), a in 0:(p-1)
            s = 0.0
            for j in 0:(p-1)
                s += X[Z[z+1]+1, j+1] * D[j*p+a+1]
            end
            K[z*p+a+1] = s
        end
        best = -1e-9; ba = -1; bs = 0
        for a in 0:(p-1)
            for s in (1, -1)
                sl = s > 0 ? (1.0 - tau) + lam[a+1] : tau - lam[a+1]
                for z in 0:(nz-1)
                    cj = s * K[z*p+a+1]
                    sl += cj > 0.0 ? (1.0 - tau) * cj : -tau * cj
                end
                if sl < best
                    best = sl; ba = a; bs = s
                end
            end
        end
        if ba < 0
            (p == 1 || nz == 0) && return 2, out
            G = vcat(h, Z)
            v = Float64[-g[j] for j in 1:p]
            return (_qr_subgrad_lp(X, G, v, tau) ? 2 : 1), out
        end
        kinks = Tuple{Float64,Int}[]
        for i in 1:n
            inh[i] && continue
            ci = 0.0
            for j in 0:(p-1)
                ci += X[i, j+1] * D[j*p+ba+1]
            end
            c[i] = bs * ci
            (abs(r[i]) <= ztol || c[i] == 0.0) && continue
            t = r[i] / c[i]
            t > 0.0 && push!(kinks, (t, i - 1))
        end
        sort!(kinks)       # Paare (t, i): totale Ordnung, Ergebnis eindeutig
        sl = best; inew = -1
        for (t, i) in kinks
            sl += abs(c[i+1])
            if sl >= 0.0
                inew = i
                break
            end
        end
        inew < 0 && return 0, out
        h[ba+1] = inew
    end
    0, out
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
    tau = Float64(tau); sc = Float64(sc); tol = Float64(tol); maxit = Int(maxit)
    beta = _fvec(beta0)
    p == 0 && return Float64[], nothing
    nb = zeros(p); A = zeros(p * p); c1 = zeros(p); r = zeros(n); w = zeros(n)
    proven = false
    for j in 1:p
        s = 0.0
        for i in 1:n
            s += X[i, j]
        end
        c1[j] = s * (tau - 0.5)
    end
    epss = (1e-2, 1e-4, 1e-6, 1e-8)
    for e in 0:3
        eps = sc * epss[e+1]
        early = false
        for it in 0:(maxit-1)
            for i in 1:n
                fit = _fit_i(X, i, beta, p)
                r[i] = y[i] - fit
                w[i] = 1.0 / (2.0 * (eps + abs(r[i])))
            end
            fill!(A, 0.0)
            for j in 0:(p-1)
                s = c1[j+1]
                for i in 1:n
                    s += X[i, j+1] * w[i] * y[i]
                end
                nb[j+1] = s
                for k in 0:j
                    a = 0.0
                    for i in 1:n
                        a += X[i, j+1] * w[i] * X[i, k+1]
                    end
                    A[j*p+k+1] = a; A[k*p+j+1] = a
                end
            end
            _solve_spd!(A, nb, p) || throw(QuantileRegError("Quantilsregression: singuläres Gleichungssystem."))
            dmax = 0.0; bmax = 0.0
            for j in 1:p
                dmax = max(dmax, abs(nb[j] - beta[j])); bmax = max(bmax, abs(beta[j]))
            end
            done = dmax <= (e < 3 ? max(tol, 1e-7) : tol) * (1.0 + bmax)
            beta = copy(nb)
            done && break
            if it % 25 == 24
                st_, vb = _qr_polish(y, X, beta, tau)
                if st_ == 2
                    beta = vb; proven = true; early = true
                    break
                end
            end
        end
        early && break
        st, vb = _qr_polish(y, X, beta, tau)
        if st == 2
            beta = vb; proven = true
            break
        end
        if e == 3
            f_mm = _qr_objective(y, X, beta, tau)
            sx, xb = _qr_exchange(y, X, tau, _qr_pick(y, X, beta))
            if sx == 2
                beta = xb; proven = true
            elseif xb !== nothing && length(xb) == p && _qr_objective(y, X, xb, tau) <= f_mm
                beta = xb
            elseif st == 1
                beta = vb
            end
        end
    end
    Vector{Float64}(beta), proven
end

# ─────────────────────────────────────────────────────────────────────────────
# HMM: skalierter Vorwärts-Rückwärts-Schritt
# ─────────────────────────────────────────────────────────────────────────────

"`.hmm_forward_backward(B, A, p0)` → RList `filtered`, `smoothed`, `xi`, `scale`."
function hmm_forward_backward(B, A, p0)
    Bm = _fmat(B); Am = _fmat(A); p0 = _fvec(p0)
    T, K = size(Bm)
    al = zeros(T, K); be = zeros(T, K); ga = zeros(T, K); xi = zeros(K, K)
    cs = zeros(T)
    a = zeros(K); tmp = zeros(K)
    s = 0.0
    for j in 1:K
        a[j] = p0[j] * Bm[1, j]; s += a[j]
    end
    cs[1] = s
    for j in 1:K
        al[1, j] = a[j] / s
    end
    for t in 2:T
        s = 0.0
        for j in 1:K
            v = 0.0
            for i in 1:K
                v += al[t-1, i] * Am[i, j]
            end
            a[j] = v * Bm[t, j]; s += a[j]
        end
        cs[t] = s
        for j in 1:K
            al[t, j] = a[j] / s
        end
    end
    for j in 1:K
        be[T, j] = 1.0
    end
    for t in (T-1):-1:1
        for j in 1:K
            tmp[j] = Bm[t+1, j] * be[t+1, j]
        end
        for i in 1:K
            v = 0.0
            for j in 1:K
                v += Am[i, j] * tmp[j]
            end
            be[t, i] = v / cs[t+1]
        end
    end
    for t in 1:T
        rs = 0.0
        for j in 1:K
            ga[t, j] = al[t, j] * be[t, j]; rs += ga[t, j]
        end
        for j in 1:K
            ga[t, j] /= rs
        end
    end
    for t in 1:(T-1)
        for j in 1:K
            tmp[j] = Bm[t+1, j] * be[t+1, j]
        end
        for i in 1:K, j in 1:K
            xi[i, j] += al[t, i] * tmp[j] * Am[i, j] / cs[t+1]
        end
    end
    SimLev.RList("filtered" => al, "smoothed" => ga, "xi" => xi, "scale" => cs)
end

end # module
