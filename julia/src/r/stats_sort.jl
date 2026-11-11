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
# tabulate, findInterval, cut, quantile, median) aus R 4.3.3 (src/main/sort.c,
# qsort-body.c, seq.c; base/R/sort.R, rle.R, cut.R, findInt.R; stats/R/quantile.R, median.R);
# Python: _r/stats_sort.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).

# ── Hilfen ────────────────────────────────────────────────────────────────

const _EPOCH = Date(1970, 1, 1)
_fl(v) = (v === missing || v === nothing) ? NA : v isa Date ? Float64(Dates.value(v - _EPOCH)) : Float64(v)

"Art der Eingabe von median/quantile (seit 1.6.4, RP, C-060): :factor, :ordered, :date, :text oder :num."
function _stat_kind(x)
    x isa SimLev.RFmt.RFactor && return x.ordered ? :ordered : :factor
    vals = x isa RVector ? x.values : x
    vals isa Union{AbstractArray,Tuple} || (vals = (vals,))
    eltype(vals) <: Union{Missing,Nothing,Real} && return :num
    any(v -> v isa AbstractString || v isa AbstractChar, vals) && return :text
    any(v -> v isa Date, vals) && return :date
    return :num
end
_stat_reject(fn, what) = error(SimLev.chk_msg("rp.stat_art", fn, what))
# type == c(1L, 3L) wie R (Zahl, Wahrheitswert oder Text "1"/"3")
_type13(t) = t isa AbstractString ? t in ("1", "3") : (t isa Real && !isnan(Float64(t)) && (t == 1 || t == 3))

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

"`seq.int(from, to, length.out = n)` (Werte wie R; seit 1.6.4 wie R aufgerundet und geprüft, C-061)."
function seq_len_out(frm, to, length_out)
    lo = length_out === missing ? NaN : Float64(length_out)
    (isnan(lo) || lo < 0) && error("'length.out' must be a non-negative number")
    n = ceil(Int, lo)
    frm = Float64(frm); to = Float64(to)
    isfinite(frm) || error("'from' must be a finite number")
    isfinite(to) || error("'to' must be a finite number")
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
    return sortperm(lst; alg = MergeSort, lt = r_isless, rev = decreasing)   # lst::Vector{String} (seit 1.6.4 statt str_lt)
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
    dv = decreasing isa AbstractVector || decreasing isa Tuple ? collect(decreasing) : [decreasing]
    # seit 1.6.4 (C-018) wie R: mit Textschlüsseln (method "shell") höchstens ein Wert, sonst (radix) rep_len auf die
    # Zahl der Schlüssel; ein leerer Vektor ergibt NA (bis 1.6.3 las der Kern bei zu kurzem decreasing dahinter)
    any(k -> k[3], keys) && length(dv) > 1 && error("'decreasing' of length > 1 is only for method = \"radix\"")
    (isempty(dv) || any(d -> d === missing || d === nothing || (d isa AbstractFloat && isnan(d)), dv)) &&
        error("'decreasing' elements must be TRUE or FALSE")
    dec = Bool[Bool(dv[mod1(i, length(dv))]) for i in 1:length(keys)]
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
    # seit 1.6.4 wie R match.arg (RP, C-056; bis 1.6.3 nur volle Namen); "random" braucht R's Zufallszahlen
    ties_method = SimLev.RFmt._r_match_arg(ties_method, ("average", "first", "last", "random", "max", "min"))
    ties_method == "random" && error(SimLev.chk_msg("rp.rank_random"))
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
    # seit 1.6.4 (Befund C-063) wie R: Matrix, Faktor und Liste sind keine Vektoren eines Grundtyps
    (x isa AbstractArray && ndims(x) > 1) || x isa SimLev.RFmt.RFactor || x isa SimLev.RList ||
        (x isa AbstractVector && any(v -> v isa Union{AbstractArray,AbstractDict,NamedTuple}, x)) ?
        error("'x' must be a vector of an atomic type") : nothing
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
    if nbins !== nothing   # seit 1.6.4 (Befund C-062) wie R: Prüfung und Meldungen von tabulate()
        nb = nbins isa Union{AbstractVector,Tuple} && length(nbins) == 1 ? first(nbins) : nbins
        (nb isa Real && !(nb isa Bool)) || error("invalid 'nbin' argument")
        isnan(Float64(nb)) && error("missing value where TRUE/FALSE needed")
        abs(Float64(nb)) >= 2147483648 && error("attempt to make a table with >= 2^31 elements")
        nbins = trunc(Int, Float64(nb))
        nbins < 0 && error("invalid 'nbin' argument")
    end
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
        br = filter(!isnan, br)   # seit 1.6.4 wie R sort.int: NA/NaN entfallen (C-009)
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
        labs = Union{Missing,String}[(s === missing || s === nothing || (s isa AbstractFloat && isnan(s))) ? missing :
                                     string(s) for s in labels]
        length(labs) != nb - 1 && error("number of intervals and length of 'labels' differ")
        any(ismissing, labs) && error("cut: labels darf kein NA enthalten.")   # seit 1.6.4 (Entscheidung 67)
    end
    code = _bincode(xv, br, right, include_lowest)
    if codes_only
        any(==(0), code) && return _vec_out(Union{Missing,Int}[c == 0 ? missing : c for c in code])
        return _vec_out(code)
    end
    # seit 1.6.4 wie R factor(code, seq_along(labels), labels): gleiche Beschriftungen ergeben eine Stufe
    # (C-009); NA als Beschriftung ist ein Fehler (oben)
    cats = unique(String[s for s in labs])
    pos = Int[findfirst(==(s), cats) for s in labs]
    return SimLev.RFmt.RFactor(Int[c == 0 ? 0 : pos[c] for c in code], cats; ordered = ordered_result)
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

"""`sort(x, partial = partial)` für Doubles wie R (1-basierte Indizes; NA/NaN entfallen wie bei `na.last = NA`).
Seit 1.6.4 (C-015) mit den Prüfungen von R: nicht endliche Stellen „non-finite 'partial'“, bis 10 Stellen
ganzzahlig (zur Null hin) im Bereich 1 … Länge, sonst „index k outside bounds“ bzw. außerhalb des int-Bereichs
„NA index“ (mit Warnung); bis 1.6.3 hing der Kern, stürzte ab oder las fremden Speicher."""
function sort_partial(x, partial)
    v = Float64[t for t in collect(Float64, _v(x)) if !isnan(t)]
    p = collect(Float64, _v(partial))
    all(isfinite, p) || error("non-finite 'partial'")
    if length(p) <= 10
        ki = Union{Nothing,Int64}[-2147483648.0 < t < 2147483648.0 ? trunc(Int64, t) : nothing for t in sort(p)]
        any(t -> t === nothing, ki) && @warn "NAs introduced by coercion to integer range"
        for t in ki
            t === nothing && error("NA index")
            (t < 1 || t > length(v)) && error("index $t outside bounds")
        end
        k = Int64[t for t in ki]
    else
        k = zeros(Int64, length(p))   # mehr als 10 Stellen: vollständig sortiert wie R (ohne Prüfung)
    end
    SimLev._rb_psort(v, k)
end

"`asInteger` des numerischen `switch`-Ausdrucks: abgeschnitten, ausserhalb des int-Bereichs NA mit Warnung."
function _switch_int(t::Float64)
    isnan(t) && return nothing
    if !(-2147483648.0 < t < 2147483648.0)
        @warn "NAs introduced by coercion to integer range"
        return nothing
    end
    return trunc(Int, t)
end

"""
`type` von `quantile.default` wie R auswerten (seit 1.6.4, Befund C-028): wirksamer Typ 1–9, 0 für den Zweig
`type <= 3` ohne passende `switch`-Wahl (R nimmt dann die untere Ordnungsstatistik `x[j]`) oder der Fehler, den R an
derselben Stelle meldet (`if (type == 7)`, `switch`, `type - 3`).
"""
function quantile_type(type)
    v = type isa Union{AbstractVector,Tuple} ? collect(type) : [type]
    length(v) > 1 && error("the condition has length > 1")
    isempty(v) && error("argument is of length zero")
    t = v[1]
    (t === missing || t === nothing) && error("missing value where TRUE/FALSE needed")
    if t isa AbstractString   # Textvergleich wie R ("7" == 7 ist TRUE, sonst Kollation gegen "3")
        t == "7" && return 7
        str_collate(String(t), "3") <= 0 && error("numeric EXPR required for 'switch' without named alternatives")
        error("non-numeric argument to binary operator")
    end
    t = Float64(t)
    isnan(t) && error("missing value where TRUE/FALSE needed")
    t == 7 && return 7
    if t <= 3
        k = _switch_int(t)
        return k !== nothing && 1 <= k <= 3 ? k : 0
    end
    k = _switch_int(t - 3)
    (k === nothing || !(1 <= k <= 6)) && error("object 'a' not found")
    return k + 3
end

"R `quantile.default` im Zweig `type <= 3` ohne `h`: `x[j]` mit `j = floor(n * p)` (Rand: x[1])."
function _quantile_lower(xv::Vector{Float64}, pp::Vector{Float64})
    n = length(xv)
    out = fill(NA, length(pp))
    n == 0 && return out
    xs = sort(xv)
    pad = vcat(xs[1], xs[1], xs, xs[end], xs[end])
    for (i, p) in enumerate(pp)
        isnan(p) || (out[i] = pad[floor(Int, n * p) + 2])
    end
    return out
end

"""
    quantile(x, probs = [0, .25, .5, .75, 1]; na_rm = false, names = true, type = 7, digits = 7)

`quantile.default` (Typen 1–9). Ergebnis: RVector mit Namen wie "25%" bzw.
bei `names = false` Vector (Länge 1: Skalar).
"""
function quantile(x, probs = [0.0, 0.25, 0.5, 0.75, 1.0]; na_rm::Bool = false, names::Bool = true,
                  type = 7, digits::Integer = 7)
    # seit 1.6.4 (RP, C-060) wie R: ungeordnete Faktoren, geordnete außer type 1/3, Text und Datum mit type 4 bis 9 mit
    # R's Meldungen; geordnete Faktoren (type 1/3), Text und Datum mit type 1 bis 3 abgelehnt (rp.stat_art; R rechnet
    # dort); bis 1.6.3 Faktor-Codes bzw. Tageszahlen als Zahlen
    kind = _stat_kind(x)
    kind === :factor && error("(unordered) factors are not allowed")
    if kind === :ordered
        tv = type isa Union{AbstractVector,Tuple} ? collect(type) : [type]
        any(_type13, tv) || error("'type' must be 1 or 3 for ordered factors")
        _stat_reject("quantile", "geordnete Faktoren")
    end
    if kind === :text || kind === :date
        vals = collect(Any, x isa RVector ? x.values : x)
        nav = [v === missing || v === nothing || (v isa AbstractFloat && isnan(v)) for v in vals]
        (!na_rm && any(nav)) && error("missing values and NaN's not allowed if 'na.rm' is FALSE")
        p0 = _v(probs); eps0 = 100 * _DBL_EPS
        any(t -> !isnan(t) && (t < -eps0 || t > 1 + eps0), p0) && error("'probs' outside [0,1]")
        quantile_type(type) >= 4 &&
            error(kind === :date ? "* not defined for \"Date\" objects" : "non-numeric argument to binary operator")
        _stat_reject("quantile", kind === :date ? "Datumswerte" : "Texte")
    end
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
    typ = quantile_type(type)   # seit 1.6.4 wie R (C-028)
    qs = typ == 0 ? _quantile_lower(Vector{Float64}(xv), pp) :
         SimLev._rb_quantile(xv, pp, typ)      # C-Kern sl_r_quantile (Typen 1–9)
    qs = Float64[pok[i] ? qs[i] : p[i] for i in eachindex(qs)]
    (names && np_ > 0) && return RVector(qs; names = _format_perc(pp, Int(digits)))
    return _vec_out(qs)
end

"`median.default(x, na.rm)` (C-Kern sl_r_median, seit 1.6.0)."
function median(x; na_rm::Bool = false)
    # seit 1.6.4 (RP, C-060) wie R: Faktoren „need numeric data“; Text: mittlerer Wert nach R's Sortierung, bei gerader
    # Anzahl NA mit R's Warnung; Datumswerte abgelehnt (rp.stat_art; R liefert ein Datum mit Bruchteil); bis 1.6.3
    # Faktor-Codes bzw. Tageszahlen als Zahlen
    kind = _stat_kind(x)
    (kind === :factor || kind === :ordered) && error("need numeric data")
    kind === :date && _stat_reject("median", "Datumswerte")
    if kind === :text
        vals = collect(Any, x isa RVector ? x.values : x)
        na = [v === missing || v === nothing for v in vals]
        if na_rm
            vals = vals[.!na]
        elseif any(na)
            return missing                       # x[NA_integer_]: NA
        end
        n = length(vals)
        n == 0 && return missing
        xs = _ssort2(String[string(v) for v in vals], false)
        isodd(n) && return xs[(n + 1) ÷ 2]
        @warn "argument is not numeric or logical: returning NA"
        return NA
    end
    is_int = _is_int_like(x)
    xv = _v(x)
    r = SimLev._rb_median(xv, na_rm, is_int)
    r === nothing && return is_int ? missing : NA
    (is_int && isodd(count(!isnan, xv))) && return Int(r)
    return r
end
