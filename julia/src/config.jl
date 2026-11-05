# ─────────────────────────────────────────────────────────────────────────────
# Asset-Konfiguration und Strategie-Objekte (Gegenstück zu asset_config.R / strategy.R)
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
                 "deliverable", "start", "tax_regime", "signal_buy", "signal_sell", "wrapper")

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
        Base.display(d::TextDisplay, M::MIME"text/plain", x::$T) = _display_text(d, M, x)
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

# ── Hilfen (match.arg: seit 1.6.3 nur `_match_arg` aus util.jl) ───────────────────

function _pmatch(value::AbstractString, choices)
    i = findfirst(==(value), choices)
    i !== nothing && return i
    isempty(value) && return nothing
    hits = [i for (i, c) in enumerate(choices) if startswith(c, value)]
    return length(hits) == 1 ? hits[1] : nothing
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

# ── Fonds-Wrapper: Hilfen der Strategie (R: wrapper.R) ─────────

"`inherits(x, \"SimLevWrapperConfig\")` (Fonds-Wrapper aus `wrapper_config()`)."
_is_wrapper(@nospecialize(x)) = inherits(x, "SimLevWrapperConfig")

"Feld `k` eines Assets (asset_config, Dict, RList, NamedTuple) oder `nothing`."
function _aget(@nospecialize(a), k::String)
    a isa NamedTuple && return get(a, Symbol(k), nothing)
    a isa AbstractDict && return get(a, k, nothing)
    a isa AbstractVector{<:Pair} && (i = findfirst(p -> String(string(p.first)) == k, a); return i === nothing ? nothing : a[i].second)
    return nothing
end

"Assets einer Strategie als Paare (Name => Asset)."
_strategy_pairs(@nospecialize(st)) = st isa AbstractVector{<:Pair} ? [String(string(p.first)) => p.second for p in st] :
                                     _kvpairs(st isa Union{Strategy,AssetConfig} ? collect(st) : st)

"""
Kursspalten einer Strategie (R: `.strategy_columns`): je Asset sein Name, für Wrapper-Assets die Spalten
der inneren Strategie; Reihenfolge wie in der Strategie, ohne Doppelte.
"""
function _strategy_columns(@nospecialize(strategy))
    cols = String[]
    for (nm, a) in _strategy_pairs(strategy)
        w = _aget(a, "wrapper")
        for c in (_is_wrapper(w) ? _strategy_columns(w["strategy"]) : [nm])
            c in cols || push!(cols, c)
        end
    end
    return cols
end

"Namen der Wrapper-Assets einer Strategie (R: `.strategy_wrappers`)."
_strategy_wrappers(@nospecialize(strategy)) = String[nm for (nm, a) in _strategy_pairs(strategy)
                                                     if _is_mapping(a) && _aget(a, "wrapper") !== nothing]

"`.wrapper_assets_text`: `\"A 60 %, B 40 %\"`."
_wrapper_assets_text(@nospecialize(strategy)) =
    join(("$nm $(r_format1(Float64(100 * a["share"]); digits = 15)) %" for (nm, a) in _strategy_pairs(strategy)), ", ")

"Klasse wie `paste(class(x), collapse = \"/\")` (für Meldungen)."
# Meldung von asset_config() für wrapper mit trading = "signal" (strategy_from_weights() erkennt sie und nennt das Asset)
const _AC_MSG_WRAPPER_SIGNAL = "asset_config: mit wrapper ist nur trading = \"bnh\" möglich (keine Signale auf den Anteilswert; Signale gehen in der inneren Strategie)."

function _cls_all(@nospecialize(x))
    c = r_class(x)
    isempty(c) || return join(c, "/")
    x isa Integer && !(x isa Bool) && return "numeric"
    return _r_class1(x)
end

"""
    asset_config(asset_class = "etf", trading = "bnh", share = 1.0,
                 spread = 0.0, partial_exemption = 0.0, deliverable = false,
                 start = nothing, tax_regime = nothing, signal_buy = nothing,
                 signal_sell = nothing, wrapper = nothing)

Asset-Konfiguration erstellen und prüfen.

Erstellt und validiert die Konfiguration eines einzelnen Assets für die Simulation. Pflichtfelder werden
geprüft, ungültige Werte sofort gemeldet. Das Ergebnis wird als `"asset_config"`-Objekt in `create_strategy`
eingesetzt.

# Argumente
- `asset_class`: Character. Assetklasse. Zulässig: `"etf"` (Standard), `"etn"`, `"etc"`, `"certificate"` sowie
  die veralteten Werte `"etn_standard"` und `"etn_deliverable"`, die mit Warnung in `"etn"` mit `deliverable =
  false` bzw. `true` umgesetzt werden.
- `trading`: Character. Handelsstrategie: `"bnh"` (Buy-and-Hold) oder `"signal"` (signalgesteuert). Bei
  `"signal"` steuern die Signalspalten nur Ein- und Ausstieg: Ohne Bestand wartet das Geld des Assets als Cash
  auf das Kaufsignal; hält das Asset Stücke (Position offen), wird neues Geld (Sparraten, Restcash,
  Umverteilungen) sofort angelegt wie bei Buy-and-Hold (nicht am Tag eines Verkaufssignals), unabhängig von
  `balance_mode`. Standard: `"bnh"`.
- `share`: Numerisch (keine Zeichenkette). Zielgewicht des Assets im Portfolio **als Anteil** (größer 0 und
  höchstens 1, z. B. `0.6` = 60 %). Es wird nicht normiert: `simulation` verlangt, dass sich die Gewichte
  aller Assets auf 1 summieren. Standard: `1`.
- `spread`: Numerisch. Voller Bid-Ask-Spread **in Prozent** (z. B. `0.1` = 0,1 %), nicht negativ. Pro Seite
  wird der halbe Spread angewandt. Standard: `0` (ohne Spread; wer Spreads abbilden will, gibt sie an).
- `partial_exemption`: Numerisch. Teilfreistellungssatz nach § 20 Abs. 1 InvStG **in Prozent** (0 bis 100; z.
  B. `30` für Aktien-ETFs, `15` für Mischfonds). Wirkt nur im Regime `"investment_fund"`. Werte zwischen 0 und
  1 (vermutlich ein Anteil statt Prozent, z. B. `0.3`) werden mit Warnung angenommen. Standard: `0`.
- `deliverable`: Logisch. Physisch lieferbar (relevant für ETC/ETN: `true` → `"private_sale"`-Regime wie
  Xetra-Gold)? Standard: `false`.
- `start`: Date, Character (`"JJJJ-MM-TT"`) oder `nothing`. Frühestmögliches Kaufdatum für dieses Asset (für
  gestaffelte Asset-Starts); wird als `Date` gespeichert, ein ungültiges Datum führt zu einem Fehler. In
  `simulation` erhält das Asset ab diesem Tag sein volles Zielgewicht `share`: Am Starttag wird immer auf die
  Zielgewichte umgeschichtet (Verkauf der übrigen Assets, Erstkauf des neuen Assets; mit Steuern, Spreads und
  Gebühren wie bei jedem Rebalancing), auch ohne `balance_mode`; ein zusätzlicher Handelsblock läuft an diesem
  Tag nicht. Mit `balance_mode = true` gilt danach der normale Rhythmus, ohne `balance_mode` wird danach nicht
  mehr umgeschichtet (Sparraten nach Strategie-Gewichten). Standard: `nothing` (ab Simulationsbeginn).
- `tax_regime`: Character oder `nothing`. Steuerregime: `"investment_fund"` (§§ 18–20 InvStG, ETFs),
  `"capital_gains"` (§ 20 EStG, keine VP), `"private_sale"` (§ 23 EStG, 1-Jahres-Frist). `nothing` = wird
  automatisch aus `asset_class` und `deliverable` abgeleitet. Andere Werte führen zu einem Fehler.
- `signal_buy`: Character oder `nothing`. Name der Spalte in `data` mit dem Kaufsignal (logisch, `true` =
  kaufen). Bei `trading = "signal"` Pflicht (sonst Fehler).
- `signal_sell`: Character oder `nothing`. Name der Spalte in `data` mit dem Verkaufssignal (logisch, `true` =
  verkaufen). Bei `trading = "signal"` Pflicht (sonst Fehler).
- `wrapper`: `nothing` oder ein Objekt aus `wrapper_config`: Das Asset ist dann ein Fonds-Wrapper (Zertifikat
  oder Fonds über eine innere Strategie). Sein Name ist **keine** Kursspalte; `simulation` rechnet die Kurse
  als Anteilswert (`wrapper_nav`) aus den inneren Spalten. Eine Spalte gleichen Namens in `data` ist ein
  Fehler. Mit `wrapper` ist nur `trading = "bnh"` möglich (keine Signale auf den Anteilswert; Signale gehen in
  der inneren Strategie). Die äußeren Felder (`asset_class`, `tax_regime`, `partial_exemption`, `spread`,
  `share`, `start`) gelten für den Wrapper wie für ein Einzelpapier. Standard: `nothing` (kein Wrapper).

# Rückgabe
Objekt der Klasse `"asset_config"` (benannte Liste) mit den Feldern `asset_class`, `trading`, `share`,
`spread`, `partial_exemption`, `deliverable`, `start`, `tax_regime`, `signal_buy`, `signal_sell`, mit Wrapper
zusätzlich `wrapper`; validiert und ggf. mit abgeleitetem `tax_regime`. Die Zahlen bleiben in den Einheiten
der Eingabe (`share` als Anteil, `spread` und `partial_exemption` in Prozent).

`print` und `summary` geben die Konfiguration auf der Konsole aus (mit Wrapper eine Zeile mit den inneren
Assets und den Fondskosten) und liefern `x` unsichtbar zurück.

# Details
Das `tax_regime` wird automatisch abgeleitet, wenn `nothing`:

- `"etf"` → `"investment_fund"`
- `"etn"`, `"etc"`: `deliverable = true` → `"private_sale"`; sonst `"capital_gains"`
- `"certificate"` → `"capital_gains"`

Der `spread` ist der *volle* Bid-Ask-Spread; die Engine wendet den halben Spread je Seite an (Kauf: Briefkurs,
Verkauf: Geldkurs).

# Beispiel
```julia
using SimLev
etf = asset_config("etf", "bnh"; share = 0.6, spread = 0.1, partial_exemption = 30)
gold = asset_config("etc"; share = 0.2, deliverable = true)
println(gold["tax_regime"])   # private_sale
```
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
    asset_class = _match_arg(get(vals, "asset_class", ASSET_CLASSES), ASSET_CLASSES)
    trading = _match_arg(get(vals, "trading", ACTION_TYPES), ACTION_TYPES)
    share = get(vals, "share", 1.0)
    spread = get(vals, "spread", 0.0)
    partial_exemption = get(vals, "partial_exemption", 0.0)
    deliverable = get(vals, "deliverable", false)
    start = get(vals, "start", nothing)
    tax_regime = get(vals, "tax_regime", nothing)
    signal_buy = get(vals, "signal_buy", nothing)
    signal_sell = get(vals, "signal_sell", nothing)
    wrapper = get(vals, "wrapper", nothing)
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
    if wrapper !== nothing   # Fonds-Wrapper: keine Signale auf den Anteilswert
        _is_wrapper(wrapper) || error("asset_config: wrapper muss NULL oder ein Objekt aus wrapper_config() sein, nicht $(_cls_all(wrapper)).")
        trading == "signal" && error(_AC_MSG_WRAPPER_SIGNAL)
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
    wrapper === nothing || (d["wrapper"] = wrapper)   # nur mit Wrapper ein Feld (sonst Objekt wie bisher)
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
    w = get(x, "wrapper", nothing)
    if _is_wrapper(w)
        println(io, "  Wrapper:      $(_wrapper_assets_text(w["strategy"])); Fondskosten $(r_format1(Float64(w["costs"]["fee"]); digits = 15)) % p. a., " *
                    "Performancegebühr $(r_format1(Float64(w["costs"]["performance_fee"]); digits = 15)) %")
    end
end

"""
    create_strategy(; NAME = asset_config(...), ...)
    create_strategy("NAME" => asset_config(...), ...)
    create_strategy(; assets = ...)

Strategie aus benannten Asset-Konfigurationen erstellen.

Funktionen zum Erstellen, Validieren und Bearbeiten von `"strategy"`-Objekten. Eine Strategie ist eine
benannte Liste von `asset_config`-Konfigurationen, die an `simulation` übergeben wird.

# Argumente
- `NAME`: Assets als Schlüsselwörter `NAME = asset_config(...)` oder als Paare `"NAME" => asset_config(...)`.
- `assets`: Benannte Liste von `asset_config`-Objekten oder `nothing`. Alternative zu `...` für
  programmatische Nutzung (nicht beides zugleich). Standard: `nothing`.

# Rückgabe
- `create_strategy`: Objekt der Klasse `"strategy"`.

- `strategy_validate`: `true` wenn valide; sonst Fehler mit Beschreibung.

- `strategy_add_asset`, `strategy_update_asset`, `strategy_remove_asset`: Aktualisiertes `"strategy"`-Objekt.

- `print`, `summary`: Ausgabe auf der Konsole; `x` bzw. `object` unsichtbar.

# Details
`create_strategy` normiert die Zielgewichte nicht, und auch `simulation` normiert sie nicht: Die `share`-Werte
(Anteile, je größer 0 und höchstens 1) müssen sich für die Simulation auf 1 summieren, sonst bricht
`simulation` mit Fehler ab. `summary` weist auf eine abweichende Summe hin.

`strategy_validate` prüft ohne `data`, ob `strategy` die Klasse `"strategy"` hat und jedes Element ein
`asset_config`-Objekt ist (Wertebereiche prüft bereits `asset_config`). Mit `data`: zusätzlich, ob jede
Asset-Spalte und bei `trading = "signal"` die Signalspalten vorhanden sind. Für Fonds-Wrapper
(`asset_config(wrapper = )`) werden statt des Asset-Namens die Spalten der inneren Strategie geprüft (auch
deren Signalspalten); eine Spalte mit dem Namen des Wrapper-Assets ist ein Fehler.

`strategy_update_asset` akzeptiert Felder als `name = wert`-Paare; nur Felder, die das Asset bereits hat,
sowie `wrapper` werden übernommen (unbekannte mit Warnung ignoriert; `wrapper = nothing` entfernt einen
Wrapper). Das Asset wird danach mit `asset_config` neu geprüft; nicht angegebene Felder bleiben unverändert.
Ändert sich `asset_class` oder `deliverable` und wird `tax_regime` nicht mit angegeben, wird ein bisher
automatisch abgeleitetes `tax_regime` neu abgeleitet (z. B. `"certificate"` -> `"etf"`: `"investment_fund"`);
ein abweichend gesetztes (explizites) `tax_regime` bleibt erhalten.

Die veralteten Klassen `"etn_deliverable"`/`"etn_standard"` setzt bereits `asset_config` mit Warnung in
`"etn"` mit `deliverable = true`/`false` um.

Eine einfache benannte Liste ohne Klasse liefert `unclass(strategy)` — nützlich für Systeme, die keine
S3-Objekte erwarten.

# Beispiel
```julia
using SimLev
st = create_strategy(MSCI = asset_config("etf"; share = 0.7, partial_exemption = 30),
                     BOND = asset_config("etf"; share = 0.3))
println(st)
```
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

"""
    strategy_validate(strategy, data_pos = nothing; data = data_pos)

Strategie (und optional die Spalten von `data`) prüfen; `true` oder Fehler.

Funktionen zum Erstellen, Validieren und Bearbeiten von `"strategy"`-Objekten. Eine Strategie ist eine
benannte Liste von `asset_config`-Konfigurationen, die an `simulation` übergeben wird.

# Argumente
- `strategy`: Ein `"strategy"`-Objekt.
- `data_pos`: `data` auch als zweites Positionsargument.
- `data`: `data.frame` oder `nothing`. Falls angegeben, prüft `strategy_validate` ob alle Asset-Spalten und
  Signal-Spalten in `data` vorhanden sind.

# Rückgabe
- `create_strategy`: Objekt der Klasse `"strategy"`.

- `strategy_validate`: `true` wenn valide; sonst Fehler mit Beschreibung.

- `strategy_add_asset`, `strategy_update_asset`, `strategy_remove_asset`: Aktualisiertes `"strategy"`-Objekt.

- `print`, `summary`: Ausgabe auf der Konsole; `x` bzw. `object` unsichtbar.

# Details
`create_strategy` normiert die Zielgewichte nicht, und auch `simulation` normiert sie nicht: Die `share`-Werte
(Anteile, je größer 0 und höchstens 1) müssen sich für die Simulation auf 1 summieren, sonst bricht
`simulation` mit Fehler ab. `summary` weist auf eine abweichende Summe hin.

`strategy_validate` prüft ohne `data`, ob `strategy` die Klasse `"strategy"` hat und jedes Element ein
`asset_config`-Objekt ist (Wertebereiche prüft bereits `asset_config`). Mit `data`: zusätzlich, ob jede
Asset-Spalte und bei `trading = "signal"` die Signalspalten vorhanden sind. Für Fonds-Wrapper
(`asset_config(wrapper = )`) werden statt des Asset-Namens die Spalten der inneren Strategie geprüft (auch
deren Signalspalten); eine Spalte mit dem Namen des Wrapper-Assets ist ein Fehler.

`strategy_update_asset` akzeptiert Felder als `name = wert`-Paare; nur Felder, die das Asset bereits hat,
sowie `wrapper` werden übernommen (unbekannte mit Warnung ignoriert; `wrapper = nothing` entfernt einen
Wrapper). Das Asset wird danach mit `asset_config` neu geprüft; nicht angegebene Felder bleiben unverändert.
Ändert sich `asset_class` oder `deliverable` und wird `tax_regime` nicht mit angegeben, wird ein bisher
automatisch abgeleitetes `tax_regime` neu abgeleitet (z. B. `"certificate"` -> `"etf"`: `"investment_fund"`);
ein abweichend gesetztes (explizites) `tax_regime` bleibt erhalten.

Die veralteten Klassen `"etn_deliverable"`/`"etn_standard"` setzt bereits `asset_config` mit Warnung in
`"etn"` mit `deliverable = true`/`false` um.

Eine einfache benannte Liste ohne Klasse liefert `unclass(strategy)` — nützlich für Systeme, die keine
S3-Objekte erwarten.

# Beispiel
```julia
using SimLev
st = create_strategy(MSCI = asset_config("etf"; share = 0.7, partial_exemption = 30),
                     BOND = asset_config("etf"; share = 0.3))
using Dates, Random
rng = MersenneTwister(1)
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:199), "MSCI" => 100 .* cumprod(1 .+ 4e-4 .+ 0.012 .* randn(rng, 200)),
           "BOND" => 50 .* cumprod(1 .+ 1e-4 .+ 0.004 .* randn(rng, 200)))
println(strategy_validate(st, d))
```
"""
function strategy_validate(strategy, data_pos = nothing; data = data_pos)
    inherits(strategy, "strategy") ||
        error("strategy_validate: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), nicht $(_r_class1(strategy)).")
    for (name, a) in strategy
        inherits(a, "asset_config") || error("strategy_validate: Asset '$name' ist kein asset_config()-Objekt (Klasse $(_r_class1(a))).")
    end
    if data !== nothing
        cols = _colnames(data)
        # Fonds-Wrapper: der Asset-Name ist keine Kursspalte, geprüft werden die Spalten der inneren Strategie
        coll = [w for w in _strategy_wrappers(strategy) if w in cols]
        isempty(coll) || error("strategy_validate: Asset '$(coll[1])' ist ein Fonds-Wrapper (asset_config(wrapper = )); data darf keine Spalte gleichen Namens enthalten (der Anteilswert wird aus den inneren Spalten gerechnet).")
        miss = [n for n in _strategy_columns(strategy) if !(n in cols)]
        isempty(miss) || error("strategy_validate: Kursspalte(n) " * join(("'$m'" for m in miss), ", ") *
                               " fehlen in data (je Asset eine Spalte gleichen Namens; vorhanden: $(join(cols, ", "))).")
        for (name, a) in strategy
            if _is_wrapper(get(a, "wrapper", nothing))   # innere Signale
                strategy_validate(a["wrapper"]["strategy"], data)
                continue
            end
            if a["trading"] == "signal"
                a["signal_buy"] in cols || error("strategy_validate: signal_buy-Spalte '$(a["signal_buy"])' fehlt in data (Asset '$name').")
                a["signal_sell"] in cols || error("strategy_validate: signal_sell-Spalte '$(a["signal_sell"])' fehlt in data (Asset '$name').")
            end
        end
    end
    return true
end

"""
    strategy_add_asset(strategy, name::AbstractString, asset)

Asset hinzufügen bzw. ersetzen (gibt eine neue Strategie zurück).

Funktionen zum Erstellen, Validieren und Bearbeiten von `"strategy"`-Objekten. Eine Strategie ist eine
benannte Liste von `asset_config`-Konfigurationen, die an `simulation` übergeben wird.

# Argumente
- `strategy`: Ein `"strategy"`-Objekt.
- `name`: Character. Name des Assets (muss Spalte in `data` entsprechen, außer bei Fonds-Wrappern).
- `asset`: Ein `asset_config`-Objekt.

# Rückgabe
- `create_strategy`: Objekt der Klasse `"strategy"`.

- `strategy_validate`: `true` wenn valide; sonst Fehler mit Beschreibung.

- `strategy_add_asset`, `strategy_update_asset`, `strategy_remove_asset`: Aktualisiertes `"strategy"`-Objekt.

- `print`, `summary`: Ausgabe auf der Konsole; `x` bzw. `object` unsichtbar.

# Details
`create_strategy` normiert die Zielgewichte nicht, und auch `simulation` normiert sie nicht: Die `share`-Werte
(Anteile, je größer 0 und höchstens 1) müssen sich für die Simulation auf 1 summieren, sonst bricht
`simulation` mit Fehler ab. `summary` weist auf eine abweichende Summe hin.

`strategy_validate` prüft ohne `data`, ob `strategy` die Klasse `"strategy"` hat und jedes Element ein
`asset_config`-Objekt ist (Wertebereiche prüft bereits `asset_config`). Mit `data`: zusätzlich, ob jede
Asset-Spalte und bei `trading = "signal"` die Signalspalten vorhanden sind. Für Fonds-Wrapper
(`asset_config(wrapper = )`) werden statt des Asset-Namens die Spalten der inneren Strategie geprüft (auch
deren Signalspalten); eine Spalte mit dem Namen des Wrapper-Assets ist ein Fehler.

`strategy_update_asset` akzeptiert Felder als `name = wert`-Paare; nur Felder, die das Asset bereits hat,
sowie `wrapper` werden übernommen (unbekannte mit Warnung ignoriert; `wrapper = nothing` entfernt einen
Wrapper). Das Asset wird danach mit `asset_config` neu geprüft; nicht angegebene Felder bleiben unverändert.
Ändert sich `asset_class` oder `deliverable` und wird `tax_regime` nicht mit angegeben, wird ein bisher
automatisch abgeleitetes `tax_regime` neu abgeleitet (z. B. `"certificate"` -> `"etf"`: `"investment_fund"`);
ein abweichend gesetztes (explizites) `tax_regime` bleibt erhalten.

Die veralteten Klassen `"etn_deliverable"`/`"etn_standard"` setzt bereits `asset_config` mit Warnung in
`"etn"` mit `deliverable = true`/`false` um.

Eine einfache benannte Liste ohne Klasse liefert `unclass(strategy)` — nützlich für Systeme, die keine
S3-Objekte erwarten.

# Beispiel
```julia
using SimLev
st = create_strategy(MSCI = asset_config("etf"; share = 0.7, partial_exemption = 30),
                     BOND = asset_config("etf"; share = 0.3))
st = strategy_add_asset(st, "GOLD", asset_config("etc"; share = 0.1, deliverable = true))
println(collect(keys(st)))
```
"""
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

Felder eines Assets ändern und mit `asset_config` neu prüfen.

Funktionen zum Erstellen, Validieren und Bearbeiten von `"strategy"`-Objekten. Eine Strategie ist eine
benannte Liste von `asset_config`-Konfigurationen, die an `simulation` übergeben wird.

# Argumente
- `strategy`: Ein `"strategy"`-Objekt.
- `name`: Character. Name des Assets (muss Spalte in `data` entsprechen, außer bei Fonds-Wrappern).
- `felder...`: Für `create_strategy`: benannte `asset_config`-Objekte (z. B. `SPY = asset_config(...)`);
  einfache Listen werden über `asset_config` umgewandelt und geprüft. Jeder Name darf nur einmal vorkommen
  (sonst Fehler). Für `strategy_update_asset`: benannte Felder, die im Asset aktualisiert werden. Für `print`,
  `summary`: ignoriert.

# Rückgabe
- `create_strategy`: Objekt der Klasse `"strategy"`.

- `strategy_validate`: `true` wenn valide; sonst Fehler mit Beschreibung.

- `strategy_add_asset`, `strategy_update_asset`, `strategy_remove_asset`: Aktualisiertes `"strategy"`-Objekt.

- `print`, `summary`: Ausgabe auf der Konsole; `x` bzw. `object` unsichtbar.

# Details
`create_strategy` normiert die Zielgewichte nicht, und auch `simulation` normiert sie nicht: Die `share`-Werte
(Anteile, je größer 0 und höchstens 1) müssen sich für die Simulation auf 1 summieren, sonst bricht
`simulation` mit Fehler ab. `summary` weist auf eine abweichende Summe hin.

`strategy_validate` prüft ohne `data`, ob `strategy` die Klasse `"strategy"` hat und jedes Element ein
`asset_config`-Objekt ist (Wertebereiche prüft bereits `asset_config`). Mit `data`: zusätzlich, ob jede
Asset-Spalte und bei `trading = "signal"` die Signalspalten vorhanden sind. Für Fonds-Wrapper
(`asset_config(wrapper = )`) werden statt des Asset-Namens die Spalten der inneren Strategie geprüft (auch
deren Signalspalten); eine Spalte mit dem Namen des Wrapper-Assets ist ein Fehler.

`strategy_update_asset` akzeptiert Felder als `name = wert`-Paare; nur Felder, die das Asset bereits hat,
sowie `wrapper` werden übernommen (unbekannte mit Warnung ignoriert; `wrapper = nothing` entfernt einen
Wrapper). Das Asset wird danach mit `asset_config` neu geprüft; nicht angegebene Felder bleiben unverändert.
Ändert sich `asset_class` oder `deliverable` und wird `tax_regime` nicht mit angegeben, wird ein bisher
automatisch abgeleitetes `tax_regime` neu abgeleitet (z. B. `"certificate"` -> `"etf"`: `"investment_fund"`);
ein abweichend gesetztes (explizites) `tax_regime` bleibt erhalten.

Die veralteten Klassen `"etn_deliverable"`/`"etn_standard"` setzt bereits `asset_config` mit Warnung in
`"etn"` mit `deliverable = true`/`false` um.

Eine einfache benannte Liste ohne Klasse liefert `unclass(strategy)` — nützlich für Systeme, die keine
S3-Objekte erwarten.

# Beispiel
```julia
using SimLev
st = create_strategy(MSCI = asset_config("etf"; share = 0.7, partial_exemption = 30),
                     BOND = asset_config("etf"; share = 0.3))
st = strategy_update_asset(st, "MSCI"; share = 0.6, spread = 0.1)
println(st["MSCI"]["share"])
```
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
        if !haskey(asset, param) && param != "wrapper"   # wrapper: Feld nur bei Wrapper-Assets vorhanden
            @warn "strategy_update_asset: unbekannter Parameter '$param' wird ignoriert (möglich: $(join(keys(asset), ", ")))."
            continue
        end
        asset[param] = value
    end
    out = Strategy(RList(collect(strategy)...))
    out[String(name)] = _config_from_mapping(collect(asset))
    return out
end

"""
    strategy_remove_asset(strategy, name::AbstractString)

Asset entfernen (Warnung, wenn die Strategie danach leer ist).

Funktionen zum Erstellen, Validieren und Bearbeiten von `"strategy"`-Objekten. Eine Strategie ist eine
benannte Liste von `asset_config`-Konfigurationen, die an `simulation` übergeben wird.

# Argumente
- `strategy`: Ein `"strategy"`-Objekt.
- `name`: Character. Name des Assets (muss Spalte in `data` entsprechen, außer bei Fonds-Wrappern).

# Rückgabe
- `create_strategy`: Objekt der Klasse `"strategy"`.

- `strategy_validate`: `true` wenn valide; sonst Fehler mit Beschreibung.

- `strategy_add_asset`, `strategy_update_asset`, `strategy_remove_asset`: Aktualisiertes `"strategy"`-Objekt.

- `print`, `summary`: Ausgabe auf der Konsole; `x` bzw. `object` unsichtbar.

# Details
`create_strategy` normiert die Zielgewichte nicht, und auch `simulation` normiert sie nicht: Die `share`-Werte
(Anteile, je größer 0 und höchstens 1) müssen sich für die Simulation auf 1 summieren, sonst bricht
`simulation` mit Fehler ab. `summary` weist auf eine abweichende Summe hin.

`strategy_validate` prüft ohne `data`, ob `strategy` die Klasse `"strategy"` hat und jedes Element ein
`asset_config`-Objekt ist (Wertebereiche prüft bereits `asset_config`). Mit `data`: zusätzlich, ob jede
Asset-Spalte und bei `trading = "signal"` die Signalspalten vorhanden sind. Für Fonds-Wrapper
(`asset_config(wrapper = )`) werden statt des Asset-Namens die Spalten der inneren Strategie geprüft (auch
deren Signalspalten); eine Spalte mit dem Namen des Wrapper-Assets ist ein Fehler.

`strategy_update_asset` akzeptiert Felder als `name = wert`-Paare; nur Felder, die das Asset bereits hat,
sowie `wrapper` werden übernommen (unbekannte mit Warnung ignoriert; `wrapper = nothing` entfernt einen
Wrapper). Das Asset wird danach mit `asset_config` neu geprüft; nicht angegebene Felder bleiben unverändert.
Ändert sich `asset_class` oder `deliverable` und wird `tax_regime` nicht mit angegeben, wird ein bisher
automatisch abgeleitetes `tax_regime` neu abgeleitet (z. B. `"certificate"` -> `"etf"`: `"investment_fund"`);
ein abweichend gesetztes (explizites) `tax_regime` bleibt erhalten.

Die veralteten Klassen `"etn_deliverable"`/`"etn_standard"` setzt bereits `asset_config` mit Warnung in
`"etn"` mit `deliverable = true`/`false` um.

Eine einfache benannte Liste ohne Klasse liefert `unclass(strategy)` — nützlich für Systeme, die keine
S3-Objekte erwarten.

# Beispiel
```julia
using SimLev
st = create_strategy(MSCI = asset_config("etf"; share = 0.7, partial_exemption = 30),
                     BOND = asset_config("etf"; share = 0.3))
println(collect(keys(strategy_remove_asset(st, "BOND"))))
```
"""
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
        w = get(a, "wrapper", nothing)
        print(io, r_sprintf("  Klasse: %s | Anteil: %.0f%% | Steuer: %s%s\n", a["asset_class"], a["share"] * 100, a["tax_regime"],
                            _is_wrapper(w) ? " | Wrapper: " * join(keys(w["strategy"]), ", ") : ""))
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
