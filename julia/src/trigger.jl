# ─────────────────────────────────────────────────────────────────────────────
# Vorberechnung der Event-Trigger-Spalte (Port von compute_rebal_trigger.R)
# ─────────────────────────────────────────────────────────────────────────────

function _getcol(df, name::AbstractString)
    if df isa RFrame
        return haskey(df, name) ? df[name] : nothing
    elseif df isa AbstractDict
        haskey(df, name) && return df[name]
        haskey(df, Symbol(name)) && return df[Symbol(name)]
        return nothing
    elseif df isa NamedTuple
        return haskey(df, Symbol(name)) ? df[Symbol(name)] : nothing
    end
    s = Symbol(name)
    s in propertynames(df) || return nothing
    return getproperty(df, s)
end

function _nrow_any(df)
    df isa RFrame && return nrow(df)
    df isa NamedTuple && return isempty(df) ? 0 : length(first(df))
    df isa AbstractDict && return isempty(df) ? 0 : length(first(values(df)))
    error("rebalance_trigger: df muss ein data.frame sein.")
end

function _with_col(df, name::AbstractString, v::AbstractVector)
    if df isa RFrame
        out = copy(df)
        out[String(name)] = v
        return out
    elseif df isa NamedTuple
        return merge(df, NamedTuple{(Symbol(name),)}((v,)))
    elseif df isa AbstractDict
        out = copy(df)
        out[keytype(out) === Symbol ? Symbol(name) : name] = v
        return out
    end
    error("rebalance_trigger: df muss ein data.frame sein.")
end

_f64(x) = x === missing || x === nothing ? NA : Float64(x)
_first_obs(v) = (i = findfirst(!isnan, v); i === nothing ? length(v) : i)

"""
    rebalance_trigger(df, type; threshold = 10, lev_col = "target_leverage",
                          vol_col = "sigma_ewma", triggers = nothing, out_col = "rebal_trigger")

Logische Trigger-Spalte für `simulation(...; rebalance = rebalance_plan(; event_col = ...))` vorberechnen
(`type` = `"abs_leverage"`, `"rel_leverage"`, `"vol_band"` oder `"combined"`).
`threshold` **in Prozent** (intern /100). Die Referenz ist der erste nicht
fehlende Wert und springt nur an Trigger-Tagen; NA löst nicht aus. `"combined"`
verknüpft die Sub-Trigger aus `triggers` (Liste benannter Listen) per ODER.
Gibt eine Kopie von `df` (RFrame, NamedTuple oder Dict) mit der Spalte
`out_col` zurück; Tag 1 ist immer `false`.
"""
function rebalance_trigger(df, type::AbstractString; threshold::Real = 10,
                               lev_col::AbstractString = "target_leverage",
                               vol_col::AbstractString = "sigma_ewma",
                               triggers = nothing, out_col::AbstractString = "rebal_trigger")
    n = _nrow_any(df)
    n < 1 && error("rebalance_trigger: leerer data.frame.")
    thr = threshold / 100
    trig = falses(n)
    if type == "abs_leverage" || type == "rel_leverage"
        col = _getcol(df, lev_col)
        col === nothing && error("Spalte '$lev_col' fehlt.")
        lev = Float64[_f64(x) for x in col]
        t0 = _first_obs(lev)
        held = lev[t0]
        for t in t0+1:n
            v = lev[t]
            isnan(v) && continue
            if type == "abs_leverage"
                if abs(v - held) > thr
                    trig[t] = true; held = v
                end
            elseif held != 0 && abs(v / held - 1) > thr
                trig[t] = true; held = v
            end
        end
    elseif type == "vol_band"
        col = _getcol(df, vol_col)
        col === nothing && error("Spalte '$vol_col' fehlt.")
        vol = Float64[_f64(x) for x in col]
        t0 = _first_obs(vol)
        ref = vol[t0]
        for t in t0+1:n
            v = vol[t]
            if !isnan(v) && ref != 0 && abs(v / ref - 1) > thr
                trig[t] = true; ref = v
            end
        end
    elseif type == "combined"
        (triggers === nothing || isempty(triggers)) && error("type='combined' benötigt eine nicht-leere Liste 'triggers'.")
        for sub in triggers
            kw = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in _kvpairs(sub isa NamedTuple || sub isa AbstractDict || sub isa AbstractVector{<:Pair} ? sub : collect(sub)))
            haskey(kw, :df) && delete!(kw, :df)
            st = String(pop!(kw, :type))
            haskey(kw, :out_col) || (kw[:out_col] = "..__sub__..")
            sub_df = rebalance_trigger(df, st; kw...)
            trig .|= Bool.(_getcol(sub_df, String(kw[:out_col])))
        end
    else
        error("Unbekannter type='$type'.")
    end
    return _with_col(df, out_col, Vector{Bool}(trig))
end
