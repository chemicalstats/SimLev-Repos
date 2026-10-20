# ─────────────────────────────────────────────────────────────────────────────
# Eingabedaten der Engine: spaltenorientierte Sicht mit R-Spaltenarten
#
# Akzeptiert werden RFrame, NamedTuples von Vektoren, Dicts (String/Symbol =>
# Vektor) und Pair-Vektoren. Spaltenarten wie in R:
#   :numeric   Vector{Float64} (NA bleibt NA, NaN bleibt NaN)
#   :logical   Vector{Union{Missing,Bool}}
#   :character Vector{Union{Missing,String}}   (:factor ebenso)
#   :date      Vector{Float64} Tage seit 1970-01-01 (NA = fehlend)
#   :posixct   wie :date (aus Datum-Uhrzeit)
#   :other     Vector{Any}
#   :filled    Vector{Bool} (interne Spalte ".filled")
# ─────────────────────────────────────────────────────────────────────────────

mutable struct _Frame
    names::Vector{String}
    cols::Dict{String,AbstractVector}
    kinds::Dict{String,Symbol}
    filled_attr::Any
end

_fnrow(fr::_Frame) = isempty(fr.names) ? 0 : length(fr.cols[fr.names[1]])
Base.haskey(fr::_Frame, name::AbstractString) = haskey(fr.cols, name)
function _fset!(fr::_Frame, name::String, v::AbstractVector, kind::Symbol)
    haskey(fr.cols, name) || push!(fr.names, name)
    fr.cols[name] = v
    fr.kinds[name] = kind
    return fr
end
function _fdrop!(fr::_Frame, name::String)
    if haskey(fr.cols, name)
        filter!(!=(name), fr.names)
        delete!(fr.cols, name); delete!(fr.kinds, name)
    end
    return fr
end
function _ftake!(fr::_Frame, idx::AbstractVector{Int})
    for nm in fr.names
        fr.cols[nm] = fr.cols[nm][idx]
    end
    return fr
end
_fis_numeric(fr::_Frame, name) = get(fr.kinds, name, :none) == :numeric
function _fr_class(fr::_Frame, name)
    k = get(fr.kinds, name, :other)
    k == :numeric && return "numeric"
    k == :logical && return "logical"
    k == :character && return "character"
    k == :factor && return "factor"
    k == :date && return "Date"
    k == :posixct && return "POSIXct"
    return "list"
end

"is.na() für einen Spalteneintrag."
_isna_val(x) = x === missing || x === nothing || (x isa AbstractFloat && isnan(x))
_isna_vec(v::AbstractVector{Float64}) = BitVector(isnan.(v))
_isna_vec(v::AbstractVector) = BitVector([_isna_val(x) for x in v])

const _EPOCH_D = Date(1970, 1, 1)
_dday(d::Date) = Float64(Dates.value(d - _EPOCH_D))

function _classify_values(vals::AbstractVector)
    n = length(vals)
    ok = [v for v in vals if !_isna_val(v)]
    isempty(ok) && return (:logical, Vector{Union{Missing,Bool}}(fill(missing, n)))
    all(v -> v isa Bool, ok) && return (:logical, Union{Missing,Bool}[_isna_val(v) ? missing : Bool(v) for v in vals])
    all(v -> v isa Real, ok) && return (:numeric, Float64[_isna_val(v) ? NA : Float64(v) for v in vals])
    all(v -> v isa AbstractString, ok) && return (:character, Union{Missing,String}[_isna_val(v) ? missing : String(v) for v in vals])
    if all(v -> v isa Date, ok)
        return (:date, Float64[_isna_val(v) ? NA : _dday(v) for v in vals])
    end
    if all(v -> v isa Union{Date,DateTime}, ok)
        return (:posixct, Float64[_isna_val(v) ? NA : _dday(Date(v)) for v in vals])
    end
    return (:other, Any[v for v in vals])
end

"Eine Spalte in (Art, Vektor) umwandeln."
function _column(v)
    v isa RVector && (v = v.values)
    v isa AbstractVector || (v = [v])
    T = eltype(v)
    S = Base.nonmissingtype(T)
    if S === Bool
        return (:logical, Vector{Union{Missing,Bool}}(v))
    elseif S <: Real && S !== Union{}
        return (:numeric, Float64[x === missing ? NA : Float64(x) for x in v])
    elseif S <: AbstractString
        return (:character, Union{Missing,String}[x === missing ? missing : String(x) for x in v])
    elseif S === Date
        return (:date, Float64[x === missing ? NA : _dday(x) for x in v])
    elseif S === DateTime
        return (:posixct, Float64[x === missing ? NA : _dday(Date(x)) for x in v])
    end
    return _classify_values(collect(Any, v))
end

function _raw_columns(data)
    if data isa RFrame
        return names(data), collect(data.cols), get(attrs(data), "filled", nothing)
    elseif data isa NamedTuple
        return [String(k) for k in keys(data)], collect(values(data)), nothing
    elseif data isa AbstractDict
        ks = collect(keys(data))
        return [String(string(k)) for k in ks], [data[k] for k in ks], nothing
    elseif data isa AbstractVector{<:Pair}
        return [String(string(p.first)) for p in data], [p.second for p in data], nothing
    end
    error("unbekannte Datenstruktur")
end

function _to_frame(data)
    nms, vals, fa = _raw_columns(data)
    for (i, nm) in enumerate(nms)
        if nm in nms[1:i-1]
            error("simulation: Spaltenname '$nm' kommt in 'data' mehrfach vor; jede Spalte muss eindeutig benannt sein.")
        end
    end
    cols = Dict{String,AbstractVector}(); kinds = Dict{String,Symbol}()
    for (nm, v) in zip(nms, vals)
        k, a = _column(v)
        cols[nm] = a; kinds[nm] = k
    end
    lens = unique([length(a) for a in values(cols)])
    length(lens) > 1 && error("simulation: alle Spalten von 'data' müssen gleich lang sein.")
    return _Frame(collect(String, nms), cols, kinds, fa)
end

"Attribut `filled`: (Matrix oder nothing, Spaltennamen oder nothing, Zeilenzahl)."
function _filled_matrix(fa)
    fa === nothing && return (nothing, nothing, 0)
    if fa isa RFrame
        cols = [Bool[x === true for x in c] for c in fa.cols]
        m = isempty(cols) ? falses(nrow(fa), 0) : BitMatrix(hcat(cols...))
        return (m, names(fa), nrow(fa))
    elseif fa isa NamedMat
        return (BitMatrix(Bool.(fa.data)), fa.colnames, size(fa.data, 1))
    elseif fa isa AbstractMatrix
        return (BitMatrix(Bool.(fa)), nothing, size(fa, 1))
    elseif fa isa NamedTuple || fa isa AbstractDict
        ps = _kvpairs(fa)
        isempty(ps) && return (falses(0, 0), String[], 0)
        m = BitMatrix(hcat([Bool.(collect(p.second)) for p in ps]...))
        return (m, [p.first for p in ps], size(m, 1))
    elseif fa isa AbstractVector
        return (nothing, nothing, length(fa))
    end
    return (nothing, nothing, 1)
end

"`as.logical()` einer Spalte (NA → false) für Event-Flags."
function _as_logical_col(fr::_Frame, col::String)
    v = fr.cols[col]
    k = fr.kinds[col]
    out = falses(length(v))
    for (i, x) in enumerate(v)
        _isna_val(x) && continue
        if k == :numeric
            out[i] = x != 0
        elseif x isa AbstractString
            out[i] = x in ("TRUE", "true", "T", "True")
        elseif x isa Bool
            out[i] = x
        elseif x isa Real
            out[i] = x != 0
        end
    end
    return out
end
