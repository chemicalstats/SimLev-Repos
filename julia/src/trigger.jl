# ─────────────────────────────────────────────────────────────────────────────
# Vorberechnung der Event-Trigger-Spalte (Gegenstück zu compute_rebal_trigger.R)
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

Logische Trigger-Spalte für `simulation(..., rebalance=rebalance_plan(event_col=...))` vorberechnen.

Berechnet eine binäre Trigger-Spalte, die `simulation` über `event_col` konsumiert. Die gesamte
Schwellenwert-/Bandlogik liegt hier, außerhalb der Engine — der Nutzer kann sie nach Bedarf anpassen oder
ersetzen.

Vier Trigger-Typen sind implementiert:

- `"abs_leverage"`: Trigger, wenn die absolute Abweichung des Ziel-Hebels vom zuletzt gehaltenen Hebel größer
  als `threshold` ist.
- `"rel_leverage"`: Trigger, wenn die relative Abweichung des Ziel-Hebels vom zuletzt gehaltenen Hebel größer
  als `threshold` ist.
- `"vol_band"`: Trigger, wenn die Volatilität relativ zum letzten Rebalancing-Referenzwert um mehr als
  `threshold` abweicht.
- `"combined"`: OR-Verknüpfung mehrerer Sub-Trigger-Specs aus `triggers`.

Der Referenzwert (gehaltener Hebel bzw. Volatilität) ist der erste nicht fehlende Wert (in der Regel der erste
Tag; bei führenden `NA`, etwa in der Anlaufphase einer EWMA-Volatilität, der erste Tag mit Wert; bis dahin
wird nicht ausgelöst) und wird nur an Tagen fortgeschrieben, an denen dieser Trigger auslöst (nicht an
kalendarischen Rebalancing-Tagen in `simulation`). Ausgelöst wird bei einer Abweichung *größer* als die
Schwelle; `NA`-Werte lösen nicht aus. Bei `"rel_leverage"` und `"vol_band"` wird nicht ausgelöst, solange der
Referenzwert 0 ist.

# Argumente
- `df`: `data.frame` mit täglichen Feldern (mindestens eine Zeile). Muss die relevanten numerischen Spalten
  (`lev_col` bzw. `vol_col`) enthalten, sonst Fehler.
- `type`: Character. Trigger-Typ: `"abs_leverage"`, `"rel_leverage"`, `"vol_band"` oder `"combined"`. Kein
  Standardwert; andere Werte führen zu einem Fehler.
- `threshold`: Numerisch. Auslöseschwelle **in Prozent** (Paket-Konvention). Bedeutung je Typ:
  `"abs_leverage"` in Prozentpunkten des Hebels (`10` = 0,10 Hebelabweichung); `"rel_leverage"`/`"vol_band"`
  relative Abweichung (`10` = 10 %). Bei `type = "combined"` ignoriert (Schwellen je Sub-Trigger). Standard:
  `10`.
- `lev_col`: Character. Name der Ziel-Hebel-Spalte in `df`. Wird von `"abs_leverage"` und `"rel_leverage"`
  verwendet. Standard: `"target_leverage"`.
- `vol_col`: Character. Name der Volatilitätsspalte in `df`. Wird von `"vol_band"` verwendet. Standard:
  `"sigma_ewma"`.
- `triggers`: Liste von Sub-Trigger-Specs (nur bei `type = "combined"`). Jeder Eintrag ist eine Liste mit
  `type` und ggf. `threshold` (in Prozent, fehlt er: `10`), `lev_col`, `vol_col`. Jeder Sub-Trigger führt
  seinen eigenen Referenzwert; die Ergebnisse werden OR-verknüpft. Standard: `nothing`.
- `out_col`: Character. Name der zu erzeugenden logischen Spalte in `df`. Standard: `"rebal_trigger"`.

# Rückgabe
`df` mit einer zusätzlichen logischen Spalte `out_col`. `true` bedeutet: an diesem Tag wird Rebalancing
ausgelöst. Tag 1 ist immer `false` (kein Rebalancing am Einstiegstag).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 500
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["ETF"] = 100 .* cumprod(1 .+ 4e-4 .+ 0.012 .* randn(rng, n))
d["target_leverage"] = 2 .+ 0.5 .* sin.(range(0, 4pi; length = n))
d["sigma_ewma"] = 0.01 .+ 0.005 .* abs.(randn(rng, n))
d = rebalance_trigger(d, "abs_leverage"; threshold = 10)
println(sum(d["rebal_trigger"]))     # Anzahl der Rebalancing-Tage
```
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
