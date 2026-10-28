# ─────────────────────────────────────────────────────────────────────────────
# Asset-Konfiguration und Strategie-Objekte (Port von asset_config.R / strategy.R)
#
# AssetConfig, Strategy (und SimLevResult in result.jl) sind dünne Hüllen um
# eine RList: Zugriff wie in R über `x.feld` bzw. `x["feld"]`, `keys(x)` in
# R-Reihenfolge, `r_class(x)` liefert die S3-Klassen, `show(io, MIME"text/plain"(), x)`
# die Druckausgabe der R-Methode.
# ─────────────────────────────────────────────────────────────────────────────

const ASSET_CLASSES = ("etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable")
const ACTION_TYPES = ("bnh", "signal")
const VALID_REGIMES = ("investment_fund", "capital_gains", "private_sale")
const _FIELDS = ("asset_class", "trading", "share", "spread", "partial_exemption",
                 "deliverable", "start", "tax_regime", "signal_buy", "signal_sell")

"Gemeinsame Methoden der RList-Hüllen (`T` hat das Feld `data::RList`)."
macro _rlist_wrapper(T, classes)
    quote
        Base.length(x::$T) = length(getfield(x, :data))
        Base.iterate(x::$T, i::Int = 1) = iterate(getfield(x, :data), i)
        Base.getindex(x::$T, k::AbstractString) = getfield(x, :data)[k]
        Base.getindex(x::$T, k::Symbol) = getfield(x, :data)[String(k)]
        Base.getindex(x::$T, i::Integer) = getfield(x, :data)[i]
        Base.setindex!(x::$T, v, k::AbstractString) = (getfield(x, :data)[k] = v; x)
        Base.setindex!(x::$T, v, k::Symbol) = (getfield(x, :data)[String(k)] = v; x)
        Base.haskey(x::$T, k::AbstractString) = haskey(getfield(x, :data), k)
        Base.haskey(x::$T, k::Symbol) = haskey(getfield(x, :data), String(k))
        Base.get(x::$T, k::Union{AbstractString,Symbol}, d) = get(getfield(x, :data), String(k), d)
        Base.keys(x::$T) = keys(getfield(x, :data))
        Base.values(x::$T) = values(getfield(x, :data))
        Base.delete!(x::$T, k::AbstractString) = (delete!(getfield(x, :data), k); x)
        Base.getproperty(x::$T, s::Symbol) = s === :data ? getfield(x, :data) : getfield(x, :data)[String(s)]
        Base.setproperty!(x::$T, s::Symbol, v) = (getfield(x, :data)[String(s)] = v)
        Base.propertynames(x::$T, private::Bool = false) = Tuple(Symbol.(keys(getfield(x, :data))))
        Base.copy(x::$T) = $T(copy(getfield(x, :data)))
        SimLev.r_class(x::$T) = String[$(classes)...]
        function Base.show(io::IO, ::MIME"text/plain", x::$T)
            f = _dispatch(_PRINTERS, x, "print")
            f === nothing ? print(io, x) : f(io, x)
        end
    end |> esc
end

"Validierte Konfiguration eines Assets (R-Klasse `asset_config`); Felder wie in R."
struct AssetConfig <: AbstractDict{String,Any}
    data::RList
end
@_rlist_wrapper AssetConfig ("asset_config", "list")
Base.show(io::IO, a::AssetConfig) = print(io, "AssetConfig(", r_deparse(a["asset_class"]), ", ", r_deparse(a["trading"]),
                                          ", ", r_deparse(a["share"]), ")")

"Geordnete Sammlung benannter AssetConfig-Objekte (R-Klasse `strategy`)."
struct Strategy <: AbstractDict{String,Any}
    data::RList
end
@_rlist_wrapper Strategy ("strategy", "list")
Base.show(io::IO, s::Strategy) = print(io, "Strategy(", join(keys(s), ", "), ")")

# ── match.arg und Hilfen ─────────────────────────────────────────────────────

function _pmatch(value::AbstractString, choices)
    i = findfirst(==(value), choices)
    i !== nothing && return i
    isempty(value) && return nothing
    hits = [i for (i, c) in enumerate(choices) if startswith(c, value)]
    return length(hits) == 1 ? hits[1] : nothing
end

"Nachbildung von R's `match.arg` (eindeutige Präfixe, R-Meldungen)."
function match_arg(value, choices, argname::AbstractString = "arg")
    choices = Tuple(String(c) for c in choices)
    value === nothing && return choices[1]
    if value isa Union{AbstractVector,Tuple}
        Tuple(string(v) for v in value) == choices && return choices[1]
        all(v -> v isa AbstractString, value) || error("'arg' must be NULL or a character vector")
        length(value) > 1 && error("'arg' must be of length 1")
        value = isempty(value) ? "" : first(value)
    end
    value isa Union{AbstractString,Symbol} || error("'arg' must be NULL or a character vector")
    v = String(string(value))
    i = _pmatch(v, choices)
    if i === nothing
        chs = unique([c for c in choices if !isempty(c)])
        error((length(chs) == 1 ? "'arg' should be " : "'arg' should be one of ") * join(("“$(c)”" for c in chs), ", "))
    end
    return choices[i]
end

_is_num1(x) = x isa Real && !(x isa Bool) && !isnan(Float64(x))

"Klassenname wie `class(x)[1]` in R (für Meldungen)."
function _r_class1(@nospecialize(x))
    x === nothing && return "NULL"
    cl = r_class(x)
    isempty(cl) || return cl[1]
    x isa Bool && return "logical"
    x isa Integer && return "integer"
    x isa Real && return "numeric"
    x isa AbstractString && return "character"
    x isa Date && return "Date"
    x isa DateTime && return "POSIXct"
    x isa Function && return "function"
    x isa RFrame && return "data.frame"
    x isa AbstractMatrix && return "matrix"
    if x isa AbstractVector
        T = Base.nonmissingtype(eltype(x))
        T <: Bool && return "logical"
        T <: Integer && return "integer"
        T <: Real && return "numeric"
        T <: AbstractString && return "character"
        T <: Date && return "Date"
        return "list"
    end
    (x isa AbstractDict || x isa NamedTuple || x isa Tuple) && return "list"
    return string(nameof(typeof(x)))
end

"Einheitliche Sicht auf benannte Listen (RList, Dict, NamedTuple, Pair-Vektor, Hüllen)."
_is_mapping(x) = x isa AbstractDict || x isa NamedTuple || x isa AbstractVector{<:Pair}
_kvpairs(x::NamedTuple) = [String(k) => v for (k, v) in pairs(x)]
_kvpairs(x::AbstractVector{<:Pair}) = [String(string(p.first)) => p.second for p in x]
_kvpairs(x::AbstractDict) = [String(string(k)) => v for (k, v) in x]

_to_date_or_nothing(x) = (z = _as_date(x); z === nothing ? nothing : from_days(z))

"""
    asset_config(asset_class = "etf", trading = "bnh", share = 1.0,
                 spread = 0.1, partial_exemption = 0.0, deliverable = false,
                 start = nothing, tax_regime = nothing, signal_buy = nothing,
                 signal_sell = nothing)

Asset-Konfiguration erstellen und prüfen (R: `asset_config()`). Alle Argumente
dürfen positionell (Reihenfolge wie in R) oder als Schlüsselwort angegeben
werden. Raten in Prozent: `spread = 0.1` = 0,1 % voller Bid-Ask-Spread,
`partial_exemption = 30` = 30 % Teilfreistellung; `share` ist ein Anteil in (0, 1].
"""
function asset_config(args...; kw...)
    length(args) > length(_FIELDS) && error("unused argument ($(r_deparse(args[length(_FIELDS)+1])))")
    vals = Dict{String,Any}()
    for (i, a) in enumerate(args)
        vals[_FIELDS[i]] = a
    end
    for (k, v) in kw
        ks = String(k)
        ks in _FIELDS || error("unused argument ($ks = $(r_deparse(v)))")
        haskey(vals, ks) && error("formal argument \"$ks\" matched by multiple actual arguments")
        vals[ks] = v
    end
    return _asset_config(vals)
end

function _asset_config(vals::Dict{String,Any})
    asset_class = match_arg(get(vals, "asset_class", ASSET_CLASSES), ASSET_CLASSES, "asset_class")
    trading = match_arg(get(vals, "trading", ACTION_TYPES), ACTION_TYPES, "trading")
    share = get(vals, "share", 1.0)
    spread = get(vals, "spread", 0.1)
    partial_exemption = get(vals, "partial_exemption", 0.0)
    deliverable = get(vals, "deliverable", false)
    start = get(vals, "start", nothing)
    tax_regime = get(vals, "tax_regime", nothing)
    signal_buy = get(vals, "signal_buy", nothing)
    signal_sell = get(vals, "signal_sell", nothing)
    if asset_class == "etn_standard"
        @warn "asset_config: asset_class = \"etn_standard\" ist veraltet; stattdessen asset_class = \"etn\" mit deliverable = FALSE verwenden."
        asset_class = "etn"; deliverable = false
    elseif asset_class == "etn_deliverable"
        @warn "asset_config: asset_class = \"etn_deliverable\" ist veraltet; stattdessen asset_class = \"etn\" mit deliverable = TRUE verwenden."
        asset_class = "etn"; deliverable = true
    end
    for (x, arg) in ((share, "share"), (spread, "spread"), (partial_exemption, "partial_exemption"))
        _is_num1(x) || error("asset_config: $arg muss eine einzelne Zahl sein, nicht $(r_deparse(x)).")
    end
    if share <= 0 || share > 1
        error("asset_config: share muss ein Anteil größer 0 und höchstens 1 sein (z. B. 0.6 für 60 %), nicht " *
              r_format1(share) *
              (share > 1 && share <= 100 ?
               "; für $(r_format1(share)) % share = $(r_format1(share / 100)) angeben" : "") * ".")
    end
    spread < 0 && error("asset_config: spread muss >= 0 sein (voller Spread in Prozent, z. B. 0.1 für 0,1 %), nicht $(r_format1(spread)).")
    (partial_exemption < 0 || partial_exemption > 100) &&
        error("asset_config: partial_exemption muss zwischen 0 und 100 liegen (Teilfreistellung in Prozent, z. B. 30 für 30 %), nicht $(r_format1(partial_exemption)).")
    if partial_exemption > 0 && partial_exemption < 1
        @warn "asset_config: partial_exemption = $(r_format1(partial_exemption)) wird als $(r_format1(partial_exemption)) % Teilfreistellung gelesen (Prozent-Konvention); gemeint war vermutlich $(r_format1(partial_exemption * 100))."
    end
    if start !== nothing
        st = (start isa Union{AbstractVector,Tuple}) ? (length(start) == 1 ? _to_date_or_nothing(first(start)) : nothing) :
             _to_date_or_nothing(start)
        st === nothing && error("asset_config: start = $(r_deparse(start)) ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\").")
        start = st
    end
    if trading == "signal" && (signal_buy === nothing || signal_sell === nothing)
        error("asset_config: bei trading = \"signal\" müssen signal_buy und signal_sell angegeben werden (Namen der Signalspalten in data).")
    end
    if tax_regime === nothing
        tax_regime = asset_class == "etf" ? "investment_fund" :
                     asset_class in ("etn", "etc") ? (_isTRUE(deliverable) ? "private_sale" : "capital_gains") :
                     "capital_gains"
    elseif !(tax_regime isa AbstractString && tax_regime in VALID_REGIMES)
        error("asset_config: tax_regime = $(r_deparse(tax_regime)) ist ungültig; erlaubt sind $(join(VALID_REGIMES, ", ")) (oder NULL: aus asset_class abgeleitet).")
    end
    d = RList("asset_class" => asset_class, "trading" => trading, "share" => share,
              "spread" => spread, "partial_exemption" => partial_exemption, "deliverable" => deliverable,
              "start" => start, "tax_regime" => String(tax_regime),
              "signal_buy" => signal_buy === nothing ? nothing : String(string(signal_buy)),
              "signal_sell" => signal_sell === nothing ? nothing : String(string(signal_sell)))
    return AssetConfig(d)
end

_isTRUE(x) = x isa Bool && x

"`do.call(asset_config, <Liste>)` (unbekannte Felder sind ein Fehler wie in R)."
function _config_from_mapping(m)
    ps = _kvpairs(m isa AssetConfig ? collect(m) : m)
    unknown = [p for p in ps if !(p.first in _FIELDS)]
    if !isempty(unknown)
        error("unused argument" * (length(unknown) > 1 ? "s" : "") * " (" *
              join(("$(p.first) = $(r_deparse(p.second))" for p in unknown), ", ") * ")")
    end
    return _asset_config(Dict{String,Any}(ps))
end

function _print_asset_config(io::IO, x)
    println(io, "Asset-Konfiguration")
    println(io, "-------------------")
    println(io, r_sprintf("  Klasse:       %s", x["asset_class"]))
    println(io, r_sprintf("  Aktion:       %s", x["trading"]))
    println(io, r_sprintf("  Anteil:       %.1f%%", x["share"] * 100))
    print(io, r_sprintf("  Steuerregime: %s\n", x["tax_regime"]))
    x["asset_class"] == "etf" && print(io, r_sprintf("  Teilfrei.:    %.0f%%\n", x["partial_exemption"]))
    x["asset_class"] in ("etn", "etc") && print(io, r_sprintf("  Lieferbar:    %s\n", x["deliverable"]))
end

"""
    create_strategy(; NAME = asset_config(...), ...)
    create_strategy("NAME" => asset_config(...), ...)
    create_strategy(; assets = ...)

Strategie aus benannten Asset-Konfigurationen erstellen (R: `create_strategy()`).
Einfache Listen (NamedTuple, Dict, Pair-Vektor) werden mit `asset_config()`
geprüft; die Gewichte werden nicht normiert.
"""
function create_strategy(args...; assets = nothing, kwargs...)
    n_dots = length(args) + length(kwargs)
    assets !== nothing && n_dots > 0 && error("create_strategy: Assets entweder über ... oder über assets angeben, nicht beides.")
    dots = Pair{String,Any}[]
    unnamed = false
    for a in args
        if a isa Pair
            push!(dots, String(string(a.first)) => a.second)
        else
            unnamed = true
            push!(dots, "" => a)
        end
    end
    for (k, v) in kwargs
        push!(dots, String(k) => v)
    end
    if assets !== nothing
        if !_is_mapping(assets)
            error("create_strategy: assets muss eine benannte Liste sein (Name = Kursspalte in data), nicht " *
                  (assets isa Union{AbstractVector,Tuple} ? "eine unbenannte Liste" : _r_class1(assets)) * ".")
        end
        dots = Pair{String,Any}[p for p in _kvpairs(assets)]
    end
    isempty(dots) && error("create_strategy: mindestens eine Asset-Konfiguration angeben, z. B. create_strategy(ETF = asset_config(\"etf\")).")
    (unnamed || any(p -> isempty(p.first), dots)) &&
        error("create_strategy: alle Assets müssen benannt sein (Name = Kursspalte in data), z. B. create_strategy(ETF = asset_config(\"etf\")).")
    seen = Set{String}()
    for p in dots
        p.first in seen && error("create_strategy: Asset-Name '$(p.first)' kommt mehrfach vor; jeder Name darf nur einmal vorkommen.")
        push!(seen, p.first)
    end
    out = RList()
    for (name, cfg) in dots
        if cfg isa AssetConfig
            out[name] = cfg
        elseif inherits(cfg, "asset_config") && cfg isa RList
            out[name] = AssetConfig(copy(cfg))
        elseif _is_mapping(cfg)
            out[name] = _config_from_mapping(cfg)
        else
            error("create_strategy: Asset '$name' muss ein asset_config()-Objekt oder eine Liste sein, nicht $(_r_class1(cfg)).")
        end
    end
    return Strategy(out)
end

_colnames(data) = data isa RFrame ? names(data) : data isa AbstractDict ? [String(string(k)) for k in keys(data)] :
                  [String(string(k)) for k in propertynames(data)]

"Strategie (und optional die Spalten von `data`) prüfen; `true` oder Fehler."
function strategy_validate(strategy, data_pos = nothing; data = data_pos)
    inherits(strategy, "strategy") ||
        error("strategy_validate: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), nicht $(_r_class1(strategy)).")
    for (name, a) in strategy
        inherits(a, "asset_config") || error("strategy_validate: Asset '$name' ist kein asset_config()-Objekt (Klasse $(_r_class1(a))).")
    end
    if data !== nothing
        cols = _colnames(data)
        miss = [n for n in keys(strategy) if !(n in cols)]
        isempty(miss) || error("strategy_validate: Kursspalte(n) " * join(("'$m'" for m in miss), ", ") *
                               " fehlen in data (je Asset eine Spalte gleichen Namens; vorhanden: $(join(cols, ", "))).")
        for (name, a) in strategy
            if a["trading"] == "signal"
                a["signal_buy"] in cols || error("strategy_validate: signal_buy-Spalte '$(a["signal_buy"])' fehlt in data (Asset '$name').")
                a["signal_sell"] in cols || error("strategy_validate: signal_sell-Spalte '$(a["signal_sell"])' fehlt in data (Asset '$name').")
            end
        end
    end
    return true
end

"Asset hinzufügen bzw. ersetzen (gibt eine neue Strategie zurück)."
function strategy_add_asset(strategy, name::AbstractString, asset)
    inherits(strategy, "strategy") ||
        error("strategy_add_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), nicht $(_r_class1(strategy)).")
    inherits(asset, "asset_config") || error("strategy_add_asset: asset muss ein asset_config()-Objekt sein, nicht $(_r_class1(asset)).")
    out = Strategy(RList(collect(strategy)...))
    out[String(name)] = asset
    return out
end

"""
    strategy_update_asset(strategy, name; felder...)

Felder eines Assets ändern und mit `asset_config()` neu prüfen. Ändert sich
`asset_class` oder `deliverable` ohne Angabe von `tax_regime`, wird ein bisher
automatisch abgeleitetes Steuerregime neu abgeleitet.
"""
function strategy_update_asset(strategy, name::AbstractString; updates...)
    inherits(strategy, "strategy") ||
        error("strategy_update_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), nicht $(_r_class1(strategy)).")
    haskey(strategy, name) || error("strategy_update_asset: Asset '$name' ist nicht in der Strategie (vorhanden: $(join(keys(strategy), ", "))).")
    asset = RList(collect(strategy[name])...)
    upd = [String(k) => v for (k, v) in updates]
    if any(p -> p.first in ("asset_class", "deliverable"), upd) && !any(p -> p.first == "tax_regime", upd)
        derived = try
            tmp = copy(asset); tmp["tax_regime"] = nothing
            Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                _config_from_mapping(collect(tmp))["tax_regime"]
            end
        catch
            nothing
        end
        derived == get(asset, "tax_regime", nothing) && (asset["tax_regime"] = nothing)
    end
    for (param, value) in upd
        if !haskey(asset, param)
            @warn "strategy_update_asset: unbekannter Parameter '$param' wird ignoriert (möglich: $(join(keys(asset), ", ")))."
            continue
        end
        asset[param] = value
    end
    out = Strategy(RList(collect(strategy)...))
    out[String(name)] = _config_from_mapping(collect(asset))
    return out
end

"Asset entfernen (Warnung, wenn die Strategie danach leer ist)."
function strategy_remove_asset(strategy, name::AbstractString)
    inherits(strategy, "strategy") ||
        error("strategy_remove_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), nicht $(_r_class1(strategy)).")
    haskey(strategy, name) || error("strategy_remove_asset: Asset '$name' ist nicht in der Strategie (vorhanden: $(join(keys(strategy), ", "))).")
    out = Strategy(RList(collect(strategy)...))
    delete!(out, String(name))
    length(out) == 0 && @warn "strategy_remove_asset: Nach dem Entfernen von '$name' enthält die Strategie keine Assets mehr."
    return out
end

function _print_strategy(io::IO, x)
    n = length(x)
    println(io, r_sprintf("Anlagestrategie (%d %s)", n, n == 1 ? "Asset" : "Assets"))
    println(io, "================================\n")
    for (name, a) in x
        println(io, name, ":")
        print(io, r_sprintf("  Klasse: %s | Anteil: %.0f%% | Steuer: %s\n", a["asset_class"], a["share"] * 100, a["tax_regime"]))
    end
end

function _summary_strategy_text(x)
    n = length(x)
    io = IOBuffer()
    println(io, r_sprintf("Strategie-Übersicht: %d %s\n", n, n == 1 ? "Asset" : "Assets"))
    total_share = r_sum([a["share"] for (_, a) in x])
    println(io, r_sprintf("Gesamtgewicht: %.1f%%", total_share * 100))
    abs(total_share - 1) > 0.001 && println(io, "  (Hinweis: Summe ist nicht 100%)")
    println(io, "\nNach Steuerregime:")
    regimes = [a["tax_regime"] for (_, a) in x]
    for r in unique(regimes)
        k = count(==(r), regimes)
        println(io, r_sprintf("  %s: %d %s", r, k, k == 1 ? "Asset" : "Assets"))
    end
    return String(take!(io))
end

"Übersicht einer Strategie (R: `summary.strategy`): druckt und gibt die Strategie zurück."
function Base.summary(s::Strategy; io::IO = stdout)
    print(io, _summary_strategy_text(s))
    return s
end
"Wie `print` (R: `summary.asset_config`)."
function Base.summary(a::AssetConfig; io::IO = stdout)
    _print_asset_config(io, a)
    return a
end

register_print!("asset_config", _print_asset_config)
register_print!("strategy", _print_strategy)
register_summary!("strategy", (x, args...; io::IO = stdout, kw...) -> (print(io, _summary_strategy_text(x)); x))
register_summary!("asset_config", (x, args...; io::IO = stdout, kw...) -> (_print_asset_config(io, x); x))
