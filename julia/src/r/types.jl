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

# Methode aus tab zur ersten passenden R-Klasse von x (seit 1.6.4 ohne den ungelesenen Parameter what)
function _dispatch(tab, x)
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
# seit 1.6.5 (CR2-W1-5): so viele Namen wie Werte (bis 1.6.4 angenommen, BoundsError erst beim Zugriff)
function RVector(v::AbstractVector{T}; names = nothing, attrs = Dict{String,Any}()) where {T}
    names === nothing || length(names) == length(v) || chk_stop("laenge", "RVector", "names", chk_fmt(length(v)))
    RVector{T}(collect(v), names === nothing ? nothing : collect(String, names), Dict{String,Any}(attrs))
end
"Benannter Vektor aus Paaren: `named(\"a\" => 1.0, \"b\" => 2.0)`."
named(ps::Pair...) = (_named_check(ps); RVector([p.second for p in ps]; names = [String(p.first) for p in ps]))
# seit 1.6.4 (K42 E5): nur Paare mit nicht leerem Namen (Text oder Symbol), sonst Meldung statt MethodError
_named_check(ps) = all(p -> p.first isa Union{AbstractString,Symbol} && !isempty(String(p.first)), ps) ||
    chk_stop("e5.named", "named")
named(ps...) = chk_stop("e5.named", "named")
Base.size(x::RVector) = size(x.values)
Base.getindex(x::RVector, i::Int) = x.values[i]
Base.setindex!(x::RVector, v, i::Int) = (x.values[i] = v)
function Base.getindex(x::RVector, k::AbstractString)
    i = x.names === nothing ? nothing : findfirst(==(k), x.names)
    i === nothing && chk_stop("d.name_fehlt", "RVector", k)   # seit 1.6.5 Meldung statt KeyError
    x.values[i]
end
function Base.setindex!(x::RVector, v, k::AbstractString)
    i = x.names === nothing ? nothing : findfirst(==(k), x.names)
    i === nothing && chk_stop("d.name_fehlt", "RVector", k)
    x.values[i] = v
end
Base.IndexStyle(::Type{<:RVector}) = IndexLinear()
Base.haskey(x::RVector, k::AbstractString) = x.names !== nothing && k in x.names

# ── NamedMat (Matrix mit dimnames) ───────────────────────────────────────────

"""
    NamedMat(data; rownames = nothing, colnames = nothing)

Matrix mit dimnames. Zugriff nach Namen und Nummern gemischt: `m["zeile", "spalte"]`, `m[1, "spalte"]`,
`m["zeile", 2]`, `m[:, "spalte"]`, `m["zeile", :]`, Namenvektoren `m[:, ["x", "z"]]`, `m[["a"], :]`; ebenso
Zuweisungen (`m["a", "x"] = 9.0`). Teilmatrizen (`m[1:2, :]`, `m[:, ["x", "z"]]`) und Rechnungen ergeben eine
gewöhnliche `Matrix` ohne Namen (Entscheidung 189); sonst wie `Matrix`. Doppelte Namen sind wie in R erlaubt, ein Name
trifft dann den ersten.
"""
struct NamedMat{T} <: AbstractMatrix{T}
    data::Matrix{T}
    rownames::Union{Nothing,Vector{String}}
    colnames::Union{Nothing,Vector{String}}
    attrs::Dict{String,Any}
end
# seit 1.6.5 (CR2-W4-1): Zahl der Namen muss zur Matrix passen (bis 1.6.4 ohne Prüfung)
function NamedMat(m::AbstractMatrix{T}; rownames = nothing, colnames = nothing, attrs = Dict{String,Any}()) where {T}
    rownames === nothing || length(rownames) == size(m, 1) || chk_stop("laenge", "NamedMat", "rownames", chk_fmt(size(m, 1)))
    colnames === nothing || length(colnames) == size(m, 2) || chk_stop("laenge", "NamedMat", "colnames", chk_fmt(size(m, 2)))
    NamedMat{T}(Matrix(m), rownames === nothing ? nothing : collect(String, rownames),
                colnames === nothing ? nothing : collect(String, colnames), Dict{String,Any}(attrs))
end
Base.size(m::NamedMat) = size(m.data)
Base.IndexStyle(::Type{<:NamedMat}) = IndexCartesian()
Base.getindex(m::NamedMat, i::Int, j::Int) = m.data[i, j]
Base.setindex!(m::NamedMat, v, i::Int, j::Int) = (m.data[i, j] = v)
# Namen in Nummern (seit 1.6.5, CR2-W4-1: zwei Namen, Namenvektoren, Zuweisung; fehlender Name mit Meldung statt
# KeyError); andere Indizes unverändert
function _nm_idx(nm, k::AbstractString)
    i = nm === nothing ? nothing : findfirst(==(k), nm)
    i === nothing && chk_stop("d.name_fehlt", "NamedMat", k)
    return i
end
_nm_idx(nm, k::AbstractVector{<:AbstractString}) = Int[_nm_idx(nm, x) for x in k]
_nm_idx(nm, k) = k
const _NMIdx = Union{AbstractString,AbstractVector{<:AbstractString}}
Base.getindex(m::NamedMat, i::_NMIdx, j::_NMIdx) = m.data[_nm_idx(m.rownames, i), _nm_idx(m.colnames, j)]
Base.getindex(m::NamedMat, i, j::_NMIdx) = m.data[i, _nm_idx(m.colnames, j)]
Base.getindex(m::NamedMat, i::_NMIdx, j) = m.data[_nm_idx(m.rownames, i), j]
Base.setindex!(m::NamedMat, v, i::_NMIdx, j::_NMIdx) = (m.data[_nm_idx(m.rownames, i), _nm_idx(m.colnames, j)] = v)
Base.setindex!(m::NamedMat, v, i, j::_NMIdx) = (m.data[i, _nm_idx(m.colnames, j)] = v)
Base.setindex!(m::NamedMat, v, i::_NMIdx, j) = (m.data[_nm_idx(m.rownames, i), j] = v)

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
function RFrame(ps::Pair...; rownames = nothing, class = String[], attrs = Dict{String,Any}(), nrow = nothing, kw...)
    # seit 1.6.5 (FB-2): Spalten auch als Schlüsselwörter, RFrame(; date = d, A = a); rownames, class, attrs und nrow
    # bleiben Einstellungen
    isempty(kw) || (ps = (ps..., (String(k) => v for (k, v) in kw)...))
    nms = String[String(p.first) for p in ps]   # doppelte Namen bleiben erlaubt (die Funktionen melden sie selbst)
    cols = AbstractVector[_as_col(p.second) for p in ps]
    n = nrow === nothing ? (isempty(cols) ? 0 : length(cols[1])) : nrow
    for (k, c) in zip(nms, cols)
        length(c) == n || throw(ArgumentError("RFrame: Spalte '$k' hat Länge $(length(c)), erwartet $n"))
    end
    RFrame(nms, cols, n, rownames === nothing ? nothing : collect(String, rownames), Dict{String,Any}(attrs),
           collect(String, class isa AbstractString ? [class] : class))
end
RFrame(nms::AbstractVector{<:AbstractString}, cols::AbstractVector; kw...) = RFrame((String(k) => c for (k, c) in zip(nms, cols))...; kw...)
"`RFrame(nt)`: Tabelle aus einem NamedTuple von Spalten (seit 1.6.5, FB-2; bis 1.6.4 `RFrame(pairs(nt)...)`)."
RFrame(nt::NamedTuple; kw...) = RFrame((String(k) => v for (k, v) in pairs(nt))...; kw...)
_as_col(v::AbstractVector) = v isa RVector ? v.values : v
_as_col(v) = [v]

_rf(df::RFrame, s::Symbol) = getfield(df, s)
nrow(df::RFrame) = _rf(df, :nrow)
ncol(df::RFrame) = length(_rf(df, :names))
# seit 1.6.4 (K42 E5): andere Typen mit der Meldung tabelle statt MethodError
nrow(@nospecialize(df)) = chk_stop("tabelle", "nrow", "df", chk_msg("tabelle.formen"))
ncol(@nospecialize(df)) = chk_stop("tabelle", "ncol", "df", chk_msg("tabelle.formen"))
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
ergibt (R: eigene `[`-Methode, z. B. `[.SimLevWrapperNav`); Eintrag über `register_plain_rows!`.
"""
const _PLAIN_ROWS = Set{String}()
register_plain_rows!(cls::AbstractString) = (push!(_PLAIN_ROWS, String(cls)); nothing)

"""
Zeilen auswählen (Vektor von Indizes oder Bool-Maske), wie `df[rows, , drop = FALSE]`. Klasse und Attribute
bleiben, außer für Klassen aus `register_plain_rows!` (dann gewöhnliche Tabelle, wie R mit eigener `[`-Methode).
"""
function rows(df::RFrame, idx)
    # seit 1.6.4 (K42 E5): Zeilennummern 1 bis nrow (ganze Zahlen) oder logische Auswahl der Länge nrow
    n = _rf(df, :nrow)
    okidx = idx isa AbstractVector{Bool} ? length(idx) == n :
        (idx isa Union{Integer,AbstractVector,AbstractRange,Tuple} && !(idx isa Bool) &&
         all(i -> i isa Integer && !(i isa Bool) && 1 <= i <= n, idx))
    okidx || chk_stop("e5.rows", "rows", chk_fmt(n), chk_fmt(n))
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
# seit 1.6.4 (K42 E5): andere Typen mit Meldung statt MethodError
attrs(@nospecialize(x)) = chk_stop("klasse", "attrs", "x", "RList, RFrame, RVector, NamedMat oder approxfun()")   # seit 1.6.5 "x" statt "F" (CR2-V3-4)

"`inherits(x, cls)`; seit 1.6.4 wie R auch ein Vektor von Klassennamen (wahr, wenn einer passt); seit 1.6.5 erbt jede
`RFrame` wie in R von \"data.frame\" (CR2-V3-4)."
_inh_class(x) = r_class(x)
_inh_class(x::RFrame) = (c = r_class(x); "data.frame" in c ? c : vcat(c, "data.frame"))
inherits(x, cls::AbstractString) = cls in _inh_class(x)
inherits(x, cls::Union{AbstractVector,Tuple}) =
    all(c -> c isa AbstractString, cls) ? any(c -> c in _inh_class(x), cls) : chk_stop("e3.namen", "inherits", "cls")
inherits(x, cls) = chk_stop("e3.namen", "inherits", "cls")

# Druck über die registrierte Methode der R-Klasse, sonst Standarddruck (seit 1.6.4 eine Methode für RList und RFrame)
function Base.show(io::IO, ::MIME"text/plain", x::Union{RList,RFrame})
    f = _dispatch(_PRINTERS, x)
    f === nothing ? _default_print(io, x) : f(io, x)
end
Base.show(io::IO, x::RList) = print(io, "RList(", join(_rl_keys(x), ", "), ")")
# seit 1.6.5 (CR2-V1-2): print/println/string zeigen wie R print die registrierte Druckausgabe (show bleibt kurz für
# die Einbettung in Sammlungen); ohne registrierte Methode wie bisher
function Base.print(io::IO, x::Union{RList,RFrame})
    f = _dispatch(_PRINTERS, x)
    f === nothing && return show(io, x)
    t = sprint(f, x; context = io)
    print(io, endswith(t, "\n") ? chop(t) : t)   # println(x) endet dann wie R print mit genau einem Zeilenumbruch
end
Base.show(io::IO, df::RFrame) = print(io, "RFrame(", nrow(df), " × ", ncol(df), ": ", join(_rf(df, :names), ", "), ")")

# display() im Text (Skript, `julia datei.jl`) wie R: Endet die Druckausgabe schon mit einem Zeilenumbruch,
# folgt keiner mehr (Julias Standard hängt immer einen an, das ergäbe eine Leerzeile, die R nicht druckt).
function _display_text(d::TextDisplay, M::MIME"text/plain", x)
    s = sprint(show, M, x; context = d.io)
    print(d.io, s)
    endswith(s, "\n") || println(d.io)
    nothing
end
Base.display(d::TextDisplay, M::MIME"text/plain", x::Union{RList,RFrame}) = _display_text(d, M, x)

# Voreinstellung, bis die Formatierung (RFmt) eine R-genaue print-Funktion setzt
const _DEFAULT_PRINT = Ref{Function}((io, x) -> print(io, x))
_default_print(io, x) = _DEFAULT_PRINT[](io, x)

"Generisches `summary(object, ...)` wie in R (Methode nach S3-Klasse; Argumentname `object` wie R)."
function r_summary(object, args...; kw...)
    f = _dispatch(_SUMMARIES, object)
    f === nothing && chk_stop("e5.methode", "summary")   # seit 1.6.4 ohne Typ (Entscheidung 8)
    f(object, args...; kw...)
end
"Generisches `plot()` wie in R (Methode nach S3-Klasse; erzeugt SVG)."
function r_plot(x, args...; kw...)
    f = _dispatch(_PLOTS, x)
    f === nothing && chk_stop("e5.methode", "plot")   # seit 1.6.4 ohne Typ (Entscheidung 8)
    f(x, args...; kw...)
end
