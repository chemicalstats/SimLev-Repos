# ─────────────────────────────────────────────────────────────────────────────
# R-Datenstrukturen für die Julia-Fassung
#
#   R                      Julia
#   ─────────────────────  ───────────────────────────────────────────────────
#   NULL                   nothing
#   NA (numerisch)         SimLev.NA (NaN mit Nutzlast 1954, ≠ NaN)
#   NA (sonst)             missing
#   Vektor Länge 1         Skalar (Float64, Int, Bool, String, Date)
#   Vektor                 Vector{T}
#   Vektor mit Namen/Attr. RVector{T}  (x["name"], x[i], names(x), attrs(x))
#   Matrix                 Matrix{T};  mit dimnames: NamedMat{T}
#   data.frame             RFrame      (df.spalte, df["spalte"], nrow, ncol, names)
#   Liste mit Namen        RList       (x.name, x["name"], keys(x), class)
#   Liste ohne Namen       Vector{Any}
#
# Objekte mit S3-Klasse sind RList bzw. RFrame mit gesetztem `class`.
# Druckausgabe: `register_print!(klasse, f)` mit `f(io, x)`; `show(io,
# MIME"text/plain"(), x)` schreibt dann exakt die Ausgabe der R-print-Methode.
# Ebenso `register_summary!` / `register_plot!` für die generischen
# Funktionen `r_summary(object, args...)` und `r_plot(x, args...)`.
# ─────────────────────────────────────────────────────────────────────────────

const _PRINTERS = Dict{String,Function}()
const _SUMMARIES = Dict{String,Function}()
const _PLOTS = Dict{String,Function}()

"Druckmethode für die S3-Klasse `cls` registrieren: `f(io::IO, x)`."
register_print!(cls::AbstractString, f::Function) = (_PRINTERS[String(cls)] = f; nothing)
"`summary`-Methode für die S3-Klasse `cls` registrieren: `f(x, args...; kw...)`."
register_summary!(cls::AbstractString, f::Function) = (_SUMMARIES[String(cls)] = f; nothing)
"`plot`-Methode für die S3-Klasse `cls` registrieren: `f(x, args...; kw...)`."
register_plot!(cls::AbstractString, f::Function) = (_PLOTS[String(cls)] = f; nothing)

function _dispatch(tab, x, what)
    for c in r_class(x)
        f = get(tab, c, nothing)
        f === nothing || return f
    end
    return nothing
end

# ── RList ────────────────────────────────────────────────────────────────────

"""
    RList(pairs...; class = String[])

Benannte R-Liste: geordnet, Zugriff über `x.name` oder `x["name"]`.
"""
mutable struct RList <: AbstractDict{String,Any}
    keys::Vector{String}
    vals::Vector{Any}
    class::Vector{String}
    attrs::Dict{String,Any}           # weitere R-Attribute (attr(x, "name")), Zugriff über attrs(x)
end
RList(k::Vector{String}, v::Vector{Any}, c::Vector{String}) = RList(k, v, c, Dict{String,Any}())
RList(; class = String[]) = RList(String[], Any[], collect(String, class isa AbstractString ? [class] : class))
function RList(ps::Pair...; class = String[])
    x = RList(; class = class)
    for (k, v) in ps
        x[String(k)] = v
    end
    x
end
function RList(d::AbstractDict; class = String[])
    x = RList(; class = class)
    for (k, v) in d
        x[String(k)] = v
    end
    x
end

_rl_keys(x::RList) = getfield(x, :keys)
_rl_vals(x::RList) = getfield(x, :vals)
Base.length(x::RList) = length(_rl_keys(x))
function Base.getindex(x::RList, k::AbstractString)
    i = findfirst(==(k), _rl_keys(x))
    i === nothing && throw(KeyError(k))
    _rl_vals(x)[i]
end
Base.getindex(x::RList, k::Symbol) = x[String(k)]
Base.getindex(x::RList, i::Integer) = _rl_vals(x)[i]
function Base.setindex!(x::RList, v, k::AbstractString)
    i = findfirst(==(k), _rl_keys(x))
    if i === nothing
        push!(_rl_keys(x), String(k)); push!(_rl_vals(x), v)
    else
        _rl_vals(x)[i] = v
    end
    x
end
Base.setindex!(x::RList, v, k::Symbol) = setindex!(x, v, String(k))
Base.haskey(x::RList, k::AbstractString) = k in _rl_keys(x)
Base.haskey(x::RList, k::Symbol) = haskey(x, String(k))
Base.get(x::RList, k::AbstractString, d) = haskey(x, k) ? x[k] : d
Base.get(x::RList, k::Symbol, d) = get(x, String(k), d)
function Base.delete!(x::RList, k::AbstractString)
    i = findfirst(==(k), _rl_keys(x))
    i === nothing || (deleteat!(_rl_keys(x), i); deleteat!(_rl_vals(x), i))
    x
end
Base.keys(x::RList) = copy(_rl_keys(x))
Base.values(x::RList) = copy(_rl_vals(x))
function Base.iterate(x::RList, i = 1)
    i > length(x) && return nothing
    (_rl_keys(x)[i] => _rl_vals(x)[i], i + 1)
end
function Base.getproperty(x::RList, s::Symbol)
    s === :class && return getfield(x, :class)
    return x[String(s)]
end
function Base.setproperty!(x::RList, s::Symbol, v)
    s === :class && return setfield!(x, :class, collect(String, v isa AbstractString ? [v] : v))
    x[String(s)] = v
end
Base.propertynames(x::RList, private::Bool = false) = Tuple(Symbol.(_rl_keys(x)))
Base.copy(x::RList) = RList(copy(_rl_keys(x)), copy(_rl_vals(x)), copy(getfield(x, :class)), copy(getfield(x, :attrs)))

# ── RVector (Vektor mit Namen und/oder Attributen) ──────────────────────────

"""
    RVector(values; names = nothing, attrs = Dict())

R-Vektor mit Namen (`x["a"]`) und Attributen (`attrs(x)["duration"]`).
Verhält sich wie ein `AbstractVector` (Rechnen liefert gewöhnliche Vektoren).
"""
struct RVector{T} <: AbstractVector{T}
    values::Vector{T}
    names::Union{Nothing,Vector{String}}
    attrs::Dict{String,Any}
end
RVector(v::AbstractVector{T}; names = nothing, attrs = Dict{String,Any}()) where {T} =
    RVector{T}(collect(v), names === nothing ? nothing : collect(String, names), Dict{String,Any}(attrs))
"Benannter Vektor aus Paaren: `named(\"a\" => 1.0, \"b\" => 2.0)`."
named(ps::Pair...) = RVector([p.second for p in ps]; names = [String(p.first) for p in ps])
Base.size(x::RVector) = size(x.values)
Base.getindex(x::RVector, i::Int) = x.values[i]
Base.setindex!(x::RVector, v, i::Int) = (x.values[i] = v)
function Base.getindex(x::RVector, k::AbstractString)
    x.names === nothing && throw(KeyError(k))
    i = findfirst(==(k), x.names)
    i === nothing && throw(KeyError(k))
    x.values[i]
end
function Base.setindex!(x::RVector, v, k::AbstractString)
    i = x.names === nothing ? nothing : findfirst(==(k), x.names)
    i === nothing && throw(KeyError(k))
    x.values[i] = v
end
Base.IndexStyle(::Type{<:RVector}) = IndexLinear()
Base.haskey(x::RVector, k::AbstractString) = x.names !== nothing && k in x.names

# ── NamedMat (Matrix mit dimnames) ───────────────────────────────────────────

"""
    NamedMat(data; rownames = nothing, colnames = nothing)

Matrix mit dimnames; `m["zeile", "spalte"]`, `m[:, "spalte"]`, sonst wie `Matrix`.
"""
struct NamedMat{T} <: AbstractMatrix{T}
    data::Matrix{T}
    rownames::Union{Nothing,Vector{String}}
    colnames::Union{Nothing,Vector{String}}
    attrs::Dict{String,Any}
end
NamedMat(m::AbstractMatrix{T}; rownames = nothing, colnames = nothing, attrs = Dict{String,Any}()) where {T} =
    NamedMat{T}(Matrix(m), rownames === nothing ? nothing : collect(String, rownames),
                colnames === nothing ? nothing : collect(String, colnames), Dict{String,Any}(attrs))
Base.size(m::NamedMat) = size(m.data)
Base.getindex(m::NamedMat, i::Int, j::Int) = m.data[i, j]
Base.setindex!(m::NamedMat, v, i::Int, j::Int) = (m.data[i, j] = v)
_nm_idx(nm, k::AbstractString) = (i = nm === nothing ? nothing : findfirst(==(k), nm); i === nothing ? throw(KeyError(k)) : i)
_nm_idx(nm, k) = k
Base.getindex(m::NamedMat, i, j::AbstractString) = m.data[_nm_idx(m.rownames, i), _nm_idx(m.colnames, j)]
Base.getindex(m::NamedMat, i::AbstractString, j) = m.data[_nm_idx(m.rownames, i), _nm_idx(m.colnames, j)]

# ── RFrame (data.frame) ──────────────────────────────────────────────────────

"""
    RFrame(pairs...; rownames = nothing, class = String[], attrs = Dict())

data.frame: geordnete Spalten (`df.spalte`, `df["spalte"]`, `df[i, "spalte"]`),
`nrow(df)`, `ncol(df)`, `names(df)`, Attribute in `attrs(df)`.
"""
mutable struct RFrame
    names::Vector{String}
    cols::Vector{AbstractVector}
    nrow::Int
    rownames::Union{Nothing,Vector{String}}
    attrs::Dict{String,Any}
    class::Vector{String}
end
function RFrame(ps::Pair...; rownames = nothing, class = String[], attrs = Dict{String,Any}(), nrow = nothing)
    nms = String[String(p.first) for p in ps]
    cols = AbstractVector[_as_col(p.second) for p in ps]
    n = nrow === nothing ? (isempty(cols) ? 0 : length(cols[1])) : nrow
    for (k, c) in zip(nms, cols)
        length(c) == n || throw(ArgumentError("RFrame: Spalte '$k' hat Länge $(length(c)), erwartet $n"))
    end
    RFrame(nms, cols, n, rownames === nothing ? nothing : collect(String, rownames), Dict{String,Any}(attrs),
           collect(String, class isa AbstractString ? [class] : class))
end
RFrame(nms::AbstractVector{<:AbstractString}, cols::AbstractVector; kw...) = RFrame((String(k) => c for (k, c) in zip(nms, cols))...; kw...)
_as_col(v::AbstractVector) = v isa RVector ? v.values : v
_as_col(v) = [v]

_rf(df::RFrame, s::Symbol) = getfield(df, s)
nrow(df::RFrame) = _rf(df, :nrow)
ncol(df::RFrame) = length(_rf(df, :names))
Base.names(df::RFrame) = copy(_rf(df, :names))
Base.size(df::RFrame) = (nrow(df), ncol(df))
Base.size(df::RFrame, i::Integer) = size(df)[i]
function Base.getindex(df::RFrame, k::AbstractString)
    i = findfirst(==(k), _rf(df, :names))
    i === nothing && throw(KeyError(k))
    _rf(df, :cols)[i]
end
Base.getindex(df::RFrame, k::Symbol) = df[String(k)]
Base.getindex(df::RFrame, i::Integer, k::Union{AbstractString,Symbol}) = df[k][i]
function Base.setindex!(df::RFrame, v, k::AbstractString)
    c = _as_col(v isa AbstractVector ? v : fill(v, nrow(df)))
    length(c) == nrow(df) || throw(ArgumentError("RFrame: Spalte '$k' hat Länge $(length(c)), erwartet $(nrow(df))"))
    i = findfirst(==(k), _rf(df, :names))
    if i === nothing
        push!(_rf(df, :names), String(k)); push!(_rf(df, :cols), c)
    else
        _rf(df, :cols)[i] = c
    end
    df
end
Base.setindex!(df::RFrame, v, k::Symbol) = setindex!(df, v, String(k))
Base.haskey(df::RFrame, k::AbstractString) = k in _rf(df, :names)
Base.haskey(df::RFrame, k::Symbol) = haskey(df, String(k))
function Base.getproperty(df::RFrame, s::Symbol)
    s in (:names, :cols, :nrow, :rownames, :attrs, :class) && return getfield(df, s)
    return df[String(s)]
end
function Base.setproperty!(df::RFrame, s::Symbol, v)
    s in (:names, :cols, :nrow, :rownames, :attrs, :class) && return setfield!(df, s, v)
    df[String(s)] = v
end
Base.propertynames(df::RFrame, private::Bool = false) = Tuple(Symbol.(_rf(df, :names)))
"""
Klassen, deren Zeilenauswahl mit [`rows`](@ref) eine gewöhnliche Tabelle ohne Klasse und ohne Attribute
ergibt (R: eigene `[`-Methode, z. B. `[.SimLevWrapperNav`, Etappe 8.0); Eintrag über `register_plain_rows!`.
"""
const _PLAIN_ROWS = Set{String}()
register_plain_rows!(cls::AbstractString) = (push!(_PLAIN_ROWS, String(cls)); nothing)

"""
Zeilen auswählen (Vektor von Indizes oder Bool-Maske), wie `df[rows, , drop = FALSE]`. Klasse und Attribute
bleiben, außer für Klassen aus `register_plain_rows!` (dann gewöhnliche Tabelle, wie R mit eigener `[`-Methode).
"""
function rows(df::RFrame, idx)
    ii = idx isa AbstractVector{Bool} ? findall(idx) : collect(idx)
    cl = _rf(df, :class)
    plain = !isempty(_PLAIN_ROWS) && any(in(_PLAIN_ROWS), cl)
    RFrame(copy(_rf(df, :names)), AbstractVector[c[ii] for c in _rf(df, :cols)], length(ii),
           _rf(df, :rownames) === nothing ? nothing : _rf(df, :rownames)[ii],
           plain ? Dict{String,Any}() : copy(_rf(df, :attrs)), plain ? String[] : copy(cl))
end
Base.copy(df::RFrame) = RFrame(copy(_rf(df, :names)), AbstractVector[copy(c) for c in _rf(df, :cols)], nrow(df),
                               _rf(df, :rownames) === nothing ? nothing : copy(_rf(df, :rownames)),
                               copy(_rf(df, :attrs)), copy(_rf(df, :class)))
"Spalten als NamedTuple-artige Paare (für Eingaben der Engine)."
Base.pairs(df::RFrame) = (k => c for (k, c) in zip(_rf(df, :names), _rf(df, :cols)))

"""
    as_rframe(x) -> RFrame oder x

Zentraler Konverter für data.frame-artige Eingaben der Erweiterungen:
`RFrame` (unverändert), `NamedTuple` aus Spalten, `Dict` (Spalten nach Namen
sortiert, da ungeordnet; andere `AbstractDict` in ihrer Reihenfolge) und
`Pair`-Vektor (`["date" => d, "A" => a]`). Spalten sind Vektoren gleicher Länge
(Skalare zählen als Länge 1 und werden auf die Länge der übrigen Spalten
gebracht, wie `data.frame(a = 1:3, b = 0)`); `RVector`-Spalten verlieren ihre
Namen. Alles andere (Matrizen, Vektoren, `RList`, ungleich lange Spalten …)
kommt unverändert zurück, damit die aufrufende Funktion ihre R-Meldung gibt.
"""
as_rframe(x::RFrame) = x
as_rframe(x) = x
function as_rframe(x::NamedTuple)
    isempty(x) && return x
    return _as_rframe_cols(x, String[String(k) for k in keys(x)], Any[v for v in values(x)])
end
function as_rframe(x::AbstractDict)
    (x isa RList || isempty(x)) && return x
    ks = collect(keys(x))
    all(k -> k isa Union{AbstractString,Symbol}, ks) || return x
    nms = String[String(k) for k in ks]
    vals = Any[x[k] for k in ks]
    if x isa Dict
        o = sortperm(nms)
        nms, vals = nms[o], vals[o]
    end
    return _as_rframe_cols(x, nms, vals)
end
function as_rframe(x::AbstractVector{<:Pair})
    isempty(x) && return x
    all(p -> p.first isa Union{AbstractString,Symbol}, x) || return x
    return _as_rframe_cols(x, String[String(p.first) for p in x], Any[p.second for p in x])
end
function _as_rframe_cols(x, nms::Vector{String}, vals::Vector{Any})
    lens = Int[]
    for v in vals
        if v isa AbstractVector
            push!(lens, length(v))
        elseif !(v isa Union{Real,AbstractString,Missing,Dates.Date,Symbol})
            return x
        end
    end
    n = isempty(lens) ? 1 : lens[1]
    all(==(n), lens) || return x
    allunique(nms) || return x
    cols = AbstractVector[v isa AbstractVector ? (v isa RVector ? v.values : v) : fill(v isa Symbol ? String(v) : v, n) for v in vals]
    return RFrame(nms, cols; nrow = n)
end

# ── gemeinsame Zugriffe ──────────────────────────────────────────────────────

"R-Klassenvektor eines Objekts (leer, wenn keine S3-Klasse)."
r_class(x) = String[]
r_class(x::RList) = getfield(x, :class)
r_class(x::RFrame) = getfield(x, :class)
r_class(x::RVector) = collect(String, get(x.attrs, "class", String[]))

"Attribute eines Objekts (`attributes(x)` ohne names/dim/class)."
attrs(x::RVector) = x.attrs
attrs(x::RList) = getfield(x, :attrs)
attrs(x::NamedMat) = x.attrs
attrs(x::RFrame) = getfield(x, :attrs)

"`inherits(x, cls)`"
inherits(x, cls::AbstractString) = cls in r_class(x)

function Base.show(io::IO, ::MIME"text/plain", x::RList)
    f = _dispatch(_PRINTERS, x, "print")
    f === nothing ? _default_print(io, x) : f(io, x)
end
Base.show(io::IO, x::RList) = print(io, "RList(", join(_rl_keys(x), ", "), ")")
function Base.show(io::IO, ::MIME"text/plain", df::RFrame)
    f = _dispatch(_PRINTERS, df, "print")
    f === nothing ? _default_print(io, df) : f(io, df)
end
Base.show(io::IO, df::RFrame) = print(io, "RFrame(", nrow(df), " × ", ncol(df), ": ", join(_rf(df, :names), ", "), ")")

# Voreinstellung, bis die Formatierung (RFmt) eine R-genaue print-Funktion setzt
const _DEFAULT_PRINT = Ref{Function}((io, x) -> print(io, x))
_default_print(io, x) = _DEFAULT_PRINT[](io, x)

"Generisches `summary(object, ...)` wie in R (Methode nach S3-Klasse; Argumentname `object` wie R)."
function r_summary(object, args...; kw...)
    f = _dispatch(_SUMMARIES, object, "summary")
    f === nothing && error("summary(): keine Methode für $(typeof(object))")
    f(object, args...; kw...)
end
"Generisches `plot()` wie in R (Methode nach S3-Klasse; erzeugt SVG)."
function r_plot(x, args...; kw...)
    f = _dispatch(_PLOTS, x, "plot")
    f === nothing && error("plot(): keine Methode für $(typeof(x))")
    f(x, args...; kw...)
end
