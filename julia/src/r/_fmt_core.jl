# RFmt – Kern: Optionen, interne Vektordarstellung, C-printf, round/signif,
# formatReal/scientific, Kodierung von Zahlen und Zeichenketten.
# Vorlage: python/simlev/_r/fmt.py; Quellen R 4.3.3 (format.c, printutils.c,
# util.c, nmath/fround.c, nmath/fprec.c).

# ── Optionen ────────────────────────────────────────────────────────────────

const _OPT = Dict{Symbol,Any}(:digits => 7, :scipen => 0, :width => 80, :OutDec => ".")

"""
    set_options(; digits, scipen, width, OutDec)

Wie `options()`; liefert die alten Werte als `Dict` (zurücksetzen mit
`set_options(; alt...)`).
"""
function set_options(; kw...)
    old = Dict{Symbol,Any}()
    for (k, v) in kw
        haskey(_OPT, k) || throw(KeyError(k))
        old[k] = _OPT[k]
        _OPT[k] = v
    end
    return old
end

"`getOption(name)` für digits, scipen, width, OutDec."
get_option(name) = _OPT[Symbol(name)]

#: R's `NA_real_` (= `SimLev.NA`); R's NaN ist ein gewöhnliches `NaN`
#: (Julia unterscheidet beide über `isna_strict`).
const NA_REAL = SimLev.NA

# ── glibc: snprintf, log10, pow ────────────────────────────────────────────

_log10(x::Float64) = ccall((:log10, SimLev._LIBM), Cdouble, (Cdouble,), x)
_cpow(x::Float64, y::Float64) = ccall((:pow, SimLev._LIBM), Cdouble, (Cdouble, Cdouble), x, y)

# C-snprintf (Bibliothek je Betriebssystem: SimLev._LIBC, siehe rnum.jl)
_snprintf(fmt::String, x::Float64) = SimLev._c_sprintf(fmt, x)
_snprintf(fmt::String, x::Integer) = SimLev._c_sprintf(fmt, Int32(x))
_snprintf(fmt::String, s::AbstractString) = SimLev._c_sprintf(fmt, String(s))
# Formate mit '*' für Breite und Genauigkeit (str_signif)
_snprintf_wd(fmt::String, w::Integer, d::Integer, x::Float64) = SimLev._c_sprintf(fmt, Int32(w), Int32(d), x)
_snprintf_w(fmt::String, w::Integer, x::Integer) = SimLev._c_sprintf(fmt, Int32(w), Int32(x))
function _snprintf_wd(fmt::String, w::Integer, d::Integer, x::Float64, lim::Int)
    s = _snprintf_wd(fmt, w, d, x)
    return _cut(s, lim)
end
# C-Puffer der Länge lim (+ NUL): Ergebnis auf lim Bytes kürzen
_cut(s::String, lim::Int) = ncodeunits(s) <= lim ? s : String(codeunits(s)[1:lim])

# ── interne Darstellung eines atomaren R-Vektors ───────────────────────────

const _Str = Union{Nothing,String}

"""
Interne Darstellung (wie `_V` in der Python-Fassung).

type: :double, :integer, :logical, :character, :Date, :factor, :NULL
d: double/Date (NA = NaN), i: integer/factor (factor: 1-basiert, 0 = NA),
l: logical, s: character (nothing = NA); na/nan: Masken.
"""
mutable struct _V
    type::Symbol
    d::Vector{Float64}
    i::Vector{Int}
    l::Vector{Bool}
    s::Vector{_Str}
    na::Vector{Bool}
    nan::Vector{Bool}
    names::Union{Nothing,Vector{_Str}}
    levels::Vector{String}
    ordered::Bool
    scalar::Bool
end

const _E_D = Float64[]
const _E_I = Int[]
const _E_L = Bool[]
const _E_S = _Str[]

function _len(v::_V)
    t = v.type
    t === :double || t === :Date ? length(v.d) :
    t === :integer || t === :factor ? length(v.i) :
    t === :logical ? length(v.l) : t === :character ? length(v.s) : 0
end
Base.length(v::_V) = _len(v)

_Vd(d::Vector{Float64}, na, nan; names = nothing, scalar = false, type = :double) =
    _V(type, d, Int[], Bool[], _Str[], na, nan, names, String[], false, scalar)
function _Vd(d::Vector{Float64}; names = nothing, scalar = false)
    na = Bool[isnan(x) && SimLev.isna_strict(x) for x in d]
    nan = Bool[isnan(x) && !SimLev.isna_strict(x) for x in d]
    _Vd(d, na, nan; names, scalar)
end
_Vi(i::Vector{Int}, na; names = nothing, scalar = false) =
    _V(:integer, Float64[], i, Bool[], _Str[], na, falses(length(i)) |> collect, names, String[], false, scalar)
_Vl(l::Vector{Bool}, na; names = nothing, scalar = false) =
    _V(:logical, Float64[], Int[], l, _Str[], na, falses(length(l)) |> collect, names, String[], false, scalar)
_Vs(s::Vector{_Str}; names = nothing, scalar = false) =
    _V(:character, Float64[], Int[], Bool[], s, Bool[x === nothing for x in s], falses(length(s)) |> collect, names, String[], false, scalar)
_Vdate(d::Vector{Float64}, na; names = nothing, scalar = false) =
    _V(:Date, d, Int[], Bool[], _Str[], na, falses(length(d)) |> collect, names, String[], false, scalar)
_Vf(codes::Vector{Int}, levels; names = nothing, ordered = false, scalar = false) =
    _V(:factor, Float64[], codes, Bool[], _Str[], Bool[c == 0 for c in codes], falses(length(codes)) |> collect, names,
       collect(String, levels), ordered, scalar)
_Vnull() = _V(:NULL, Float64[], Int[], Bool[], _Str[], Bool[], Bool[], nothing, String[], false, false)

function _subset(v::_V, idx)
    t = v.type
    _V(t, (t === :double || t === :Date) ? v.d[idx] : Float64[],
       (t === :integer || t === :factor) ? v.i[idx] : Int[],
       t === :logical ? v.l[idx] : Bool[], t === :character ? v.s[idx] : _Str[],
       v.na[idx], v.nan[idx], v.names === nothing ? nothing : v.names[idx], v.levels, v.ordered, false)
end

# ── Faktor ─────────────────────────────────────────────────────────────────

"""
    RFactor(codes, levels; ordered = false)

R-Faktor: Codes (1-basiert, 0 = NA) und Levels. Verhält sich als Vektor der
Labels (`f[i]` liefert das Level bzw. `missing`). Erzeugen mit
[`r_factor`](@ref).
"""
struct RFactor <: AbstractVector{Union{Missing,String}}
    codes::Vector{Int}
    levels::Vector{String}
    ordered::Bool
end
RFactor(codes::AbstractVector{<:Integer}, levels::AbstractVector; ordered::Bool = false) =
    RFactor(collect(Int, codes), collect(String, levels), ordered)
Base.size(f::RFactor) = size(f.codes)
Base.IndexStyle(::Type{RFactor}) = IndexLinear()
Base.getindex(f::RFactor, i::Int) = f.codes[i] == 0 ? missing : f.levels[f.codes[i]]
Base.getindex(f::RFactor, I::AbstractVector) = RFactor(f.codes[I], f.levels, f.ordered)
Base.copy(f::RFactor) = RFactor(copy(f.codes), copy(f.levels), f.ordered)

"""
    r_factor(x; levels = nothing, ordered = false)

`factor(x, levels, ordered)`: Levels voreingestellt als sortierte eindeutige
Werte (Zahlen numerisch, Zeichenketten nach R's Kollation
`SimLev.RStats.str_collate`, d. h. ICU wie R; `unique(as.character(y)[order(y)])`).
"""
function r_factor(x; levels = nothing, ordered::Bool = false)
    x isa RFactor && levels === nothing && return RFactor(copy(x.codes), copy(x.levels), ordered || x.ordered)
    v = _as_v(x)
    vals = _as_character_list(v)
    if levels === nothing
        if v.type in (:double, :integer, :logical, :Date)
            nv = v.type === :double || v.type === :Date ? v.d : v.type === :integer ? Float64.(v.i) : Float64.(v.l)
            u = sort(unique([nv[i] for i in 1:length(v) if !v.na[i] && !v.nan[i]]))
            lev = _as_character_list(v.type === :integer ? _Vi(Int.(u), falses(length(u)) |> collect) :
                                     v.type === :logical ? _Vl(Bool.(u), falses(length(u)) |> collect) :
                                     v.type === :Date ? _Vdate(u, falses(length(u)) |> collect) :
                                     _Vd(u, falses(length(u)) |> collect, falses(length(u)) |> collect))
            levs = unique(String[s for s in lev])
        else
            levs = sort(unique(String[s for s in vals if s !== nothing]); alg = MergeSort, lt = SimLev.RStats.str_lt)
        end
    else
        levs = String[string(l) for l in (levels isa AbstractVector ? levels : [levels])]
    end
    codes = Int[s === nothing ? 0 : something(findfirst(==(s), levs), 0) for s in vals]
    return RFactor(codes, levs, ordered)
end

# ── Julia-Objekt → _V ──────────────────────────────────────────────────────

const _EPOCH = Date(1970, 1, 1)
_days(d::Date) = Float64(Dates.value(d) - Dates.value(_EPOCH))
_days(d::DateTime) = _days(Date(d))

_isna_el(x) = x === missing || x === nothing || (x isa AbstractFloat && isnan(x))

function _from_seq(vals::AbstractVector; names = nothing, scalar = false)
    kinds = Set{Symbol}()
    for x in vals
        if _isna_el(x)
            x isa AbstractFloat && push!(kinds, :nanfloat)
            continue
        end
        if x isa Bool
            push!(kinds, :logical)
        elseif x isa Integer
            push!(kinds, :integer)
        elseif x isa Real
            push!(kinds, :double)
        elseif x isa AbstractString || x isa Char || x isa Symbol
            push!(kinds, :character)
        elseif x isa Date || x isa DateTime
            push!(kinds, :Date)
        else
            push!(kinds, :character)
        end
    end
    n = length(vals)
    if :character in kinds
        s = _Str[_isna_el(x) ? nothing : x isa AbstractString ? String(x) : string(x) for x in vals]
        return _Vs(s; names, scalar)
    end
    if :Date in kinds
        a = Float64[_isna_el(x) ? NaN : _days(x) for x in vals]
        return _Vdate(a, Bool[isnan(z) for z in a]; names, scalar)
    end
    if :double in kinds || (:nanfloat in kinds && setdiff(kinds, [:nanfloat]) != Set([:logical]))
        a = Float64[x === missing || x === nothing ? SimLev.NA : Float64(x) for x in vals]
        return _Vd(a; names, scalar)
    end
    if :integer in kinds && any(x -> !_isna_el(x) && abs(Int128(x)) > 2147483647, vals)
        a = Float64[_isna_el(x) ? SimLev.NA : Float64(x) for x in vals]
        return _Vd(a; names, scalar)
    end
    if :integer in kinds
        na = Bool[_isna_el(x) for x in vals]
        return _Vi(Int[na[i] ? 0 : Int(vals[i]) for i in 1:n], na; names, scalar)
    end
    na = Bool[_isna_el(x) for x in vals]
    return _Vl(Bool[na[i] ? false : Bool(vals[i]) for i in 1:n], na; names, scalar)
end

_strnames(nm) = nm === nothing ? nothing : _Str[s === nothing || s === missing ? nothing : string(s) for s in nm]

function _from_vec(x::AbstractVector; names = nothing)
    T = nonmissingtype(eltype(x))
    n = length(x)
    if T === Union{}
        return _Vl(falses(n) |> collect, trues(n) |> collect; names)
    elseif T === Bool
        na = Bool[ismissing(z) for z in x]
        return _Vl(Bool[ismissing(z) ? false : z for z in x], na; names)
    elseif T <: Integer
        if n > 0 && any(z -> !ismissing(z) && abs(Int128(z)) > 2147483647, x)
            return _Vd(Float64[ismissing(z) ? SimLev.NA : Float64(z) for z in x]; names)
        end
        na = Bool[ismissing(z) for z in x]
        return _Vi(Int[ismissing(z) ? 0 : Int(z) for z in x], na; names)
    elseif T <: AbstractFloat
        return _Vd(Float64[ismissing(z) ? SimLev.NA : Float64(z) for z in x]; names)
    elseif T <: AbstractString
        return _Vs(_Str[ismissing(z) ? nothing : String(z) for z in x]; names)
    elseif T <: Union{Date,DateTime}
        a = Float64[ismissing(z) ? NaN : _days(z) for z in x]
        return _Vdate(a, Bool[ismissing(z) for z in x]; names)
    end
    return _from_seq(collect(x); names)
end

"""Julia-Objekt → interne Darstellung. `type` erzwingt einen R-Typ
("integer", "double", "logical", "character", "Date", "factor")."""
function _as_v(x, type = nothing)
    v = _as_v0(x, type)
    if type !== nothing
        t = Symbol(type)
        t === :numeric && (t = :double)
        v.type != t && (v = _coerce(v, t))
    end
    return v
end

function _as_v0(x, type)
    x isa _V && return x
    if x === nothing
        return (type !== nothing && Symbol(type) !== :NULL) ? _Vl([false], [true]; scalar = true) : _Vnull()
    end
    x === missing && return _Vl([false], [true]; scalar = true)
    if x isa RFactor
        return _Vf(copy(x.codes), x.levels; ordered = x.ordered)
    elseif x isa SimLev.RVector
        cls = get(x.attrs, "class", String[])
        cls = cls isa AbstractString ? [cls] : cls
        if "factor" in cls && haskey(x.attrs, "levels")
            codes = Int[ismissing(c) || c === nothing ? 0 : Int(c) for c in x.values]
            return _Vf(codes, collect(String, x.attrs["levels"]); names = _strnames(x.names), ordered = "ordered" in cls)
        end
        return _from_vec(x.values; names = _strnames(x.names))
    elseif x isa SimLev.NamedMat
        return _from_vec(vec(x.data))
    elseif x isa AbstractMatrix
        return _from_vec(vec(x))
    elseif x isa AbstractVector{<:Pair}
        return _from_seq(Any[p.second for p in x]; names = _Str[string(p.first) for p in x])
    elseif x isa AbstractDict
        return _from_seq(Any[v for v in values(x)]; names = _Str[string(k) for k in keys(x)])
    elseif x isa AbstractVector
        return _from_vec(x)
    elseif x isa Tuple
        return _from_seq(Any[z for z in x])
    elseif x isa AbstractRange
        return _from_vec(collect(x))
    end
    return _from_seq(Any[x]; scalar = true)
end

const _NUM_RE = r"^[ \t\n\r\f\v]*([+-]?)(?:(0[xX][0-9a-fA-F]*\.?[0-9a-fA-F]*(?:[pP][+-]?[0-9]+)?)|((?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)|(Inf|inf|infinity|Infinity|INF)|(NaN))[ \t\n\r\f\v]*$"

"String → double wie `String2Real`: (Wert, NA, NaN, Warnung)."
function _r_strtod(s)
    (s === nothing || s == "NA") && return (SimLev.NA, true, false, false)
    m = match(_NUM_RE, s)
    m === nothing && return (SimLev.NA, true, false, true)
    sgn = m.captures[1] == "-" ? -1.0 : 1.0
    if m.captures[2] !== nothing
        h = String(m.captures[2])
        occursin(r"[pP]", h) || (h *= "p0")
        z = tryparse(Float64, h)
        z === nothing && return (SimLev.NA, true, false, true)
        return (sgn * z, false, false, false)
    end
    m.captures[3] !== nothing && return (sgn * parse(Float64, m.captures[3]), false, false, false)
    m.captures[4] !== nothing && return (sgn * Inf, false, false, false)
    return (NaN, false, true, false)
end

function _coerce(v::_V, type::Symbol)
    v.type === type && return v
    r = _coerce0(v, type)
    r.scalar = v.scalar
    return r
end

function _coerce0(v::_V, type::Symbol)
    n = length(v)
    if v.type === :logical && all(v.na) && type !== :character
        type === :double && return _Vd(fill(SimLev.NA, n), trues(n) |> collect, falses(n) |> collect; names = v.names)
        type === :Date && return _Vdate(fill(NaN, n), trues(n) |> collect; names = v.names)
        type === :integer && return _Vi(zeros(Int, n), trues(n) |> collect; names = v.names)
        type === :factor && return _Vf(zeros(Int, n), String[]; names = v.names)
    end
    if type === :character
        return _Vs(_as_character_list(v); names = v.names)
    end
    if type === :double
        if v.type in (:integer, :logical, :Date, :factor)
            src = v.type === :integer || v.type === :factor ? Float64.(v.i) : v.type === :logical ? Float64.(v.l) : copy(v.d)
            f = Float64[v.na[i] ? SimLev.NA : src[i] for i in 1:n]
            return _Vd(f, copy(v.na), falses(n) |> collect; names = v.names)
        elseif v.type === :character
            f = Float64[]; na = Bool[]; nan = Bool[]; warn = false
            for s in v.s
                z, isna, isnan_, bad = _r_strtod(s)
                push!(f, z); push!(na, isna); push!(nan, isnan_)
                warn |= bad
            end
            warn && @warn "NAs introduced by coercion"
            return _Vd(f, na, nan; names = v.names)
        end
    end
    if type === :integer
        if v.type === :double
            na = Bool[v.na[i] || v.nan[i] || !isfinite(v.d[i]) for i in 1:n]
            big = Bool[isfinite(v.d[i]) && abs(v.d[i]) >= 2147483648.0 for i in 1:n]
            any(i -> big[i] || isinf(v.d[i]), 1:n) && @warn "NAs introduced by coercion to integer range"
            na .|= big
            iv = Int[na[i] ? 0 : Int(trunc(v.d[i])) for i in 1:n]
            return _Vi(iv, na; names = v.names)
        elseif v.type === :logical
            return _Vi(Int.(v.l), copy(v.na); names = v.names)
        elseif v.type === :character
            return _coerce0(_coerce0(v, :double), :integer)
        elseif v.type === :factor
            return _Vi(copy(v.i), copy(v.na); names = v.names)
        elseif v.type === :Date
            return _coerce0(_Vd(copy(v.d), copy(v.na), falses(n) |> collect; names = v.names), :integer)
        end
    end
    if type === :logical && v.type in (:double, :integer)
        na = v.type === :double ? Bool[v.na[i] || v.nan[i] for i in 1:n] : copy(v.na)
        vals = v.type === :double ? v.d : v.i
        return _Vl(Bool[!na[i] && vals[i] != 0 for i in 1:n], na; names = v.names)
    end
    if type === :Date && v.type in (:double, :integer)
        f = v.type === :double ? copy(v.d) : Float64.(v.i)
        f[v.na] .= NaN
        return _Vdate(f, copy(v.na); names = v.names)
    end
    error("Umwandlung $(v.type) -> $type nicht unterstützt")
end

# Ausgabe von format() & Co.
_jstr(s::_Str) = s === nothing ? missing : s
function _jvec(strs::AbstractVector)
    any(isnothing, strs) && return Union{Missing,String}[s === nothing ? missing : s for s in strs]
    return String[s for s in strs]
end
_jnames(nm) = String[s === nothing ? "NA" : s for s in nm]
function _out(strs::AbstractVector, v::_V)
    v.scalar && length(strs) == 1 && return _jstr(strs[1])
    a = _jvec(strs)
    v.names === nothing && return a
    return SimLev.RVector(a; names = _jnames(v.names))
end

# ── round / signif ─────────────────────────────────────────────────────────

const _M_LOG10_2 = 0.301029995663981195213738894724
const _DBL_DIG = 15
const _MAX10E = 308

"R_pow_di: x^n durch wiederholtes Quadrieren."
function _pow_di(x::Float64, n::Int)
    xn = 1.0
    isnan(x) && return x
    if n != 0
        isfinite(x) || return _cpow(x, Float64(n))
        neg = n < 0
        neg && (n = -n)
        while true
            (n & 1) != 0 && (xn *= x)
            n >>= 1
            n != 0 || break
            x *= x
        end
        neg && (xn = 1.0 / xn)
    end
    return xn
end

_nearbyint(x::Float64) = round(x, RoundNearest)
_logb(x::Float64) = Float64(exponent(x))

"R's `fround` (R >= 4.0.0) für ein double."
function fround(x::Float64, digits::Float64)
    max_digits = 308 + 15
    (isnan(x) || isnan(digits)) && return x + digits
    isfinite(x) || return x
    (digits > max_digits || x == 0.0) && return x
    digits < -_MAX10E && return 0.0
    digits == 0.0 && return _nearbyint(x)
    dig = Int(floor(digits + 0.5))
    sgn = 1.0
    if x < 0.0
        sgn = -1.0
        x = -x
    end
    l10x = _M_LOG10_2 * (0.5 + _logb(x))
    l10x + dig > _DBL_DIG && return sgn * x
    if dig <= _MAX10E
        pow10 = _pow_di(10.0, dig)
        x10 = x * pow10
        i10 = floor(x10)
        xd = i10 / pow10
        xu = ceil(x10) / pow10
    else
        e10 = dig - _MAX10E
        p10 = _pow_di(10.0, e10)
        pow10 = _pow_di(10.0, _MAX10E)
        x10 = (x * pow10) * p10
        i10 = floor(x10)
        xd = i10 / pow10 / p10
        xu = ceil(x10) / pow10 / p10
    end
    du = xu - x
    dd = x - xd
    return sgn * ((du < dd || (rem(i10, 2.0) == 1 && du == dd)) ? xu : xd)
end
fround(x::Real, digits::Real) = fround(Float64(x), Float64(digits))

"R's `fprec` (signif) für ein double."
function fprec(x::Float64, digits::Float64)
    max_digits = 22
    (isnan(x) || isnan(digits)) && return x + digits
    isfinite(x) || return x
    if !isfinite(digits)
        digits > 0.0 && return x
        digits = 1.0
    end
    x == 0 && return x
    dig = Int(round(digits, RoundNearestTiesAway))   # C round()
    if dig > max_digits
        return x
    elseif dig < 1
        dig = 1
    end
    sgn = 1.0
    if x < 0.0
        sgn = -sgn
        x = -x
    end
    l10 = _log10(x)
    e10 = trunc(Int, dig - 1 - floor(l10))
    if abs(l10) < _MAX10E - 2
        p10 = 1.0
        if e10 > _MAX10E
            p10 = _pow_di(10.0, e10 - _MAX10E)
            e10 = _MAX10E
        end
        if e10 > 0
            pow10 = _pow_di(10.0, e10)
            return sgn * (_nearbyint((x * pow10) * p10) / pow10) / p10
        else
            pow10 = _pow_di(10.0, -e10)
            return sgn * (_nearbyint(x / pow10) * pow10)
        end
    else
        do_round = _MAX10E - l10 >= _pow_di(10.0, -dig)
        e2 = dig + (e10 > 0 ? 1 : -1) * max_digits
        p10 = _pow_di(10.0, e2)
        x *= p10
        P10 = _pow_di(10.0, e10 - e2)
        x *= P10
        do_round && (x += 0.5)
        x = floor(x) / p10
        return sgn * x / P10
    end
end
fprec(x::Real, digits::Real) = fprec(Float64(x), Float64(digits))

_tofloat(x) = x === missing || x === nothing ? SimLev.NA : Float64(x)

function _math2(f, x, digits)
    isint(z) = z isa Integer && !(z isa Bool)
    if x isa SimLev.RFrame
        nms = names(x)
        bad = [nms[j] for (j, c) in enumerate(getfield(x, :cols)) if !(nonmissingtype(eltype(c)) <: Real) || c isa RFactor]
        isempty(bad) || error("non-numeric-alike variable(s) in data frame: " * join(bad, ", "))
        y = copy(x)
        for (j, c) in enumerate(getfield(y, :cols))
            getfield(y, :cols)[j] = _math2(f, c, digits)
        end
        return y
    elseif x isa SimLev.RVector
        return SimLev.RVector(_math2(f, x.values, digits); names = x.names, attrs = copy(x.attrs))
    elseif x isa SimLev.NamedMat
        return SimLev.NamedMat(_math2(f, x.data, digits); rownames = x.rownames, colnames = x.colnames, attrs = copy(x.attrs))
    elseif x === nothing || x === missing
        return SimLev.NA
    elseif x isa Number
        isint(x) && f === fround && return x
        return f(Float64(x), Float64(digits isa AbstractVector ? digits[1] : digits))
    elseif x isa AbstractArray
        T = nonmissingtype(eltype(x))
        if T <: Integer && !(T <: Bool) && f === fround && T !== Union{}
            return copy(x)
        end
        if digits isa AbstractVector && length(digits) > 1
            flat = vec(x)
            n = max(length(flat), length(digits))
            return Float64[f(_tofloat(flat[mod1(i, length(flat))]), Float64(digits[mod1(i, length(digits))])) for i in 1:n]
        end
        dd = Float64(digits isa AbstractVector ? digits[1] : digits)
        return map(z -> f(_tofloat(z), dd), x)
    end
    error("round/signif: nicht unterstützter Typ $(typeof(x))")
end

"""
    r_round(x, digits = 0)

`round(x, digits)` wie R >= 4.0.0 (Algorithmus aus `fround.c`): Skalare,
Vektoren, Matrizen, `RVector`, `NamedMat`, `RFrame` (elementweise).
"""
r_round(x, d = 0; digits = d) = _math2(fround, x, digits)

"`signif(x, digits = 6)` wie R (`fprec.c`)."
signif(x, d = 6; digits = d) = _math2(fprec, x, digits)

# ── long double (F80) für scientific() ─────────────────────────────────────

const F80 = SimLev.F80
include("_fmt_powl.jl")

_f80(m::UInt64, e::Int32) = F80(m, e, false, SimLev._FIN)
const _TBL80 = F80[F80(parse(Float64, "1e$k")) for k in 0:27]
const _TBLD = Float64[parse(Float64, "1e$k") for k in 0:27]
const _KP_MAX = 27

function _powl10(k::Int)
    -350 <= k <= 350 || error("powl(10, $k) außerhalb der Tabelle")
    m, e = _POWL10[k + 351]
    return _f80(m, e)
end

# Vergleich a < b für endliche Werte oder Null
function _f80_lt(a::F80, b::F80)
    sa = a.cls == SimLev._ZERO ? 0 : a.neg ? -1 : 1
    sb = b.cls == SimLev._ZERO ? 0 : b.neg ? -1 : 1
    sa != sb && return sa < sb
    sa == 0 && return false
    lt = a.e != b.e ? a.e < b.e : a.m < b.m
    eq = a.e == b.e && a.m == b.m
    return sa > 0 ? lt : (!lt && !eq)
end

# nearbyintl (gerade Rundung), Ergebnis als double
function _f80_nearbyint(a::F80)
    a.cls == SimLev._ZERO && return a.neg ? -0.0 : 0.0
    a.cls != SimLev._FIN && return Float64(a)
    e = Int(a.e)
    e >= 63 && return Float64(a)
    e < -1 && return a.neg ? -0.0 : 0.0
    sh = 63 - e                      # 1 … 64
    m = UInt128(a.m)
    ip = m >> sh
    r = m & ((UInt128(1) << sh) - 1)
    half = UInt128(1) << (sh - 1)
    (r > half || (r == half && isodd(ip))) && (ip += 1)
    z = Float64(ip)
    return a.neg ? -z : z
end

# ── formatReal ─────────────────────────────────────────────────────────────

"`scientific()` aus format.c für r = |x| > 0 (endlich): (kpower, nsig, roundingwidens)."
function _scientific(r::Float64, digits::Int)
    if digits >= _DBL_DIG + 1
        buff = _snprintf("%#." * string(digits - 1) * "e", r)
        kpw = parse(Int, buff[digits+3:end])
        j = digits
        while j >= 2
            buff[j+1] != '0' && break
            j -= 1
        end
        return kpw, j, false
    end
    kp = floor(Int, _log10(r)) - digits + 1
    rp = F80(r)
    if abs(kp) <= _KP_MAX
        if kp > 0
            rp = rp / _TBL80[kp+1]
        elseif kp < 0
            rp = rp * _TBL80[-kp+1]
        end
    else
        rp = rp / _powl10(kp)
    end
    if _f80_lt(rp, _TBL80[digits])
        rp = rp * F80(10.0)
        kp -= 1
    end
    alpha = _f80_nearbyint(rp)
    nsig = digits
    for _ in 1:digits
        alpha /= 10.0
        if alpha == floor(alpha)
            nsig -= 1
        else
            break
        end
    end
    if nsig == 0 && digits > 0
        nsig = 1
        kp += 1
    end
    kpower = kp + digits - 1
    rgt = clamp(digits - kpower, 0, _KP_MAX)
    fuzz = 0.5 / _TBLD[rgt+1]
    rw = kpower > 0 && kpower <= _KP_MAX && _f80_lt(F80(r), _TBL80[kpower+1] - F80(fuzz))
    return kpower, nsig, rw
end

"`formatReal`: (w, d, e) für die Werte `x` (na: NA-Maske)."
function _format_real(x::AbstractVector{Float64}, na::AbstractVector{Bool}, digits = nothing, nsmall = 0, scipen = nothing)
    digits === nothing && (digits = _OPT[:digits])
    scipen === nothing && (scipen = _OPT[:scipen])
    digits = Int(digits)
    naflag = nanflag = posinf = neginf = false
    neg = 0
    anyf = false
    rgt = mxl = mxsl = mxns = typemin(Int)
    mnl = typemax(Int)
    for i in eachindex(x)
        xi = x[i]
        if !isfinite(xi)
            if isnan(xi)
                na[i] ? (naflag = true) : (nanflag = true)
            elseif xi > 0
                posinf = true
            else
                neginf = true
            end
            continue
        end
        anyf = true
        if xi == 0.0
            kpower, nsig, rw, negi = 0, 1, false, 0
        else
            negi = xi < 0 ? 1 : 0
            kpower, nsig, rw = _scientific(abs(xi), digits)
        end
        left = kpower + 1 - (rw ? 1 : 0)
        sleft = negi + (left <= 0 ? 1 : left)
        right = nsig - left
        negi == 1 && (neg = 1)
        right > rgt && (rgt = right)
        left > mxl && (mxl = left)
        left < mnl && (mnl = left)
        sleft > mxsl && (mxsl = sleft)
        nsig > mxns && (mxns = nsig)
    end
    if anyf
        digits == 0 && (rgt = 0)
        mxl < 0 && (mxsl = 1 + neg)
        rgt < 0 && (rgt = 0)
        wF = mxsl + rgt + (rgt != 0)
        e = (mxl > 100 || mnl <= -99) ? 2 : 1
        d = mxns - 1
        w = neg + (d > 0) + d + 4 + e
        if wF <= w + scipen
            e = 0
            if nsmall > rgt
                rgt = nsmall
                wF = mxsl + rgt + (rgt != 0)
            end
            d = rgt
            w = wF
        end
    else
        w = d = e = 0
    end
    naflag && w < 2 && (w = 2)
    nanflag && w < 3 && (w = 3)
    posinf && w < 3 && (w = 3)
    neginf && w < 4 && (w = 4)
    return w, d, e
end
_format_real(v::_V, digits = nothing, nsmall = 0, scipen = nothing) = _format_real(v.d, v.na, digits, nsmall, scipen)

_realfmt(w, d, e) = e != 0 ? (d != 0 ? "%#" * string(w) * "." * string(d) * "e" : "%" * string(w) * "." * string(d) * "e") :
                    "%" * string(w) * "." * string(d) * "f"

"`EncodeReal0` für ein double (fmt = vorbereitetes C-Format)."
function _encode_real(x::Float64, w::Int, d::Int, e::Int, dec::AbstractString = ".", na::Bool = false, fmt = nothing;
                      na_string = "NA")
    if !isfinite(x)
        s = isnan(x) ? ((!na && !SimLev.isna_strict(x)) ? "NaN" : na_string) : x > 0 ? "Inf" : "-Inf"
        return lpad(s, w)
    end
    x == 0.0 && (x = 0.0)
    s = _snprintf(fmt === nothing ? _realfmt(w, d, e) : fmt, x)
    dec != "." && (s = replace(s, "." => dec))
    return s
end

"Nachkomma-Nullen entfernen wie `EncodeRealDrop0`."
function _drop0(s::String)
    p = findfirst('.', s)
    p === nothing && return s
    b = codeunits(s)
    q = p + 1
    repl = p
    while q <= length(b) && UInt8('0') <= b[q] <= UInt8('9')
        b[q] != UInt8('0') && (repl = q + 1)
        q += 1
    end
    return s[1:repl-1] * s[q:end]
end

function _encode_reals(v::_V, w, d, e, dec = ".")
    fmt = _realfmt(w, d, e)
    return _Str[_encode_real(v.d[i], w, d, e, dec, v.na[i], fmt) for i in 1:length(v.d)]
end

_index_width(n) = trunc(Int, _log10(Float64(n) + 0.5) + 1)

"`formatInteger`: Feldbreite."
function _format_integer(v::_V)
    w = any(v.na) ? 2 : 1
    xmin = typemax(Int); xmax = typemin(Int); ok = false
    for i in 1:length(v.i)
        v.na[i] && continue
        ok = true
        v.i[i] < xmin && (xmin = v.i[i])
        v.i[i] > xmax && (xmax = v.i[i])
    end
    if ok
        xmin < 0 && (w = max(w, _index_width(-xmin) + 1))
        xmax > 0 && (w = max(w, _index_width(xmax)))
    end
    return w
end

_encode_integer(x::Int, na::Bool, w::Int, na_string = "NA") = na ? lpad(na_string, w) : lpad(string(x), w)

function _format_logical(v::_V)
    w = 1
    for i in 1:length(v.l)
        if v.na[i]
            w < 2 && (w = 2)
        elseif v.l[i] && w < 4
            w = 4
        elseif !v.l[i] && w < 5
            w = 5
            break
        end
    end
    return w
end

_encode_logical(x::Bool, na::Bool, w::Int, na_string = "NA") = na ? lpad(na_string, w) : lpad(x ? "TRUE" : "FALSE", w)

# ── Zeichenketten: Breite und Kodierung ────────────────────────────────────

const _UC = Base.Unicode

function _wcwidth(c::Char)
    k = UInt32(c)
    cat = _UC.category_code(c)
    (cat == _UC.UTF8PROC_CATEGORY_MN || cat == _UC.UTF8PROC_CATEGORY_ME || k == 0x200B) && return 0
    cat == _UC.UTF8PROC_CATEGORY_CF && k != 0xAD && return 0
    return textwidth(c) == 2 ? 2 : 1
end

function _printable(c::Char)
    cat = _UC.category_code(c)
    return !(cat == _UC.UTF8PROC_CATEGORY_CC || cat == _UC.UTF8PROC_CATEGORY_CN || cat == _UC.UTF8PROC_CATEGORY_CS ||
             cat == _UC.UTF8PROC_CATEGORY_ZL || cat == _UC.UTF8PROC_CATEGORY_ZP)
end

const _NOQ = '\0'

"`Rstrwid`: Anzeigebreite (Escapes mitgezählt); q = Anführungszeichen oder '\\0'."
function _strwid(s::AbstractString, q::Char = _NOQ)
    n = 0
    for c in s
        k = UInt32(c)
        if 0x20 <= k < 0x7F
            if c == '\\'
                n += 2
            elseif c == '\'' || c == '"' || c == '`'
                n += q == c ? 2 : 1
            else
                n += 1
            end
        elseif k < 0x80
            n += c in ('\a', '\b', '\f', '\n', '\r', '\t', '\v', '\0') ? 2 : 4
        else
            n += _printable(c) ? _wcwidth(c) : (k > 0xFFFF ? 10 : 6)
        end
    end
    return n
end

const _ESC = Dict('\a' => "\\a", '\b' => "\\b", '\f' => "\\f", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t",
                  '\v' => "\\v", '\0' => "\\0")

function _escape(s::AbstractString, q::Char = _NOQ)
    io = IOBuffer()
    for c in s
        k = UInt32(c)
        if 0x20 <= k < 0x7F
            if c == '\\'
                print(io, "\\\\")
            elseif (c == '\'' || c == '"' || c == '`') && q == c
                print(io, '\\', c)
            else
                print(io, c)
            end
        elseif k < 0x80
            print(io, get(_ESC, c, "\\" * string(k, base = 8, pad = 3)))
        elseif _printable(c)
            print(io, c)
        elseif k > 0xFFFF
            print(io, "\\U{", string(k, base = 16, pad = 6), "}")
        else
            print(io, "\\u", string(k, base = 16, pad = 4))
        end
    end
    return String(take!(io))
end

"`EncodeString`: s (nothing = NA), Feldbreite w, q = '\"' oder '\\0'."
function _encode_string(s::_Str, w::Int, q::Char = _NOQ, justify = "left"; na_quote = "NA", na_noquote = "<NA>")
    if s === nothing
        p = q != _NOQ ? na_quote : na_noquote
        i = length(p)
        q = _NOQ
    else
        i = _strwid(s, q)
        p = _escape(s, q)
    end
    b = w - i - (q != _NOQ ? 2 : 0)
    justify == "none" && (b = 0)
    left = right = ""
    if b > 0 && justify != "left"
        b0 = justify == "centre" ? b ÷ 2 : b
        left = " "^b0
        b -= b0
    end
    b > 0 && justify != "right" && (right = " "^b)
    q != _NOQ && (p = string(q, p, q))
    return left * p * right
end

"`formatString`: größte Breite."
function _format_string(strs, q::Char = _NOQ)
    w = 0
    for s in strs
        l = s === nothing ? (q != _NOQ ? 2 : 4) : _strwid(s, q) + (q != _NOQ ? 2 : 0)
        l > w && (w = l)
    end
    return w
end

_qchar(quote_) = quote_ === nothing || quote_ === false || quote_ == "" ? _NOQ :
                 quote_ === true ? '"' : quote_ isa Char ? quote_ : first(String(quote_))

"""
    encode_string(x; width = 0, quote_ = "", justify = "left", na_encode = true)

`encodeString`: Escapes, Anführungszeichen, Auffüllen (`width = nothing` =
größte Breite).
"""
function encode_string(x; width = 0, quote_ = "", justify = "left", na_encode = true)
    v = _as_v(x, "character")
    q = _qchar(quote_)
    if width === nothing
        width = maximum([s === nothing ? 2 : _strwid(s, q) + (q != _NOQ ? 2 : 0) for s in v.s]; init = 0)
    end
    out = _Str[]
    for s in v.s
        if s === nothing && !na_encode
            push!(out, nothing)
        elseif s === nothing
            push!(out, justify == "left" ? rpad("NA", width) : lpad("NA", width))
        else
            push!(out, _encode_string(s, Int(width), q, justify))
        end
    end
    return _out(out, v)
end

"""
    nchar(x, type = "chars")

`nchar(x, type)`: "chars", "bytes" oder "width" (NA → 2 wie in R).
"""
function nchar(x, t = "chars"; type = t)
    v = _as_v(x, "character")
    res = Int[]
    for s in v.s
        if s === nothing
            push!(res, 2)
        elseif type == "bytes"
            push!(res, ncodeunits(s))
        elseif type == "width"
            push!(res, sum((UInt32(c) >= 0x80 ? _wcwidth(c) : 1 for c in s); init = 0))
        else
            push!(res, length(s))
        end
    end
    v.scalar && return res[1]
    return res
end

# ── as.character / paste ───────────────────────────────────────────────────

"`StringFromReal` mit 15 Stellen (as.character für double)."
function _real_to_str(x::Float64, na::Bool = false, nan::Bool = false)
    isnan(x) && return (na || !nan) ? nothing : "NaN"
    w, d, e = _format_real([x], [false], 15)
    return _drop0(_encode_real(x, w, d, e, _OPT[:OutDec]))
end

function _as_character_list(v::_V)::Vector{_Str}
    t = v.type
    t === :character && return copy(v.s)
    t === :double && return _Str[v.na[i] ? nothing : _real_to_str(v.d[i], false, v.nan[i]) for i in 1:length(v.d)]
    t === :integer && return _Str[v.na[i] ? nothing : string(v.i[i]) for i in 1:length(v.i)]
    t === :logical && return _Str[v.na[i] ? nothing : (v.l[i] ? "TRUE" : "FALSE") for i in 1:length(v.l)]
    t === :Date && return _format_date_list(v.d, _Str["%Y-%m-%d"])
    t === :factor && return _Str[v.na[i] ? nothing : v.levels[v.i[i]] for i in 1:length(v.i)]
    t === :NULL && return _Str[]
    error(string(t))
end

"""
    as_character(x)

`as.character(x)`; double mit 15 signifikanten Stellen (R 4.3). Namen
entfallen wie in R; NA → `missing`.
"""
function as_character(x)
    v = _as_v(x)
    res = _as_character_list(v)
    v.scalar && return _jstr(res[1])
    return _jvec(res)
end

"""
    paste(args...; sep = " ", collapse = nothing)

`paste(..., sep, collapse)` (NA wird zu "NA").
"""
function paste(args...; sep = " ", collapse = nothing)
    vecs = Vector{Vector{String}}()
    allscalar = true
    for a in args
        v = _as_v(a)
        v.type === :NULL && continue
        v.scalar || (allscalar = false)
        push!(vecs, String[q === nothing ? "NA" : q for q in _as_character_list(v)])
    end
    isempty(vecs) && return collapse !== nothing ? "" : String[]
    n = maximum(length.(vecs))
    if n == 0
        res = String[]
    else
        vecs = [isempty(s) ? [""] : s for s in vecs]
        res = String[join((s[mod1(i, length(s))] for s in vecs), sep) for i in 1:n]
    end
    collapse !== nothing && return join(res, collapse)
    n == 1 && allscalar && return res[1]
    return res
end

"`paste0(..., collapse)`."
paste0(args...; collapse = nothing) = paste(args...; sep = "", collapse = collapse)

"`toString(x)`."
to_string(x; sep = ", ") = paste(x; collapse = sep)
