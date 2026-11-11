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

_first_obs(v) = (i = findfirst(!isnan, v); i === nothing ? length(v) : i)
# Spalte als Vector{Float64} und erste Beobachtung (seit 1.6.1 eine Hilfe für beide Auslöser)
const _TRIG_FN = "rebalance_trigger"
const _TRIG_SUB_FIELDS = ("type", "threshold", "lev_col", "vol_col", "triggers", "df")

"Spalte numerisch (eine Spalte nur aus NA zählt als Zahlenspalte, Entscheidung 14), ohne ±Inf; erster Wert."
function _trig_series(df, name::AbstractString, arg::AbstractString)
    col = _getcol(df, name)
    col === nothing && chk_stop("e2.spalte_von", _TRIG_FN, arg, "df")   # seit K43 T1-R5 (bis dahin "Spalte '<name>' fehlt.")
    col isa SimLev.RFmt.RFactor && chk_stop("spalte_faktor", _TRIG_FN, name)   # Entscheidung 15
    kind, arr = all(ismissing, col) ? (:logical, fill(missing, length(col))) : _column(col)
    if kind == :logical && all(ismissing, arr)
        kind, arr = :numeric, fill(NaN, length(arr))
    end
    kind == :numeric || chk_stop("spalte_typ", _TRIG_FN, name, chk_msg("typ.numerisch"))
    v = Float64[x for x in arr]
    any(isinf, v) && chk_stop("e1.spalte_endlich", _TRIG_FN, name)
    return v, _first_obs(v)
end

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
  Seit 1.6.4 darf die Spalte in `df` noch nicht vorhanden sein (vorher still überschrieben).

Seit 1.6.4 geprüft: `df` nur als `RFrame`; `threshold` eine einzelne endliche Zahl `>= 0`; Spaltennamen einzeln und
nicht leer; die genutzte Spalte nur Zahlen oder NA (kein `Inf`); Teil-Trigger nur mit den Feldern `type`,
`threshold`, `lev_col`, `vol_col`, `triggers` und `df` (gleiche Zeilenzahl).

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
function rebalance_trigger(df, type; threshold = 10,
                               lev_col = "target_leverage",
                               vol_col = "sigma_ewma",
                               triggers = nothing, out_col = "rebal_trigger")
    @nospecialize
    fn = _TRIG_FN
    # seit 1.6.4 Eingabeprüfung vor der Rechnung (A-013, A-036): df nur als RFrame (Entscheidung 6), type aus der
    # Liste, threshold eine einzelne endliche Zahl >= 0, Spaltennamen einzeln und nicht leer, die genutzte Spalte
    # numerisch und ohne ±Inf, Teil-Trigger von "combined" mit den Feldern type, threshold, lev_col, vol_col,
    # triggers und df (eigenes df mit gleicher Zeilenzahl; out_col dort nicht)
    chk_df(df, fn, "df")
    n = nrow(df)
    n < 1 && chk_stop("zeilen_keine", fn, "df")   # seit K43 T1-R5 aus der Tabelle
    type = chk_choice(type, fn, "type", ("abs_leverage", "rel_leverage", "vol_band", "combined"))
    threshold = chk_num1(threshold, fn, "threshold"; lo = 0)
    lev_col = chk_name1(lev_col, fn, "lev_col")
    vol_col = chk_name1(vol_col, fn, "vol_col")
    out_col = chk_name1(out_col, fn, "out_col")
    # seit 1.6.4 (Entscheidung 26): vorhandene Spalte nicht still überschreiben
    String(out_col) in names(df) && chk_stop("spalte_vorhanden", fn, out_col, "df", "out_col")
    thr = threshold / 100
    trig = falses(n)
    if type == "abs_leverage" || type == "rel_leverage"
        lev, t0 = _trig_series(df, lev_col, "lev_col")
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
        vol, t0 = _trig_series(df, vol_col, "vol_col")
        ref = vol[t0]
        for t in t0+1:n
            v = vol[t]
            if !isnan(v) && ref != 0 && abs(v / ref - 1) > thr
                trig[t] = true; ref = v
            end
        end
    else
        # seit K43 T1-R5 aus der Tabelle (bis dahin "type='combined' benötigt eine nicht-leere Liste 'triggers'.")
        triggers === nothing && chk_stop("fehlt", fn, "triggers")
        (triggers isa Union{AbstractVector,Tuple,AbstractDict,NamedTuple} && isempty(triggers)) &&
            chk_stop("ut1.liste_leer", fn, "triggers")
        (triggers isa Union{AbstractVector,Tuple} && !(triggers isa AbstractVector{<:Pair})) || chk_stop("liste", fn, "triggers")
        subs = Dict{Symbol,Any}[]
        for (i, sub) in enumerate(triggers)
            _is_mapping(sub) || chk_stop("liste", fn, "triggers[[$i]]")
            ps = _kvpairs(sub)
            for p in ps
                p.first in _TRIG_SUB_FIELDS || chk_stop("e1.trigger_feld", fn, p.first, i)
            end
            any(p -> p.first == "type" && p.second !== nothing, ps) || chk_stop("fehlt", fn, "triggers[[$i]]\$type")
            push!(subs, Dict{Symbol,Any}(Symbol(p.first) => p.second for p in ps if p.second !== nothing))   # R modifyList
        end
        for kw in subs
            st = pop!(kw, :type, nothing)
            sdf = pop!(kw, :df, df)   # eigenes df eines Teil-Triggers (wie R; bis 1.6.3 übergangen)
            sub_df = rebalance_trigger(sdf, st; out_col = "..__sub__..", kw...)
            nrow(sub_df) == n || chk_stop("e1.trigger_df", fn, n)
            trig .|= Bool.(_getcol(sub_df, "..__sub__.."))
        end
    end
    out = copy(df)
    out[String(out_col)] = Vector{Bool}(trig)
    return out
end
