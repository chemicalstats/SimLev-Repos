# ─────────────────────────────────────────────────────────────────────────────
# RStats – R's stats-Interna (R 4.3.3), bitgleich
#
# Portiert aus src/library/stats/R/*.R und src/library/stats/src/*.c bzw. *.f
# (sowie Teilen von src/main/sort.c, qsort-body.c, seq.c, cum.c) über die
# Vorlage python/simlev/_r/stats.py. Rechenreihenfolge, long-double-
# Akkumulation (SimLev.F80) und libm-Aufrufe (SimLev.RLibm) wie in R.
#
# Konventionen
# * Namen wie in R bzw. der Python-Fassung, `.` → `_` (weighted.mean →
#   weighted_mean, lm.fit → lm_fit, p.adjust → p_adjust, …). Kollisionen mit
#   Base: r_sort, r_rank, r_filter, r_binomial.
# * Eingaben: Vektoren (NA = SimLev.NA bzw. missing), RVector (benannt),
#   Matrix, NamedMat, RFrame, Skalare.
# * Ergebnisse: Länge 1 als Skalar, sonst Vector; benannte Vektoren als
#   RVector; Matrizen als Matrix bzw. mit dimnames als NamedMat; Listen als
#   RList (S3-Klasse im Feld `class`); data.frames als RFrame; Faktoren als
#   SimLev.RFmt.RFactor.
# * Fehler: error(<R-Text>); Warnungen: @warn <R-Text>.
# ─────────────────────────────────────────────────────────────────────────────
module RStats

import ..SimLev
import ..SimLev: RList, RVector, NamedMat, RFrame, NA, isna_strict, F80
using Dates

export quantile, median, var, sd, cov, cor, cov2cor, weighted_mean, scale, approx, approxfun,
       r_filter, optimize, optimise, uniroot, optim, optimhess, nlminb, lm_fit, lm, poly, summary_lm, glm, glm_fit,
       r_binomial, smooth_spline, predict_smooth_spline, predict, density, bw_nrd0, fft, hclust, dist,
       as_dist, dist_as_matrix, p_adjust, t_test, r_rank, order, r_sort, sort_partial, rle, cut,
       findInterval, tabulate, ave, aggregate, complete_cases, ecdf, fitted, coef, residuals,
       seq_len_out, ApproxFun, str_collate, r_isless

const _DBL_EPS = 2.220446049250313e-16
const _DBL_MAX = 1.7976931348623157e308

"sqrt mit C-Semantik (negativ → NaN statt DomainError)."
@inline _csqrt(x::Float64) = x < 0.0 ? reinterpret(Float64, 0xFFF8000000000000) : sqrt(x)

include("_collate.jl")
include("_optim.jl")
include("_lbfgsb.jl")
include("_fft.jl")
include("_sbart.jl")

# Kollationszustand (ICU-Handles) gilt nur im laufenden Prozess.
# Beim Laden nur zurücksetzen (nach der Vorkompilierung wären Zeiger ungültig).
__init__() = (_COLL.init = false; _COLL.coll = C_NULL; _COLL.warned = false; nothing)

# ── Hilfen ────────────────────────────────────────────────────────────────

const _EPOCH = Date(1970, 1, 1)
_fl(v) = (v === missing || v === nothing) ? NA : v isa Date ? Float64(Dates.value(v - _EPOCH)) : Float64(v)

"Numerischer Vektor (Float64) und Namen (oder nothing)."
_vec(x::RVector) = (Float64[_fl(v) for v in x.values], x.names)
_vec(x::NamedMat) = (Float64[_fl(v) for v in vec(x.data)], nothing)
_vec(x::RFrame) = (Float64[_fl(v) for c in x.cols for v in c], nothing)
_vec(x::SimLev.RFmt.RFactor) = (Float64[c == 0 ? NA : Float64(c) for c in x.codes], nothing)
_vec(x::AbstractArray) = (Float64[_fl(v) for v in vec(x)], nothing)
_vec(x::Tuple) = _vec(collect(x))
_vec(x::Union{Real,Date}) = (Float64[_fl(x)], nothing)
_vec(::Missing) = (Float64[NA], nothing)
_vec(::Nothing) = (Float64[], nothing)
_v(x) = _vec(x)[1]

_isint_t(T) = (S = Base.nonmissingtype(T); S <: Integer)
_is_int_like(x::RVector) = _isint_t(eltype(x.values))
_is_int_like(x::AbstractArray) = _isint_t(eltype(x))
_is_int_like(x::Integer) = true
_is_int_like(x) = false

_names_of(x::RVector) = x.names
_names_of(x) = nothing

"Vektorergebnis: RVector mit Namen, sonst Vector (Länge 1 → Skalar)."
function _vec_out(v::AbstractVector, names = nothing)
    names !== nothing && return RVector(collect(v); names = names)
    length(v) == 1 && return v[1]
    return collect(v)
end
_out(Z, rn = nothing, cn = nothing) = (rn === nothing && cn === nothing) ? Z : NamedMat(Z; rownames = rn, colnames = cn)

"Warnung nur einmal je Aufruf (R zählt sie, die Referenz vergleicht eindeutige Texte)."
_warn1!(seen::Set{String}, msg::String) = (msg in seen || (push!(seen, msg); @warn msg); nothing)

# ── long double (F80) ────────────────────────────────────────────────────

const _LD0 = F80(0.0)
_ld(x::Float64) = F80(x)
_ld(x::Integer) = F80(x)
_ldsum(a) = (s = _LD0; for v in a; s = s + F80(Float64(v)); end; s)
_ldisnan(a::F80) = isnan(Float64(a))
_ldiszero(a::F80) = SimLev._iszero80(a)

"Vergleich zweier F80: -1, 0, 1 (2 bei NaN)."
function _ldcmp(a::F80, b::F80)
    (_ldisnan(a) || _ldisnan(b)) && return 2
    SimLev._lt80(a, b) && return -1
    SimLev._lt80(b, a) && return 1
    return 0
end

"sqrtl() für F80 (korrekt gerundet auf 64 Mantissenbits wie x87 fsqrt; über ld80.jl)."
_ldsqrt(a::F80) = sqrt(a)

"sum() wie R (long double)."
_rsum(a) = SimLev.r_sum(a)

"mean() für Doubles (long double, zweiter Korrekturdurchlauf)."
function _rmean(a)
    n = length(a)
    n == 0 && return NaN
    ln = F80(n)
    s = _ldsum(a) / ln
    if isfinite(Float64(s))
        t = _LD0
        for v in a
            t = t + (F80(Float64(v)) - s)
        end
        s = s + t / ln
    end
    return Float64(s)
end

"mean() für ganzzahlige Vektoren."
function _rmean_int(a)
    n = length(a)
    n == 0 && return NaN
    s = _LD0
    for v in a
        s = s + F80(Int(v))
    end
    return Float64(s / F80(n))
end

"`seq.int(from, to, length.out = n)` (Werte wie R)."
function seq_len_out(frm, to, length_out)
    n = trunc(Int, length_out)
    frm = Float64(frm); to = Float64(to)
    n <= 0 && return Float64[]
    out = Vector{Float64}(undef, n)
    out[1] = frm
    n > 1 && (out[n] = to)
    if n > 2
        nint = Float64(n - 1)
        rby = to - frm
        if isfinite(rby)
            rby = rby / nint
            for i in 1:n-2
                out[i+1] = frm + Float64(i) * rby
            end
        else
            rby = to / nint - frm / nint
            f4 = frm / 4.0
            b4 = rby / 4.0
            for i in 1:n-2
                out[i+1] = (f4 + Float64(i) * b4) * 4.0
            end
        end
    end
    out
end

# ── Sortieren, Ränge ─────────────────────────────────────────────────────

"Werte für die Sortierung: (Werte, NA-Maske, ist_Zeichenkette)."
function _keys(x)
    if x isa SimLev.RFmt.RFactor
        v = Float64[c == 0 ? NA : Float64(c) for c in x.codes]
        return v, isnan.(v), false
    end
    a = x isa RVector ? x.values : x isa Tuple ? collect(x) : x isa AbstractArray ? vec(x) : [x]
    T = Base.nonmissingtype(eltype(a))
    if T <: AbstractString || (T === Any && any(v -> v isa AbstractString, a))
        na = Bool[v === missing || v === nothing || (v isa AbstractFloat && isnan(v)) for v in a]
        return Any[v for v in a], na, true
    end
    v = Float64[_fl(t) for t in a]
    return v, isnan.(v), false
end

_z0(v::Float64) = v == 0.0 ? 0.0 : v

"Stabile Sortierpermutation (−0 = +0; absteigend: Gleichstände in Eingabereihenfolge)."
function _stable_argsort(v::AbstractVector, isstr::Bool, decreasing::Bool)
    n = length(v)
    n == 0 && return Int[]
    if !isstr
        vv = Float64[_z0(Float64(t)) for t in v]
        return decreasing ? sortperm(-vv; alg = MergeSort, lt = <) : sortperm(vv; alg = MergeSort, lt = <)
    end
    # R's orderVector1 mit Scollate: stabil (Gleichstand → Index aufsteigend), auch absteigend
    lst = [String(t) for t in v]
    return sortperm(lst; alg = MergeSort, lt = str_lt, rev = decreasing)
end

"R's `ssort2` (Shellsort mit Scollate) für `sort()` unbenannter Zeichenketten."
function _ssort2(vals::AbstractVector, decreasing::Bool)
    x = collect(Any, vals)
    n = length(x)
    n < 2 && return x
    incs = (1073790977, 268460033, 67121153, 16783361, 4197377, 1050113,
            262913, 65921, 16577, 4193, 1073, 281, 77, 23, 8, 1, 0)
    t = 1
    while incs[t] > n
        t += 1
    end
    h = incs[t]
    while t <= 16
        for i in h:(n - 1)          # 0-basiert wie in C
            v = x[i+1]
            j = i
            if decreasing
                while j >= h && str_collate(String(x[j-h+1]), String(v)) < 0
                    x[j+1] = x[j-h+1]; j -= h
                end
            else
                while j >= h && str_collate(String(x[j-h+1]), String(v)) > 0
                    x[j+1] = x[j-h+1]; j -= h
                end
            end
            x[j+1] = v
        end
        t += 1
        h = incs[t]
    end
    return x
end

"""
    order(args...; na_last = true, decreasing = false)

`order(..., na.last, decreasing)` (stabil wie method = "radix"); 1-basierte
Indizes. `na_last`: true, false oder nothing (= NA: entfernen).
"""
function order(args...; na_last = true, decreasing = false)
    keys = [_keys(a) for a in args]
    n = length(keys[1][1])
    for k in keys
        length(k[1]) != n && error("argument lengths differ")
    end
    dec = decreasing isa AbstractVector || decreasing isa Tuple ? collect(Bool, decreasing) : fill(Bool(decreasing), length(keys))
    length(dec) == 1 && (dec = fill(dec[1], length(keys)))
    idx = collect(1:n)
    for kk in length(keys):-1:1
        v, na, isstr = keys[kk]
        d = dec[kk]
        vv = v[idx]
        nn = na[idx]
        ok = findall(.!nn)
        bad = findall(nn)
        sub = _stable_argsort(vv[ok], isstr, d)
        okp = ok[sub]
        new = na_last === nothing ? okp : (na_last === true ? vcat(okp, bad) : vcat(bad, okp))
        idx = idx[new]
    end
    if na_last === nothing
        anyna = falses(n)
        for (v, na, _) in keys
            anyna .|= na
        end
        idx = idx[.!anyna[idx]]
    end
    return idx
end

"`sort(x, decreasing, na.last = NA)`; Namen bleiben erhalten."
function r_sort(x; decreasing::Bool = false, na_last = nothing)
    names = _names_of(x)
    vals = x isa RVector ? x.values : x isa AbstractArray ? vec(x) : [x]
    if names === nothing && !(x isa SimLev.RFmt.RFactor)
        _, na, isstr = _keys(x)
        if isstr
            # sort.int(method = "shell") ohne Namen: .Internal(sort()) = ssort2
            y = _ssort2(vals[.!na], decreasing)
            nas = collect(Any, vals[na])
            out = (na_last === nothing || isempty(nas)) ? y : na_last === true ? vcat(y, nas) : vcat(nas, y)
            return _vec_out(collect(eltype(vals), out))
        end
    end
    o = order(x; na_last = na_last, decreasing = decreasing)
    out = vals[o]
    names !== nothing && return RVector(out; names = names[o])
    return _vec_out(out)
end

"""
    r_rank(x; na_last = true, ties_method = "average")

`rank(x, na.last, ties.method)`; `ties_method` "average" (double), "first",
"last", "min", "max" (integer). `na_last`: true, false, nothing (= NA) oder "keep".
"""
function r_rank(x; na_last = true, ties_method::AbstractString = "average")
    names = _names_of(x)
    v, nas, isstr = _keys(x)
    xs = v[.!nas]
    m = length(xs)
    if ties_method in ("average", "min", "max")
        o = _stable_argsort(xs, isstr, false)
        y = ties_method == "average" ? Vector{Float64}(undef, m) : Vector{Int}(undef, m)
        sv = xs[o]
        _eq = isstr ? ((a, b) -> str_collate(String(a), String(b)) == 0) : (==)   # R's equal(): Scollate == 0
        i = 1
        while i <= m
            j = i
            while j < m && _eq(sv[j], sv[j+1])
                j += 1
            end
            for t in i:j
                if ties_method == "average"
                    y[o[t]] = (Float64(i - 1) + (j - 1) + 2) / 2.0
                elseif ties_method == "max"
                    y[o[t]] = j
                else
                    y[o[t]] = i
                end
            end
            i = j + 1
        end
    elseif ties_method == "first"
        o = order(xs)
        y = invperm(o)
    elseif ties_method == "last"
        o1 = order(xs; decreasing = true)
        y = order(Float64.(reverse(o1)))
    else
        error("ties.method \"$ties_method\" is not supported")
    end
    if na_last !== nothing && any(nas)
        keep = na_last == "keep"
        N = length(v)
        if eltype(y) <: AbstractFloat
            yy = fill(NA, N)
        elseif keep
            yy = Vector{Union{Missing,Int}}(missing, N)
        else
            yy = zeros(Int, N)
        end
        if keep || na_last === true
            yy[.!nas] = y
            keep || (yy[nas] = (m+1):N)
        else
            ln = count(nas)
            yy[.!nas] = y .+ ln
            yy[nas] = 1:ln
        end
        names !== nothing && return RVector(yy; names = names)
        return _vec_out(yy)
    end
    names !== nothing && return RVector(y; names = names[.!nas])
    return _vec_out(y)
end

"`rle(x)`: RList (Klasse \"rle\") mit `lengths` (Int) und `values`."
function rle(x)
    a = x isa RVector ? x.values : x isa AbstractArray ? vec(x) : [x]
    n = length(a)
    n == 0 && return RList("lengths" => Int[], "values" => a; class = "rle")
    brk = Int[]
    for i in 2:n
        p = a[i]; q = a[i-1]
        diff = if p === missing || q === missing
            true
        elseif p isa AbstractFloat || q isa AbstractFloat
            isnan(p) || isnan(q) || p != q
        else
            p != q
        end
        diff && push!(brk, i - 1)
    end
    ends = vcat(brk, n)
    lens = diff_int(vcat(0, ends))
    vals = a[ends]
    return RList("lengths" => (length(lens) == 1 ? lens[1] : lens), "values" => (length(vals) == 1 ? vals[1] : collect(vals)); class = "rle")
end
diff_int(v) = [v[i+1] - v[i] for i in 1:length(v)-1]

"`tabulate(bin, nbins = max(1, bin, na.rm = TRUE))`."
function tabulate(bin; nbins = nothing)
    b = [isnan(t) ? t : trunc(t) for t in _v(bin)]
    if nbins === nothing
        bb = filter(!isnan, b)
        nbins = trunc(Int, max(1.0, isempty(bb) ? 1.0 : maximum(bb)))
    end
    nbins = Int(nbins)
    out = zeros(Int, nbins)
    for t in b
        isnan(t) && continue
        i = trunc(Int, t)
        (1 <= i <= nbins) && (out[i] += 1)
    end
    return _vec_out(out)
end

_cnt_le(v, x) = searchsortedlast(v, x; lt = <)          # #{v .<= x}
_cnt_lt(v, x) = searchsortedfirst(v, x; lt = <) - 1     # #{v .< x}

"`findInterval(x, vec, rightmost.closed, all.inside, left.open)`."
function findInterval(x, vec; rightmost_closed::Bool = false, all_inside::Bool = false, left_open::Bool = false)
    v = _v(vec)
    xx = _v(x)
    if any(isnan, v) || any(i -> v[i+1] < v[i], 1:length(v)-1)
        error("'vec' must be sorted non-decreasingly and not contain NAs")
    end
    n = length(v)
    res = Vector{Union{Missing,Int}}(missing, length(xx))
    for (k, t) in enumerate(xx)
        isnan(t) && continue
        if left_open
            r = _cnt_lt(v, t)
            (rightmost_closed && n > 0 && t == v[1]) && (r = 1)
        else
            r = _cnt_le(v, t)
            (rightmost_closed && n > 0 && t == v[n]) && (r = n - 1)
        end
        all_inside && n > 0 && (r = clamp(r, 1, max(1, n - 1)))
        res[k] = r
    end
    any(ismissing, res) && return _vec_out(res)
    return _vec_out(Int[r for r in res])
end

function _bincode(x::Vector{Float64}, B::Vector{Float64}, right::Bool, include_lowest::Bool)
    nb1 = length(B) - 1
    lft = !right
    out = zeros(Int, length(x))        # 0 = NA
    for (i, xi) in enumerate(x)
        isnan(xi) && continue
        lo, hi = 1, nb1 + 1
        if xi < B[lo] || B[hi] < xi || (xi == B[lft ? hi : lo] && !include_lowest)
            continue
        end
        while hi - lo >= 2
            new = (hi + lo) ÷ 2
            if xi > B[new] || (lft && xi == B[new])
                lo = new
            else
                hi = new
            end
        end
        out[i] = lo
    end
    out
end

"""
    cut(x, breaks; labels = nothing, include_lowest = false, right = true, dig_lab = 3, ordered_result = false)

`cut.default`; `labels = false` liefert die Codes (Int, NA → missing), sonst
einen Faktor (SimLev.RFmt.RFactor) mit R's Beschriftungen.
"""
function cut(x, breaks; labels = nothing, include_lowest::Bool = false, right::Bool = true, dig_lab::Int = 3,
             ordered_result::Bool = false)
    xv = _v(x)
    br = _v(breaks)
    if length(br) == 1
        b0 = br[1]
        (isnan(b0) || b0 < 2) && error("invalid number of intervals")
        nb = trunc(Int, b0 + 1)
        ok = filter(!isnan, xv)
        rx = isempty(ok) ? (Inf, -Inf) : (minimum(ok), maximum(ok))
        dx = rx[2] - rx[1]
        if dx == 0
            dx = rx[1] != 0 ? abs(rx[1]) : 1.0
            br = seq_len_out(rx[1] - dx / 1000, rx[2] + dx / 1000, nb)
        else
            br = seq_len_out(rx[1], rx[2], nb)
            br[1] = rx[1] - dx / 1000
            br[nb] = rx[2] + dx / 1000
        end
    else
        br = br[_stable_argsort(br, false, false)]
        nb = length(br)
    end
    length(unique(_z0.(br))) < length(br) && error("'breaks' are not unique")
    codes_only = false
    if labels === nothing
        ok = false
        ch = String[]
        for dig in dig_lab:max(12, dig_lab)
            ch = collect(String, SimLev.RFmt.formatC(0.0 .+ br; digits = dig, width = 1))
            ok = all(i -> ch[i+1] != ch[i], 1:length(ch)-1)
            ok && break
        end
        if ok
            labs = [(right ? "(" : "[") * ch[i] * "," * ch[i+1] * (right ? "]" : ")") for i in 1:nb-1]
            if include_lowest
                if right
                    labs[1] = "[" * labs[1][2:end]
                else
                    labs[end] = labs[end][1:end-1] * "]"
                end
            end
        else
            labs = ["Range_$i" for i in 1:nb-1]
        end
    elseif labels === false
        codes_only = true
        labs = String[]
    else
        labs = [string(s) for s in labels]
        length(labs) != nb - 1 && error("number of intervals and length of 'labels' differ")
    end
    code = _bincode(xv, br, right, include_lowest)
    if codes_only
        any(==(0), code) && return _vec_out(Union{Missing,Int}[c == 0 ? missing : c for c in code])
        return _vec_out(code)
    end
    return SimLev.RFmt.RFactor(code, labs; ordered = ordered_result)
end

function _isok_el(v)
    v === missing && return false
    v === nothing && return false
    v isa AbstractFloat && return !isnan(v)
    return true
end

"`complete.cases(...)` für Vektoren, Matrizen und data.frames."
function complete_cases(args...)
    n = -1
    ok = Bool[]
    for a in args
        cols = if a isa RFrame
            collect(a.cols)
        elseif a isa NamedMat
            [a.data[:, j] for j in 1:size(a.data, 2)]
        elseif a isa AbstractMatrix
            [a[:, j] for j in 1:size(a, 2)]
        elseif a isa RVector
            [a.values]
        elseif a isa AbstractVector && !isempty(a) && first(a) isa AbstractVector
            collect(a)
        elseif a isa AbstractVector
            [a]
        else
            [[a]]
        end
        for c in cols
            m = Bool[_isok_el(v) for v in c]
            if n < 0
                n = length(m)
                ok = copy(m)
            else
                length(m) != n && error("not all arguments have the same length")
                ok .&= m
            end
        end
    end
    n < 0 && error("no input has determined the number of cases")
    return ok
end

# ── Lage- und Streuungsmaße ──────────────────────────────────────────────

function _format_perc(probs::Vector{Float64}, digits::Int = 7)
    x = 100 .* probs
    isempty(x) && return String[]
    s = length(x) < 100 ? SimLev.RFmt.formatC(x; format = "fg", width = 1, digits = digits) :
        SimLev.RFmt.format(x; trim = true, digits = digits)
    s = s isa AbstractString ? [s] : collect(s)
    return [isnan(xi) ? "" : string(si) * "%" for (si, xi) in zip(s, x)]
end

# R's partielle Sortierung (sort.default(x, partial =)): bis 10 Indizes
# psort (rPsort2/Psort0), sonst R_qsort (Singleton). Für Werte, die sich nur im
# Vorzeichen der Null unterscheiden, hängt das Ergebnis vom Verfahren ab.

@inline _rcmp(a::Float64, b::Float64) = a < b ? -1 : a > b ? 1 : 0

function _rpsort2!(x, lo::Int, hi::Int, k::Int)       # 0-basierte Indizes über _Off
    L, R = lo, hi
    while L < R
        v = x[k]
        i, j = L, R
        while i <= j
            while _rcmp(x[i], v) < 0
                i += 1
            end
            while _rcmp(v, x[j]) < 0
                j -= 1
            end
            if i <= j
                t = x[i]; x[i] = x[j]; x[j] = t
                i += 1
                j -= 1
            end
        end
        j < k && (L = i)
        k < i && (R = j)
    end
    nothing
end

function _psort0!(x, lo::Int, hi::Int, ind::AbstractVector{Int})
    nind = length(ind)
    (nind < 1 || hi - lo < 1) && return nothing
    if nind <= 1
        _rpsort2!(x, lo, hi, ind[1] - 1)
        return nothing
    end
    this = 1
    mid = (lo + hi) ÷ 2
    for i in 1:nind
        ind[i] - 1 <= mid && (this = i)
    end
    z = ind[this] - 1
    _rpsort2!(x, lo, hi, z)
    _psort0!(x, lo, z - 1, view(ind, 1:this-1))
    _psort0!(x, z + 1, hi, view(ind, this+1:nind))
    nothing
end

"R_qsort(v, 1, n) (Singleton 1969, R's qsort-body.c), in place (1-basiert)."
function _r_qsort!(v::Vector{Float64})
    n = length(v)
    n < 2 && return nothing
    il = zeros(Int, 40); iu = zeros(Int, 40)
    R = 0.375
    i, j = 1, n
    ii = i
    m = 1
    k = 0; l = 0; ij = 0
    vt = 0.0; vtt = 0.0
    state = :L10
    while true
        if state === :L10
            if i < j
                if R < 0.5898437
                    R += 0.0390625
                else
                    R -= 0.21875
                end
                state = :L20
            else
                state = :L80
            end
        elseif state === :L20
            k = i
            ij = trunc(Int, i + trunc(Int, (j - i) * R))
            vt = v[ij]
            if v[i] > vt
                v[ij] = v[i]; v[i] = vt; vt = v[ij]
            end
            l = j
            if v[j] < vt
                v[ij] = v[j]; v[j] = vt; vt = v[ij]
                if v[i] > vt
                    v[ij] = v[i]; v[i] = vt; vt = v[ij]
                end
            end
            while true
                l -= 1
                while v[l] > vt
                    l -= 1
                end
                vtt = v[l]
                k += 1
                while v[k] < vt
                    k += 1
                end
                k > l && break
                v[l] = v[k]
                v[k] = vtt
            end
            m += 1
            if l - i <= j - k
                il[m] = k; iu[m] = j; j = l
            else
                il[m] = i; iu[m] = l; i = k
            end
            state = :L90
        elseif state === :L80
            m == 1 && break
            i = il[m]; j = iu[m]; m -= 1
            state = :L90
        elseif state === :L90
            if j - i > 10
                state = :L20
            elseif i == ii
                state = :L10
            else
                i -= 1
                state = :L100
            end
        elseif state === :L100
            while true
                i += 1
                i == j && break
                vt = v[i+1]
                v[i] <= vt || break
            end
            if i == j
                state = :L80
                continue
            end
            k = i
            while true
                v[k+1] = v[k]
                k -= 1
                vt < v[k] || break
            end
            v[k+1] = vt
            state = :L100
        end
    end
    nothing
end

"`sort(x, partial = partial)` für Doubles ohne NA wie R (1-basierte Indizes)."
function sort_partial(x, partial)
    v = collect(Float64, _v(x))
    praw = Int[trunc(Int, t) for t in _v(partial)]
    if length(praw) <= 10
        _psort0!(_Off(v, 1), 0, length(v) - 1, sort(praw))
    else
        _r_qsort!(v)
    end
    return v
end

"unique() für Doubles (Reihenfolge des ersten Auftretens; −0 = +0)."
function _r_unique(a)
    out = Float64[]
    for t in a
        if isnan(t)
            any(isnan, out) || push!(out, t)
        else
            any(u -> u == t, out) || push!(out, t)
        end
    end
    out
end

const _QAB = Dict(4 => (0.0, 1.0), 5 => (0.5, 0.5), 6 => (0.0, 0.0), 7 => (1.0, 1.0),
                  8 => (1.0 / 3, 1.0 / 3), 9 => (3.0 / 8, 3.0 / 8))

"""
    quantile(x, probs = [0, .25, .5, .75, 1]; na_rm = false, names = true, type = 7, digits = 7)

`quantile.default` (Typen 1–9). Ergebnis: RVector mit Namen wie "25%" bzw.
bei `names = false` Vector (Länge 1: Skalar).
"""
function quantile(x, probs = [0.0, 0.25, 0.5, 0.75, 1.0]; na_rm::Bool = false, names::Bool = true,
                  type::Integer = 7, digits::Integer = 7)
    xv = _v(x)
    if na_rm
        xv = filter(!isnan, xv)
    elseif any(isnan, xv)
        error("missing values and NaN's not allowed if 'na.rm' is FALSE")
    end
    p = _v(probs)
    eps = 100 * _DBL_EPS
    pok = .!isnan.(p)
    any(i -> pok[i] && (p[i] < -eps || p[i] > 1 + eps), eachindex(p)) && error("'probs' outside [0,1]")
    n = length(xv)
    pp = Float64[isnan(t) ? t : max(0.0, min(1.0, t)) for t in p]
    np_ = length(pp)
    type = Int(type)
    if n == 0
        xs = copy(xv)
    elseif type == 7
        idx = 1 .+ max(n - 1, 0) .* pp
        cand = vcat(floor.(idx), ceil.(idx))[vcat(pok, pok)]
        xs = sort_partial(xv, _r_unique(cand))
    else
        if type <= 3
            nppm = type == 3 ? n .* pp .- 0.5 : n .* pp
            jv = floor.(nppm)
        else
            a, b = _QAB[type]
            jv = floor.(a .+ pp .* (n + 1 - a - b) .+ 4 * _DBL_EPS)
        end
        m1 = [pok[i] && jv[i] > 0 && jv[i] <= n for i in eachindex(jv)]
        m2 = [pok[i] && jv[i] > 0 && jv[i] < n for i in eachindex(jv)]
        part = _r_unique(vcat([1.0], jv[m1], (jv .+ 1)[m2], [Float64(n)]))
        xs = sort_partial(xv, part)
    end
    qs = fill(NA, np_)
    if n == 0
    elseif type == 7
        index = 1 .+ max(n - 1, 0) .* pp
        for k in 1:np_
            pok[k] || continue
            lo = floor(index[k]); hi = ceil(index[k])
            l = trunc(Int, lo); h = trunc(Int, hi)
            xl = 1 <= l <= n ? xs[l] : NaN
            xh = 1 <= h <= n ? xs[h] : NaN
            q = xl
            if index[k] > lo && xh != q
                hh = index[k] - lo
                q = (1 - hh) * q + hh * xh
            end
            qs[k] = q
        end
    else
        if type <= 3
            nppm = type == 3 ? n .* pp .- 0.5 : n .* pp
            j = floor.(nppm)
            if type == 1
                h = Float64[(!pok[i] || nppm[i] > j[i]) ? 1.0 : 0.0 for i in eachindex(j)]
            elseif type == 2
                h = Float64[((nppm[i] > j[i]) ? 1.0 : 0.0) + 1 for i in eachindex(j)] ./ 2
            else
                h = Float64[(!pok[i] || nppm[i] != j[i] || mod(j[i], 2.0) == 1.0) ? 1.0 : 0.0 for i in eachindex(j)]
            end
        else
            a, b = _QAB[type]
            fuzz = 4 * _DBL_EPS
            nppm = a .+ pp .* (n + 1 - a - b)
            j = floor.(nppm .+ fuzz)
            h = nppm .- j
            h = Float64[(abs(t) < fuzz && !isnan(t)) ? 0.0 : t for t in h]
        end
        xx = n > 0 ? vcat(xs[1], xs[1], xs, xs[n], xs[n]) : fill(NaN, 4)
        for k in 1:np_
            jk = j[k]
            isnan(jk) && continue
            jj = trunc(Int, jk)
            i2 = jj + 2; i3 = jj + 3
            x2 = 1 <= i2 <= length(xx) ? xx[i2] : NaN
            x3 = 1 <= i3 <= length(xx) ? xx[i3] : NaN
            hk = h[k]
            q = x2
            (!isnan(hk) && hk == 1) && (q = x3)
            ca = isnan(hk) ? nothing : (0 < hk)
            cb = isnan(hk) ? nothing : (hk < 1)
            cc = (isnan(x2) || isnan(x3)) ? nothing : (x2 != x3)
            other = !(ca === false || cb === false || cc === false)
            other && (q = (1 - hk) * x2 + hk * x3)
            qs[k] = q
        end
    end
    qs = Float64[pok[i] ? qs[i] : p[i] for i in eachindex(qs)]
    (names && np_ > 0) && return RVector(qs; names = _format_perc(pp, Int(digits)))
    return _vec_out(qs)
end

"`median.default(x, na.rm)`."
function median(x; na_rm::Bool = false)
    is_int = _is_int_like(x)
    xv = _v(x)
    if na_rm
        xv = filter(!isnan, xv)
    elseif any(isnan, xv)
        return is_int ? missing : NA
    end
    n = length(xv)
    n == 0 && return is_int ? missing : NA
    half = (n + 1) ÷ 2
    s = is_int ? sort(xv) : sort_partial(xv, isodd(n) ? [half] : [half, half + 1])
    if isodd(n)
        v = s[half]
        return is_int ? Int(v) : v
    end
    pair = s[half:half+1]
    is_int && return _rmean_int(Int.(pair))
    return _rmean(pair)
end

"`weighted.mean(x, w, na.rm)`."
function weighted_mean(x, w = nothing; na_rm::Bool = false)
    xv = _v(x)
    if w === nothing
        na_rm && (xv = filter(!isnan, xv))
        return _rsum(xv) / Float64(length(xv))
    end
    wv = _v(w)
    length(wv) != length(xv) && error("'x' and 'w' must have the same length")
    if na_rm
        i = .!isnan.(xv)
        wv = wv[i]; xv = xv[i]
    end
    prod = [xv[i] * wv[i] for i in eachindex(xv) if wv[i] != 0]
    return _rsum(prod) / _rsum(wv)
end

# ── cov / cor (cov.c) ────────────────────────────────────────────────────

const _USE = ["all.obs", "complete.obs", "pairwise.complete.obs", "everything", "na.or.complete"]

function _pmatch_use(use::AbstractString)
    hits = [i for (i, u) in enumerate(_USE) if startswith(u, use)]
    if length(hits) != 1
        use in _USE && return findfirst(==(use), _USE)
        error("invalid 'use' argument")
    end
    return hits[1]
end

_fmat(m::AbstractMatrix) = Float64[_fl(v) for v in m]

"→ (Matrix n×nc, ist_Matrix, Spaltennamen)."
function _as_cov_input(x)
    x isa RFrame && return (hcat([Float64[_fl(v) for v in c] for c in x.cols]...)::Matrix{Float64}, true, names(x))
    x isa NamedMat && return (_fmat(x.data), true, x.colnames)
    x isa AbstractMatrix && return (_fmat(x), true, nothing)
    v = _v(x)
    return (reshape(v, :, 1), false, nothing)
end
_is_matlike(x) = x isa RFrame || x isa AbstractMatrix

"MEAN-Makro: zwei Durchläufe in long double; Ergebnis double."
function _mean_ld(col::AbstractVector{Float64})
    nobs = length(col)
    s = _LD0
    for v in col
        s = s + F80(v)
    end
    tmp = s / F80(nobs)
    if isfinite(Float64(tmp))
        s2 = _LD0
        for v in col
            s2 = s2 + (F80(v) - tmp)
        end
        tmp = tmp + s2 / F80(nobs)
    end
    return Float64(tmp)
end

"sum (LD)(a - am) * (b - bm)."
function _ld_cross(a, am::Float64, b, bm::Float64)
    s = _LD0
    lam = F80(am); lbm = F80(bm)
    @inbounds for i in eachindex(a)
        s = s + (F80(a[i]) - lam) * (F80(b[i]) - lbm)
    end
    s
end

@inline _isign(d::Float64) = d > 0 ? 1 : d < 0 ? -1 : 0

function _kendall_sum(xx, yy)
    n = length(xx)
    tot = 0
    @inbounds for k in 1:n, j in 1:n
        tot += _isign(xx[k] - xx[j]) * _isign(yy[k] - yy[j])
    end
    Float64(tot)
end

function _kendall_count_ne(xx)
    n = length(xx)
    tot = 0
    @inbounds for k in 1:n, j in 1:n
        xx[k] != xx[j] && (tot += 1)
    end
    Float64(tot)
end

_clamp1(v::Float64) = v >= 1.0 ? 1.0 : (v <= -1.0 ? -1.0 : v)

function _cov_complete1!(X, ind, ans, sd0, cor, kendall)
    n, ncx = size(X)
    nobs = count(ind)
    if nobs <= 1
        fill!(ans, NA)
        return
    end
    Xi = X[ind, :]
    xm = zeros(ncx)
    kendall || (for i in 1:ncx; xm[i] = _mean_ld(view(Xi, :, i)); end)
    n1 = nobs - 1
    for i in 1:ncx, j in 1:i
        if !kendall
            s = _ld_cross(view(Xi, :, i), xm[i], view(Xi, :, j), xm[j])
            ans[i, j] = ans[j, i] = Float64(s / F80(n1))
        else
            ans[i, j] = ans[j, i] = _kendall_sum(view(Xi, :, i), view(Xi, :, j))
        end
    end
    if cor
        for i in 1:ncx
            xm[i] = _csqrt(ans[i, i])
        end
        for i in 1:ncx
            for j in 1:i-1
                if xm[i] == 0 || xm[j] == 0
                    sd0[] = true
                    ans[i, j] = ans[j, i] = NA
                else
                    ans[i, j] = ans[j, i] = _clamp1(ans[i, j] / (xm[i] * xm[j]))
                end
            end
            ans[i, i] = 1.0
        end
    end
end

function _cov_na_1!(X, has_na, ans, sd0, cor, kendall)
    n, ncx = size(X)
    if n <= 1
        fill!(ans, NA)
        return
    end
    xm = fill(NaN, ncx)
    if !kendall
        for i in 1:ncx
            xm[i] = has_na[i] ? NA : _mean_ld(view(X, :, i))
        end
    end
    n1 = n - 1
    for i in 1:ncx
        if has_na[i]
            for j in 1:i
                ans[i, j] = NA; ans[j, i] = NA
            end
            continue
        end
        for j in 1:i
            if has_na[j]
                ans[i, j] = ans[j, i] = NA
            elseif !kendall
                ans[i, j] = ans[j, i] = Float64(_ld_cross(view(X, :, i), xm[i], view(X, :, j), xm[j]) / F80(n1))
            else
                ans[i, j] = ans[j, i] = _kendall_sum(view(X, :, i), view(X, :, j))
            end
        end
    end
    if cor
        for i in 1:ncx
            has_na[i] || (xm[i] = _csqrt(ans[i, i]))
        end
        for i in 1:ncx
            if !has_na[i]
                for j in 1:i-1
                    if xm[i] == 0 || xm[j] == 0
                        sd0[] = true
                        ans[i, j] = ans[j, i] = NA
                    else
                        ans[i, j] = ans[j, i] = _clamp1(ans[i, j] / (xm[i] * xm[j]))
                    end
                end
            end
            ans[i, i] = 1.0
        end
    end
end

"COV_SDEV aus cov_complete2/cov_na_2: (double) SQRTL(sum)."
function _sdev2(col, m, n1, kendall)
    s = kendall ? F80(_kendall_count_ne(col)) : _ld_cross(col, m, col, m) / F80(n1)
    return Float64(_ldsqrt(s))
end

function _cov_complete2!(X, Y, ind, ans, sd0, cor, kendall)
    ncx = size(X, 2); ncy = size(Y, 2)
    nobs = count(ind)
    if nobs <= 1
        fill!(ans, NA)
        return
    end
    Xi = X[ind, :]; Yi = Y[ind, :]
    xm = zeros(ncx); ym = zeros(ncy)
    n1 = nobs - 1
    if !kendall
        for i in 1:ncx; xm[i] = _mean_ld(view(Xi, :, i)); end
        for i in 1:ncy; ym[i] = _mean_ld(view(Yi, :, i)); end
    end
    for i in 1:ncx, j in 1:ncy
        if !kendall
            ans[i, j] = Float64(_ld_cross(view(Xi, :, i), xm[i], view(Yi, :, j), ym[j]) / F80(n1))
        else
            ans[i, j] = _kendall_sum(view(Xi, :, i), view(Yi, :, j))
        end
    end
    if cor
        xs = [_sdev2(view(Xi, :, i), xm[i], n1, kendall) for i in 1:ncx]
        ys = [_sdev2(view(Yi, :, j), ym[j], n1, kendall) for j in 1:ncy]
        for i in 1:ncx, j in 1:ncy
            if xs[i] == 0.0 || ys[j] == 0.0
                sd0[] = true
                ans[i, j] = NA
            else
                ans[i, j] = _clamp1(ans[i, j] / (xs[i] * ys[j]))
            end
        end
    end
end

function _cov_na_2!(X, Y, hx, hy, ans, sd0, cor, kendall)
    n, ncx = size(X); ncy = size(Y, 2)
    if n <= 1
        fill!(ans, NA)
        return
    end
    xm = zeros(ncx); ym = zeros(ncy)
    n1 = n - 1
    if !kendall
        for i in 1:ncx; xm[i] = hx[i] ? NA : _mean_ld(view(X, :, i)); end
        for i in 1:ncy; ym[i] = hy[i] ? NA : _mean_ld(view(Y, :, i)); end
    end
    for i in 1:ncx
        if hx[i]
            ans[i, :] .= NA
            continue
        end
        for j in 1:ncy
            if hy[j]
                ans[i, j] = NA
            elseif !kendall
                ans[i, j] = Float64(_ld_cross(view(X, :, i), xm[i], view(Y, :, j), ym[j]) / F80(n1))
            else
                ans[i, j] = _kendall_sum(view(X, :, i), view(Y, :, j))
            end
        end
    end
    if cor
        xs = [hx[i] ? NA : _sdev2(view(X, :, i), xm[i], n1, kendall) for i in 1:ncx]
        ys = [hy[j] ? NA : _sdev2(view(Y, :, j), ym[j], n1, kendall) for j in 1:ncy]
        for i in 1:ncx
            hx[i] && continue
            for j in 1:ncy
                hy[j] && continue
                if xs[i] == 0.0 || ys[j] == 0.0
                    sd0[] = true
                    ans[i, j] = NA
                else
                    ans[i, j] = _clamp1(ans[i, j] / (xs[i] * ys[j]))
                end
            end
        end
    end
end

function _cov_pairwise!(X, Y, ans, sd0, cor, kendall, sym)
    ncx = size(X, 2); ncy = size(Y, 2)
    for i in 1:ncx
        for j in (sym ? (1:i) : (1:ncy))
            xx = view(X, :, i); yy = view(Y, :, j)
            ok = .!(isnan.(xx) .| isnan.(yy))
            nobs = count(ok)
            if nobs >= 2
                xo = xx[ok]; yo = yy[ok]
                n1 = nobs - 1
                if !kendall
                    xmean = _ldsum(xo) / F80(nobs)
                    ymean = _ldsum(yo) / F80(nobs)
                    s = _LD0; xsd = _LD0; ysd = _LD0
                    for k in 1:nobs
                        xmd = F80(xo[k]) - xmean
                        ymd = F80(yo[k]) - ymean
                        s = s + xmd * ymd
                        xsd = xsd + xmd * xmd
                        ysd = ysd + ymd * ymd
                    end
                else
                    s = _LD0; xsd = _LD0; ysd = _LD0
                    for k in 1:nobs
                        t1 = 0; t2 = 0; t3 = 0
                        for l in 1:k-1
                            sx = _isign(xo[k] - xo[l]); sy = _isign(yo[k] - yo[l])
                            t1 += sx * sy; t2 += sx * sx; t3 += sy * sy
                        end
                        s = s + F80(t1); xsd = xsd + F80(t2); ysd = ysd + F80(t3)
                    end
                end
                if cor
                    if _ldiszero(xsd) || _ldiszero(ysd)
                        sd0[] = true
                        val = NA
                    else
                        if !kendall
                            xsd = xsd / F80(n1); ysd = ysd / F80(n1); s = s / F80(n1)
                        end
                        s = s / (_ldsqrt(xsd) * _ldsqrt(ysd))
                        c1 = _ldcmp(s, F80(1.0)); c2 = _ldcmp(s, F80(-1.0))
                        s = (c1 == 0 || c1 == 1) ? F80(1.0) : ((c2 == 0 || c2 == -1) ? F80(-1.0) : s)
                        val = Float64(s)
                    end
                elseif !kendall
                    val = Float64(s / F80(n1))
                else
                    val = Float64(s)
                end
                ans[i, j] = val
            else
                ans[i, j] = NA
            end
            sym && (ans[j, i] = ans[i, j])
        end
    end
end

function _corcov(x, y, method_na::Int, kendall::Bool, cor::Bool)
    X, xmat, xcn = _as_cov_input(x)
    n, ncx = size(X)
    ansmat = xmat
    if y === nothing
        Y = nothing; ncy = ncx; ycn = nothing
    else
        Y, ymat, ycn = _as_cov_input(y)
        size(Y, 1) != n && error("incompatible dimensions")
        ymat && (ansmat = true)
        ncy = size(Y, 2)
    end
    na_fail = false; everything = false; empty_err = true; pair = false
    if method_na == 1
        na_fail = true
    elseif method_na == 2
        isempty(X) && error("no complete element pairs")
    elseif method_na == 3
        pair = true
    elseif method_na == 4
        everything = true; empty_err = false
    elseif method_na == 5
        empty_err = false
    else
        error("invalid 'use' (computational method)")
    end
    (empty_err && isempty(X)) && error("'x' is empty")
    ans = fill(NA, ncx, ncy)
    sd0 = Ref(false)
    hasna(M) = Bool[n > 0 && any(isnan, view(M, :, j)) for j in 1:size(M, 2)]
    function complete(X, Y)
        ind = Bool[!any(isnan, view(X, i, :)) for i in 1:size(X, 1)]
        Y === nothing || (ind .&= Bool[!any(isnan, view(Y, i, :)) for i in 1:size(Y, 1)])
        (na_fail && !all(ind)) && error("missing observations in cov/cor")
        ind
    end
    if Y === nothing
        if everything
            _cov_na_1!(X, hasna(X), ans, sd0, cor, kendall)
        elseif !pair
            ind = complete(X, nothing)
            _cov_complete1!(X, ind, ans, sd0, cor, kendall)
            (empty_err && !any(ind)) && error("no complete element pairs")
        else
            _cov_pairwise!(X, X, ans, sd0, cor, kendall, true)
        end
    else
        if everything
            _cov_na_2!(X, Y, hasna(X), hasna(Y), ans, sd0, cor, kendall)
        elseif !pair
            ind = complete(X, Y)
            _cov_complete2!(X, Y, ind, ans, sd0, cor, kendall)
            (empty_err && !any(ind)) && error("no complete element pairs")
        else
            _cov_pairwise!(X, Y, ans, sd0, cor, kendall, false)
        end
    end
    sd0[] && @warn "the standard deviation is zero"
    if ansmat
        return y === nothing ? _out(ans, xcn, xcn) : _out(ans, xcn, ycn)
    end
    return _vec_out(vec(ans))
end

function _rank_cols(u)
    X, ismat, cn = _as_cov_input(u)
    isempty(X) && return u
    if ismat
        nr, nc = size(X)
        R = nr > 1 ? hcat([Float64[_fl(t) for t in _ranks_keep(X[:, j])] for j in 1:nc]...) :
            Float64[i for i in 1:nr, j in 1:nc]
        rn = u isa RFrame ? u.rownames : u isa NamedMat ? u.rownames : nothing
        return _out(R, rn, cn)
    end
    return Float64[_fl(t) for t in _ranks_keep(vec(X))]
end
function _ranks_keep(v)
    r = r_rank(v; na_last = "keep")
    r isa RVector ? r.values : r isa AbstractVector ? r : [r]
end

function _drop_rows(x, keep::AbstractVector{Bool})
    x isa RFrame && return SimLev.rows(x, keep)
    x isa NamedMat && return NamedMat(x.data[keep, :]; rownames = x.rownames === nothing ? nothing : x.rownames[keep],
                                      colnames = x.colnames)
    x isa AbstractMatrix && return x[keep, :]
    x isa RVector && return RVector(x.values[keep]; names = x.names === nothing ? nothing : x.names[keep])
    return _v(x)[keep]
end
function _na_omit_rows(x)
    X, _, _ = _as_cov_input(x)
    keep = Bool[!any(isnan, view(X, i, :)) for i in 1:size(X, 1)]
    _drop_rows(x, keep)
end

function _cor_cov(x, y, use, method, cor::Bool)
    na_method = _pmatch_use(use)
    method in ("pearson", "kendall", "spearman") || error("'arg' should be one of “pearson”, “kendall”, “spearman”")
    (!_is_matlike(x) && y === nothing) && error("supply both 'x' and 'y' or a matrix-like 'x'")
    method == "pearson" && return _corcov(x, y, na_method, false, cor)
    kend = method == "kendall"
    if na_method in (2, 5)
        y === nothing && return _corcov(_rank_cols(_na_omit_rows(x)), nothing, na_method, kend, cor)
        X, _, _ = _as_cov_input(x)
        Y, _, _ = _as_cov_input(y)
        keep = Bool[!(any(isnan, view(X, i, :)) || any(isnan, view(Y, i, :))) for i in 1:size(X, 1)]
        return _corcov(_rank_cols(_drop_rows(x, keep)), _rank_cols(_drop_rows(y, keep)), na_method, kend, cor)
    end
    if na_method != 3
        return _corcov(_rank_cols(x), y === nothing ? nothing : _rank_cols(y), na_method, kend, cor)
    end
    cor || error("cannot handle 'pairwise.complete.obs'")
    X, xmat, xcn = _as_cov_input(x)
    rk(v) = (rr_ = r_rank(v); Float64[_fl(t) for t in (rr_ isa AbstractVector ? rr_ : [rr_])])
    if y === nothing
        ncx = size(X, 2)
        ncx == 0 && error("'x' is empty")
        r = zeros(ncx, ncx)
        for i in 1:ncx, j in 1:i
            x2 = X[:, i]; y2 = X[:, j]
            ok = .!(isnan.(x2) .| isnan.(y2))
            r[i, j] = any(ok) ? _corcov(rk(x2[ok]), rk(y2[ok]), 1, kend, true) : NA
        end
        if ncx == 1
            d = r[1, 1]
            isnan(d) && error("invalid 'nrow' value (too large or NA)")
            m = trunc(Int, d)
            m < 0 && error("invalid 'nrow' value (< 0)")
            m != 1 && error("non-conformable arrays")
            r = (r .+ r) .- 1.0
        else
            rt = permutedims(r)
            r = Float64[(r[i, j] + rt[i, j]) - (i == j ? r[i, i] : 0.0) for i in 1:ncx, j in 1:ncx]
        end
        return _out(r, xcn, xcn)
    end
    Y, ymat, ycn = _as_cov_input(y)
    (isempty(X) || isempty(Y)) && error("both 'x' and 'y' must be non-empty")
    r = zeros(size(X, 2), size(Y, 2))
    for i in 1:size(X, 2), j in 1:size(Y, 2)
        x2 = X[:, i]; y2 = Y[:, j]
        ok = .!(isnan.(x2) .| isnan.(y2))
        r[i, j] = any(ok) ? _corcov(rk(x2[ok]), rk(y2[ok]), 1, kend, true) : NA
    end
    (xmat || ymat) && return _out(r, xcn, ycn)
    return _vec_out(vec(r))
end

"`cor(x, y, use, method)`: pearson, kendall, spearman."
cor(x, y = nothing; use::AbstractString = "everything", method::AbstractString = "pearson") = _cor_cov(x, y, use, method, true)
"`cov(x, y, use, method)`."
cov(x, y = nothing; use::AbstractString = "everything", method::AbstractString = "pearson") = _cor_cov(x, y, use, method, false)

"`var(x, y, na.rm, use)`."
function var(x, y = nothing; na_rm::Bool = false, use = nothing)
    use === nothing && (use = na_rm ? "na.or.complete" : "everything")
    return _corcov(x, y, _pmatch_use(use), false, false)
end

"`sd(x, na.rm)` = `sqrt(var(x, na.rm))`."
function sd(x; na_rm::Bool = false)
    x = _is_matlike(x) ? _v(x) : x
    v = var(x; na_rm = na_rm)
    return isnan(v) ? v : _csqrt(v)
end

"`cov2cor(V)`."
function cov2cor(V)
    X, ismat, cn = _as_cov_input(V)
    (ismat && size(X, 1) == size(X, 2)) || error("'V' is not a square numeric matrix")
    rn = V isa NamedMat ? V.rownames : V isa RFrame ? V.rownames : nothing
    p = size(X, 1)
    D = [X[i, i] for i in 1:p]
    pos = [!isnan(d) && d > 0 for d in D]
    Is = [pos[i] ? sqrt(1.0 / D[i]) : NaN for i in 1:p]
    (any(.!pos) || any(!isfinite, Is)) && @warn "diag(V) had non-positive or NA entries; the non-finite result may be dubious"
    r = Matrix{Float64}(undef, p, p)
    for j in 1:p, i in 1:p
        v = (Is[i] * X[i, j]) * Is[j]
        # R: Ergebnis genau dann NA, wenn V[i,j] NA ist; jedes andere NaN ist NaN
        isnan(v) && (v = isna_strict(X[i, j]) ? NA : NaN)
        r[i, j] = v
    end
    for i in 1:p
        r[i, i] = 1.0
    end
    return _out(r, rn, cn)
end

function _colmean_narm(col)
    ok = filter(!isnan, col)
    isempty(ok) && return NaN
    return Float64(_ldsum(ok) / F80(length(ok)))
end

"""
    scale(x; center = true, scale = true)

`scale.default(x, center, scale)`: NamedMat mit den Attributen
"scaled:center" und "scaled:scale" (`attrs(m)`).
"""
function scale(x; center = true, scale = true)
    X, _, cn = _as_cov_input(x)
    X = copy(X)
    rn = x isa NamedMat ? x.rownames : x isa RFrame ? x.rownames : x isa RVector ? x.names : nothing
    nc = size(X, 2)
    cen = nothing; sc = nothing
    if center isa Bool
        if center
            cen = [_colmean_narm(X[:, j]) for j in 1:nc]
            X = X .- permutedims(cen)
        end
    else
        cen = _v(center)
        length(cen) != nc && error("length of 'center' must equal the number of columns of 'x'")
        X = X .- permutedims(cen)
    end
    if scale isa Bool
        if scale
            sc = zeros(nc)
            for j in 1:nc
                v = filter(!isnan, X[:, j])
                sc[j] = _csqrt(_rsum(v .* v) / max(1, length(v) - 1))
            end
            X = X ./ permutedims(sc)
        end
    else
        sc = _v(scale)
        length(sc) != nc && error("length of 'scale' must equal the number of columns of 'x'")
        X = X ./ permutedims(sc)
    end
    at = Dict{String,Any}()
    cen === nothing || (at["scaled:center"] = _vec_out(cen, cn))
    sc === nothing || (at["scaled:scale"] = _vec_out(sc, cn))
    return NamedMat(X; rownames = rn, colnames = cn, attrs = at)
end

# ── approx / approxfun / filter ──────────────────────────────────────────

"Gleiche Werte (−0 = +0, NaN als ein Wert) in Reihenfolge des ersten Auftretens."
function _unique_keys(v::Vector{Float64})
    keys = Float64[]
    idx = Int[]
    d = Dict{Float64,Int}()
    nanidx = 0
    for t in v
        if isnan(t)
            if nanidx == 0
                push!(keys, t); nanidx = length(keys)
            end
            push!(idx, nanidx)
        else
            k = _z0(t)
            g = get(d, k, 0)
            if g == 0
                push!(keys, t); g = length(keys); d[k] = g
            end
            push!(idx, g)
        end
    end
    keys, idx
end

function _regularize(x, y, ties, warn_collapsing::Bool, na_rm::Bool)
    xv = _v(x)
    if y === nothing
        yv = xv
        xv = Float64.(1:length(yv))
    else
        yv = _v(y)
    end
    length(xv) != length(yv) && error("'x' and 'y' lengths differ")
    kept_na = false
    na = isnan.(xv) .| isnan.(yv)
    ok = .!na
    if any(na)
        if na_rm
            xv = xv[ok]; yv = yv[ok]
            nx = length(xv)
        else
            kept_na = true
            nx = count(ok)
        end
    else
        nx = length(xv)
    end
    ordered = false
    fun = ties
    if ties isa AbstractString && ties == "ordered"
        ordered = true
        fun = nothing
    elseif ties isa Tuple && length(ties) == 2 && ties[2] isa Function
        fun = ties[2]
        ordered = ties[1] == "ordered"
    end
    if !(ties isa AbstractString && ties == "ordered")
        xx = kept_na ? xv[ok] : xv
        if !ordered && length(xx) > 1 && any(i -> xx[i+1] < xx[i], 1:length(xx)-1)
            o = _nan_last_perm(xv)
            xv = xv[o]; yv = yv[o]
        end
        ux, gidx = _unique_keys(xv)
        if length(ux) < nx
            warn_collapsing && @warn "collapsing to unique 'x' values"
            f = (fun === nothing || fun === _rmean || fun == "mean") ? _rmean : fun
            groups = [Float64[] for _ in ux]
            for (g, yi) in zip(gidx, yv)
                push!(groups[g], yi)
            end
            yv = Float64[Float64(first(_v(f(gr)))) for gr in groups]
            xv = ux
            kept_na && (ok = .!isnan.(xv))
        end
    end
    return xv, yv, kept_na, (kept_na ? ok : nothing)
end

"Stabile aufsteigende Permutation, NaN zuletzt (wie numpy argsort, kind = stable)."
function _nan_last_perm(v::Vector{Float64})
    ok = findall(!isnan, v)
    bad = findall(isnan, v)
    vcat(ok[_stable_argsort(v[ok], false, false)], bad)
end

function _approx_core(x::Vector{Float64}, y::Vector{Float64}, v::Vector{Float64}, method::Int,
                      yleft::Float64, yright::Float64, f::Float64)
    n = length(x)
    out = Vector{Float64}(undef, length(v))
    if n == 0
        fill!(out, NaN)
        return out
    end
    f2 = f
    f1 = 1 - f
    for (k, vk) in enumerate(v)
        if isnan(vk)
            out[k] = vk
            continue
        end
        i = 1
        j = n
        if vk < x[i]
            out[k] = yleft; continue
        end
        if vk > x[j]
            out[k] = yright; continue
        end
        while i < j - 1
            ij = (i + j) ÷ 2
            if vk < x[ij]
                j = ij
            else
                i = ij
            end
        end
        if vk == x[j]
            out[k] = y[j]; continue
        end
        if vk == x[i]
            out[k] = y[i]; continue
        end
        if method == 1
            out[k] = y[i] + (y[j] - y[i]) * ((vk - x[i]) / (x[j] - x[i]))
        else
            out[k] = (f1 != 0.0 ? y[i] * f1 : 0.0) + (f2 != 0.0 ? y[j] * f2 : 0.0)
        end
    end
    out
end

function _approx_setup(x, y, method, yleft, yright, rule, f::Float64, ties, na_rm::Bool, ties_missing::Bool)
    meths = [("linear", 1), ("constant", 2)]
    m = isempty(method) ? Int[] : [v for (k, v) in meths if startswith(k, method)]
    length(m) != 1 && error("invalid interpolation method")
    method = m[1]
    rule = collect(_v(rule))
    length(rule) == 1 && (rule = [rule[1], rule[1]])
    xv, yv, kept_na, notna = _regularize(x, y, ties, ties_missing, na_rm)
    nona = na_rm || !kept_na
    nx = nona ? length(xv) : count(notna)
    if nx <= 1
        method == 1 && error("need at least two non-NA values to interpolate")
        nx == 0 && error("zero non-NA points")
    end
    yleft === nothing && (yleft = rule[1] == 1 ? NA : yv[1])
    yright === nothing && (yright = rule[2] == 1 ? NA : yv[end])
    if method == 2
        (!isfinite(f) || f < 0 || f > 1) && error("approx(): invalid f value")
    end
    if na_rm
        (any(isnan, xv) || any(isnan, yv)) && error("approx(): attempted to interpolate NA values")
    else
        any(isnan, xv) && error("approx(x,y, .., na.rm=FALSE): NA values in x are not allowed")
    end
    return xv, yv, method, Float64(yleft), Float64(yright), nona, notna, nx
end

"""
    approx(x, y = nothing; xout = nothing, method = "linear", n = 50, yleft, yright, rule = 1, f = 0, ties = nothing, na_rm = true)

`approx(...)`; `ties = nothing` entspricht R's Voreinstellung `mean` (mit
Warnung beim Zusammenfassen); auch "ordered", eine Funktion oder
`("ordered", fun)`. Ergebnis: RList mit `x` und `y`.
"""
function approx(x, y = nothing; xout = nothing, method::AbstractString = "linear", n::Integer = 50, yleft = nothing,
                yright = nothing, rule = 1, f::Real = 0, ties = nothing, na_rm::Bool = true)
    ties_missing = ties === nothing
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(x, y, method, yleft, yright, rule, Float64(f),
                                                         ties === nothing ? _rmean : ties, na_rm, ties_missing)
    if xout === nothing
        n <= 0 && error("'approx' requires n >= 1")
        if nona
            xo = seq_len_out(xv[1], xv[nx], n)
        else
            xs = xv[notna]
            xo = seq_len_out(xs[1], xs[end], n)
        end
    else
        xo = _v(xout)
    end
    yo = _approx_core(xv, yv, xo, meth, yl, yr, Float64(f))
    xres = xout === nothing ? _vec_out(xo) : (xout isa Real ? Float64(xout) : xout)
    return RList("x" => xres, "y" => (xout isa Real ? yo[1] : _vec_out(yo)))
end

"Interpolationsfunktion aus `approxfun()`/`ecdf()`; aufrufbar `f(v)`."
struct ApproxFun <: Function
    x::Vector{Float64}
    y::Vector{Float64}
    method::Int
    yleft::Float64
    yright::Float64
    f::Float64
    attrs::Dict{String,Any}
end
function (F::ApproxFun)(v)
    out = _approx_core(F.x, F.y, _v(v), F.method, F.yleft, F.yright, F.f)
    v isa Real && return out[1]
    return _vec_out(out)
end
SimLev.attrs(F::ApproxFun) = F.attrs

"`approxfun(...)`: liefert eine aufrufbare Funktion `v -> y` (ApproxFun mit x, y)."
function approxfun(x, y = nothing; method::AbstractString = "linear", yleft = nothing, yright = nothing, rule = 1,
                   f::Real = 0, ties = nothing, na_rm::Bool = true)
    ties_missing = ties === nothing
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(x, y, method, yleft, yright, rule, Float64(f),
                                                         ties === nothing ? _rmean : ties, na_rm, ties_missing)
    return ApproxFun(xv, yv, meth, yl, yr, Float64(f), Dict{String,Any}())
end

"`filter(x, filter, method, sides, circular, init)` (ohne ts-Attribute)."
function r_filter(x, filter; method::AbstractString = "convolution", sides::Integer = 2, circular::Bool = false,
                  init = nothing)
    meth = [m for m in ("convolution", "recursive") if startswith(m, method)]
    length(meth) != 1 && error("'arg' should be one of “convolution”, “recursive”")
    method = meth[1]
    is_mat = x isa AbstractMatrix || x isa RFrame
    X = is_mat ? _as_cov_input(x)[1] : reshape(_v(x), :, 1)
    n, nser = size(X)
    fv = _v(filter)
    nf = length(fv)
    any(isnan, fv) && error("missing values in 'filter'")
    Y = fill(NA, n, nser)
    isok(t) = !isnan(t)
    if method == "convolution"
        nf > n && error("'filter' is longer than time series")
        sides = Int(sides)
        sides in (1, 2) || error("argument 'sides' must be 1 or 2")
        nshift = sides == 2 ? nf ÷ 2 : 0
        for s in 1:nser
            xs = view(X, :, s)
            for i in 0:n-1
                if !circular
                    (i + nshift - (nf - 1) < 0 || i + nshift >= n) && continue
                end
                z = 0.0
                bad = false
                for j in 0:nf-1
                    ii = i + nshift - j
                    if circular
                        ii < 0 && (ii += n)
                        ii >= n && (ii -= n)
                    end
                    tmp = xs[ii+1]
                    if isok(tmp)
                        z += fv[j+1] * tmp
                    else
                        bad = true
                        break
                    end
                end
                Y[i+1, s] = bad ? NA : z
            end
        end
    else
        if init === nothing
            ini = zeros(nf, nser)
        else
            ia = init isa AbstractMatrix ? _fmat(init isa NamedMat ? init.data : init) : reshape(_v(init), :, 1)
            size(ia, 1) != nf && error("length of 'init' must equal length of 'filter'")
            ncol = size(ia, 2)
            if ncol != 1 && ncol != nser
                nser == 1 && error("'init' must have $nser column")
                error("'init' must have 1 or $nser columns")
            end
            ini = (ncol == 1 && nser > 1) ? repeat(ia, 1, nser) : ia
        end
        for s in 1:nser
            r = vcat(reverse(ini[:, s]), zeros(n))
            for i in 1:n
                sm = X[i, s]
                if !isok(sm)
                    r[nf+i] = NA
                    continue
                end
                badf = false
                for j in 1:nf
                    tmp = r[nf+i-j]
                    if isok(tmp)
                        sm += tmp * fv[j]
                    else
                        r[nf+i] = NA
                        badf = true
                        break
                    end
                end
                badf || (r[nf+i] = sm)
            end
            Y[:, s] = r[nf+1:end]
        end
    end
    is_mat && return Y
    return _vec_out(Y[:, 1])
end

# ── optimize / uniroot / optim ───────────────────────────────────────────

"Rückgabe einer Zielfunktion als double-Vektor (coerceVector)."
_num1(v) = v isa Number || v === missing ? Float64[_fl(v)] : _v(v)

"""
    optimize(f, interval = nothing, args...; lower, upper, maximum = false, tol = .Machine\$double.eps^0.25, kwargs...)

`optimize(f, interval, ..., lower, upper, maximum, tol)` (Brent fmin): RList
mit `minimum` (bzw. `maximum`) und `objective`.
"""
function optimize(f, interval = nothing, args...; lower = nothing, upper = nothing, maximum::Bool = false,
                  tol::Real = 0.0001220703125, kwargs...)
    lower === nothing && (lower = Base.minimum(_v(interval)))
    upper === nothing && (upper = Base.maximum(_v(interval)))
    lower = Float64(lower); upper = Float64(upper)
    seen = Set{String}()
    function fcn1(x)
        a = _num1(f(x, args...; kwargs...))
        length(a) != 1 && error("invalid function value in 'optimize'")
        v = maximum ? -a[1] : a[1]
        if !isfinite(v)
            _warn1!(seen, "NA/Inf replaced by maximum positive value")
            return _DBL_MAX
        end
        return v
    end
    isfinite(lower) || error("invalid 'xmin' value")
    isfinite(upper) || error("invalid 'xmax' value")
    lower >= upper && error("'xmin' not less than 'xmax'")
    tol = Float64(tol)
    (!isfinite(tol) || tol <= 0.0) && error("invalid 'tol' value")
    val = brent_fmin(lower, upper, fcn1, tol)
    obj = f(val, args...; kwargs...)
    a = _num1(obj)
    return RList((maximum ? "maximum" : "minimum") => val, "objective" => (length(a) == 1 ? a[1] : obj))
end
const optimise = optimize

_g(x) = SimLev.r_sprintf("%g", x)

"""
    uniroot(f, interval = nothing, args...; lower, upper, f_lower, f_upper, extendInt = "no", check_conv = false, tol, maxiter = 1000, trace = 0, kwargs...)

`uniroot(...)`: RList mit `root`, `f.root`, `iter`, `init.it`, `estim.prec`.
"""
function uniroot(f, interval = nothing, args...; lower = nothing, upper = nothing, f_lower = nothing,
                 f_upper = nothing, extendInt::AbstractString = "no", check_conv::Bool = false,
                 tol::Real = 0.0001220703125, maxiter::Integer = 1000, trace::Integer = 0, kwargs...)
    if interval !== nothing
        length(_v(interval)) != 2 && error("'interval' must be a vector of length 2")
    end
    lower === nothing && (lower = Base.minimum(_v(interval)))
    upper === nothing && (upper = Base.maximum(_v(interval)))
    lower = Float64(lower); upper = Float64(upper)
    lower < upper || error("lower < upper  is not fulfilled")
    ff(x) = (v = _num1(f(x, args...; kwargs...)); isempty(v) ? NaN : v[1])
    f_lower === nothing && (f_lower = ff(lower))
    isnan(f_lower) && error("f.lower = f(lower) is NA")
    f_upper === nothing && (f_upper = ff(upper))
    isnan(f_upper) && error("f.upper = f(upper) is NA")
    f_lower = Float64(f_lower); f_upper = Float64(f_upper)
    sigs = [("yes", nothing), ("downX", -1.0), ("no", 0.0), ("upX", 1.0)]
    ext = isempty(extendInt) ? [] : [v for (k, v) in sigs if startswith(k, extendInt)]
    length(ext) != 1 && error("'arg' should be one of “no”, “yes”, “downX”, “upX”")
    Sig = ext[1]
    trunc_(x) = isnan(x) ? x : max(min(x, _DBL_MAX), -_DBL_MAX)
    flo = trunc_(f_lower)
    fup = trunc_(f_upper)
    doX = (Sig === nothing && flo * fup > 0) || (Sig !== nothing && (Sig * flo > 0 || Sig * fup < 0))
    it = 0
    if doX
        trace != 0 && print("search in [" * _g(lower) * "," * _g(upper) * "]" * (trace >= 2 ? "\n" : " ... "))
        Delta(u) = 0.01 * max(1e-4, abs(u))
        if Sig === nothing
            delta = [Delta(lower), Delta(upper)]
            while (f_lower * f_upper > 0) && (isfinite(lower) || isfinite(upper))
                iF = (isfinite(lower), isfinite(upper))
                it += 1
                it > maxiter && error("no sign change found in $(it - 1) iterations")
                if iF[1]
                    ol, of = lower, f_lower
                    lower = lower - delta[1]
                    f_lower = ff(lower)
                    if isnan(f_lower)
                        lower, f_lower = ol, of
                        delta[1] = delta[1] / 4
                    end
                end
                if iF[2]
                    ol, of = upper, f_upper
                    upper = upper + delta[2]
                    f_upper = ff(upper)
                    if isnan(f_upper)
                        upper, f_upper = ol, of
                        delta[2] = delta[2] / 4
                    end
                end
                trace >= 2 && println(SimLev.r_sprintf(" .. modified lower,upper: (%15s,%15s)", _g(lower), _g(upper)))
                delta = [2 * delta[1], 2 * delta[2]]
            end
        else
            delta = Delta(lower)
            while Sig * f_lower > 0
                it += 1
                it > maxiter && error("no sign change found in $(it - 1) iterations")
                lower = lower - delta
                f_lower = ff(lower)
                trace >= 2 && println(" .. modified lower: " * _g(lower))
                delta = 2 * delta
            end
            delta = Delta(upper)
            while Sig * f_upper < 0
                it += 1
                it > maxiter && error("no sign change found in $(it - 1) iterations")
                upper = upper + delta
                f_upper = ff(upper)
                trace >= 2 && println(" .. modified upper: " * _g(upper))
                delta = 2 * delta
            end
        end
        (trace != 0 && trace < 2) && println("extended to [" * _g(lower) * ", " * _g(upper) * "] in $it steps")
    end
    sg(v) = isnan(v) ? NaN : (v == 0 ? 0.0 : copysign(1.0, v))
    prod = sg(f_lower) * sg(f_upper)
    if !(!isnan(prod) && prod <= 0)
        error(doX ? "did not succeed extending the interval endpoints for f(lower) * f(upper) <= 0" :
              "f() values at end points not of opposite sign")
    end
    if doX && it != 0
        flo = trunc_(f_lower)
        fup = trunc_(f_upper)
    end
    isfinite(lower) || error("invalid 'xmin' value")
    isfinite(upper) || error("invalid 'xmax' value")
    lower >= upper && error("'xmin' not less than 'xmax'")
    tol = Float64(tol)
    (!isfinite(tol) || tol <= 0.0) && error("invalid 'tol' value")
    maxit = Int(maxiter)
    maxit <= 0 && error("'maxiter' must be positive")
    warned = String[]
    seen = Set{String}()
    function fcn2(x)
        v = _num1(f(x, args...; kwargs...))
        length(v) != 1 && error("invalid function value in 'zeroin'")
        val = v[1]
        if !isfinite(val)
            msg = val == -Inf ? "-Inf replaced by maximally negative value" : "NA/Inf replaced by maximum positive value"
            check_conv ? push!(warned, msg) : _warn1!(seen, msg)
            return val == -Inf ? -_DBL_MAX : _DBL_MAX
        end
        return val
    end
    root, itr, prec = zeroin2(lower, upper, flo, fup, fcn2, tol, maxit)
    (check_conv && !isempty(warned)) && error("convergence problem in zero finding: " * warned[1])
    if itr < 0
        msg = maxiter == 1 ? "_NOT_ converged in $maxiter iteration" : "_NOT_ converged in $maxiter iterations"
        check_conv && error(msg)
        @warn msg
        itr = Int(maxiter)
    end
    if doX
        itr = itr + it
        init_it = it
    else
        init_it = missing
    end
    return RList("root" => root, "f.root" => ff(root), "iter" => itr, "init.it" => init_it, "estim.prec" => prec)
end

const _OPTIM_METHODS = ("Nelder-Mead", "BFGS", "CG", "L-BFGS-B", "SANN", "Brent")

"fminfn/fmingr aus optim.c."
struct _Fn{F,G}
    fn::F
    gr::G
    fnscale::Float64
    parscale::Vector{Float64}
    ndeps::Union{Nothing,Vector{Float64}}
    names::Union{Nothing,Vector{String}}
    lower::Union{Nothing,Vector{Float64}}
    upper::Union{Nothing,Vector{Float64}}
    usebounds::Bool
end
_Fn(fn, gr, fnscale, parscale, ndeps, names; lower = nothing, upper = nothing, usebounds = false) =
    _Fn(fn, gr, fnscale, parscale, ndeps, names, lower, upper, usebounds)

_wrap(F::_Fn, x) = F.names === nothing ? (length(x) == 1 ? x[1] : collect(Float64, x)) : RVector(collect(Float64, x); names = F.names)

function _call(F::_Fn, x)
    s = _num1(F.fn(_wrap(F, x)))
    length(s) != 1 && error("objective function in optim evaluates to length $(length(s)) not 1")
    return s[1]
end

function _fminfn(F::_Fn, p)
    x = Vector{Float64}(undef, length(p))
    for i in eachindex(p)
        isfinite(p[i]) || error("non-finite value supplied by optim")
        x[i] = p[i] * F.parscale[i]
    end
    return _call(F, x) / F.fnscale
end

function _fmingr(F::_Fn, p)
    n = length(p)
    ps = F.parscale
    if F.gr !== nothing
        x = Vector{Float64}(undef, n)
        for i in 1:n
            isfinite(p[i]) || error("non-finite value supplied by optim")
            x[i] = p[i] * ps[i]
        end
        s = _num1(F.gr(_wrap(F, x)))
        length(s) != n && error("gradient in optim evaluated to length $(length(s)) not $n")
        return Float64[s[i] * ps[i] / F.fnscale for i in 1:n]
    end
    df = zeros(n)
    x = Float64[p[i] * ps[i] for i in 1:n]
    if !F.usebounds
        for i in 1:n
            eps = F.ndeps[i]
            x[i] = (p[i] + eps) * ps[i]
            val1 = _call(F, x) / F.fnscale
            x[i] = (p[i] - eps) * ps[i]
            val2 = _call(F, x) / F.fnscale
            df[i] = (val1 - val2) / (2 * eps)
            isfinite(df[i]) || error("non-finite finite-difference value [$i]")
            x[i] = p[i] * ps[i]
        end
    else
        for i in 1:n
            epsused = eps = F.ndeps[i]
            tmp = p[i] + eps
            if tmp > F.upper[i]
                tmp = F.upper[i]
                epsused = tmp - p[i]
            end
            x[i] = tmp * ps[i]
            val1 = _call(F, x) / F.fnscale
            tmp = p[i] - eps
            if tmp < F.lower[i]
                tmp = F.lower[i]
                eps = p[i] - tmp
            end
            x[i] = tmp * ps[i]
            val2 = _call(F, x) / F.fnscale
            df[i] = (val1 - val2) / (epsused + eps)
            isfinite(df[i]) || error("non-finite finite-difference value [$i]")
            x[i] = p[i] * ps[i]
        end
    end
    return df
end

_ctl_dict(control::Nothing) = Dict{String,Any}()
_ctl_dict(control::AbstractDict) = Dict{String,Any}(replace(string(k), "warn_1d_NelderMead" => "warn.1d.NelderMead") => v for (k, v) in control)
_ctl_dict(control::NamedTuple) = _ctl_dict(Dict(pairs(control)))
_ctl_keys(control::Nothing) = String[]
_ctl_keys(control::NamedTuple) = [replace(string(k), "warn_1d_NelderMead" => "warn.1d.NelderMead") for k in keys(control)]
_ctl_keys(control::AbstractDict) = [replace(string(k), "warn_1d_NelderMead" => "warn.1d.NelderMead") for k in keys(control)]
_resize(v::Vector{Float64}, n) = n == 0 ? Float64[] : Float64[v[(i - 1) % length(v) + 1] for i in 1:n]

"""
    optim(par, fn, gr = nothing, args...; method = "Nelder-Mead", lower = -Inf, upper = Inf, control = nothing, hessian = false, kwargs...)

`optim(...)`; Methoden "Nelder-Mead", "BFGS", "CG", "L-BFGS-B", "Brent".
`control` als Dict/NamedTuple wie in R (maxit, reltol, abstol, fnscale,
parscale, ndeps, factr, pgtol, lmm, alpha, beta, gamma, type, trace, REPORT,
warn.1d.NelderMead). Ergebnis: RList mit par, value, counts (RVector
function/gradient), convergence, message (und hessian).
"""
function optim(par, fn, gr = nothing, args...; method::AbstractString = "Nelder-Mead", lower = -Inf, upper = Inf,
               control = nothing, hessian::Bool = false, kwargs...)
    names = _names_of(par)
    pv = _v(par)
    fn1 = p -> fn(p, args...; kwargs...)
    gr1 = gr === nothing ? nothing : (p -> gr(p, args...; kwargs...))
    meths = [m for m in _OPTIM_METHODS if startswith(m, method)]
    length(meths) != 1 && error("'arg' should be one of “Nelder-Mead”, “BFGS”, “CG”, “L-BFGS-B”, “SANN”, “Brent”")
    method = meths[1]
    lo = _v(lower); up = _v(upper)
    if (any(>(-Inf), lo) || any(<(Inf), up)) && !(method in ("L-BFGS-B", "Brent"))
        @warn "bounds can only be used with method L-BFGS-B (or Brent)"
        method = "L-BFGS-B"
    end
    npar = length(pv)
    con = Dict{String,Any}("trace" => 0, "fnscale" => 1.0, "parscale" => ones(npar), "ndeps" => fill(1e-3, npar),
                           "maxit" => 100, "abstol" => -Inf, "reltol" => sqrt(_DBL_EPS), "alpha" => 1.0,
                           "beta" => 0.5, "gamma" => 2.0, "REPORT" => 10, "warn.1d.NelderMead" => true, "type" => 1,
                           "lmm" => 5, "factr" => 1e7, "pgtol" => 0.0, "tmax" => 10, "temp" => 10.0)
    nms = ["trace", "fnscale", "parscale", "ndeps", "maxit", "abstol", "reltol", "alpha", "beta", "gamma",
           "REPORT", "warn.1d.NelderMead", "type", "lmm", "factr", "pgtol", "tmax", "temp"]
    method == "Nelder-Mead" && (con["maxit"] = 500)
    if method == "SANN"
        con["maxit"] = 10000
        con["REPORT"] = 100
    end
    ctl = _ctl_dict(control)
    merge!(con, ctl)
    no = [k for k in _ctl_keys(control) if !(k in nms)]
    isempty(no) || @warn "unknown names in control: " * join(no, ", ")
    if con["trace"] < 0
        @warn "read the documentation for 'trace' more carefully"
    elseif method == "SANN" && con["trace"] != 0 && Int(con["REPORT"]) == 0
        error("'trace != 0' needs 'REPORT >= 1'")
    end
    (method == "L-BFGS-B" && (haskey(ctl, "reltol") || haskey(ctl, "abstol"))) &&
        @warn "method L-BFGS-B uses 'factr' (and 'pgtol') instead of 'reltol' and 'abstol'"
    (npar == 1 && method == "Nelder-Mead" && con["warn.1d.NelderMead"] === true) &&
        @warn "one-dimensional optimization by Nelder-Mead is unreliable:\nuse \"Brent\" or optimize() directly"
    (npar > 1 && method == "Brent") && error("method = \"Brent\" is only available for one-dimensional optimization")
    lo = _resize(lo, npar); up = _resize(up, npar)
    if method == "Brent"
        (all(isfinite, lo) && all(isfinite, up)) || error("'lower' and 'upper' must be finite values")
        fs = Float64(con["fnscale"])
        o = optimize(p -> _num1(fn(p, args...; kwargs...))[1] / fs; lower = lo[1], upper = up[1],
                     tol = Float64(con["reltol"]))
        res = RList("par" => o["minimum"], "value" => o["objective"] * fs,
                    "counts" => RVector(Union{Missing,Int}[missing, missing]; names = ["function", "gradient"]),
                    "convergence" => 0, "message" => nothing)
    else
        res = _optim_c(pv, names, fn1, gr1, method, con, lo, up)
    end
    hessian && (res["hessian"] = optimhess(res["par"], fn, gr, args...; control = con, kwargs...))
    return res
end

function _asint(v)
    v === nothing && error("'maxit' is not an integer")
    return trunc(Int, Float64(v))
end

function _optim_c(pv, names, fn1, gr1, method, con, lo, up)
    npar = length(pv)
    trace = Int(con["trace"])
    fnscale = Float64(con["fnscale"])
    ps = _v(con["parscale"])
    length(ps) != npar && error("'parscale' is of the wrong length")
    dpar = Float64[pv[i] / ps[i] for i in 1:npar]
    abstol = Float64(con["abstol"])
    reltol = Float64(con["reltol"])
    maxit = _asint(con["maxit"])
    function get_ndeps()
        nd = _v(con["ndeps"])
        length(nd) != npar && error("'ndeps' is of the wrong length")
        nd
    end
    msg = nothing
    if method == "Nelder-Mead"
        F = _Fn(fn1, nothing, fnscale, ps, nothing, names)
        X, val, fail, fncount = nmmin(npar, dpar, p -> _fminfn(F, p), abstol, reltol, Float64(con["alpha"]),
                                      Float64(con["beta"]), Float64(con["gamma"]), trace, maxit)
        par = Float64[X[i] * ps[i] for i in 1:npar]
        grcount = nothing
    elseif method == "SANN"
        error("optim(method = \"SANN\") ist nicht portiert")
    elseif method == "BFGS"
        nrep = Int(con["REPORT"])
        nd = gr1 !== nothing ? nothing : get_ndeps()
        F = _Fn(fn1, gr1, fnscale, ps, nd, names)
        b, val, fncount, grcount, fail = vmmin(npar, dpar, p -> _fminfn(F, p), p -> _fmingr(F, p), maxit, trace,
                                               fill(true, npar), abstol, reltol, nrep)
        par = Float64[b[i] * ps[i] for i in 1:npar]
    elseif method == "CG"
        typ = Int(con["type"])
        nd = gr1 !== nothing ? nothing : get_ndeps()
        F = _Fn(fn1, gr1, fnscale, ps, nd, names)
        X, val, fail, fncount, grcount = cgmin(npar, dpar, p -> _fminfn(F, p), p -> _fmingr(F, p), abstol, reltol,
                                               typ, trace, maxit)
        par = Float64[X[i] * ps[i] for i in 1:npar]
    else
        nrep = Int(con["REPORT"])
        factr = Float64(con["factr"])
        pgtol = Float64(con["pgtol"])
        lmm = Int(con["lmm"])
        nd = gr1 !== nothing ? nothing : get_ndeps()
        lower = Float64[lo[i] / ps[i] for i in 1:npar]
        upper = Float64[up[i] / ps[i] for i in 1:npar]
        nbd = Int[isfinite(lower[i]) ? (isfinite(upper[i]) ? 2 : 1) : (isfinite(upper[i]) ? 3 : 0) for i in 1:npar]
        F = _Fn(fn1, gr1, fnscale, ps, nd, names; lower = lower, upper = upper, usebounds = true)
        x, val, fail, fncount, grcount, msg = lbfgsb(npar, lmm, dpar, lower, upper, nbd, p -> _fminfn(F, p),
                                                     p -> _fmingr(F, p), factr, pgtol, maxit; trace = trace,
                                                     nREPORT = nrep)
        par = Float64[x[i] * ps[i] for i in 1:npar]
    end
    return RList("par" => _vec_out(par, names), "value" => val * fnscale,
                 "counts" => RVector(Union{Missing,Int}[fncount, grcount === nothing ? missing : grcount];
                                     names = ["function", "gradient"]),
                 "convergence" => Int(fail), "message" => msg)
end

"`optimHess(par, fn, gr, ..., control)` (Hesse-Matrix wie in optim)."
function optimhess(par, fn, gr = nothing, args...; control = nothing, kwargs...)
    names = _names_of(par)
    pv = _v(par)
    npar = length(pv)
    con = Dict{String,Any}("fnscale" => 1.0, "parscale" => ones(npar), "ndeps" => fill(1e-3, npar))
    if control !== nothing
        for (k, v) in _ctl_dict(control)
            haskey(con, k) && (con[k] = v)
        end
    end
    fnscale = Float64(con["fnscale"])
    ps = _v(con["parscale"])
    length(ps) != npar && error("'parscale' is of the wrong length")
    nd = _v(con["ndeps"])
    length(nd) != npar && error("'ndeps' is of the wrong length")
    fn1 = p -> fn(p, args...; kwargs...)
    gr1 = gr === nothing ? nothing : (p -> gr(p, args...; kwargs...))
    F = _Fn(fn1, gr1, fnscale, ps, nd, names)
    dpar = Float64[pv[i] / ps[i] for i in 1:npar]
    ans = zeros(npar, npar)
    for i in 1:npar
        eps = nd[i] / ps[i]
        dpar[i] = dpar[i] + eps
        df1 = _fmingr(F, dpar)
        dpar[i] = dpar[i] - 2 * eps
        df2 = _fmingr(F, dpar)
        for j in 1:npar
            ans[j, i] = (fnscale * (df1[j] - df2[j])) / (2 * eps * ps[i] * ps[j])
        end
        dpar[i] = dpar[i] + eps
    end
    for i in 1:npar, j in 1:i-1
        tmp = 0.5 * (ans[j, i] + ans[i, j])
        ans[j, i] = ans[i, j] = tmp
    end
    return _out(ans, names, names)
end

# ── nlminb (PORT) ─────────────────────────────────────────────────────────

const _PORT_CPOS = ("eval.max" => 17, "iter.max" => 18, "trace" => 19, "maxiter" => 18,
                    "abs.tol" => 31, "rel.tol" => 32, "x.tol" => 33, "xf.tol" => 34,
                    "step.min" => 35, "step.max" => 36, "sing.tol" => 37,
                    "scale.init" => 38, "diff.g" => 42)

const _PORT_MSG = Dict(3 => "X-convergence (3)", 4 => "relative convergence (4)",
                       5 => "both X-convergence and relative convergence (5)",
                       6 => "absolute function convergence (6)", 7 => "singular convergence (7)",
                       8 => "false convergence (8)",
                       9 => "function evaluation limit reached without convergence (9)",
                       10 => "iteration limit reached without convergence (10)",
                       14 => "storage only has been allocated (14)", 15 => "LIV too small (15)",
                       16 => "LV too small (16)", 63 => "fn cannot be computed at initial par (63)",
                       65 => "gr cannot be computed at initial par (65)",
                       300 => "initial par violates constraints")

"`pmatch(nms, table)` (duplicates.ok = FALSE); 0 = NA."
function _pmatch(nms::Vector{String}, table::Vector{String})
    used = falses(length(table))
    ans = zeros(Int, length(nms))
    for (i, s) in enumerate(nms), (j, t) in enumerate(table)
        if !used[j] && s == t
            ans[i] = j; used[j] = true
            break
        end
    end
    for (i, s) in enumerate(nms)
        (ans[i] != 0 || isempty(s)) && continue
        mtch = 0; cnt = 0
        for (j, t) in enumerate(table)
            if !used[j] && startswith(t, s)
                mtch = j; cnt += 1
            end
        end
        if mtch > 0 && cnt == 1
            used[mtch] = true
            ans[i] = mtch
        end
    end
    return ans
end

"`any(x != ref)` mit R's NA-Logik (`missing` = NA)."
function _r_any_ne(x::Vector{Float64}, ref::Float64)
    na = false
    for e in x
        if isnan(e)
            na = true
        elseif e != ref
            return true
        end
    end
    return na ? missing : false
end

function _ctl_int(val)
    val isa Bool && return Int(val)
    f = Float64(val)
    if isnan(f) || abs(f) >= 2147483648.0
        isnan(f) || @warn "NAs introduced by coercion to integer range"
        return -2147483648
    end
    return Int(trunc(f))
end

_ctl_pairs(control::Nothing) = Pair{String,Any}[]
_ctl_pairs(control::NamedTuple) = Pair{String,Any}[string(k) => v for (k, v) in pairs(control)]
_ctl_pairs(control) = Pair{String,Any}[string(k) => v for (k, v) in control]

"""
    nlminb(start, objective, gradient = nothing, hessian = nothing, args...;
           scale = 1, control = nothing, lower = -Inf, upper = Inf, kwargs...)

`nlminb(start, objective, gradient, hessian, ..., scale, control, lower, upper)`:
Minimierung mit der PORT-Bibliothek (`drmnf`, `drmng`, `drmnh` und die Varianten
mit Schranken `drmnfb`, `drmngb`, `drmnhb`) wie in R.

- `start`: Startwerte (Vektor oder benannter `RVector`).
- `objective`: Zielfunktion `objective(par, args...; kwargs...)`; `par` ist wie
  `start` benannt (`RVector`), sonst ein Vektor (Länge 1: Skalar).
- `gradient`: optional, Gradient (Länge n); `hessian`: optional (nur mit
  `gradient`), Hesse-Matrix n × n.
- `scale`: Skalierung der Parameter (wird auf n verlängert).
- `control`: `NamedTuple`, Pair-Vektor oder `Dict` mit `eval.max`, `iter.max`,
  `trace`, `abs.tol`, `rel.tol`, `x.tol`, `xf.tol`, `step.min`, `step.max`,
  `sing.tol`, `scale.init`, `diff.g` (Teilnamen wie in R; die Reihenfolge
  zählt nur für die Warnung über unbekannte Namen).
- `lower`, `upper`: Schranken (werden auf n verlängert).

Ergebnis: `RList` mit `par`, `objective`, `convergence`, `iterations`,
`evaluations` (`RVector` function/gradient) und `message`.
"""
function nlminb(start, objective, gradient = nothing, hessian = nothing, args...; scale = 1,
                control = nothing, lower = -Inf, upper = Inf, kwargs...)
    names = _names_of(start)
    pv = copy(_v(start))
    n = length(pv)
    liv = 78 + 3n
    lv = 130 + (n * (n + 27)) ÷ 2
    iv = zeros(Int, liv)
    v = zeros(lv)
    SimLev.RPort.divset(2, iv, liv, lv, v)
    ctl = _ctl_pairs(control)
    if !isempty(ctl)
        nms = String[first(p) for p in ctl]
        vals = Any[last(p) for p in ctl]
        tab = String[first(p) for p in _PORT_CPOS]
        pos = _pmatch(nms, tab)
        nap = pos .== 0
        if any(nap)
            msg = length(nap) == 1 ? "unrecognized control element named %s ignored" :
                  "unrecognized control elements named %s ignored"
            @warn replace(msg, "%s" => join(["‘" * nms[i] * "’" for i in eachindex(nms) if nap[i]], ", "))
            vals = vals[.!nap]
            pos = pos[.!nap]
        end
        ivv = [(last(_PORT_CPOS[p]), vals[i]) for (i, p) in enumerate(pos) if p <= 4]
        vvv = [(last(_PORT_CPOS[p]), vals[i]) for (i, p) in enumerate(pos) if p > 4]
        ivi = Int[_ctl_int(val) for (_, val) in ivv]
        for ((k, _), val) in zip(ivv, ivi)
            iv[k] = val
        end
        for (k, val) in vvv
            v[k] = Float64(val)
        end
    end
    fn = p -> objective(p, args...; kwargs...)
    gr = hs = nothing
    if gradient !== nothing
        gr = p -> gradient(p, args...; kwargs...)
        if hessian !== nothing
            hessian isa Bool && error("logical 'hessian' argument not allowed.  See documentation.")
            hs = p -> hessian(p, args...; kwargs...)
        end
    end
    lo = _v(lower)
    up = _v(upper)
    a1 = _r_any_ne(lo, -Inf)
    bounded = a1 === true ? true : _r_any_ne(up, Inf)
    (a1 === missing && bounded === false) && (bounded = missing)
    bounded === missing && error("missing value where TRUE/FALSE needed")
    low = bounded ? Float64[lo[(i - 1) % length(lo) + 1] for i in 1:n] : nothing
    upp = bounded ? Float64[up[(i - 1) % length(up) + 1] for i in 1:n] : nothing
    sc = _v(scale)
    d = n == 0 ? Float64[] : Float64[sc[(i - 1) % length(sc) + 1] for i in 1:n]
    x = SimLev.RPort.port_nlminb(fn, gr, hs, low, upp, d, iv, v, pv, names)
    iv1 = iv[1]
    if 19 <= iv1 <= 43
        hit = [first(p) for p in _PORT_CPOS if last(p) == iv1]
        msg = isempty(hit) ?
              SimLev.RFmt.r_sprintf("V[IV[1]] = V[%d] = %g is out of range (see PORT docu.)", iv1, v[iv1]) :
              SimLev.RFmt.r_sprintf("'control' component '%s' = %g, is out of range", hit[1], v[iv1])
    else
        msg = get(_PORT_MSG, iv1, "See PORT documentation.  Code ($iv1)")
    end
    return RList("par" => _vec_out(x, names), "objective" => v[10],
                 "convergence" => (3 <= iv1 <= 6 ? 0 : 1), "iterations" => iv[31],
                 "evaluations" => RVector([iv[6], iv[30]]; names = ["function", "gradient"]),
                 "message" => msg)
end

# ── lm.fit / lm / poly / glm ─────────────────────────────────────────────

_LA() = SimLev.RLinalg

"""
    lm_fit(x, y; offset = nothing, method = "qr", tol = 1e-7, singular_ok = true)

`lm.fit(x, y, offset, method, tol, singular.ok)` (LINPACK dqrls): RList
(Klasse \"lm\") mit coefficients (RVector), residuals, effects (RVector),
rank, fitted.values, assign, qr (RList \"qr\": qr, qraux, pivot, tol, rank),
df.residual.
"""
function lm_fit(x, y; offset = nothing, method::AbstractString = "qr", tol::Real = 1e-07, singular_ok::Bool = true)
    if x isa NamedMat
        X = _fmat(x.data); cn = x.colnames; rn_x = x.rownames
    elseif x isa RFrame
        X, _, cn = _as_cov_input(x); rn_x = x.rownames
    elseif x isa AbstractMatrix
        X = _fmat(x); cn = nothing; rn_x = nothing
    else
        error("'x' must be a matrix")
    end
    n = size(X, 1)
    n == 0 && error("0 (non-NA) cases")
    p = size(X, 2)
    ynames = nothing
    if y isa RVector
        ynames = y.names
        Y = Float64[_fl(v) for v in y.values]
    elseif y isa NamedMat
        Y = _fmat(y.data)
    elseif y isa AbstractMatrix
        Y = _fmat(y)
    else
        Y = _v(y)
    end
    ymat = Y isa AbstractMatrix && size(Y, 2) > 1
    (Y isa AbstractMatrix && size(Y, 2) == 1) && (Y = Y[:, 1])
    if p == 0
        return RList("coefficients" => Float64[], "residuals" => y, "fitted.values" => 0 .* Y, "rank" => 0,
                     "df.residual" => size(Y, 1); class = "lm")
    end
    offset !== nothing && (Y = Y .- (offset isa Number ? Float64(offset) : _v(offset)))
    size(Y, 1) != n && error("incompatible dimensions")
    method != "qr" && @warn "method = '$method' is not supported. Using 'qr'"
    all(isfinite, X) || error("NA/NaN/Inf in 'x'")
    all(isfinite, Y) || error("NA/NaN/Inf in 'y'")
    Y2 = reshape(Y, n, :)
    z = _LA().dqrls(X, Y2, Float64(tol))
    (!singular_ok && z.rank < p) && error("singular fit encountered")
    rank = z.rank
    pivot = z.pivot
    dn = cn !== nothing ? cn : ["x$i" for i in 1:p]
    nmeff = vcat([dn[pivot[i]] for i in 1:rank], fill("", n - rank))
    coef = copy(z.coefficients)
    coef[rank+1:end, :] .= NA
    if z.pivoted
        c2 = similar(coef)
        c2[pivot, :] = coef
        coef = c2
    end
    resid = z.residuals
    eff = z.effects
    fitted = Y2 .- resid
    offset !== nothing && (fitted = fitted .+ reshape(offset isa Number ? fill(Float64(offset), n) : _v(offset), n, :))
    qcn = cn === nothing ? nothing : (z.pivoted ? [cn[i] for i in pivot] : cn)
    q = RList("qr" => _out(z.qr, rn_x, qcn), "qraux" => z.qraux, "pivot" => pivot, "tol" => Float64(tol),
              "rank" => rank; class = "qr")
    if ymat
        res = RList("coefficients" => NamedMat(coef; rownames = dn), "residuals" => resid,
                    "effects" => NamedMat(eff; rownames = nmeff), "rank" => rank, "fitted.values" => fitted;
                    class = "lm")
    else
        res = RList("coefficients" => RVector(coef[:, 1]; names = dn), "residuals" => _vec_out(resid[:, 1], ynames),
                    "effects" => RVector(eff[:, 1]; names = nmeff), "rank" => rank,
                    "fitted.values" => _vec_out(fitted[:, 1], ynames); class = "lm")
    end
    res["assign"] = nothing
    res["qr"] = q
    res["df.residual"] = n - rank
    return res
end

_coefs_get(c, k) = c isa AbstractDict ? c[k] : getproperty(c, Symbol(k))

"""
    poly(x, degree = 1; coefs = nothing, raw = false, simple = false)

`poly(x, degree, coefs, raw, simple)` (orthogonale Polynome wie R):
NamedMat n×degree (Spaltennamen "1", "2", …) mit den Attributen "coefs"
(RList alpha, norm2), "degree" und "class" (`attrs(m)`).
"""
function poly(x, degree::Integer = 1; coefs = nothing, raw::Bool = false, simple::Bool = false)
    xv = _v(x)
    degree = Int(degree)
    degree < 1 && error("'degree' must be at least 1")
    n = length(xv)
    cnames = string.(1:degree)
    if raw
        Z = Float64[SimLev.r_pow(v, k) for v in xv, k in 1:degree]
        return NamedMat(Z; colnames = cnames, attrs = Dict{String,Any}("degree" => collect(1:degree),
                                                                       "class" => ["poly", "matrix"]))
    end
    if coefs === nothing
        any(isnan, xv) && error("missing values are not allowed in 'poly'")
        degree >= length(unique(_z0.(xv))) && error("'degree' must be less than number of unique points")
        xbar = _rmean(xv)
        xc = xv .- xbar
        X = Float64[SimLev.r_pow(v, k) for v in xc, k in 0:degree]
        QR = _LA().qr(X)
        QR["rank"] < degree && error("'degree' must be less than number of unique points")
        zq = QR["qr"]
        zq = zq isa NamedMat ? copy(zq.data) : copy(zq)
        for j in 1:size(zq, 2), i in 1:size(zq, 1)
            i == j || (zq[i, j] = 0.0)
        end
        Z = _LA().qr_qy(QR, zq)
        Z = Z isa NamedMat ? Z.data : Z
        Z2 = Z .* Z
        norm2 = [_rsum(Z2[:, k]) for k in 1:size(Z, 2)]
        alpha = ([_rsum(xc .* Z2[:, k]) for k in 1:size(Z, 2)] ./ norm2 .+ xbar)[1:degree]
        norm2 = vcat(1.0, norm2)
    else
        alpha = _v(_coefs_get(coefs, "alpha"))
        norm2 = _v(_coefs_get(coefs, "norm2"))
        Z = ones(n, degree + 1)
        Z[:, 2] = xv .- alpha[1]
        for i in 2:degree
            Z[:, i+1] = (xv .- alpha[i]) .* Z[:, i] .- (norm2[i+1] / norm2[i]) .* Z[:, i-1]
        end
    end
    sq = sqrt.(norm2[2:end])
    Z = Z ./ permutedims(sq)
    Z = Z[:, 2:end]
    return NamedMat(Z; colnames = cnames,
                    attrs = Dict{String,Any}("coefs" => RList("alpha" => _vec_out(alpha), "norm2" => norm2),
                                             "degree" => collect(1:degree), "class" => ["poly", "matrix"]))
end

# Minimaler Formel-Parser für die Formen, die das Paket nutzt:
#   y ~ x,  y ~ x1 + x2,  y ~ X (Matrix),  y ~ poly(x, d),  y ~ stats::poly(x, d),
#   Achsenabschnitt entfernen mit "- 1" oder "0 +".

function _split_top(s::AbstractString, sep::Char)
    out = String[]
    depth = 0
    cur = IOBuffer()
    for ch in s
        if ch in "(["
            depth += 1
        elseif ch in ")]"
            depth -= 1
        end
        if ch == sep && depth == 0
            push!(out, String(take!(cur)))
        else
            print(cur, ch)
        end
    end
    push!(out, String(take!(cur)))
    out
end

"Spaltennamen-Präfix wie R's deparse (\", \" zwischen Argumenten)."
function _deparse_call(term::AbstractString)
    t = strip(term)
    occursin('(', t) || return String(t)
    fn, rest = split(t, '(', limit = 2)
    inner = rest[1:findlast(')', rest)-1]
    args = [strip(a) for a in _split_top(inner, ',')]
    return strip(fn) * "(" * join(args, ", ") * ")"
end

function _eval_lit(e::AbstractString, ns)
    s = String(strip(e))
    haskey(ns, s) && return ns[s]
    s in ("TRUE", "T") && return true
    s in ("FALSE", "F") && return false
    v = tryparse(Float64, s)
    v !== nothing && return v
    error("Formelterm '$s' wird nicht unterstützt")
end

function _eval_term(term::AbstractString, ns)
    t = String(strip(term))
    haskey(ns, t) && return ns[t]
    tt = replace(replace(t, "stats::" => ""), "base::" => "")
    if startswith(tt, "poly(")
        inner = tt[6:findlast(')', tt)-1]
        args = [strip(a) for a in _split_top(inner, ',')]
        xv = _eval_term(args[1], ns)
        kw = Dict{Symbol,Any}()
        pos = Any[]
        for a in args[2:end]
            if occursin('=', a) && !startswith(a, "=")
                k, v = split(a, '=', limit = 2)
                kw[Symbol(strip(k))] = _eval_lit(v, ns)
            else
                push!(pos, _eval_lit(a, ns))
            end
        end
        isempty(pos) || (kw[:degree] = pos[1])
        deg = Int(pop!(kw, :degree, 1))
        haskey(kw, :raw) && (kw[:raw] = Bool(kw[:raw]))
        return poly(xv, deg; kw...)
    end
    return _eval_lit(tt, ns)
end

_nsdict(x::Nothing) = Dict{String,Any}()
_nsdict(x::AbstractDict) = Dict{String,Any}(string(k) => v for (k, v) in x)
_nsdict(x::NamedTuple) = Dict{String,Any}(string(k) => v for (k, v) in pairs(x))
_nsdict(x::RFrame) = Dict{String,Any}(k => c for (k, c) in zip(names(x), x.cols))

function _model_frame(formula::AbstractString, data, env)
    occursin('~', formula) || error("invalid formula")
    lhs, rhs = split(formula, '~', limit = 2)
    ns = _nsdict(env)
    rownames = nothing
    if data !== nothing
        merge!(ns, _nsdict(data))
        data isa RFrame && (rownames = data.rownames)
    end
    intercept = true
    terms = String[]
    expanded = String[]
    for t in strip.(_split_top(rhs, '+'))
        parts = _split_top(t, '-')
        push!(expanded, String(strip(parts[1])))
        for pp in parts[2:end]
            if strip(pp) == "1"
                intercept = false
            elseif !isempty(strip(pp))
                error("Formelterm '-$(strip(pp))' wird nicht unterstützt")
            end
        end
    end
    for t in expanded
        t == "" && continue
        if t in ("0", "-1")
            intercept = false
            continue
        end
        t == "1" && continue
        push!(terms, t)
    end
    yv = _eval_term(strip(lhs), ns)
    cols = Tuple{String,Any}[(t, _eval_term(t, ns)) for t in terms]
    return String(strip(lhs)), yv, cols, intercept, rownames
end

function _design(y, cols, intercept::Bool, rownames)
    yv = y isa AbstractMatrix ? _fmat(y isa NamedMat ? y.data : y) : _v(y)
    n = size(yv, 1)
    mats = Matrix{Float64}[]
    names = String[]
    assign = Int[]
    ok = yv isa AbstractMatrix ? Bool[!any(isnan, view(yv, i, :)) for i in 1:n] : .!isnan.(yv)
    for (k, (lab, v)) in enumerate(cols)
        if v isa AbstractMatrix || v isa RFrame
            a, _, cn = _as_cov_input(v)
            push!(mats, a)
            pre = _deparse_call(lab)
            ok .&= Bool[!any(isnan, view(a, i, :)) for i in 1:size(a, 1)]
            if size(a, 2) == 1
                push!(names, pre); push!(assign, k)
                continue
            end
            cn === nothing && (cn = string.(1:size(a, 2)))
            append!(names, pre .* cn)
            append!(assign, fill(k, size(a, 2)))
        else
            a = _v(v)
            push!(mats, reshape(a, :, 1))
            push!(names, _deparse_call(lab))
            push!(assign, k)
            ok .&= .!isnan.(a)
        end
    end
    X = intercept ? hcat(ones(n), mats...) : (isempty(mats) ? zeros(n, 0) : hcat(mats...))
    if intercept
        names = vcat("(Intercept)", names)
        assign = vcat(0, assign)
    end
    rownames === nothing && (rownames = string.(1:n))
    return X, yv, names, assign, ok, rownames
end

"""
    lm(formula; data = nothing, env = nothing, kwargs...)

`lm(formula, data)` für einfache Formeln ("y ~ x", "y ~ x1 + x2", "y ~ X" mit
Matrix X, "y ~ poly(x, d)", ohne Achsenabschnitt mit "- 1"/"0 +"). Variablen
aus `data` (RFrame/NamedTuple/Dict), `env` (Dict/NamedTuple) oder
Schlüsselwortargumenten. Fehlende Werte: na.omit. Ergebnis: RList (Klasse
\"lm\") wie `lm_fit` plus `model`.
"""
function lm(formula::AbstractString; data = nothing, env = nothing, kwargs...)
    ns = _nsdict(env)
    for (k, v) in kwargs
        ns[string(k)] = v
    end
    ylab, yv, cols, intercept, rownames = _model_frame(formula, data, ns)
    X, y, names, assign, ok, rn = _design(yv, cols, intercept, rownames)
    keep = ok
    Xk = X[keep, :]
    yk = y[keep]
    rnk = rn[keep]
    fit = lm_fit(NamedMat(Xk; rownames = rnk, colnames = names), RVector(yk; names = rnk))
    fit["assign"] = assign
    fit["xlevels"] = RList()
    fit["call"] = nothing
    fit["terms"] = RList("intercept" => (intercept ? 1 : 0), "formula" => formula)
    model = RList(ylab => yk)
    for (lab, v) in cols
        model[lab] = v isa NamedMat ? NamedMat(v.data[keep, :]; colnames = v.colnames, attrs = v.attrs) :
                     v isa AbstractMatrix ? v[keep, :] : _v(v)[keep]
    end
    fit["model"] = model
    all(keep) || (fit["na.action"] = findall(.!keep))
    return fit
end

"`coef(obj)`."
coef(obj) = obj["coefficients"]
"`fitted(obj)`."
fitted(obj) = obj["fitted.values"]
"`residuals(obj)` (Antwort-Residuen)."
residuals(obj) = obj["residuals"]

_vals(x) = x isa RVector ? Float64[_fl(v) for v in x.values] : x isa AbstractArray ? Float64[_fl(v) for v in vec(x)] : Float64[_fl(x)]

"`summary.lm(object)`: residuals, coefficients (NamedMat), aliased, sigma, df, r.squared, adj.r.squared, fstatistic, cov.unscaled."
function summary_lm(object)
    z = object
    p = Int(z["rank"])
    rdf = z["df.residual"]
    r = _vals(z["residuals"])
    terms = get(z, "terms", nothing)
    intercept = terms === nothing ? 1 : Int(get(terms, "intercept", 1))
    ans = RList(; class = "summary.lm")
    if p == 0
        n = length(r)
        rss = _rsum(r .* r)
        resvar = rss / rdf
        al = isnan.(_vals(z["coefficients"]))
        ans["residuals"] = z["residuals"]
        ans["aliased"] = al
        ans["df"] = [0, n, length(al)]
        ans["coefficients"] = NamedMat(zeros(0, 4); colnames = ["Estimate", "Std. Error", "t value", "Pr(>|t|)"])
        ans["sigma"] = _csqrt(resvar)
        ans["r.squared"] = 0.0
        ans["adj.r.squared"] = 0.0
        return ans
    end
    Qr = z["qr"]
    Qm = Qr["qr"]
    Q = Qm isa NamedMat ? Qm.data : Qm
    n = size(Q, 1)
    n - p != rdf && @warn "residual degrees of freedom in object suggest this is not an \"lm\" fit"
    f = _vals(z["fitted.values"])
    if intercept != 0
        d = f .- _rmean(f)
        mss = _rsum(d .* d)
    else
        mss = _rsum(f .* f)
    end
    rss = _rsum(r .* r)
    resvar = rss / rdf
    if isfinite(resvar)
        mf = _rmean(f)
        resvar < (mf * mf + var(f)) * 1e-30 && @warn "essentially perfect fit: summary may be unreliable"
    end
    R = _LA().chol2inv(Q[1:p, 1:p])
    R = R isa AbstractMatrix ? R : fill(Float64(R), 1, 1)
    se = [_csqrt(R[i, i] * resvar) for i in 1:p]
    cf = z["coefficients"]
    cfv = _vals(cf)
    piv = collect(Int, Qr["pivot"] isa Number ? [Qr["pivot"]] : Qr["pivot"])
    est = cfv[piv[1:p]]
    tval = est ./ se
    pv = Float64[2 * SimLev.RNmath.pt(abs(t), Float64(rdf); lower_tail = false) for t in tval]
    cnames = cf isa RVector && cf.names !== nothing ? cf.names : string.(0:length(cfv)-1)
    rn = [cnames[i] for i in piv[1:p]]
    ans["residuals"] = z["residuals"]
    ans["coefficients"] = NamedMat(hcat(est, se, tval, pv); rownames = rn,
                                   colnames = ["Estimate", "Std. Error", "t value", "Pr(>|t|)"])
    ans["aliased"] = RVector(isnan.(cfv); names = cnames)
    ans["sigma"] = _csqrt(resvar)
    ans["df"] = [p, rdf, size(Q, 2)]
    if p != intercept
        df_int = intercept != 0 ? 1 : 0
        rsq = mss / (mss + rss)
        ans["r.squared"] = rsq
        ans["adj.r.squared"] = 1 - (1 - rsq) * ((n - df_int) / rdf)
        ans["fstatistic"] = RVector([(mss / (p - df_int)) / resvar, Float64(p - df_int), Float64(rdf)];
                                    names = ["value", "numdf", "dendf"])
    else
        ans["r.squared"] = 0.0
        ans["adj.r.squared"] = 0.0
    end
    ans["cov.unscaled"] = NamedMat(R; rownames = rn, colnames = rn)
    return ans
end

const _INVEPS = 1 / _DBL_EPS

function _logit_link(mu)
    m = _v(mu)
    out = similar(m)
    for (i, x) in enumerate(m)
        (x < 0 || x > 1) && error("Value " * _g(x) * " out of range (0, 1)")
        q = x != 1 ? x / (1 - x) : Inf
        out[i] = SimLev.RLibm.log(q)
    end
    out
end

function _logit_linkinv(eta)
    e = _v(eta)
    out = similar(e)
    for (i, t) in enumerate(e)
        tmp = t < -30.0 ? _DBL_EPS : (t > 30.0 ? _INVEPS : SimLev.RLibm.exp(t))
        out[i] = tmp / (1 + tmp)
    end
    out
end

function _logit_mu_eta(eta)
    e = _v(eta)
    out = similar(e)
    for (i, t) in enumerate(e)
        if t > 30.0 || t < -30.0
            out[i] = _DBL_EPS
        else
            ex = SimLev.RLibm.exp(t)
            opexp = 1 + ex
            out[i] = ex / (opexp * opexp)
        end
    end
    out
end

_y_log_y(y, mu) = y != 0.0 ? y * SimLev.RLibm.log(y / mu) : 0.0

function _binomial_dev_resids(y, mu, wt)
    yv = _v(y); muv = _v(mu); wv = _v(wt)
    n = length(yv)
    out = Vector{Float64}(undef, n)
    for i in 1:n
        mui = length(muv) > 1 ? muv[i] : muv[1]
        yi = yv[i]
        w = length(wv) > 1 ? wv[i] : wv[1]
        out[i] = 2 * w * (_y_log_y(yi, mui) + _y_log_y(1 - yi, 1 - mui))
    end
    out
end

function _binomial_aic(y, n, mu, wt, dev)
    isdefined(SimLev.RNmath, :dbinom) || return NaN
    nv = _v(n); wv = _v(wt); yv = _v(y); muv = _v(mu)
    m = any(>(1), nv) ? nv : wv
    fac = Float64[m[i] > 0 ? wv[i] / m[i] : 0.0 for i in eachindex(m)]
    rr(v) = SimLev.RFmt.r_round(v)
    db = _v(SimLev.RNmath.dbinom(_v(rr(m .* yv)), _v(rr(m)), muv; log = true))
    return -2 * _rsum(fac .* db)
end

"`binomial(link = \"logit\")` (nur der Logit-Link aus family.c): RList (Klasse \"family\")."
function r_binomial(link::AbstractString = "logit")
    link != "logit" && error("binomial(): nur link = 'logit' ist portiert")
    return RList("family" => "binomial", "link" => "logit", "linkfun" => _logit_link, "linkinv" => _logit_linkinv,
                 "variance" => (mu -> (m = _v(mu); m .* (1 .- m))), "dev.resids" => _binomial_dev_resids,
                 "aic" => _binomial_aic, "mu.eta" => _logit_mu_eta,
                 "validmu" => (mu -> (m = _v(mu); all(isfinite, m) && all(t -> 0 < t < 1, m))),
                 "valideta" => (eta -> true), "dispersion" => 1; class = "family")
end

"""
    glm(formula; family = r_binomial(), data = nothing, weights = nothing, control = nothing, env = nothing, kwargs...)

`glm(formula, family = binomial(), data)` mit IRLS wie glm.fit (Familie
binomial/logit). Ergebnis: RList (Klasse c(\"glm\", \"lm\")).
"""
function glm(formula::AbstractString; family = nothing, data = nothing, weights = nothing, control = nothing,
             env = nothing, kwargs...)
    family === nothing && (family = r_binomial())
    family isa Function && (family = family())
    ns = _nsdict(env)
    for (k, v) in kwargs
        ns[string(k)] = v
    end
    ylab, yv, cols, intercept, rownames = _model_frame(formula, data, ns)
    X, y, names, assign, ok, rn = _design(yv, cols, intercept, rownames)
    X = X[ok, :]; y = y[ok]; rn = rn[ok]
    ctl = Dict{String,Any}("epsilon" => 1e-8, "maxit" => 25, "trace" => false)
    control === nothing || merge!(ctl, _ctl_dict(control))
    fit = glm_fit(X, y; weights = weights, family = family, control = ctl, intercept = intercept,
                  xnames = names, ynames = rn)
    fit["call"] = nothing
    fit["formula"] = formula
    fit["terms"] = RList("intercept" => (intercept ? 1 : 0))
    return fit
end

"`glm.fit` (IRLS) wie R."
function glm_fit(x, y; weights = nothing, start = nothing, etastart = nothing, mustart = nothing, offset = nothing,
                 family = nothing, control = nothing, intercept::Bool = true, singular_ok::Bool = true,
                 xnames = nothing, ynames = nothing)
    family === nothing && error("'family' argument seems not to be a valid family object")
    ctl = Dict{String,Any}("epsilon" => 1e-8, "maxit" => 25, "trace" => false)
    control === nothing || merge!(ctl, _ctl_dict(control))
    eps_c = Float64(ctl["epsilon"])
    eps_c <= 0 && error("value of 'epsilon' must be > 0")
    maxit = Int(ctl["maxit"])
    maxit <= 0 && error("maximum number of iterations must be > 0")
    X = x isa AbstractMatrix ? _fmat(x isa NamedMat ? x.data : x) : reshape(_v(x), :, 1)
    y = copy(_v(y))
    nobs = length(y)
    nvars = size(X, 2)
    wts = weights === nothing ? ones(nobs) : copy(_v(weights))
    off = offset === nothing ? zeros(nobs) : _v(offset)
    variance = family["variance"]
    linkinv = family["linkinv"]
    dev_resids = family["dev.resids"]
    mu_eta = family["mu.eta"]
    valideta = get(family, "valideta", e -> true)
    validmu = get(family, "validmu", m -> true)
    n_ = ones(nobs)
    y[wts .== 0] .= 0
    any(t -> t < 0 || t > 1, y) && error("y values must be 0 <= y <= 1")
    ms = (wts .* y .+ 0.5) ./ (wts .+ 1)
    mm = wts .* y
    rmm = _v(SimLev.RFmt.r_round(mm))
    any(i -> abs(mm[i] - rmm[i]) > 1e-3, eachindex(mm)) && @warn "non-integer #successes in a binomial glm!"
    mustart === nothing && (mustart = ms)
    conv = false
    coefold = nothing
    mprod(A, b) = _v(_LA().matprod(A, b))
    if etastart !== nothing
        eta = _v(etastart)
    elseif start !== nothing
        start = _v(start)
        length(start) != nvars && error("length of 'start' should equal $nvars and correspond to initial coefs")
        coefold = copy(start)
        eta = off .+ mprod(X, start)
    else
        eta = family["linkfun"](mustart)
    end
    mu = linkinv(eta)
    (validmu(mu) && valideta(eta)) || error("cannot find valid starting values: please specify some")
    devold = _rsum(dev_resids(y, mu, wts))
    boundary = false
    start === nothing && (start = fill(NA, nvars))
    coef = nothing
    fit = nothing
    it = 0
    good = wts .> 0
    w = nothing
    dev = devold
    for itr in 1:maxit
        it = itr
        good = wts .> 0
        varmu = variance(mu)[good]
        any(isnan, varmu) && error("NAs in V(mu)")
        any(==(0), varmu) && error("0s in V(mu)")
        mev = mu_eta(eta)
        any(isnan, mev[good]) && error("NAs in d(mu)/d(eta)")
        good = (wts .> 0) .& (mev .!= 0)
        if !any(good)
            conv = false
            @warn "no observations informative at iteration $it"
            break
        end
        z = (eta .- off)[good] .+ (y .- mu)[good] ./ mev[good]
        w = sqrt.((wts[good] .* (mev[good] .* mev[good])) ./ variance(mu)[good])
        fit = _LA().dqrls(X[good, :] .* w, reshape(z .* w, :, 1), min(1e-7, eps_c / 1000))
        cf = fit.coefficients[:, 1]
        if !all(isfinite, cf)
            conv = false
            @warn "non-finite coefficients at iteration $it"
            break
        end
        nobs < fit.rank && error(nobs == 1 ? "X matrix has rank $(fit.rank), but only $nobs observation" :
                                 "X matrix has rank $(fit.rank), but only $nobs observations")
        (!singular_ok && fit.rank < nvars) && error("singular fit encountered")
        start = copy(start)
        start[fit.pivot] = cf
        eta = mprod(X, start)
        eta = eta .+ off
        mu = linkinv(eta)
        dev = _rsum(dev_resids(y, mu, wts))
        ctl["trace"] == true && println("Deviance = " * SimLev.RFmt.as_character(dev) * " Iterations - $it")
        boundary = false
        if !isfinite(dev)
            coefold === nothing && error("no valid set of coefficients has been found: please supply starting values")
            @warn "step size truncated due to divergence"
            ii = 1
            while !isfinite(dev)
                ii > maxit && error("inner loop 1; cannot correct step size")
                ii += 1
                start = (start .+ coefold) ./ 2
                eta = mprod(X, start) .+ off
                mu = linkinv(eta)
                dev = _rsum(dev_resids(y, mu, wts))
            end
            boundary = true
        end
        if !(valideta(eta) && validmu(mu))
            coefold === nothing && error("no valid set of coefficients has been found: please supply starting values")
            @warn "step size truncated: out of bounds"
            ii = 1
            while !(valideta(eta) && validmu(mu))
                ii > maxit && error("inner loop 2; cannot correct step size")
                ii += 1
                start = (start .+ coefold) ./ 2
                eta = mprod(X, start) .+ off
                mu = linkinv(eta)
            end
            boundary = true
            dev = _rsum(dev_resids(y, mu, wts))
        end
        if abs(dev - devold) / (0.1 + abs(dev)) < eps_c
            conv = true
            coef = copy(start)
            break
        end
        devold = dev
        coef = copy(start)
        coefold = copy(start)
    end
    conv || @warn "glm.fit: algorithm did not converge"
    boundary && @warn "glm.fit: algorithm stopped at boundary value"
    epsw = 10 * _DBL_EPS
    (any(>(1 - epsw), mu) || any(<(epsw), mu)) && @warn "glm.fit: fitted probabilities numerically 0 or 1 occurred"
    coef === nothing && (coef = copy(start))
    rank = fit !== nothing ? fit.rank : 0
    if fit !== nothing && rank < nvars
        coef[fit.pivot[rank+1:end]] .= NA
    end
    resid = (y .- mu) ./ mu_eta(eta)
    xn = xnames
    res = RList(; class = ["glm", "lm"])
    res["coefficients"] = xn !== nothing ? RVector(coef; names = xn) : _vec_out(coef)
    res["residuals"] = _vec_out(resid, ynames)
    res["fitted.values"] = _vec_out(mu, ynames)
    xxnames = nothing
    if fit !== nothing
        xxnames = xn !== nothing ? [xn[i] for i in fit.pivot] : nothing
        eff = fit.effects[:, 1]
        res["effects"] = xxnames !== nothing ? RVector(eff; names = vcat(xxnames[1:rank], fill("", count(good) - rank))) : eff
        qrm = fit.qr
        nr = min(count(good), nvars)
        if nr < nvars
            Rmat = Matrix{Float64}(undef, nvars, nvars)
            for j in 1:nvars, i in 1:nvars
                Rmat[i, j] = i == j ? 1.0 : 0.0
            end
            Rmat[1:nr, 1:nvars] = qrm[1:nr, 1:nvars]
        else
            Rmat = qrm[1:nvars, 1:nvars]
        end
        for j in 1:nvars, i in j+1:nvars
            Rmat[i, j] = 0.0
        end
        res["R"] = _out(Rmat, xxnames, xxnames)
    end
    res["rank"] = rank
    if fit !== nothing
        res["qr"] = RList("qr" => _out(fit.qr, nothing, xxnames), "rank" => rank, "qraux" => fit.qraux,
                          "pivot" => fit.pivot, "tol" => min(1e-7, eps_c / 1000); class = "qr")
    end
    res["family"] = family
    res["linear.predictors"] = _vec_out(eta, ynames)
    res["deviance"] = fit !== nothing ? dev : devold
    wtdmu = intercept ? _rsum(wts .* y) / _rsum(wts) : linkinv(off)
    nulldev = _rsum(dev_resids(y, wtdmu, wts))
    n_ok = nobs - count(==(0), wts)
    nulldf = n_ok - (intercept ? 1 : 0)
    resdf = n_ok - rank
    aic_model = try
        family["aic"](y, n_, mu, wts, res["deviance"]) + 2 * rank
    catch
        NaN
    end
    res["aic"] = aic_model
    res["null.deviance"] = nulldev
    res["iter"] = it
    wt = zeros(nobs)
    w !== nothing && (wt[good] = w .* w)
    res["weights"] = _vec_out(wt, ynames)
    res["prior.weights"] = _vec_out(wts, ynames)
    res["df.residual"] = resdf
    res["df.null"] = nulldf
    res["y"] = _vec_out(y, ynames)
    res["converged"] = conv
    res["boundary"] = boundary
    return res
end

# ── fft / density ────────────────────────────────────────────────────────

"`fft(z, inverse)` (R's gemischte Basis); Ergebnis ComplexF64 gleicher Form (Matrizen: mehrdimensional wie R)."
function fft(z; inverse::Bool = false)
    a = z isa NamedMat ? z.data : z isa RVector ? z.values : z
    if a isa Number
        r, i = fft_vec([Float64(real(a))], [Float64(imag(a))]; inverse = inverse)
        return complex(r[1], i[1])
    end
    flat = vec(a)
    re = Float64[real(v) for v in flat]
    im = Float64[imag(v) for v in flat]
    dims = ndims(a) >= 2 ? collect(size(a)) : nothing
    r, i = fft_vec(re, im; inverse = inverse, dims = dims)
    out = ComplexF64[complex(r[k], i[k]) for k in eachindex(r)]
    return reshape(out, size(a))
end

"`bw.nrd0(x)`."
function bw_nrd0(x)
    xv = _v(x)
    length(xv) < 2 && error("need at least 2 data points")
    hi = sd(xv)
    q = quantile(xv, [0.25, 0.75]; names = false)
    iqr = q[2] - q[1]
    q134 = iqr / 1.34
    lo = isnan(hi) ? hi : (q134 < hi ? q134 : hi)
    (!isnan(hi) && isnan(q134)) && (lo = NaN)
    if lo == 0
        lo = hi
        if lo == 0
            lo = abs(xv[1])
            lo == 0 && (lo = 1.0)
        end
    end
    return 0.9 * lo * SimLev.r_pow(Float64(length(xv)), -0.2)
end

function _bindist(x, w, xlo, xhi, n)
    y = zeros(2 * n)
    ixmin = 0
    ixmax = n - 2
    xdelta = (xhi - xlo) / (n - 1)
    for (xi, wi) in zip(x, w)
        if isfinite(xi)
            xpos = (xi - xlo) / xdelta
            (xpos > 2147483647 || xpos < -2147483648) && continue
            ix = trunc(Int, floor(xpos))
            fx = xpos - ix
            if ixmin <= ix <= ixmax
                y[ix+1] += (1 - fx) * wi
                y[ix+2] += fx * wi
            elseif ix == -1
                y[1] += fx * wi
            elseif ix == ixmax + 1
                y[ix+1] += (1 - fx) * wi
            end
        end
    end
    y
end

"""
    density(x; bw = "nrd0", adjust = 1, kernel = "gaussian", weights = nothing, n = 512, from_ = nothing, to = nothing, cut = 3, na_rm = false)

`density.default(...)`: RList (Klasse \"density\") mit x, y, bw, n.
"""
function density(x; bw = "nrd0", adjust::Real = 1, kernel::AbstractString = "gaussian", weights = nothing,
                 n::Integer = 512, from_ = nothing, to = nothing, cut::Real = 3, na_rm::Bool = false)
    kernels = ["gaussian", "epanechnikov", "rectangular", "triangular", "biweight", "cosine", "optcosine"]
    km = [k for k in kernels if startswith(k, kernel)]
    length(km) != 1 && error("'arg' should be one of " * join(["“$(k)”" for k in kernels], ", "))
    kernel = km[1]
    xv = _v(x)
    N = length(xv)
    has_wts = weights !== nothing
    wv = Float64[]
    if has_wts
        wv = _v(weights)
        length(wv) != N && error("'x' and 'weights' have unequal length")
    end
    xna = isnan.(xv)
    if any(xna)
        if na_rm
            xv = xv[.!xna]
            N = length(xv)
            if has_wts
                trueD = SimLev.RLinalg.all_equal_numeric(1.0, _rsum(wv)) === true
                wv = wv[.!xna]
                trueD && (wv = wv ./ _rsum(wv))
            end
        else
            error("'x' contains missing values")
        end
    end
    nx = N
    xfin = isfinite.(xv)
    if !all(xfin)
        xv = xv[xfin]
        nx = length(xv)
    end
    if !has_wts
        wv = nx > 0 ? fill(1.0 / nx, nx) : Float64[]
        totMass = nx / N
    else
        all(isfinite, wv) || error("'weights' must all be finite")
        any(<(0), wv) && error("'weights' must not be negative")
        wsum = _rsum(wv)
        if !all(xfin)
            wv = wv[xfin]
            totMass = _rsum(wv) / wsum
        else
            totMass = 1.0
        end
        SimLev.RLinalg.all_equal_numeric(1.0, wsum) === true || @warn "sum(weights) != 1  -- will not get true density"
    end
    n_user = Int(n)
    n = max(n_user, 512)
    n > 512 && (n = trunc(Int, SimLev.r_pow(2.0, ceil(SimLev.RLibm.log2(Float64(n))))))
    if bw isa AbstractString
        nx < 2 && error("need at least 2 points to select a bandwidth automatically")
        (has_wts && var(wv) > 0) && @warn "Selecting bandwidth *not* using 'weights'"
        lowercase(bw) != "nrd0" && error("density(): nur bw = 'nrd0' ist portiert")
        bw = bw_nrd0(xv)
    end
    bw = Float64(bw)
    isfinite(bw) || error("non-finite 'bw'")
    bw = adjust * bw
    bw <= 0 && error("'bw' is not positive.")
    from_ === nothing && (from_ = minimum(xv) - cut * bw)
    to === nothing && (to = maximum(xv) + cut * bw)
    from_ = Float64(from_); to = Float64(to)
    isfinite(from_) || error("non-finite 'from'")
    isfinite(to) || error("non-finite 'to'")
    lo = from_ - 4 * bw
    up = to + 4 * bw
    y = _bindist(xv, wv, lo, up, n) .* totMass
    kords = seq_len_out(0.0, 2 * (up - lo), 2 * n)
    kords[n+2:2n] = -kords[n:-1:2]
    cosf = SimLev.RLibm.c_cos
    if kernel == "gaussian"
        kords = _v(SimLev.RNmath.dnorm(kords; sd = bw))
    elseif kernel == "rectangular"
        a = bw * sqrt(3.0)
        kords = Float64[abs(k) < a ? 0.5 / a : 0.0 for k in kords]
    elseif kernel == "triangular"
        a = bw * sqrt(6.0)
        kords = Float64[abs(k) < a ? (1 - abs(k) / a) / a : 0.0 for k in kords]
    elseif kernel == "epanechnikov"
        a = bw * sqrt(5.0)
        kords = Float64[(q = abs(k) / a; abs(k) < a ? 3 / 4 * (1 - q * q) / a : 0.0) for k in kords]
    elseif kernel == "biweight"
        a = bw * sqrt(7.0)
        kords = Float64[(q = abs(k) / a; t = 1 - q * q; abs(k) < a ? 15 / 16 * (t * t) / a : 0.0) for k in kords]
    elseif kernel == "cosine"
        a = bw / sqrt(1 / 3 - 2 / (pi * pi))
        kords = Float64[abs(k) < a ? (1 + cosf(pi * k / a)) / (2 * a) : 0.0 for k in kords]
    else
        a = bw / sqrt(1 - 8 / (pi * pi))
        kords = Float64[abs(k) < a ? pi / 4 * cosf(pi * k / (2 * a)) / a : 0.0 for k in kords]
    end
    fyr, fyi = fft_vec(y, zeros(length(y)))
    fkr, fki = fft_vec(kords, zeros(length(kords)))
    pr = similar(fyr); pim = similar(fyi)
    for k in eachindex(fyr)
        cr = fkr[k]; ci = -fki[k]
        pr[k] = fyr[k] * cr - fyi[k] * ci
        pim[k] = fyr[k] * ci + fyi[k] * cr
    end
    kr, _ = fft_vec(pr, pim; inverse = true)
    kv = Float64[(t = kr[k] / length(y); isnan(t) ? t : (t > 0 ? t : 0.0)) for k in 1:n]
    xords = seq_len_out(lo, up, n)
    xo = seq_len_out(from_, to, n_user)
    return RList("x" => xo, "y" => approx(xords, kv; xout = xo)["y"], "bw" => bw, "n" => N, "call" => nothing,
                 "data.name" => "x", "has.na" => false; class = "density")
end

# ── dist / hclust ────────────────────────────────────────────────────────

const _DIST_METHODS = ["euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski"]

_mkdist(v, size, labels, diag, upper, method) =
    RVector(collect(Float64, v); attrs = Dict{String,Any}("Size" => size, "Labels" => labels, "Diag" => diag,
                                                         "Upper" => upper, "method" => method, "class" => ["dist"]))

"`dist(x, method, diag, upper, p)`: RVector (Klasse \"dist\", Attribute Size, Labels, Diag, Upper, method)."
function dist(x; method::AbstractString = "euclidean", diag::Bool = false, upper::Bool = false, p::Real = 2)
    startswith("euclidian", method) && (method = "euclidean")
    hits = [i for (i, m) in enumerate(_DIST_METHODS) if startswith(m, method)]
    isempty(hits) && error("invalid distance method")
    (length(hits) > 1 && !(method in _DIST_METHODS)) && error("ambiguous distance method")
    mi = length(hits) == 1 ? hits[1] : findfirst(==(method), _DIST_METHODS)
    X, _, _ = _as_cov_input(x)
    rn = x isa NamedMat ? x.rownames : x isa RFrame ? x.rownames : x isa RVector ? x.names : nothing
    nr = size(X, 1)
    p = Float64(p)
    (mi == 6 && (!isfinite(p) || p <= 0)) && error("distance(): invalid p")
    out = Float64[]
    warned = Ref(false)
    for j in 1:nr, i in j+1:nr
        push!(out, _dist1(view(X, i, :), view(X, j, :), mi, p, warned))
    end
    warned[] && @warn "treating non-finite values as NA"
    return _mkdist(out, nr, rn, diag, upper, _DIST_METHODS[mi])
end

function _dist1(a, b, method, p, warned)
    nc = length(a)
    both(x1, x2) = !isnan(x1) && !isnan(x2)
    d = 0.0; cnt = 0
    if method == 2
        d = -_DBL_MAX
        for k in 1:nc
            both(a[k], b[k]) || continue
            dev = abs(a[k] - b[k])
            isnan(dev) && continue
            dev > d && (d = dev)
            cnt += 1
        end
        cnt == 0 && return NA
        return d
    elseif method == 4
        for k in 1:nc
            x1 = a[k]; x2 = b[k]
            both(x1, x2) || continue
            s = abs(x1) + abs(x2)
            df = abs(x1 - x2)
            if s > 2.2250738585072014e-308 || df > 2.2250738585072014e-308
                dev = df / s
                if !isnan(dev) || (!isfinite(df) && df == s)
                    isnan(dev) && (dev = 1.0)
                    d += dev
                    cnt += 1
                end
            end
        end
        cnt == 0 && return NA
        cnt != nc && (d /= (cnt / nc))
        return d
    elseif method == 5
        total = 0; count = 0; dd = 0
        for k in 1:nc
            x1 = a[k]; x2 = b[k]
            both(x1, x2) || continue
            if !(isfinite(x1) && isfinite(x2))
                warned[] = true
            else
                if x1 != 0.0 || x2 != 0.0
                    count += 1
                    (x1 != 0.0 && x2 != 0.0) || (dd += 1)
                end
                total += 1
            end
        end
        total == 0 && return NA
        count == 0 && return 0.0
        return dd / count
    end
    for k in 1:nc
        both(a[k], b[k]) || continue
        dev = a[k] - b[k]
        isnan(dev) && continue
        if method == 1
            d += dev * dev
        elseif method == 3
            d += abs(dev)
        else
            d += SimLev.r_pow(abs(dev), p)
        end
        cnt += 1
    end
    cnt == 0 && return NA
    cnt != nc && (d /= (cnt / nc))
    method == 1 && return sqrt(d)
    method == 3 && return d
    return SimLev.r_pow(d, 1.0 / p)
end

_is_dist(d) = d isa RVector && "dist" in SimLev.r_class(d)

"`as.dist(m)`: unteres Dreieck einer Matrix als dist-Objekt."
function as_dist(m; diag::Bool = false, upper::Bool = false)
    _is_dist(m) && return m
    A, _, cn = _as_cov_input(m)
    rn = m isa NamedMat ? m.rownames : m isa RFrame ? m.rownames : nothing
    p = size(A, 1)
    size(A, 2) != p && @warn "non-square matrix"
    vals = Float64[A[i, j] for j in 1:size(A, 2) for i in 1:size(A, 1) if i > j]
    return _mkdist(vals, p, rn !== nothing ? rn : cn, diag, upper, nothing)
end

"`as.matrix(<dist>)` (dimnames Labels bzw. 1..n)."
function dist_as_matrix(d)
    size = d.attrs["Size"]
    M = zeros(size, size)
    k = 0
    for j in 1:size, i in j+1:size
        k += 1
        M[i, j] = d.values[k]
    end
    M = M .+ permutedims(M)
    lab = d.attrs["Labels"] !== nothing ? d.attrs["Labels"] : string.(1:size)
    return NamedMat(M; rownames = lab, colnames = lab)
end

const _HC_METHODS = ["ward.D", "single", "complete", "average", "mcquitty", "median", "centroid", "ward.D2"]

"`hclust(d, method, members)` (Fortran hclust/hcass2): RList (Klasse \"hclust\")."
function hclust(d, method::AbstractString = "complete"; members = nothing)
    if method == "ward"
        println(stderr, "The \"ward\" method has been renamed to \"ward.D\"; note new \"ward.D2\"")
        method = "ward.D"
    end
    hits = [i for (i, m) in enumerate(_HC_METHODS) if startswith(m, method)]
    method in _HC_METHODS && (hits = [findfirst(==(method), _HC_METHODS)])
    isempty(hits) && error("invalid clustering method " * method)
    length(hits) > 1 && error("ambiguous clustering method " * method)
    iopt = hits[1]
    _is_dist(d) || error("invalid dissimilarities")
    n = Int(d.attrs["Size"])
    n > 65536 && error("size cannot be NA nor exceed 65536")
    n < 2 && error("must have n >= 2 objects to cluster")
    ln = n * (n - 1) ÷ 2
    if length(d.values) != ln
        length(d.values) < ln && error("dissimilarities of improper length")
        @warn "dissimilarities of improper length"
    end
    membr = members === nothing ? ones(n) : _v(members)
    length(membr) != n && error("invalid length of members")
    diss = collect(Float64, d.values)
    ia, ib, crit = _hclust_f(n, ln, iopt, membr, diss)
    order, iia, iib = _hcass2(n, ia, ib)
    return RList("merge" => hcat(iia[1:n-1], iib[1:n-1]), "height" => _vec_out(crit[1:n-1]),
                 "order" => order, "labels" => d.attrs["Labels"], "method" => _HC_METHODS[iopt],
                 "call" => nothing, "dist.method" => d.attrs["method"]; class = "hclust")
end

@inline _ioffst(n, i, j) = j + (i - 1) * n - (i * (i + 1)) ÷ 2

function _hclust_f(n, ln, iopt, membr0, diss)
    INF = 1.0e300
    ia = zeros(Int, n); ib = zeros(Int, n); crit = zeros(n)
    nn = zeros(Int, n); disnn = zeros(n)
    membr = collect(Float64, membr0)
    flag = fill(true, n)
    im = jj = jm = 0
    ncl = n
    if iopt == 8
        for i in 1:ln
            diss[i] = diss[i] * diss[i]
        end
    end
    for i in 1:n-1
        dmin = INF
        for j in i+1:n
            ind = _ioffst(n, i, j)
            if dmin > diss[ind]
                dmin = diss[ind]
                jm = j
            end
        end
        nn[i] = jm
        disnn[i] = dmin
    end
    isWard = iopt == 1 || iopt == 8
    while true
        dmin = INF
        for i in 1:n-1
            if flag[i] && disnn[i] < dmin
                dmin = disnn[i]
                im = i
                jm = nn[i]
            end
        end
        ncl -= 1
        i2 = min(im, jm)
        j2 = max(im, jm)
        ia[n-ncl] = i2
        ib[n-ncl] = j2
        iopt == 8 && (dmin = sqrt(dmin))
        crit[n-ncl] = dmin
        flag[j2] = false
        dmin = INF
        for k in 1:n
            if flag[k] && k != i2
                ind1 = i2 < k ? _ioffst(n, i2, k) : _ioffst(n, k, i2)
                ind2 = j2 < k ? _ioffst(n, j2, k) : _ioffst(n, k, j2)
                d12 = diss[_ioffst(n, i2, j2)]
                if isWard
                    v = ((membr[i2] + membr[k]) * diss[ind1] + (membr[j2] + membr[k]) * diss[ind2]) - membr[k] * d12
                    diss[ind1] = v / ((membr[i2] + membr[j2]) + membr[k])
                elseif iopt == 2
                    diss[ind1] = diss[ind1] <= diss[ind2] ? diss[ind1] : diss[ind2]
                elseif iopt == 3
                    diss[ind1] = diss[ind1] >= diss[ind2] ? diss[ind1] : diss[ind2]
                elseif iopt == 4
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2]) / (membr[i2] + membr[j2])
                elseif iopt == 5
                    diss[ind1] = (diss[ind1] + diss[ind2]) / 2
                elseif iopt == 6
                    diss[ind1] = ((diss[ind1] + diss[ind2]) - d12 / 2) / 2
                elseif iopt == 7
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2] -
                                  membr[i2] * membr[j2] * d12 / (membr[i2] + membr[j2])) / (membr[i2] + membr[j2])
                end
                if i2 < k
                    if diss[ind1] < dmin
                        dmin = diss[ind1]
                        jj = k
                    end
                else
                    if diss[ind1] < disnn[k]
                        disnn[k] = diss[ind1]
                        nn[k] = i2
                    end
                end
            end
        end
        membr[i2] = membr[i2] + membr[j2]
        disnn[i2] = dmin
        nn[i2] = jj
        for i in 1:n-1
            if flag[i] && (nn[i] == i2 || nn[i] == j2)
                dmin = INF
                for j in i+1:n
                    if flag[j]
                        ind = _ioffst(n, i, j)
                        if diss[ind] < dmin
                            dmin = diss[ind]
                            jj = j
                        end
                    end
                end
                nn[i] = jj
                disnn[i] = dmin
            end
        end
        ncl > 1 || break
    end
    return ia, ib, crit
end

function _hcass2(n, ia, ib)
    iia = zeros(Int, n); iib = zeros(Int, n); iorder = zeros(Int, n)
    for i in 1:n
        iia[i] = ia[i]
        iib[i] = ib[i]
    end
    for i in 1:n-2
        k = min(ia[i], ib[i])
        for j in i+1:n-1
            ia[j] == k && (iia[j] = -i)
            ib[j] == k && (iib[j] = -i)
        end
    end
    for i in 1:n-1
        iia[i] = -iia[i]
        iib[i] = -iib[i]
    end
    for i in 1:n-1
        if iia[i] > 0 && iib[i] < 0
            k = iia[i]; iia[i] = iib[i]; iib[i] = k
        end
        if iia[i] > 0 && iib[i] > 0
            k1 = min(iia[i], iib[i]); k2 = max(iia[i], iib[i])
            iia[i] = k1; iib[i] = k2
        end
    end
    iorder[1] = iia[n-1]
    iorder[2] = iib[n-1]
    loc = 2
    for i in n-2:-1:1
        for j in 1:loc
            if iorder[j] == i
                iorder[j] = iia[i]
                if j == loc
                    loc += 1
                    iorder[loc] = iib[i]
                else
                    loc += 1
                    for k in loc:-1:j+2
                        iorder[k] = iorder[k-1]
                    end
                    iorder[j+1] = iib[i]
                end
                break
            end
        end
    end
    for i in 1:n
        iorder[i] = -iorder[i]
    end
    return iorder, iia, iib
end

# ── p.adjust / ecdf / ave / aggregate / t.test ───────────────────────────

const _PADJ = ["holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none"]

function _cumext(x, greater::Bool)
    out = similar(x)
    m = greater ? -Inf : Inf
    for (k, v) in enumerate(x)
        if isnan(v)
            out[k:end] .= NA
            return out
        end
        m = greater ? (m > v ? m : v) : (m < v ? m : v)
        out[k] = m
    end
    out
end
_pmin1(x) = Float64[isnan(t) ? t : (t < 1.0 ? t : 1.0) for t in x]

"`p.adjust(p, method, n)`."
function p_adjust(p, method::AbstractString = "holm"; n = nothing)
    hits = [m for m in _PADJ if startswith(m, method)]
    method in _PADJ && (hits = [method])
    length(hits) != 1 && error("'arg' should be one of " * join(["“$(m)”" for m in _PADJ], ", "))
    method = hits[1]
    method == "fdr" && (method = "BH")
    pv, nm = _vec(p)
    p0 = copy(pv)
    nna = .!isnan.(pv)
    pp = pv[nna]
    lp = length(pp)
    n === nothing && (n = lp)
    n >= lp || error("n >= lp is not TRUE")
    n <= 1 && return _vec_out(p0, nm)
    (n == 2 && method == "hommel") && (method = "hochberg")
    if method == "bonferroni"
        r = _pmin1(n .* pp)
    elseif method == "holm"
        i = 1:lp
        o = order(pp)
        ro = order(Float64.(o))
        r = _pmin1(_cumext(Float64.(n + 1 .- i) .* pp[o], true))[ro]
    elseif method == "hommel"
        nn_ = Int(n)
        q_p = n > lp ? vcat(pp, ones(nn_ - lp)) : copy(pp)
        i = 1:nn_
        o = order(q_p)
        q_p = q_p[o]
        ro = order(Float64.(o))
        mn = minimum(nn_ .* q_p ./ i)
        q = fill(mn, nn_)
        pa = fill(mn, nn_)
        for j in nn_-1:-1:2
            ij = 1:(nn_-j+1)
            i2 = (nn_-j+2):nn_
            q1 = minimum(j .* q_p[i2] ./ (2:j))
            q[ij] = min.(j .* q_p[ij], q1)
            q[i2] .= q[nn_-j+1]
            pa = max.(pa, q)
        end
        r = max.(pa, q_p)[lp < nn_ ? ro[1:lp] : ro]
    elseif method in ("hochberg", "BH", "BY")
        i = lp:-1:1
        o = order(pp; decreasing = true)
        ro = order(Float64.(o))
        if method == "hochberg"
            r = _pmin1(_cumext(Float64.(n + 1 .- i) .* pp[o], false))[ro]
        elseif method == "BH"
            r = _pmin1(_cumext((n ./ i) .* pp[o], false))[ro]
        else
            q = _rsum(1.0 ./ (1:Int(n)))
            r = _pmin1(_cumext((q * n ./ i) .* pp[o], false))[ro]
        end
    else
        r = pp
    end
    p0[nna] = r
    return _vec_out(p0, nm)
end

"`ecdf(x)`: aufrufbare Treppenfunktion (ApproxFun, attrs nobs)."
function ecdf(x)
    xs = sort(filter(!isnan, _v(x)); lt = <)
    n = length(xs)
    n < 1 && error("'x' must have 1 or more non-missing values")
    vals, gidx = _unique_keys(xs)
    counts = zeros(Int, length(vals))
    for g in gidx
        counts[g] += 1
    end
    yv = Float64.(cumsum(counts)) ./ n
    return ApproxFun(vals, yv, 2, 0.0, 1.0, 0.0, Dict{String,Any}("nobs" => n, "class" => ["ecdf", "stepfun", "function"]))
end

_gkey(v) = v isa AbstractFloat ? _z0(Float64(v)) : v
_isna_el(v) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))
_grpvals(g) = g isa RVector ? g.values : g isa AbstractArray ? vec(g) : [g]

"`ave(x, ..., FUN = mean)`; FUN erhält einen Vector."
function ave(x, groups...; FUN = nothing)
    xv, nm = _vec(x)
    FUN === nothing && (FUN = _rmean)
    out = copy(xv)
    if isempty(groups)
        r = _v(FUN(xv))
        for i in eachindex(out)
            out[i] = r[(i - 1) % length(r) + 1]
        end
        return _vec_out(out, nm)
    end
    gs = [_grpvals(g) for g in groups]
    d = Dict{Any,Vector{Int}}()
    keys_ = Any[]
    for i in eachindex(xv)
        k = Tuple(_gkey(g[i]) for g in gs)
        any(_isna_el, k) && continue
        haskey(d, k) || (d[k] = Int[]; push!(keys_, k))
        push!(d[k], i)
    end
    # Gruppen in der Reihenfolge von interaction(...): Stufen wie factor()
    # (Zahlen numerisch, Zeichenketten nach R's Kollation), erste Variable
    # läuft am schnellsten
    pos = Dict{Any,Int}[]
    for g in gs
        ok = [!_isna_el(v) for v in g]
        lv = any(ok) ? r_sort(unique(_gkey.(g[ok]))) : Any[]
        lv isa AbstractVector || (lv = [lv])
        push!(pos, Dict{Any,Int}(_gkey(v) => i for (i, v) in enumerate(lv)))
    end
    sort!(keys_; by = k -> Tuple(pos[j][k[j]] for j in length(k):-1:1))
    for k in keys_
        ix = d[k]
        r = _v(FUN(xv[ix]))
        for (t, i) in enumerate(ix)
            out[i] = r[(t - 1) % length(r) + 1]
        end
    end
    return _vec_out(out, nm)
end

_bypairs(by::AbstractDict) = [(string(k), v) for (k, v) in by]
_bypairs(by::NamedTuple) = [(string(k), v) for (k, v) in pairs(by)]
_bypairs(by::AbstractVector{<:Pair}) = [(string(p.first), p.second) for p in by]

"`aggregate(x, by = list(name = g, ...), FUN)` für einen Vektor x: RFrame mit den Gruppenspalten und x."
function aggregate(x, by, FUN)
    xv = _v(x)
    bp = _bypairs(by)
    names_ = [b[1] for b in bp]
    levels = Vector{Any}[]
    codes = Vector{Int}[]
    for (_, g0) in bp
        g = _grpvals(g0)
        ok = [!_isna_el(v) for v in g]
        lv = collect(r_sort(unique(_gkey.(g[ok]))) |> (t -> t isa AbstractVector ? t : [t]))
        push!(levels, lv)
        pos = Dict{Any,Int}(_gkey(v) => i for (i, v) in enumerate(lv))
        push!(codes, [ok[i] ? get(pos, _gkey(g[i]), 0) : 0 for i in eachindex(g)])
    end
    combos = Dict{Vector{Int},Vector{Int}}()
    for i in eachindex(xv)
        key = [c[i] for c in codes]
        any(==(0), key) && continue
        push!(get!(combos, key, Int[]), i)
    end
    function grp(key)
        g = 0; mult = 1
        for (k, lv) in zip(key, levels)
            g += (k - 1) * mult
            mult *= length(lv)
        end
        g
    end
    ks = sort(collect(keys(combos)); by = grp)
    cols = Pair{String,Any}[]
    for (j, nm) in enumerate(names_)
        push!(cols, nm => [levels[j][k[j]] for k in ks])
    end
    push!(cols, "x" => Float64[first(_v(FUN(xv[combos[k]]))) for k in ks])
    return RFrame(cols...)
end

"`t.test.default(x, y, alternative, mu, paired, var.equal, conf.level)`: RList (Klasse \"htest\")."
function t_test(x, y = nothing; alternative::AbstractString = "two.sided", mu::Real = 0, paired::Bool = false,
                var_equal::Bool = false, conf_level::Real = 0.95)
    alts = ["two.sided", "less", "greater"]
    am = [a for a in alts if startswith(a, alternative)]
    length(am) != 1 && error("'arg' should be one of “two.sided”, “less”, “greater”")
    alternative = am[1]
    isnan(mu) && error("'mu' must be a single number")
    (isfinite(conf_level) && 0 <= conf_level <= 1) || error("'conf.level' must be a single number between 0 and 1")
    mu = Float64(mu); conf_level = Float64(conf_level)
    xv = _v(x)
    if y !== nothing
        yv = _v(y)
        dname = "x and y"
        if paired
            ok = .!(isnan.(xv) .| isnan.(yv))
            xok = yok = ok
        else
            yok = .!isnan.(yv)
            xok = .!isnan.(xv)
        end
        yv = yv[yok]
    else
        dname = "x"
        paired && error("'y' is missing for paired test")
        xok = .!isnan.(xv)
        yv = nothing
    end
    xv = xv[xok]
    if paired
        xv = xv .- yv
        yv = nothing
    end
    nx = length(xv)
    mx = _rmean(xv)
    vx = nx > 1 ? var(xv) : NA
    eps = _DBL_EPS
    NM = SimLev.RNmath
    if yv === nothing
        nx < 2 && error("not enough 'x' observations")
        df = Float64(nx - 1)
        stderr_ = sqrt(vx / nx)
        stderr_ < 10 * eps * abs(mx) && error("data are essentially constant")
        tstat = (mx - mu) / stderr_
        method = paired ? "Paired t-test" : "One Sample t-test"
        estimate = RVector([mx]; names = [paired ? "mean difference" : "mean of x"])
    else
        ny = length(yv)
        (nx < 1 || (!var_equal && nx < 2)) && error("not enough 'x' observations")
        (ny < 1 || (!var_equal && ny < 2)) && error("not enough 'y' observations")
        (var_equal && nx + ny < 3) && error("not enough observations")
        my = _rmean(yv)
        vy = ny > 1 ? var(yv) : NA
        method = (var_equal ? " " : "Welch ") * "Two Sample t-test"
        estimate = RVector([mx, my]; names = ["mean of x", "mean of y"])
        if var_equal
            df = Float64(nx + ny - 2)
            v = 0.0
            nx > 1 && (v = v + (nx - 1) * vx)
            ny > 1 && (v = v + (ny - 1) * vy)
            v = v / df
            stderr_ = sqrt(v * (1 / nx + 1 / ny))
        else
            stderrx = sqrt(vx / nx)
            stderry = sqrt(vy / ny)
            stderr_ = sqrt(stderrx * stderrx + stderry * stderry)
            df = SimLev.r_pow(stderr_, 4) / (SimLev.r_pow(stderrx, 4) / (nx - 1) + SimLev.r_pow(stderry, 4) / (ny - 1))
        end
        stderr_ < 10 * eps * max(abs(mx), abs(my)) && error("data are essentially constant")
        tstat = (mx - my - mu) / stderr_
    end
    if alternative == "less"
        pval = NM.pt(tstat, df)
        cint = [-Inf, tstat + NM.qt(conf_level, df)]
    elseif alternative == "greater"
        pval = NM.pt(tstat, df; lower_tail = false)
        cint = [tstat - NM.qt(conf_level, df), Inf]
    else
        pval = 2 * NM.pt(-abs(tstat), df)
        alpha = 1 - conf_level
        c = NM.qt(1 - alpha / 2, df)
        cint = [tstat + (-c), tstat + c]
    end
    cint = RVector([mu + v * stderr_ for v in cint]; attrs = Dict{String,Any}("conf.level" => conf_level))
    return RList("statistic" => RVector([tstat]; names = ["t"]), "parameter" => RVector([df]; names = ["df"]),
                 "p.value" => pval, "conf.int" => cint, "estimate" => estimate,
                 "null.value" => RVector([mu]; names = [paired ? "mean difference" : (y !== nothing ? "difference in means" : "mean")]),
                 "stderr" => stderr_, "alternative" => alternative, "method" => method, "data.name" => dname;
                 class = "htest")
end

# ── smooth.spline ────────────────────────────────────────────────────────

function _nknots_smspl(n::Int)
    n < 50 && return n
    L2 = SimLev.RLibm.log2
    a1 = L2(50.0); a2 = L2(100.0); a3 = L2(140.0); a4 = L2(200.0)
    if n < 200
        v = SimLev.r_pow(2.0, a1 + (a2 - a1) * (n - 50) / 150)
    elseif n < 800
        v = SimLev.r_pow(2.0, a2 + (a3 - a2) * (n - 200) / 600)
    elseif n < 3200
        v = SimLev.r_pow(2.0, a3 + (a4 - a3) * (n - 800) / 2400)
    else
        v = 200 + SimLev.r_pow(Float64(n - 3200), 0.2)
    end
    return trunc(Int, v)
end

"""
    smooth_spline(x, y = nothing; w, df, spar, lambda_, cv = false, all_knots = false, nknots, keep_data = true, df_offset = 0, penalty = 1, control_spar, tol)

`smooth.spline(...)`; `lambda` heißt `lambda_`, `cv = missing` entspricht
`cv = NA`. Ergebnis: RList (Klasse \"smooth.spline\"); Vorhersage mit
`predict_smooth_spline`.
"""
function smooth_spline(x, y = nothing; w = nothing, df = nothing, spar = nothing, lambda_ = nothing, cv = false,
                       all_knots = false, nknots = nothing, keep_data::Bool = true, df_offset::Real = 0,
                       penalty::Real = 1, control_spar = nothing, tol = nothing, keep_stuff::Bool = false)
    contr = Dict{String,Any}("low" => -1.5, "high" => 1.5, "tol" => 1e-4, "eps" => 2e-8, "maxit" => 500, "trace" => false)
    control_spar === nothing || merge!(contr, _ctl_dict(control_spar))
    (contr["tol"] < 0 || contr["eps"] <= 0 || contr["maxit"] <= 0) && error("invalid 'control.spar'")
    xv = _v(x)
    if y === nothing
        yv = xv
        xv = Float64.(1:length(yv))
    else
        yv = _v(y)
        length(yv) != length(xv) && error("'x' and 'y' lengths differ")
    end
    (all(isfinite, xv) && all(isfinite, yv)) || error("missing or infinite values in inputs are not allowed")
    n = length(xv)
    no_wgts = w === nothing
    wv = Float64[]
    if !no_wgts
        wv = _v(w)
        n != length(wv) && error("lengths of 'x' and 'w' must match")
        any(<(0), wv) && error("all weights should be non-negative")
        all(==(0), wv) && error("some weights should be positive")
        wv = (wv .* Float64(count(>(0), wv))) ./ _rsum(wv)
    end
    if tol === nothing
        q = quantile(xv, [0.25, 0.75]; names = false)
        tol = 1e-6 * (q[2] - q[1])
    end
    tol = Float64(tol)
    (!isfinite(tol) || tol <= 0) && error("'tol' must be strictly positive and finite")
    mx = _rmean(xv)
    xx = Float64[round((t - mx) / tol) for t in xv]
    uns = n > 1 && any(i -> xv[i+1] < xv[i], 1:n-1)
    iOx = uns ? _stable_argsort(xv, false, false) : collect(1:n)
    xxs = xx[iOx]
    nd = vcat(true, [xxs[i] < xxs[i+1] for i in 1:n-1])
    ux = xv[iOx][nd]
    nx = length(ux)
    nx <= 3 && error("need at least four unique 'x' values")
    if nx == n
        ox = uns ? invperm(iOx) : collect(1:n)
        tmp = no_wgts ? hcat(ones(n), 1 .* yv, 1 .* (yv .* yv))[iOx, :] : hcat(wv, wv .* yv, wv .* (yv .* yv))[iOx, :]
    else
        ukeys = xxs[nd]
        ox = [searchsortedfirst(ukeys, t; lt = <) for t in xx]
        tmp = zeros(nx, 3)
        for g in 1:nx
            idx = findall(==(g), ox)
            if no_wgts
                tmp[g, :] = [Float64(length(idx)), _rsum(yv[idx]), _rsum(yv[idx] .* yv[idx])]
            else
                tmp[g, :] = [_rsum(wv[idx]), _rsum(wv[idx] .* yv[idx]), _rsum(wv[idx] .* (yv[idx] .* yv[idx]))]
            end
        end
    end
    wbar = tmp[:, 1]
    ybar = tmp[:, 2] ./ Float64[t > 0 ? t : 1.0 for t in wbar]
    yssw = _rsum(tmp[:, 3] .- wbar .* (ybar .* ybar))
    (cv === missing && df !== nothing) && error("'cv' must not be NA when 'df' is specified")
    CV = cv !== missing && cv === true
    (CV && nx < n) && @warn "cross-validation with non-unique 'x' values seems doubtful"
    r_ux = ux[nx] - ux[1]
    xbar = (ux .- ux[1]) ./ r_ux
    if !(all_knots isa Bool)
        ak = _v(all_knots)
        (length(ak) > 1 && any(i -> ak[i+1] <= ak[i], 1:length(ak)-1)) && error("Numeric 'all.knots' must be strictly increasing")
        nknots !== nothing && @warn "'all.knots' is vector of knots; 'nknots' specification is disregarded"
        nknots = length(ak)
        (0 < ak[1] || ak[end] < 1) && error("numeric 'all.knots' must cover [0,1] (= the transformed data-range)")
        knot = vcat(fill(ak[1], 3), ak, fill(ak[end], 3))
    else
        if all_knots
            nknots !== nothing && @warn "'all.knots' is TRUE; 'nknots' specification is disregarded"
            nknots = nx
        elseif nknots === nothing
            nknots = _nknots_smspl(nx)
        else
            nknots isa Function && (nknots = nknots(nx))
            if nknots < 1
                error("'nknots' must be at least 1")
            elseif nknots > nx
                error("cannot use more inner knots than unique 'x' values")
            end
        end
        nknots = Int(nknots)
        inner = all_knots ? xbar : xbar[[trunc(Int, t) for t in seq_len_out(1, nx, nknots)]]
        knot = vcat(fill(xbar[1], 3), inner, fill(xbar[nx], 3))
    end
    nk = nknots + 2
    spar_is_lambda = lambda_ !== nothing
    if spar_is_lambda
        spar !== nothing && error("must not specify both 'spar' and 'lambda'")
        ispar = 1
    else
        ispar = spar === nothing ? (contr["trace"] == true ? -1 : 0) : 1
    end
    sparv = spar_is_lambda ? Float64(lambda_) : (ispar == 1 ? Float64(spar) : 0.0)
    icrit = cv === missing ? 0 : (cv === true ? 2 : 1)
    dofoff = Float64(df_offset)
    if df !== nothing
        if 1 < df <= nx
            icrit = 3
            dofoff = Float64(df)
        else
            @warn "not using invalid df; must have 1 < df <= n := #{unique x} = $nx"
        end
    end
    isetup = spar_is_lambda ? 2 : 0
    fit = sbart(Float64(penalty), dofoff, xbar, ybar, wbar, yssw, nx, knot, nk, icrit, sparv, ispar,
                Int(contr["maxit"]), Float64(contr["low"]), Float64(contr["high"]), Float64(contr["tol"]),
                Float64(contr["eps"]), isetup)
    ty = fit.sz[1:nx]
    if cv === missing
        lev = NA
        dfv = NA
    else
        lev = fit.lev[1:nx]
        dfv = _rsum(lev)
        isnan(dfv) && error("NA lev[]; probably smoothing parameter 'spar' way too large!")
    end
    if fit.ier > 0
        sml = !spar_is_lambda && fit.spar < 0.5
        kind = spar_is_lambda ? "extreme" : (sml ? "small" : "large")
        wtxt = "smoothing parameter value too " * kind
        (spar_is_lambda || sml) && error(wtxt)
        ty = fill(_rmean(yv), nx)
        dfv = 1.0
        @warn wtxt * "\nsetting df = 1  __use with care!__"
    end
    if cv === missing
        cvcrit = NA
    else
        r = yv .- ty[ox]
        if CV
            ww = copy(wbar)
            ww[ww .== 0] .= 1
            wfac = no_wgts ? ones(n) : wv
            r = r ./ (1 .- (lev[ox] .* wfac) ./ ww[ox])
            cvcrit = no_wgts ? _rmean(r .* r) : weighted_mean(r .* r, wv)
        else
            base = no_wgts ? _rmean(r .* r) : weighted_mean(r .* r, wv)
            t = 1 - (df_offset + penalty * dfv) / n
            cvcrit = base / (t * t)
        end
    end
    dd = ybar .- ty
    pen = _rsum(wbar .* (dd .* dd))
    fobj = RList("knot" => knot, "nk" => nk, "min" => ux[1], "range" => r_ux, "coef" => fit.coef[1:nk];
                 class = "smooth.spline.fit")
    return RList("x" => ux, "y" => ty, "w" => wbar, "yin" => ybar, "tol" => tol,
                 "data" => (keep_data ? RList("x" => xv, "y" => yv, "w" => (no_wgts ? 1.0 : wv)) : nothing),
                 "no.weights" => no_wgts, "n" => n, "lev" => lev, "cv" => cv, "cv.crit" => cvcrit, "pen.crit" => pen,
                 "crit" => fit.crit, "df" => dfv, "spar" => (spar_is_lambda ? NA : fit.spar),
                 "ratio" => (spar_is_lambda ? NA : fit.ratio), "lambda" => fit.lspar,
                 "iparms" => RVector([Float64(icrit), Float64(ispar), Float64(ispar != 1 ? fit.iter : contr["maxit"]),
                                      Float64(spar_is_lambda), fit.ier != 0 ? Float64(fit.ier) : NA];
                                     names = ["icrit", "ispar", "iter", "", "errorI"]),
                 "auxM" => nothing, "fit" => fobj, "call" => nothing; class = "smooth.spline")
end

function _predict_ssfit(obj, x = nothing, deriv::Int = 0)
    x === nothing && (x = seq_len_out(obj["min"], obj["min"] + obj["range"], length(obj["coef"]) - 4))
    xv = _v(x)
    xs = (xv .- obj["min"]) ./ obj["range"]
    el = xs .< 0
    er = xs .> 1
    ex = el .| er
    interp = .!ex
    y = copy(xs)
    if any(interp)
        y[interp] = bvalus(collect(Float64, obj["knot"]), collect(Float64, obj["coef"]), Int(obj["nk"]), xs[interp], deriv)
    end
    if any(ex)
        xrange = [obj["min"], obj["min"] + obj["range"]]
        if deriv == 0
            eo = _v(_predict_ssfit(obj, xrange)["y"])
            es = _v(_predict_ssfit(obj, xrange, 1)["y"]) .* obj["range"]
            any(el) && (y[el] = eo[1] .+ es[1] .* (xs[el] .- 0))
            any(er) && (y[er] = eo[2] .+ es[2] .* (xs[er] .- 1))
        elseif deriv == 1
            es = _v(_predict_ssfit(obj, xrange, 1)["y"]) .* obj["range"]
            y[el] .= es[1]
            y[er] .= es[2]
        else
            y[ex] .= 0.0
        end
    end
    deriv > 0 && (y = y ./ SimLev.r_pow(obj["range"], Float64(deriv)))
    return RList("x" => x, "y" => _vec_out(y))
end

"`predict.smooth.spline(object, x, deriv)`: RList mit x, y."
function predict_smooth_spline(object, x = nothing; deriv::Integer = 0)
    if x === nothing
        deriv == 0 && return RList("x" => object["x"], "y" => object["y"])
        x = object["x"]
    end
    fit = get(object, "fit", nothing)
    fit === nothing && error("not a valid \"smooth.spline\" object")
    return _predict_ssfit(fit, x, Int(deriv))
end

"Generisches `predict` (smooth.spline; lm/glm: angepasste Werte bzw. linearer Prädiktor)."
function predict(object, args...; kwargs...)
    if object isa RList
        "smooth.spline" in object.class && return predict_smooth_spline(object, args...; kwargs...)
        if "smooth.spline.fit" in object.class
            x = isempty(args) ? nothing : args[1]
            return _predict_ssfit(object, x, Int(get(kwargs, :deriv, 0)))
        end
        if isempty(args) && isempty(kwargs)
            "glm" in object.class && return object["linear.predictors"]
            "lm" in object.class && return object["fitted.values"]
        end
    end
    error("predict() für dieses Objekt ist nicht portiert")
end

end # module
