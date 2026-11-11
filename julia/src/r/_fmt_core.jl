# Herkunft:           übersetzt aus R 4.3.3, src/main/format.c, printutils.c, printvector.c,
#                     printarray.c, print.c, paste.c, sprintf.c, util.c; src/nmath/fround.c,
#                     fprec.c; nachgebildet nach R 4.3.3, src/library/base/R/format.R, dataframe.R,
#                     factor.R, dates.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); fprec.c: Übersetzung einer Fortran-Routine von
#                     W. Fullerton (Los Alamos); sprintf.c: ursprünglich Jonathan Rougier
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Datumsformat und -lesen rechnet der C-Kern
#                     core/slc_rbase_date.cpp.
# RFmt – Kern: Optionen, interne Vektordarstellung, C-printf, round/signif,
# formatReal/scientific, Kodierung von Zahlen und Zeichenketten.
# Vorlage: python/simlev/_r/fmt.py; Quellen R 4.3.3 (format.c, printutils.c,
# util.c, nmath/fround.c, nmath/fprec.c).

# ── Optionen ────────────────────────────────────────────────────────────────

const _OPT = Dict{Symbol,Any}(:digits => 7, :scipen => 0, :width => 80, :OutDec => ".", :digits_secs => nothing)

"""`asInteger` von R für ein Argument: erstes Element, Wahrheitswert 0/1, Zahl zur Null hin, Text wie `as.integer`;
NA, NaN und Werte außerhalb des int-Bereichs als `nothing` (außerhalb mit der Warnung von R). Seit 1.6.4 (C-012) für
die Prüfung von `digits`/`nsmall` wie R."""
function _r_as_int1(v)
    if v isa AbstractVector || v isa Tuple
        isempty(v) && return nothing
        v = first(v)
    end
    (v === nothing || v === missing) && return nothing
    v isa Bool && return Int(v)
    if v isa AbstractString
        # seit 1.6.5 (CR2-Q-3) wie R's IntegerFromString (wie Python): leerer Text NA ohne Warnung, sonst R_strtod mit
        # Rest nur aus Leerraum; NaN ohne Warnung, außerhalb des int-Bereichs (auch Inf) die Bereichswarnung
        isws(c) = c in (' ', '\t', '\n', '\v', '\f', '\r')
        all(isws, v) && return nothing
        cs = collect(v)
        f, e = SimLev.RExpr.r_strtod(cs, 1)
        (e == 1 || !all(isws, cs[e:end])) && (@warn "NAs introduced by coercion"; return nothing)
        v = f
    end
    v isa Real || return nothing
    f = Float64(v)
    isnan(f) && return nothing
    if !(abs(f) < 2147483648.0) || trunc(f) == -2147483648.0
        @warn "NAs introduced by coercion to integer range"
        return nothing
    end
    return Int(trunc(f))
end

"""`asLogical` von R für ein Argument: erstes Element; Zahl ungleich 0 true, NaN NA; Text "TRUE"/"true"/"True"/"T"
bzw. "FALSE"/"false"/"False"/"F", sonst NA; leer NA. Ergebnis true, false oder `nothing` (NA). Seit 1.6.4 (C-056)."""
function _r_as_lgl1(v)
    if v isa AbstractVector || v isa Tuple
        isempty(v) && return nothing
        v = first(v)
    end
    (v === nothing || v === missing) && return nothing
    v isa Bool && return v
    v isa AbstractString && return v in ("TRUE", "true", "True", "T") ? true : v in ("FALSE", "false", "False", "F") ? false : nothing
    v isa Real || return nothing
    f = Float64(v)
    return isnan(f) ? nothing : f != 0
end

"Wahrheitswert eines Arguments wie R `asLogical` mit Abbruch „invalid 'what' argument“ bei NA (seit 1.6.4, C-056)."
function _r_lgl_arg(v, what::AbstractString)
    b = _r_as_lgl1(v)
    b === nothing && error("invalid '$what' argument")
    return b
end

"`match.arg(arg, choices)` von R (seit 1.6.4, C-056)."
function _r_match_arg(arg, choices)
    arg === nothing && return choices[1]
    a = arg isa AbstractVector || arg isa Tuple ? collect(arg) : [arg]
    all(t -> t isa AbstractString || t isa Symbol, a) || error("'arg' must be NULL or a character vector")
    a = String[string(t) for t in a]
    Tuple(a) == Tuple(choices) && return choices[1]
    length(a) > 1 && error("'arg' must be of length 1")
    hits = isempty(a) ? String[] : [c for c in choices if c == a[1]]
    isempty(hits) && !isempty(a) && !isempty(a[1]) && (hits = [c for c in choices if startswith(c, a[1])])
    # mehrdeutiger Teilanfang wie R's pmatch: kein Treffer (seit 1.6.4, RP; bis dahin „there is more than one match“)
    length(hits) > 1 && (hits = String[])
    length(hits) == 1 || error("'arg' should be one of " * join(["\u201c$(c)\u201d" for c in choices], ", "))
    return hits[1]
end

"`digits` wie R prüfen (seit 1.6.4, C-012, Entscheidung 77): 1 bis 22; `kind` :format oder :print."
function _chk_digits(digits, kind::Symbol = :format)
    digits === nothing && return nothing
    d = _r_as_int1(digits)
    if d === nothing || d < 1 || d > 22
        dv = d === nothing ? -2147483648 : d
        kind === :print && error("invalid printing digits $dv")
        error("invalid value $dv for 'digits' argument")
    end
    return d
end

"`nsmall` wie R prüfen (seit 1.6.4, C-012, Entscheidung 77): ganze Zahl 0 bis 20."
function _chk_nsmall(nsmall)
    n = _r_as_int1(nsmall)
    (n === nothing || n < 0 || n > 20) && error("invalid 'nsmall' argument")
    return n
end

"Zahl NaN/NA (Vergleiche wie in R ergäben NA)."
_isnan_num(v) = v isa AbstractFloat && isnan(v)

"""
    set_options(; digits, scipen, width, OutDec, digits_secs)

Wie `options()`; `digits_secs` ist R's `digits.secs` (Ziffern für `%OS` ohne Ziffer im
Datumsformat; `nothing` = nicht gesetzt wie in R). Liefert die alten Werte als `Dict`
(zurücksetzen mit `set_options(; alt...)`).
"""
function set_options(; kw...)
    old = Dict{Symbol,Any}()
    for (k, v) in kw
        haskey(_OPT, k) || throw(KeyError(k))
        k === :digits_secs && !(v === nothing || v isa Real) && throw(ArgumentError("digits_secs: nothing oder eine Zahl"))
        if k === :digits   # seit 1.6.4 (C-012, Entscheidung 77) wie R options(digits =)
            d = _r_as_int1(v)
            (d === nothing || d < 1 || d > 22) && error("invalid 'digits' parameter, allowed 1...22")
            v = d
        end
        old[k] = _OPT[k]
        _OPT[k] = v
    end
    return old
end

# getOption("digits.secs") wie bei R's %OS: ganzzahlig (zur Null hin); nicht gesetzt, NA, NaN oder außerhalb
# des int-Bereichs 0; die Begrenzung auf 0..6 macht der Kern (wie Python fmt._digits_secs).
function _digits_secs()
    v = _OPT[:digits_secs]
    v === nothing && return 0
    x = Float64(v)
    abs(x) < 2147483648.0 || return 0
    return Int(trunc(x))
end

# R's `NA_real_` ist `SimLev.NA` (seit 1.6.3 ohne den Namen `RFmt.NA_REAL`: ohne Aufrufer); R's NaN ist ein
# gewöhnliches `NaN` (Julia unterscheidet beide über `isna_strict`).

# ── glibc: snprintf, log10, pow ────────────────────────────────────────────

_log10(x::Float64) = ccall((:log10, SimLev._LIBM), Cdouble, (Cdouble,), x)

# C-snprintf: seit 1.6.0 im C-Kern core/slc_rbase_fmt.cpp (sprintf, formatC, encodeReal)

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
Labels (`f[i]` liefert das Level bzw. `missing`).
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

# ── Julia-Objekt → _V ──────────────────────────────────────────────────────

const _EPOCH = Date(1970, 1, 1)
_days(d::Date) = Float64(Dates.value(d) - Dates.value(_EPOCH))
_days(d::DateTime) = _days(Date(d))

const _isna_el = SimLev._isna   # r/rnum.jl (seit 1.6.3)

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
    elseif x isa AbstractVector                       # auch AbstractRange (seit 1.6.4 ohne den dafür unerreichbaren Zweig)
        return _from_vec(x)
    elseif x isa Tuple
        return _from_seq(Any[z for z in x])
    end
    return _from_seq(Any[x]; scalar = true)
end

"""
String → double wie `String2Real`: (Wert, NA, NaN, Warnung). über `SimLev.RExpr._str2num` (R_strtod mit dem
C-Kern `sl_r_strtod_num`, long double wie R; vorher `parse`, korrekt gerundet und damit bei mehr als 17 Ziffern
teils anders als R). Wie Python `fmt._r_strtod`.
"""
function _r_strtod(s)
    s === nothing && return (SimLev.NA, true, false, false)
    v, bad = SimLev.RExpr._str2num(String(s))
    bad && return (SimLev.NA, true, false, true)
    if isnan(v)
        SimLev.isna_strict(v) && return (SimLev.NA, true, false, false)
        return (v, false, true, false)
    end
    return (v, false, false, false)
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

"R's `fround` (R >= 4.0.0) für ein double (C-Kern sl_r_fround, seit 1.6.0)."
fround(x::Float64, digits::Float64) = SimLev._rb_fround(x, digits)
fround(x::Real, digits::Real) = fround(Float64(x), Float64(digits))

"R's `fprec` (signif) für ein double (C-Kern sl_r_fprec, seit 1.6.0)."
fprec(x::Float64, digits::Float64) = SimLev._rb_fprec(x, digits)
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
    end
    # seit 1.6.4 wie R (C-040): NULL, Text, Faktor und Listen sind ein Fehler, digits NULL bzw. der Länge 0 „invalid
    # second argument of length 0“, NA bleibt NA, digits wird auch bei einem Skalar recycelt; ganze Zahlen bleiben nur
    # bei digits >= 0 unverändert (bis 1.6.3 auch bei digits < 0, z. B. round(15L, -1) = 15 statt 20)
    _m2_bad(z) = z === nothing || z isa AbstractString || z isa AbstractChar || z isa RFactor || z isa SimLev.RList ||
                 (z isa AbstractArray && any(t -> t isa AbstractString || t isa AbstractChar, z))
    _m2_bad(x) && error("non-numeric argument to mathematical function")
    digits === nothing && error("invalid second argument of length 0")
    _m2_bad(digits) && error("non-numeric argument to mathematical function")
    d = Float64[t === missing ? SimLev.NA : Float64(t) for t in (digits isa AbstractArray ? vec(digits) : [digits])]
    isempty(d) && error("invalid second argument of length 0")
    keep_int = f === fround && length(d) == 1 && d[1] >= 0
    if x === missing || x isa Number
        isint(x) && keep_int && return x
        (x === missing && length(d) == 1) && return SimLev.NA
        length(d) == 1 && return f(Float64(x), d[1])
        x = [x]
    end
    if x isa AbstractArray
        T = nonmissingtype(eltype(x))
        if T <: Integer && !(T <: Bool) && keep_int && T !== Union{}
            return copy(x)
        end
        # C-Kern sl_r_round_vec (seit 1.6.0)
        kind = f === fprec ? 1 : 0
        xs = Float64[_tofloat(z) for z in vec(x)]
        length(d) > 1 && return SimLev._rb_round_vec(kind, xs, d)
        return reshape(SimLev._rb_round_vec(kind, xs, d), size(x))
    end
    error("non-numeric argument to mathematical function")
end

"""
    r_round(x, digits = 0)

`round(x, digits)` wie R >= 4.0.0 (Algorithmus aus `fround.c`): Skalare,
Vektoren, Matrizen, `RVector`, `NamedMat`, `RFrame` (elementweise).
"""
r_round(x, d = 0; digits = d) = _math2(fround, x, digits)

"`signif(x, digits = 6)` wie R (`fprec.c`)."
signif(x, d = 6; digits = d) = _math2(fprec, x, digits)

# ── formatReal ─────────────────────────────────────────────────────────────

"`formatReal`: (w, d, e) für die Werte `x` (na: NA-Maske; C-Kern sl_r_format_real, seit 1.6.0)."
function _format_real(x::AbstractVector{Float64}, na::AbstractVector{Bool}, digits = nothing, nsmall = 0, scipen = nothing)
    digits === nothing && (digits = _OPT[:digits])
    scipen === nothing && (scipen = _OPT[:scipen])
    return SimLev._rb_format_real(Vector{Float64}(x), UInt8[b for b in na], Int(digits)::Int, Int(nsmall)::Int, Int(scipen)::Int)
end
_format_real(v::_V, digits = nothing, nsmall = 0, scipen = nothing) = _format_real(v.d, v.na, digits, nsmall, scipen)

"`EncodeReal0` für ein double (C-Kern sl_r_encode_real, seit 1.6.0)."
function _encode_real(x::Float64, w::Int, d::Int, e::Int, dec::AbstractString = ".", na::Bool = false;
                      na_string = "NA")
    m = UInt8[na || SimLev.isna_strict(x)]
    return SimLev._rb_encode_real([x], m, w, d, e, dec, na_string, false)[1]
end

function _encode_reals(v::_V, w, d, e, dec = ".")
    m = UInt8[v.na[i] || SimLev.isna_strict(v.d[i]) for i in 1:length(v.d)]
    return _Str[t for t in SimLev._rb_encode_real(v.d, m, Int(w), Int(d), Int(e), dec, "NA", false)]
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

# Anzeigebreite eines Zeichens wie R 4.3.3 (Ri18n_wcwidth mit den Tabellen aus src/main/rlocale_widths.h) unter
# C.UTF-8 (seit 1.6.3; bis 1.6.2 aus utf8proc, also aus dem Unicode-Stand von Julia, mit Abweichungen von R und von
# Python, z. B. Steuerzeichen, Hangul-Jamo U+1160-U+11FF, nicht vergebene Codepunkte). Bereiche _WC_LO[i]:_WC_HI[i]
# mit Breite _WC_W[i] (0 oder 2), alle übrigen Codepunkte haben Breite 1. Gewonnen aus
# nchar(intToUtf8(k), type = "width") für alle Codepunkte; gleiche Tabelle in python/simlev/_r/fmt.py.
const _WC_LO = UInt32[
    0x0000, 0x007F, 0x0300, 0x0483, 0x0591, 0x05BF, 0x05C1, 0x05C4, 0x05C7, 0x0600, 0x0610, 0x061C, 0x064B, 0x0670,
    0x06D6, 0x06DF, 0x06E7, 0x06EA, 0x070F, 0x0711, 0x0730, 0x07A6, 0x07EB, 0x07FD, 0x0816, 0x081B, 0x0825, 0x0829,
    0x0859, 0x08D3, 0x093A, 0x093C, 0x0941, 0x094D, 0x0951, 0x0962, 0x0981, 0x09BC, 0x09C1, 0x09CD, 0x09E2, 0x09FE,
    0x0A01, 0x0A3C, 0x0A41, 0x0A47, 0x0A4B, 0x0A51, 0x0A70, 0x0A75, 0x0A81, 0x0ABC, 0x0AC1, 0x0AC7, 0x0ACD, 0x0AE2,
    0x0AFA, 0x0B01, 0x0B3C, 0x0B3F, 0x0B41, 0x0B4D, 0x0B55, 0x0B62, 0x0B82, 0x0BC0, 0x0BCD, 0x0C00, 0x0C04, 0x0C3E,
    0x0C46, 0x0C4A, 0x0C55, 0x0C62, 0x0C81, 0x0CBC, 0x0CBF, 0x0CC6, 0x0CCC, 0x0CE2, 0x0D00, 0x0D3B, 0x0D41, 0x0D4D,
    0x0D62, 0x0D81, 0x0DCA, 0x0DD2, 0x0DD6, 0x0E31, 0x0E34, 0x0E47, 0x0EB1, 0x0EB4, 0x0EC8, 0x0F18, 0x0F35, 0x0F37,
    0x0F39, 0x0F71, 0x0F80, 0x0F86, 0x0F8D, 0x0F99, 0x0FC6, 0x102D, 0x1032, 0x1039, 0x103D, 0x1058, 0x105E, 0x1071,
    0x1082, 0x1085, 0x108D, 0x109D, 0x1100, 0x1160, 0x135D, 0x1712, 0x1732, 0x1752, 0x1772, 0x17B4, 0x17B7, 0x17C6,
    0x17C9, 0x17DD, 0x180B, 0x1885, 0x18A9, 0x1920, 0x1927, 0x1932, 0x1939, 0x1A17, 0x1A1B, 0x1A56, 0x1A58, 0x1A60,
    0x1A62, 0x1A65, 0x1A73, 0x1A7F, 0x1AB0, 0x1B00, 0x1B34, 0x1B36, 0x1B3C, 0x1B42, 0x1B6B, 0x1B80, 0x1BA2, 0x1BA8,
    0x1BAB, 0x1BE6, 0x1BE8, 0x1BED, 0x1BEF, 0x1C2C, 0x1C36, 0x1CD0, 0x1CD4, 0x1CE2, 0x1CED, 0x1CF4, 0x1CF8, 0x1DC0,
    0x1DFB, 0x200B, 0x202A, 0x2060, 0x2066, 0x20D0, 0x231A, 0x2329, 0x23E9, 0x23F0, 0x23F3, 0x25FD, 0x2614, 0x2648,
    0x267F, 0x2693, 0x26A1, 0x26AA, 0x26BD, 0x26C4, 0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F5, 0x26FA, 0x26FD, 0x2705,
    0x270A, 0x2728, 0x274C, 0x274E, 0x2753, 0x2757, 0x2795, 0x27B0, 0x27BF, 0x2B1B, 0x2B50, 0x2B55, 0x2CEF, 0x2D7F,
    0x2DE0, 0x2E80, 0x2E9B, 0x2F00, 0x2FF0, 0x3000, 0x302A, 0x302E, 0x3041, 0x3099, 0x309B, 0x3105, 0x3131, 0x3190,
    0x31F0, 0x3220, 0x3250, 0x4E00, 0xA490, 0xA66F, 0xA674, 0xA69E, 0xA6F0, 0xA802, 0xA806, 0xA80B, 0xA825, 0xA82C,
    0xA8C4, 0xA8E0, 0xA8FF, 0xA926, 0xA947, 0xA960, 0xA980, 0xA9B3, 0xA9B6, 0xA9BC, 0xA9E5, 0xAA29, 0xAA31, 0xAA35,
    0xAA43, 0xAA4C, 0xAA7C, 0xAAB0, 0xAAB2, 0xAAB7, 0xAABE, 0xAAC1, 0xAAEC, 0xAAF6, 0xABE5, 0xABE8, 0xABED, 0xAC00,
    0xF900, 0xFB1E, 0xFE00, 0xFE10, 0xFE20, 0xFE30, 0xFE54, 0xFE68, 0xFEFF, 0xFF01, 0xFFE0, 0xFFF9, 0x101FD, 0x102E0,
    0x10376, 0x10A01, 0x10A05, 0x10A0C, 0x10A38, 0x10A3F, 0x10AE5, 0x10D24, 0x10EAB, 0x10F46, 0x11001, 0x11038,
    0x1107F, 0x110B3, 0x110B9, 0x110BD, 0x110CD, 0x11100, 0x11127, 0x1112D, 0x11173, 0x11180, 0x111B6, 0x111C9,
    0x111CF, 0x1122F, 0x11234, 0x11236, 0x1123E, 0x112DF, 0x112E3, 0x11300, 0x1133B, 0x11340, 0x11366, 0x11370,
    0x11438, 0x11442, 0x11446, 0x1145E, 0x114B3, 0x114BA, 0x114BF, 0x114C2, 0x115B2, 0x115BC, 0x115BF, 0x115DC,
    0x11633, 0x1163D, 0x1163F, 0x116AB, 0x116AD, 0x116B0, 0x116B7, 0x1171D, 0x11722, 0x11727, 0x1182F, 0x11839,
    0x1193B, 0x1193E, 0x11943, 0x119D4, 0x119DA, 0x119E0, 0x11A01, 0x11A33, 0x11A3B, 0x11A47, 0x11A51, 0x11A59,
    0x11A8A, 0x11A98, 0x11C30, 0x11C38, 0x11C3F, 0x11C92, 0x11CAA, 0x11CB2, 0x11CB5, 0x11D31, 0x11D3A, 0x11D3C,
    0x11D3F, 0x11D47, 0x11D90, 0x11D95, 0x11D97, 0x11EF3, 0x13430, 0x16AF0, 0x16B30, 0x16F4F, 0x16F8F, 0x16FE0,
    0x16FE4, 0x16FF0, 0x17000, 0x18800, 0x18D00, 0x1B000, 0x1B150, 0x1B164, 0x1B170, 0x1BC9D, 0x1BCA0, 0x1D167,
    0x1D173, 0x1D185, 0x1D1AA, 0x1D242, 0x1DA00, 0x1DA3B, 0x1DA75, 0x1DA84, 0x1DA9B, 0x1DAA1, 0x1E000, 0x1E008,
    0x1E01B, 0x1E023, 0x1E026, 0x1E130, 0x1E2EC, 0x1E8D0, 0x1E944, 0x1F004, 0x1F0CF, 0x1F18E, 0x1F191, 0x1F200,
    0x1F210, 0x1F240, 0x1F250, 0x1F260, 0x1F300, 0x1F32D, 0x1F337, 0x1F37E, 0x1F3A0, 0x1F3CF, 0x1F3E0, 0x1F3F4,
    0x1F3F8, 0x1F440, 0x1F442, 0x1F4FF, 0x1F54B, 0x1F550, 0x1F57A, 0x1F595, 0x1F5A4, 0x1F5FB, 0x1F680, 0x1F6CC,
    0x1F6D0, 0x1F6D5, 0x1F6EB, 0x1F6F4, 0x1F7E0, 0x1F90C, 0x1F93C, 0x1F947, 0x1F97A, 0x1F9CD, 0x1FA70, 0x1FA78,
    0x1FA80, 0x1FA90, 0x1FAB0, 0x1FAC0, 0x1FAD0, 0x20000, 0xE0001, 0xE0020, 0xE0100]
const _WC_HI = UInt32[
    0x001F, 0x009F, 0x036F, 0x0489, 0x05BD, 0x05BF, 0x05C2, 0x05C5, 0x05C7, 0x0605, 0x061A, 0x061C, 0x065F, 0x0670,
    0x06DD, 0x06E4, 0x06E8, 0x06ED, 0x070F, 0x0711, 0x074A, 0x07B0, 0x07F3, 0x07FD, 0x0819, 0x0823, 0x0827, 0x082D,
    0x085B, 0x0902, 0x093A, 0x093C, 0x0948, 0x094D, 0x0957, 0x0963, 0x0981, 0x09BC, 0x09C4, 0x09CD, 0x09E3, 0x09FE,
    0x0A02, 0x0A3C, 0x0A42, 0x0A48, 0x0A4D, 0x0A51, 0x0A71, 0x0A75, 0x0A82, 0x0ABC, 0x0AC5, 0x0AC8, 0x0ACD, 0x0AE3,
    0x0AFF, 0x0B01, 0x0B3C, 0x0B3F, 0x0B44, 0x0B4D, 0x0B56, 0x0B63, 0x0B82, 0x0BC0, 0x0BCD, 0x0C00, 0x0C04, 0x0C40,
    0x0C48, 0x0C4D, 0x0C56, 0x0C63, 0x0C81, 0x0CBC, 0x0CBF, 0x0CC6, 0x0CCD, 0x0CE3, 0x0D01, 0x0D3C, 0x0D44, 0x0D4D,
    0x0D63, 0x0D81, 0x0DCA, 0x0DD4, 0x0DD6, 0x0E31, 0x0E3A, 0x0E4E, 0x0EB1, 0x0EBC, 0x0ECD, 0x0F19, 0x0F35, 0x0F37,
    0x0F39, 0x0F7E, 0x0F84, 0x0F87, 0x0F97, 0x0FBC, 0x0FC6, 0x1030, 0x1037, 0x103A, 0x103E, 0x1059, 0x1060, 0x1074,
    0x1082, 0x1086, 0x108D, 0x109D, 0x115F, 0x11FF, 0x135F, 0x1714, 0x1734, 0x1753, 0x1773, 0x17B5, 0x17BD, 0x17C6,
    0x17D3, 0x17DD, 0x180E, 0x1886, 0x18A9, 0x1922, 0x1928, 0x1932, 0x193B, 0x1A18, 0x1A1B, 0x1A56, 0x1A5E, 0x1A60,
    0x1A62, 0x1A6C, 0x1A7C, 0x1A7F, 0x1AC0, 0x1B03, 0x1B34, 0x1B3A, 0x1B3C, 0x1B42, 0x1B73, 0x1B81, 0x1BA5, 0x1BA9,
    0x1BAD, 0x1BE6, 0x1BE9, 0x1BED, 0x1BF1, 0x1C33, 0x1C37, 0x1CD2, 0x1CE0, 0x1CE8, 0x1CED, 0x1CF4, 0x1CF9, 0x1DF9,
    0x1DFF, 0x200F, 0x202E, 0x2064, 0x206F, 0x20F0, 0x231B, 0x232A, 0x23EC, 0x23F0, 0x23F3, 0x25FE, 0x2615, 0x2653,
    0x267F, 0x2693, 0x26A1, 0x26AB, 0x26BE, 0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705,
    0x270B, 0x2728, 0x274C, 0x274E, 0x2755, 0x2757, 0x2797, 0x27B0, 0x27BF, 0x2B1C, 0x2B50, 0x2B55, 0x2CF1, 0x2D7F,
    0x2DFF, 0x2E99, 0x2EF3, 0x2FD5, 0x2FFB, 0x3029, 0x302D, 0x303E, 0x3096, 0x309A, 0x30FF, 0x312F, 0x318E, 0x31E3,
    0x321E, 0x3247, 0x4DBF, 0xA48C, 0xA4C6, 0xA672, 0xA67D, 0xA69F, 0xA6F1, 0xA802, 0xA806, 0xA80B, 0xA826, 0xA82C,
    0xA8C5, 0xA8F1, 0xA8FF, 0xA92D, 0xA951, 0xA97C, 0xA982, 0xA9B3, 0xA9B9, 0xA9BD, 0xA9E5, 0xAA2E, 0xAA32, 0xAA36,
    0xAA43, 0xAA4C, 0xAA7C, 0xAAB0, 0xAAB4, 0xAAB8, 0xAABF, 0xAAC1, 0xAAED, 0xAAF6, 0xABE5, 0xABE8, 0xABED, 0xD7A3,
    0xFAFF, 0xFB1E, 0xFE0F, 0xFE19, 0xFE2F, 0xFE52, 0xFE66, 0xFE6B, 0xFEFF, 0xFF60, 0xFFE6, 0xFFFB, 0x101FD, 0x102E0,
    0x1037A, 0x10A03, 0x10A06, 0x10A0F, 0x10A3A, 0x10A3F, 0x10AE6, 0x10D27, 0x10EAC, 0x10F50, 0x11001, 0x11046,
    0x11081, 0x110B6, 0x110BA, 0x110BD, 0x110CD, 0x11102, 0x1112B, 0x11134, 0x11173, 0x11181, 0x111BE, 0x111CC,
    0x111CF, 0x11231, 0x11234, 0x11237, 0x1123E, 0x112DF, 0x112EA, 0x11301, 0x1133C, 0x11340, 0x1136C, 0x11374,
    0x1143F, 0x11444, 0x11446, 0x1145E, 0x114B8, 0x114BA, 0x114C0, 0x114C3, 0x115B5, 0x115BD, 0x115C0, 0x115DD,
    0x1163A, 0x1163D, 0x11640, 0x116AB, 0x116AD, 0x116B5, 0x116B7, 0x1171F, 0x11725, 0x1172B, 0x11837, 0x1183A,
    0x1193C, 0x1193E, 0x11943, 0x119D7, 0x119DB, 0x119E0, 0x11A0A, 0x11A38, 0x11A3E, 0x11A47, 0x11A56, 0x11A5B,
    0x11A96, 0x11A99, 0x11C36, 0x11C3D, 0x11C3F, 0x11CA7, 0x11CB0, 0x11CB3, 0x11CB6, 0x11D36, 0x11D3A, 0x11D3D,
    0x11D45, 0x11D47, 0x11D91, 0x11D95, 0x11D97, 0x11EF4, 0x13438, 0x16AF4, 0x16B36, 0x16F4F, 0x16F92, 0x16FE3,
    0x16FE4, 0x16FF1, 0x187F7, 0x18CD5, 0x18D08, 0x1B11E, 0x1B152, 0x1B167, 0x1B2FB, 0x1BC9E, 0x1BCA3, 0x1D169,
    0x1D182, 0x1D18B, 0x1D1AD, 0x1D244, 0x1DA36, 0x1DA6C, 0x1DA75, 0x1DA84, 0x1DA9F, 0x1DAAF, 0x1E006, 0x1E018,
    0x1E021, 0x1E024, 0x1E02A, 0x1E136, 0x1E2EF, 0x1E8D6, 0x1E94A, 0x1F004, 0x1F0CF, 0x1F18E, 0x1F19A, 0x1F202,
    0x1F23B, 0x1F248, 0x1F251, 0x1F265, 0x1F320, 0x1F335, 0x1F37C, 0x1F393, 0x1F3CA, 0x1F3D3, 0x1F3F0, 0x1F3F4,
    0x1F43E, 0x1F440, 0x1F4FC, 0x1F53D, 0x1F54E, 0x1F567, 0x1F57A, 0x1F596, 0x1F5A4, 0x1F64F, 0x1F6C5, 0x1F6CC,
    0x1F6D2, 0x1F6D7, 0x1F6EC, 0x1F6FC, 0x1F7EB, 0x1F93A, 0x1F945, 0x1F978, 0x1F9CB, 0x1F9FF, 0x1FA74, 0x1FA7A,
    0x1FA86, 0x1FAA8, 0x1FAB6, 0x1FAC2, 0x1FAD6, 0x3FFFF, 0xE0001, 0xE007F, 0xE01EF]
const _WC_W = UInt8[
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 2, 2, 2, 2, 2, 0, 2, 2, 0, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
    2, 0, 0, 2, 0, 2, 2, 2, 0, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 2, 2,
    2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0,
    0]

function _wcwidth(c::Char)
    k = UInt32(c)
    0x20 <= k < 0x7F && return 1
    i = searchsortedlast(_WC_LO, k)
    return i >= 1 && k <= _WC_HI[i] ? Int(_WC_W[i]) : 1
end

# Druckbar wie R unter Linux (glibc 2.39 iswprint in C.UTF-8, julia/src/r/wctype.jl; seit 1.6.4 feste Tabelle, C-047;
# bis 1.6.3 nach utf8proc, das an rund 10 000 neueren Codepunkten abwich)
_printable(c::Char) = SimLev._wct_print(c)

const _NOQ = '\0'

"`Rstrwid`: Anzeigebreite (Escapes mitgezählt); q = Anführungszeichen oder '\\0'."
function _strwid(s::AbstractString, q::Char = _NOQ)
    n = 0
    for c in s
        # seit 1.6.5 (CR2-X4-4): ungültiges UTF-8 wie R als \\xHH je Byte (Breite 4; bis 1.6.4 InvalidCharError)
        isvalid(c) || (n += 4 * ncodeunits(c); continue)
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
        if !isvalid(c)   # seit 1.6.5 (CR2-X4-4) wie R: \\xHH je Byte
            for b in codeunits(string(c))
                print(io, "\\x", string(b, base = 16, pad = 2))
            end
            continue
        end
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

"""
    nchar(x, type = "chars")

`nchar(x, type)`: "chars", "bytes" oder "width" (NA → 2 wie in R).
"""
function nchar(x, t = "chars"; type = t)
    # seit 1.6.4 wie R (C-049, C-056): Teilanfang von type erlaubt, sonst „invalid 'type' argument“; Faktor ist ein Fehler
    x isa RFactor && error("'nchar()' requires a character vector")
    hit = type isa AbstractString && !isempty(type) ? [k for k in ("bytes", "chars", "width") if startswith(k, type)] : String[]
    isempty(hit) && error("invalid 'type' argument")
    type = hit[1]
    v = _as_v(x, "character")
    res = Union{Missing,Int}[]
    for s in v.s
        if s === nothing
            # seit 1.6.4 wie R (keepNA = NA, C-039): NA ergibt für "chars" und "bytes" `missing`, für "width" 2; bis
            # 1.6.3 immer 2
            push!(res, type == "width" ? 2 : missing)
        elseif type == "bytes"
            push!(res, ncodeunits(s))
        elseif type == "width"
            push!(res, sum((_wcwidth(c) for c in s); init = 0))
        else
            push!(res, length(s))
        end
    end
    v.scalar && return res[1]
    any(ismissing, res) && return res
    return Vector{Int}(res)
end

# ── as.character / paste ───────────────────────────────────────────────────

function _as_character_list(v::_V)::Vector{_Str}
    t = v.type
    t === :character && return copy(v.s)
    if t === :double
        r = SimLev._rb_as_character_real(v.d, Int(_OPT[:scipen])::Int, String(_OPT[:OutDec])::String)
        return _Str[(v.na[i] || (isnan(v.d[i]) && !v.nan[i])) ? nothing : r[i] for i in 1:length(v.d)]
    end
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
# sep/collapse wie R's do_paste (seit 1.6.4, RP, C-056): Text (erster Wert eines Textvektors), nicht NA
function _paste_str1(v, msg)
    if v isa AbstractVector || v isa Tuple
        vv = collect(v)
        (isempty(vv) || !all(t -> t isa AbstractString || t === missing || t === nothing, vv)) && error(msg)
        v = vv[1]
    end
    v isa AbstractString || error(msg)
    return String(v)
end

function paste(args...; sep = " ", collapse = nothing)
    sep = _paste_str1(sep, "invalid separator")
    collapse === nothing || (collapse = _paste_str1(collapse, "invalid 'collapse' argument"))
    vecs = Vector{Vector{String}}()
    allscalar = true
    for a in args
        v = _as_v(a)
        # seit 1.6.5 (CR2-R-6) wie R ein leerer Vektor ("" neben anderen; bis 1.6.4 übergangen)
        v.type === :NULL && (push!(vecs, String[]); continue)
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
