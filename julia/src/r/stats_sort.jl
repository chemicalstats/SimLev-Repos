# Herkunft:           übersetzt aus R 4.3.3, src/main/sort.c, qsort-body.c, seq.c; nachgebildet nach
#                     R 4.3.3, src/library/base/R/sort.R, rle.R, cut.R, findInt.R;
#                     src/library/stats/R/quantile.R, median.R, weighted.mean.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); qsort-body.c nach R. C. Singleton,
#                     CACM-Algorithmus 347 (1969)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Ordnung, Rang, partielle Sortierung und Quantile
#                     rechnet der C-Kern core/slc_rbase_sort.cpp.
# Gemeinsame Hilfen, Sortieren, Ränge, Einteilen und Lagemaße (order, r_sort, r_rank, rle,
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
_vec(x::AbstractArray{Float64}) = (collect(Float64, vec(x)), nothing)   # ohne _fl je Element (seit 1.6.0)
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

"sum() wie R (long double; C-Kern)."
_rsum(a) = SimLev.r_sum(a)

"mean() für Doubles (long double, zweiter Korrekturdurchlauf; C-Kern)."
_rmean(a) = SimLev._rb_mean(SimLev._rbv(a))

"mean() für ganzzahlige Vektoren (C-Kern)."
_rmean_int(a) = SimLev._rb_mean_int(Int64[Int64(v) for v in a])

"`seq.int(from, to, length.out = n)` (Werte wie R)."
function seq_len_out(frm, to, length_out)
    n = trunc(Int, length_out)
    frm = Float64(frm); to = Float64(to)
    n <= 0 && return Float64[]
    return SimLev._rb_seq_len(frm, to, n)   # C-Kern sl_r_seq_len (seit 1.6.0)
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

"−0 als +0 (Schlüssel für Gleichheit wie R)."
_z0(v::Float64) = v == 0.0 ? 0.0 : v

"Stabile Sortierpermutation (−0 = +0; absteigend: Gleichstände in Eingabereihenfolge)."
function _stable_argsort(v::AbstractVector, isstr::Bool, decreasing::Bool)
    n = length(v)
    n == 0 && return Int[]
    isstr || return SimLev._rb_order([Float64[Float64(t) for t in v]], [decreasing], 1)   # C-Kern
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
    if !any(k -> k[3], keys)       # nur Zahlenschlüssel -> C-Kern sl_r_order
        nl = na_last === nothing ? -1 : (na_last === true ? 1 : 0)
        return SimLev._rb_order(Vector{Float64}[Vector{Float64}(k[1]) for k in keys], dec, nl)
    end
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
    if !isstr && haskey(SimLev._RB_TIES, ties_method)    # C-Kern sl_r_rank
        yd = SimLev._rb_rank(Float64[Float64(t) for t in xs], ties_method)
        y = ties_method == "average" ? yd : Int[Int(t) for t in yd]
    elseif ties_method in ("average", "min", "max")
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

"`tabulate(bin, nbins = max(1, bin, na.rm = TRUE))` (C-Kern)."
function tabulate(bin; nbins = nothing)
    b = _v(bin)
    if nbins === nothing
        bb = Float64[trunc(t) for t in b if !isnan(t)]
        nbins = trunc(Int, max(1.0, isempty(bb) ? 1.0 : maximum(bb)))
    end
    return _vec_out(SimLev._rb_tabulate(b, Int(nbins)))
end

"`findInterval(x, vec, rightmost.closed, all.inside, left.open)` (C-Kern)."
function findInterval(x, vec; rightmost_closed::Bool = false, all_inside::Bool = false, left_open::Bool = false)
    v = _v(vec)
    xx = _v(x)
    if any(isnan, v) || any(i -> v[i+1] < v[i], 1:length(v)-1)
        error("'vec' must be sorted non-decreasingly and not contain NAs")
    end
    r = SimLev._rb_findinterval(v, xx, rightmost_closed, all_inside, left_open)
    any(isnan, r) && return _vec_out(Union{Missing,Int}[isnan(t) ? missing : Int(t) for t in r])
    return _vec_out(Int[Int(t) for t in r])
end

"`.bincode` (C-Kern sl_r_bincode, seit 1.6.0): Intervallnummern, 0 = NA."
_bincode(x::Vector{Float64}, B::Vector{Float64}, right::Bool, include_lowest::Bool) =
    SimLev._rb_bincode(x, B, right, include_lowest)

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
        if isempty(ok)   # range(x, na.rm = TRUE) ohne Werte (Warnungen wie R, seit 1.6.0)
            @warn "no non-missing arguments to min; returning Inf"
            @warn "no non-missing arguments to max; returning -Inf"
        end
        rx = isempty(ok) ? (Inf, -Inf) : (minimum(ok), maximum(ok))
        dx = rx[2] - rx[1]
        isnan(dx) && error("missing value where TRUE/FALSE needed")   # if (dx == 0) mit NaN (seit 1.6.0 wie R)
        if dx == 0
            dx = rx[1] != 0 ? abs(rx[1]) : 1.0
            br = seq_len_out(rx[1] - dx / 1000, rx[2] + dx / 1000, nb)
        else
            # seq.int prüft die Enden (seit 1.6.0 wie R)
            isfinite(rx[1]) || error("'from' must be a finite number")
            isfinite(rx[2]) || error("'to' must be a finite number")
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

# R's partielle Sortierung (sort.default(x, partial =)): C-Kern sl_r_psort (bis 10 Indizes Auswahl,
# sonst Quicksort wie R). Für Werte, die sich nur im Vorzeichen der Null unterscheiden, hängt das
# Ergebnis vom Verfahren ab.

"`sort(x, partial = partial)` für Doubles ohne NA wie R (1-basierte Indizes)."
sort_partial(x, partial) = SimLev._rb_psort(collect(Float64, _v(x)), Int64[trunc(Int64, t) for t in _v(partial)])

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
    pp = Float64[isnan(t) ? t : max(0.0, min(1.0, t)) for t in p]
    np_ = length(pp)
    qs = SimLev._rb_quantile(xv, pp, Int(type))      # C-Kern sl_r_quantile (Typen 1–9)
    qs = Float64[pok[i] ? qs[i] : p[i] for i in eachindex(qs)]
    (names && np_ > 0) && return RVector(qs; names = _format_perc(pp, Int(digits)))
    return _vec_out(qs)
end

"`median.default(x, na.rm)` (C-Kern sl_r_median, seit 1.6.0)."
function median(x; na_rm::Bool = false)
    is_int = _is_int_like(x)
    xv = _v(x)
    r = SimLev._rb_median(xv, na_rm, is_int)
    r === nothing && return is_int ? missing : NA
    (is_int && isodd(count(!isnan, xv))) && return Int(r)
    return r
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
