# Gemeinsame Hilfen (long double F80), Sortieren, Ränge, Einteilen und Lagemaße (order, r_sort, r_rank, rle,
# tabulate, findInterval, cut, complete_cases, quantile, median, weighted_mean) aus R 4.3.3 (src/main/sort.c,
# qsort-body.c, seq.c; base/R/sort.R, rle.R, cut.R, findInt.R; stats/R/quantile.R, median.R, weighted.mean.R);
# Python: _r/stats_sort.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).

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

"Feld mit verschobenem Index: `z[i]` greift auf `z.v[i + z.o]` zu (bis 9.6c in `_fft.jl`)."
struct _Off{T,V<:AbstractVector{T}}
    v::V
    o::Int
end
@inline Base.getindex(z::_Off, i::Int) = @inbounds z.v[i+z.o]
@inline Base.setindex!(z::_Off, x, i::Int) = @inbounds (z.v[i+z.o] = x)

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
