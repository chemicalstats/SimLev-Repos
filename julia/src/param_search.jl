# ParamSearch – Gegenstück zu r/R/param_search.R und python/simlev/param_search.py
#
#  param_space() / param_range()   Suchraum (diskret oder kontinuierlich)
#  param_search()                  Raster, Zufallssuche oder Latin Hypercube;
#                                  simulation() je Punkt, Kennzahlen und
#                                  tägliche TWR-Renditen
#  param_plateau()                       Nachbarschafts-Glättung der Zielgröße
module ParamSearch

import ..SimLev
using ..SimLev: _res_fig, _res_finish, _res_line!, _res_panel, _res_points!, _res_pal, _res_range, _res_rect!,
                _res_text!, _res_tx, _res_ty
using Dates

const SL = SimLev
const NA = SimLev.NA
const OF = SimLev.Overfitting
# Platzhalter für ein R-Argument ohne Standardwert (space in param_search)
const _MISSING = SimLev.Bootstrap._MISSING

# Kennzahlen aus metrics() als (Namen, Werte); seit 1.6.4 ergibt ein unbenannter Zahlenvektor keine Namen (statt eines
# Fehlers in OF._metric_pairs), damit chk_kennzahlen ihn wie in R und Python als unbenannt meldet (Entscheidung 43)
_e2_pairs(m) = (m isa AbstractVector && !(m isa SL.RVector) && !isempty(m) && all(v -> v isa Real, m)) ?
    (String[], Float64[SL._f64(v) for v in m]) : OF._metric_pairs(m)

export param_space, param_range, param_search, param_plateau

# ═════════════════════════════════════════════════════════════════════════════
# Suchraum
# ═════════════════════════════════════════════════════════════════════════════

_is_range(d) = d isa SL.RList && SL.inherits(d, "SimLevParamRange")
_is_num(x) = x isa Real && !(x isa Bool)
_is_atomic_val(x) = x isa Union{Real,AbstractString,Missing}
_is_atomic(v) = (v isa AbstractVector && !(v isa SL.RFrame) && !isempty(v) && all(_is_atomic_val, v)) ||
                (_is_atomic_val(v) && !(v isa Missing))
_vec(v) = v isa AbstractVector ? (v isa SL.RVector ? v.values : v) : [v]

"""
    param_space(; dims...)
    param_space("name" => werte, ...)

Suchraum für `param_search`.

`param_space()` beschreibt den Suchraum für `param_search()`: je Parameter eine benannte Dimension mit
diskreten Werten oder einem stetigen Bereich aus `param_range()`. Bei `method = "grid"` werden alle
Kombinationen der Rasterwerte ausgewertet; bei `"random"` und `"lhs"` werden diskrete Werte gleichverteilt
ausgewählt und Bereiche stetig zwischen `lower` und `upper` gezogen (`n` und `step` spielen dann keine Rolle).

# Argumente
- `dims`: Benannte Dimensionen als Schlüsselwörter (`n = [50, 100]`) oder Paare (`"name" => werte`); siehe
  `...` in den übrigen Sprachen.

# Rückgabe
`param_space`: Objekt der Klasse `SimLevParamSpace` (benannte Liste der Dimensionen); `param_range`: Objekt
der Klasse `SimLevParamRange` (Liste mit `lower`, `upper`, `n`, `step`, `integer`, `log`).

# Beispiel
```julia
using SimLev
println(param_space(n = [50, 100, 200], w = param_range(0.3, 0.9; step = 0.1)))
```
"""
function param_space(args...; dims...)
    items = Pair{String,Any}[]
    for a in args
        a isa Pair || error("param_space: alle Dimensionen müssen benannt sein.")
        push!(items, String(string(a.first)) => a.second)
    end
    for (k, v) in dims
        push!(items, String(k) => v)
    end
    (isempty(items) || any(p -> isempty(p.first), items)) && error("param_space: alle Dimensionen müssen benannt sein.")
    for (k, v) in items
        _is_range(v) || _is_atomic(v) || error("param_space: Dimension '$k' muss ein Vektor oder param_range() sein.")
    end
    for (k, v) in items
        SL.chk_nofactor(v, "param_space", k)   # seit 1.6.4 (Entscheidung 15)
    end
    return SL.RList(items...; class = "SimLevParamSpace")
end

"""
    param_range(lower, upper; n = 5, step = nothing, integer = false, log = false)

Stetiger Bereich einer Dimension für `param_space`.

`param_space()` beschreibt den Suchraum für `param_search()`: je Parameter eine benannte Dimension mit
diskreten Werten oder einem stetigen Bereich aus `param_range()`. Bei `method = "grid"` werden alle
Kombinationen der Rasterwerte ausgewertet; bei `"random"` und `"lhs"` werden diskrete Werte gleichverteilt
ausgewählt und Bereiche stetig zwischen `lower` und `upper` gezogen (`n` und `step` spielen dann keine Rolle).

# Argumente
- `lower`, `upper`: Bereichsgrenzen (Zahlen in der Einheit des Parameters, `lower <= upper`; bei `log = true`
  `lower > 0`).
  Seit 1.6.4 je eine endliche Zahl.
- `n`: Anzahl Rasterpunkte des Bereichs bei `method = "grid"` (ganze Zahl von 1 bis 1e6, Standard 5); wird
  ignoriert, wenn `step` angegeben ist.
- `step`: Schrittweite des Rasters in der Einheit des Parameters (`seq(lower, upper, by = step)`, > 0); hat
  Vorrang vor `n` und `log` (`log` gilt dann nur für Zufallsziehungen). `nothing` (Standard) = `n` Punkte.
- `integer`: Logisch (Standard `false`): Raster- und Zufallswerte auf ganze Zahlen runden; doppelte
  Rasterwerte entfallen.
  Seit 1.6.4 nur TRUE oder FALSE.
- `log`: Logisch (Standard `false`): Raster gleichabständig auf der Log-Skala und Ziehung log-gleichverteilt,
  z. B. für Fensterlängen.

# Rückgabe
`param_space`: Objekt der Klasse `SimLevParamSpace` (benannte Liste der Dimensionen); `param_range`: Objekt
der Klasse `SimLevParamRange` (Liste mit `lower`, `upper`, `n`, `step`, `integer`, `log`).

# Beispiel
```julia
using SimLev
sp = param_space(n = param_range(50, 400; n = 8, integer = true, log = true), band = [0, 1, 2])
println(sp)
```
"""
function param_range(lower, upper; n = 5, step = nothing, integer = false, log = false)
    # seit 1.6.4: Grenzen je eine endliche Zahl (vorher NaN/Inf still als Stufe), integer/log TRUE/FALSE, Meldungen
    # ohne Eingabewert; Länge 1 wie Einzelwert (Entscheidung 4)
    lower, upper, n, step = SL.chk_scalar(lower), SL.chk_scalar(upper), SL.chk_scalar(n), SL.chk_scalar(step)
    isnumv(x) = _is_num(x) || (x isa AbstractArray && !(eltype(x) <: Bool) && all(_is_num, x))
    (isnumv(lower) && isnumv(upper)) || error("param_range: lower <= upper erforderlich.")
    lower = SL.chk_num1(lower, "param_range", "lower")
    upper = SL.chk_num1(upper, "param_range", "upper")
    upper < lower && error("param_range: lower <= upper erforderlich.")
    integer = SL.chk_bool1(integer, "param_range", "integer")
    log = SL.chk_bool1(log, "param_range", "log")
    log && lower <= 0 && error("param_range: log = TRUE erfordert lower > 0.")
    if step === nothing && !(_is_num(n) && isfinite(n) && n >= 1 && n == OF._r_round(n))
        error("param_range: n (Anzahl Rasterpunkte) muss eine ganze Zahl >= 1 sein.")
    end
    step === nothing && SL.chk_max(n, SL.SL_MAX_GITTER, "param_range", "n")   # seit 1.6.4 (B-004, wie n_grid; Entscheidung 16)
    if step !== nothing && !(_is_num(step) && isfinite(step) && step > 0)
        error("param_range: step muss eine Zahl > 0 sein.")
    end
    return SL.RList("lower" => lower, "upper" => upper, "n" => trunc(Int, n), "step" => step, "integer" => integer,
                    "log" => log; class = "SimLevParamRange")
end

function _print_space(io::IO, x)
    print(io, "SimLev-Parameterraum\n")
    for (k, d) in x
        if _is_range(d)
            rast = d["step"] !== nothing ? "Schritt " * OF._as_chr(d["step"]) : "$(d["n"]) Punkte"
            print(io, OF._spf("  %-14s Bereich [%g, %g]%s%s, Raster %s\n", k, Float64(d["lower"]), Float64(d["upper"]),
                              d["integer"] ? " ganzzahlig" : "", d["log"] ? " log" : "", rast))
        else
            f = OF._formatv(_vec(d))
            print(io, OF._spf("  %-14s %s\n", k, join(f[1:min(12, end)], ", ")))
        end
    end
    nothing
end

"`seq(from, to, by = by)` für Doubles (seq.default)."
function _seq_by(frm, to, by)
    frm = Float64(frm); to = Float64(to); by = Float64(by)
    dl = to - frm
    dl == 0 && to == 0 && return [to]
    fin = isfinite(dl)
    n = fin ? dl / by : to / by - frm / by
    if !isfinite(n)
        !isnan(by) && by == 0 && dl == 0 && return [frm]
        error("invalid '(to - from)/by'")
    end
    n < 0 && error("wrong sign in 'by' argument")
    n > 2147483647 && error("'by' argument is much too small")
    fin && abs(dl) / max(abs(to), abs(frm)) < 100 * eps(Float64) && return [frm]
    ni = trunc(Int, n + 1e-10)
    x = fin ? Float64[frm + k * by for k in 0:ni] : Float64[(frm / 4 + k * (by / 4)) * 4 for k in 0:ni]
    return by > 0 ? min.(x, to) : max.(x, to)
end

"`seq(from, to, length.out = n)` für Doubles (seq.default)."
function _seq_len_out(frm, to, len)
    n = Int(ceil(len))
    frm = Float64(frm); to = Float64(to)
    n <= 0 && return Float64[]
    n == 1 && return [frm]
    n == 2 && return [frm, to]
    frm == to && return fill(frm, n)
    n1 = n - 1
    del = to - frm
    if isfinite(del)
        return vcat(frm, Float64[frm + i * (del / n1) for i in 1:n-2], to)
    end
    f = frm / 4; t = to / 4
    return vcat(f, Float64[f + i * ((t - f) / n1) for i in 1:n-2], t) .* 4
end

_round_vec(v) = Float64[OF._r_round(x) for x in v]
"`unique(v)` mit Reihenfolge des ersten Auftretens (NaN gleich NaN, -0 gleich 0)."
function _unique(v)
    out = similar(v, 0)
    for x in v
        any(y -> _same(x, y), out) || push!(out, x)
    end
    out
end
_same(a, b) = (a === missing && b === missing) || (a isa AbstractFloat && b isa AbstractFloat && isnan(a) && isnan(b)) ||
              (a !== missing && b !== missing && !(a isa AbstractFloat && isnan(a)) && a == b)

"Rasterwerte einer Dimension (`.ps_levels`)."
function _ps_levels(d)
    _is_range(d) || return d
    v = if d["step"] !== nothing
        _seq_by(d["lower"], d["upper"], d["step"])
    elseif d["log"]
        SL.RLibm.exp.(_seq_len_out(SL.RLibm.log(Float64(d["lower"])), SL.RLibm.log(Float64(d["upper"])), d["n"]))
    else
        _seq_len_out(d["lower"], d["upper"], d["n"])
    end
    d["integer"] && (v = _round_vec(v))
    v = _unique(v)
    return length(v) == 1 ? v[1] : v
end

"Werte einer Dimension aus gleichverteilten u in (0, 1) abbilden (`.ps_map`)."
function _ps_map(d, u)
    uu = Float64[Float64(x) for x in _vec(u)]
    if !_is_range(d)
        dv = _vec(d); L = length(dv)
        return dv[[min(L, Int(floor(x * L)) + 1) for x in uu]]
    end
    lo = Float64(d["lower"]); hi = Float64(d["upper"])
    v = if d["log"]
        ll = SL.RLibm.log(lo)
        SL.RLibm.exp.(ll .+ uu .* (SL.RLibm.log(hi) - ll))
    else
        lo .+ uu .* (hi - lo)
    end
    d["integer"] && (v = _round_vec(v))
    return v
end

"`expand.grid(cols)` (erste Spalte läuft am schnellsten) als RFrame."
function _expand_grid(names::Vector{String}, vals::Vector)
    vs = [collect(_vec(v)) for v in vals]
    total = isempty(vs) ? 0 : prod(length.(vs))
    out = Pair{String,Any}[]
    rep_fac = 1
    for (k, v) in zip(names, vs)
        nx = length(v)
        if total == 0
            push!(out, k => v[1:0]); continue
        end
        orep = total ÷ (nx * rep_fac)
        idx = repeat(repeat(1:nx, inner = rep_fac), orep)
        push!(out, k => v[idx])
        rep_fac *= nx
    end
    return SL.RFrame(out...; nrow = total)
end

"Zeile `i` eines data.frame als benannte Liste (`as.list(D[i, , drop = FALSE])`)."
_row_list(D::SL.RFrame, i::Int, cols = names(D)) = SL.RList((k => (c = D[k][i]; c) for k in cols)...)

function _ok_rows(D::SL.RFrame, constraint)
    constraint === nothing && return trues(SL.nrow(D))
    return Bool[constraint(_row_list(D, i)) === true for i in 1:SL.nrow(D)]
end

_cat_cols(a::AbstractVector, b::AbstractVector) = vcat(a, b)
function _rbind(A::SL.RFrame, B::SL.RFrame)
    nm = names(A)
    SL.RFrame((k => _cat_cols(A[k], B[k]) for k in nm)...; nrow = SL.nrow(A) + SL.nrow(B))
end
function _unique_rows(D::SL.RFrame)
    nm = names(D); n = SL.nrow(D)
    keep = falses(n)
    seen = Vector{Vector{Any}}()
    for i in 1:n
        key = Any[D[k][i] for k in nm]
        dup = any(s -> all(_same(a, b) for (a, b) in zip(s, key)), seen)
        dup || (push!(seen, key); keep[i] = true)
    end
    SL.rows(D, keep)
end

"Versuchsplan erzeugen (`.ps_design`)."
function _ps_design(space, method, n, constraint, stream = nothing)
    nm = collect(keys(space))
    if method == "grid"
        D = _expand_grid(nm, Any[_ps_levels(space[k]) for k in nm])
        D = SL.rows(D, _ok_rows(D, constraint))
    else
        D = nothing; tries = 0
        while (D === nothing || SL.nrow(D) < n) && tries < 20
            m = D === nothing ? Int(n) : max(Int(n), 2 * (Int(n) - SL.nrow(D)))
            U = Matrix{Float64}(undef, m, length(nm))
            for j in eachindex(nm)
                if method == "lhs"
                    s = Float64[Float64(v) for v in SL.SLib.sample(m; stream = stream)]
                    U[:, j] = (s .- SL.SLib.runif(m; stream = stream)) ./ m
                else
                    U[:, j] = SL.SLib.runif(m; stream = stream)
                end
            end
            Dn = SL.RFrame((k => collect(_vec(_ps_map(space[k], U[:, j]))) for (j, k) in enumerate(nm))...; nrow = m)
            Dn = SL.rows(Dn, _ok_rows(Dn, constraint))
            D = _unique_rows(D === nothing ? Dn : _rbind(D, Dn))
            tries += 1
        end
        D = SL.rows(D, 1:(n >= 0 ? min(Int(n), SL.nrow(D)) : max(SL.nrow(D) + Int(n), 0)))
    end
    SL.nrow(D) == 0 && error("param_search: kein zulässiger Punkt im Suchraum (constraint prüfen).")
    D.rownames = nothing
    return D
end

# ═════════════════════════════════════════════════════════════════════════════
# Spezifikation auswerten
# ═════════════════════════════════════════════════════════════════════════════

"Builder-Ergebnis in eine Spezifikation umwandeln (`.as_spec`)."
function _as_spec(s)
    s isa SL.Strategy && return SL.RList("strategy" => s)
    OF._islistlike(s) && OF._lget(s, "strategy") !== nothing && return s
    return SL.RList("strategy" => s)
end

_is_logical_vec(v) = v isa AbstractVector && !isempty(v) &&
                     (Base.nonmissingtype(eltype(v)) <: Bool || all(e -> e === missing || e === nothing || e isa Bool, v))
_fill_false(v) = Bool[e === true for e in v]

"Eingabe als RFrame (Kopie)."
function _as_frame(df)
    df isa SL.RFrame && return copy(df)
    kv = OF._kv(df)
    isempty(kv) && error("'data' must be a data.frame")
    return SL.RFrame((k => collect(v) for (k, v) in kv)...)
end

"Eine Strategie-Spezifikation auf einem data.frame auswerten (`.run_spec`)."
function _run_spec(df, sp, sim_args, burn_in)
    df = _as_frame(df)
    sig = OF._lget(sp, "signal")
    if sig !== nothing
        sg = sig(df)
        if sg isa SL.RFrame
            df = sg
        else
            for (k, v) in OF._kv(sg)
                v = v isa SL.RVector ? v.values : v
                _is_logical_vec(v) && (v = _fill_false(v))
                df[k] = v
            end
        end
    end
    dat = OF._lget(sp, "data")
    dat !== nothing && (df = dat(df))
    mp = OF._lget(sp, "map")
    if mp !== nothing
        for (a, src) in OF._kv(mp)
            df[a] = df[String(src)]
        end
    end
    burn_in > 0 && (df = SL.rows(df, (Int(burn_in) + 1):SL.nrow(df)))
    args = SL._sim_args_set(sim_args, OF._lget(sp, "args"), "param_search")
    st = OF._lget(sp, "strategy")
    return OF._quiet(() -> SL._sim_call(df, st, args))
end

"`.par_lapply(X, FUN, cores)` (Schicht 0: `SimLev.RParallel.par_lapply`)."
_par_lapply(X, f, cores) = SL.RParallel.par_lapply(X, f, cores)


# ═════════════════════════════════════════════════════════════════════════════
# Parametersuche
# ═════════════════════════════════════════════════════════════════════════════

"""
    param_search(data, builder, space; strategy = nothing, method = "grid", n = 50,
                 constraint = nothing, sim_args = nothing, burn_in = 0,
                 metrics = nothing, objective = "sharpe", maximize = true,
                 keep_returns = "day", seed = nothing, cores = "auto")
    param_search(data; builder = nothing, space, strategy, ...)

Parametersuche über Strategie- und Simulationsparameter.

Wertet eine Strategie für jeden Punkt eines Parameterraums mit `simulation()` aus. Neben den Kennzahlen werden
die täglichen zeitgewichteten Renditen jedes Punkts gespeichert; darauf bauen die Überanpassungs-Prüfungen
`overfit_pbo()`, `sharpe_deflated()` und `overfit_walk_forward()` auf.

# Argumente
- `data`: Tabelle (RFrame) wie in `simulation()` (Spalte `date` und Kursspalten als Niveaus), inklusive
  Vorlauf für Signale (siehe `burn_in`).
  Seit 1.6.4 mindestens eine Datenzeile (vorab geprüft).
- `builder`: Funktion `function(p)`, die aus einer benannten Liste `p` (ein Punkt des Raums) entweder eine
  Strategie oder eine Liste `RList("strategy" => …, "signal" => …, "args" => …, "map" => …, "data" => …)`
  liefert: `signal` wie in `bootstrap_study()` (Funktion `df ->` Tabelle (RFrame) oder Liste von Spalten, z.
  B. mit `signal_sma()`), `args` (Liste, wie `sim_args`, auch mit Pfaden wie `"rebalance.thresh"`)
  überschreibt `sim_args`, `map` (benannter Zeichenvektor) legt Spalten-Aliase an, `data` ist optional eine
  Funktion `df -> df` (z. B. eine Hebelreihe mit `series_leverage()` anlegen). `nothing` (Standard) = ohne
  `builder`: die Parameter werden als Argumente von `simulation()` für `strategy` verwendet; Parameter der
  Bausteine dann mit Pfad, z. B. `param_space(rebalance.thresh = [2, 5], dca.value = [100, 200])` (wie in
  `sensitivity_grid`); die Spalten von `results` heißen wie die Pfade.
- `space`: Suchraum aus `param_space()` (oder benannte Liste, die an `param_space()` weitergegeben wird).
- `strategy`: Feste Strategie (z. B. aus `create_strategy()`), wenn `builder` fehlt; sonst ungenutzt.
- `method`: `"grid"` (Standard, volles Raster), `"random"` (Zufallssuche) oder `"lhs"` (Latin Hypercube;
  gleichmäßige Abdeckung bei vielen Dimensionen).
- `n`: Anzahl Punkte bei `"random"` und `"lhs"` (ganze Zahl, Standard 50); bei `"grid"` ignoriert. Doppelte
  Punkte werden entfernt und in höchstens 20 Runden nachgezogen; es können weniger Punkte entstehen.
  Seit 1.6.4 höchstens 10^8.
- `constraint`: Optional `function(p)`, die `true` für zulässige Punkte liefert (z. B. Gewichte summieren sich
  höchstens zu 1); Punkte ohne `true` entfallen. `nothing` (Standard) = alle Punkte.
- `sim_args`: Benannte Liste gemeinsamer Argumente für `simulation()` (Standard: keine): Argumente von
  `simulation()` außer `data` und `strategy`, also auch Bausteine (z. B. `dca = dca_plan(100, 1)`, `tax =
  tax_profile()`) und Pfade zu Parametern der Bausteine (`"dca.value"`, siehe `sensitivity_grid`). Alte
  Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. `dca_value`) ergeben einen Fehler, der den Baustein
  nennt.
- `burn_in`: Anzahl Zeilen am Anfang von `data` (bei Tagesdaten: Tage), die nach der Signalberechnung
  verworfen werden (Signal-Vorlauf; ganze Zahl, Standard 0).
  Seit 1.6.4 eine ganze Zahl ≥ 0.
- `metrics`: Funktion `SimLevResult ->` benannter numerischer Vektor (Standard `bootstrap_study_metrics()`: u.
  a. `cagr`, `max_drawdown` als Anteil, `sharpe`; `cagr` ist mit Sparplan geldgewichtet, XIRR).
  Seit 1.6.4 müssen die Namen der Kennzahlen eindeutig und nicht leer sein und dürfen keiner festen Spalte des
  Ergebnisses gleichen (sonst Fehler nach dem Rechnen).
- `objective`: Name der Zielgröße (Element von `metrics`, Standard `"sharpe"`) für Ranking, Plateau und
  `param_bootstrap()`.
- `maximize`: Logisch: Zielgröße maximieren (Standard `true`; `false` z. B. für `max_drawdown`).
- `keep_returns`: `"day"` (Standard): tägliche Renditen je Punkt speichern (nötig für `overfit_pbo()`,
  `sharpe_deflated()`, `overfit_walk_forward()`, `overfit_reality_check()`, `sharpe_haircut()`); `"none"`:
  keine. `true`/`false` (bis 1.0.0) ergeben einen Fehler.
- `seed`: Startwert für den Versuchsplan bei `"random"`/`"lhs"` (Standard `nothing`; bei `"grid"` ohne
  Bedeutung). Mit Startwert (ganze Zahl, |seed| < 2^53) ist das Ergebnis reproduzierbar und der Zufallszustand
  von SimLev bleibt unverändert; mit `nothing` wird genau einmal ein Startwert aus dem Zufallszustand von
  SimLev gezogen (siehe `simlev_seed()`), wiederholte Aufrufe liefern dann verschiedene Ergebnisse.
  `set.seed()` wirkt nicht. Die Auswertung der Punkte ist deterministisch, das Ergebnis hängt nicht von
  `cores` ab.
- `cores`: Anzahl paralleler Läufe:
  `"auto"` (Standard seit 1.6.4; bis 1.6.3 1) oder eine ganze Zahl ≥ 1.
  Mit `"auto"` rechnet SimLev die ersten Einheiten nacheinander, misst ihre Rechenzeit und wählt dann
  die Zahl der Aufgaben (Tasks auf Threads statt Prozesse) und der Kern-Threads je Lauf selbst (Planer,
  gleiche Regel in R, Python und Julia): höchstens Zahl der freien Prozessoren (Prozessoren minus andere laufende
  Prozesse gleicher oder höherer Priorität) und der Julia-Threads, so viele, wie
  der freie Speicher trägt, und nur, wenn die Startkosten kleiner sind als der Gewinn (kleine Rechnungen
  bleiben bei einer Aufgabe; mit einem Thread, `julia` ohne `-t`, immer einer).
  Ausgaben, Meldungen, Warnungen und Fehler der Einheiten erscheinen dabei wie mit `cores = 1`, in
  Einheitenreihenfolge.
  Eine feste Zahl verteilt seit 1.6.4 ohne Messung auf so viele Aufgaben (höchstens Zahl der Julia-Threads, mit einem
  Thread nacheinander); Ausgaben, Meldungen, Warnungen und Fehler der Einheiten erscheinen dabei ebenso wie mit
  `cores = 1`; höchstens Zahl der Prozessoren: mehr wird mit einem Hinweis begrenzt.
  Eine feste Zahl lohnt sich bei rechenintensiven Teilrechnungen, sonst `"auto"` (bei leichten Einheiten kann sie langsamer sein als eine Aufgabe).
  Ausgaben, die eigene Funktionen
  (etwa `metrics`) direkt mit `println` oder `print` schreiben, erscheinen bei mehreren Aufgaben in der Reihenfolge,
  in der die Einheiten fertig werden; Warnungen (`@warn`) und SimLevs eigene Meldungen erscheinen in
  Einheitenreihenfolge (R und Python: alle Ausgaben in Einheitenreihenfolge). Das Ergebnis hängt nicht von cores ab.
  Je paralleler Einheit rechnen die Kerne mit höchstens Zahl der Prozessoren / Läufe Threads (mindestens 1).

# Rückgabe
Objekt der Klasse `SimLevParamSearch`, eine Liste mit

- `results`: Tabelle (RFrame) je Punkt: `id`, eine Spalte je Parameter, die Kennzahlen aus `metrics` (`NA` bei
  Fehler) und `error` (Fehlermeldung oder `NA`).
- `returns`: Matrix Tage x Punkte der täglichen zeitgewichteten Renditen als Anteil (aus `result_index()`);
  Zeilen = Tage nach `burn_in` ohne den ersten, Spalten `p1`, `p2`, ... (Nummer = `id`); `NA` für
  fehlgeschlagene Punkte. `nothing` bei `keep_returns = "none"`.
- `dates`: Datum je Zeile von `returns` (Kalender des ersten erfolgreichen Punkts).
- `space`, `params`, `method`, `objective`, `maximize`, `builder`, `sim_args`, `burn_in`: Einstellungen
  (`params` = Parameternamen).
- `metrics`: Namen der Kennzahlen.
- `elapsed`: Laufzeit in Sekunden.

Methoden `print`, `summary`, `plot`; Weiterverarbeitung mit `param_plateau()`, `overfit_pbo()`,
`sharpe_deflated()`, `overfit_walk_forward()`, `param_bootstrap()`.

# Details
Je Punkt wird die Spezifikation in dieser Reihenfolge angewandt: `signal(df)` auf dem vollen Datensatz, dann
`data(df)`, dann `map`, dann das Verwerfen der ersten `burn_in` Zeilen und schließlich `simulation()` mit
`sim_args`, überschrieben durch `args`. Fehler einzelner Punkte brechen die Suche nicht ab, sondern stehen in
`results["error"]`. Das Ergebnis lässt sich auch mit `overfit_reality_check()` und `sharpe_haircut()`
weiterverarbeiten.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 3000
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
d["A"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.011 .* randn(rng, n))
st = create_strategy(A = asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell"))
ps = param_search(d, p -> (strategy = st, signal = df -> signal_sma(df["A"]; n = p["n"], band = p["band"])),
                  param_space(n = [50, 100, 200], band = [0, 2]); burn_in = 250)
println(ps["results"])
```
"""
SimLev.@study function param_search(data, builder_pos = nothing, space_pos = _MISSING; builder = builder_pos, space = space_pos,
                      strategy = nothing, method = nothing, n = 50, constraint = nothing,
                      sim_args = nothing, burn_in = 0, metrics = nothing, objective = "sharpe", maximize = true,
                      keep_returns = nothing, seed = nothing, cores = "auto")
    @nospecialize   # seit 1.6.3: ein Rumpf für alle Typen der Schlüsselwörter (Übersetzung je Aufrufform entfällt)
    SimLev.DataPrep._e5_match_arg(method, ("grid", "random", "lhs"), "param_search", "method")   # seit 1.6.4 (K43 T2-N4) Prüfung vor match.arg (Meldung auswahl)
    method = OF._match_arg(method, ("grid", "random", "lhs"))
    # Text statt Logisch, ohne Alias (E1); logisch vor dem Text prüfen
    keep_returns isa Bool && error("param_search: keep_returns ist \"day\" oder \"none\" (früher TRUE/FALSE).")
    SimLev.DataPrep._e5_match_arg(keep_returns, ("day", "none"), "param_search", "keep_returns")
    keep_returns = OF._match_arg(keep_returns, ("day", "none"))
    keep_ret = keep_returns == "day"
    # einheitliche Eingabeprüfung (seit 1.6.4); data/strategy mit den Meldungen von simulation(), data nur als RFrame
    # (Entscheidung 6; vorher NamedTuple/Dict umgewandelt)
    fn = "param_search"
    (data isa SL.RFrame || data isa SL._Frame) ||
        error("simulation: data muss eine Tabelle mit Spalte 'date' und je Asset einer Kursspalte sein ($(SL.chk_msg("tabelle.formen"))).")
    (data isa SL.RFrame ? SL.nrow(data) : SL._fnrow(data)) == 0 && SL.chk_stop("zeilen_keine", fn, "data")   # seit 1.6.4 (Entscheidung 38)
    builder === nothing || builder isa Function || SL.chk_stop("e2.funktion", fn, "builder")
    space === _MISSING && SL.chk_stop("fehlt", fn, "space")
    (space isa Union{SL.RList,NamedTuple,AbstractDict,AbstractVector,Tuple}) || SL.chk_stop("liste", fn, "space")
    builder === nothing && strategy !== nothing && SL.Sensitivity._e2_check_strategy(strategy)
    n = SL.chk_int1(n, fn, "n")
    SL.chk_max(n, SL.SL_MAX_N, fn, "n")   # seit 1.6.4 (Entscheidungen 16 und 36)
    constraint === nothing || constraint isa Function || SL.chk_stop("e2.funktion", fn, "constraint")
    SL.Bootstrap._is_listlike(sim_args) || SL.chk_stop("liste", fn, "sim_args")
    sim_args = SL.Bootstrap._e2_sim_args(sim_args)
    burn_in = SL.chk_int1(burn_in, fn, "burn_in"; lo = 0)
    metrics === nothing || metrics isa Function || SL.chk_stop("e2.funktion", fn, "metrics")
    objective = SL.chk_name1(objective, fn, "objective")
    maximize = SL.chk_bool1(maximize, fn, "maximize")
    cores = SL.chk_cores(cores, fn)   # seit 1.6.4 höchstens Zahl der Prozessoren, mit Hinweis (Entscheidung 41b)
    sim_args = sim_args === nothing ? SL.RList() : OF._as_rlist(sim_args)
    metrics === nothing && (metrics = SL.Bootstrap.bootstrap_study_metrics)
    # R: unbenannter Vektor -> Meldung von param_space
    space isa Union{Tuple,AbstractVector} && !(space isa AbstractVector{<:Pair}) && error("param_space: alle Dimensionen müssen benannt sein.")
    (space isa SL.RList && SL.inherits(space, "SimLevParamSpace")) || (space = param_space(OF._kv(space)...))
    if builder === nothing
        strategy === nothing && error("param_search: 'builder' oder 'strategy' angeben.")
        fixed = strategy
        SL._sim_check_names(collect(keys(space)), "param_search")   # Dimensionen = Argumente von simulation() bzw. Pfade
        builder = p -> SL.RList("strategy" => fixed, "args" => p)
    end
    sim_run_args = SL._sim_args_set(SL.RList(), sim_args, "param_search")
    # Zufall nur im Versuchsplan (Hauptstrom); die Auswertung je Punkt ist deterministisch
    design = _ps_design(space, method, n, constraint, method == "grid" ? nothing : SL.SLib.main_stream(seed, "param_search"))
    t0 = time()
    function run(i)
        p = _row_list(design, i)
        res = try
            _run_spec(data, _as_spec(builder(p)), sim_run_args, burn_in)
        catch e
            e isa InterruptException && rethrow()
            return (m = nothing, err = OF._cond_msg(e), date = nothing, ret = nothing)
        end
        m = try
            metrics(res)
        catch e
            e isa InterruptException && rethrow()
            nothing
        end
        m === nothing && return (m = nothing, err = "metrics() fehlgeschlagen", date = nothing, ret = nothing)
        mp = _e2_pairs(m)
        if keep_ret
            ix = SL.Withdrawal.result_index(res)
            v = Float64[Float64(e) for e in ix["value"]]
            return (m = mp, err = missing, date = collect(Date, ix["date"]), ret = v[2:end] ./ v[1:end-1] .- 1)
        end
        return (m = mp, err = missing, date = nothing, ret = nothing)
    end
    out = _par_lapply(1:SL.nrow(design), run, cores)
    okm = [o for o in out if o.m !== nothing]
    isempty(okm) && error("param_search: alle Punkte fehlgeschlagen, z. B.: $(out[1].err)")
    # seit 1.6.4 (Entscheidung 43, Regel 28 wie bootstrap_study): Namen der Kennzahlen eindeutig, nicht leer und keine
    # feste Spalte (id, Parameter, error); geprüft nach dem Rechnen, bei jedem cores gleich (R: gleiche Prüfung)
    for o in okm
        SL.chk_kennzahlen(o.m[1], length(o.m[2]), vcat("id", String[string(k) for k in names(design)], "error"), fn)
    end
    mnames = okm[1].m[1]
    objective in mnames || SL.chk_stop("rs.objective", fn, objective, join(mnames, ", "))
    np = length(out)
    M = fill(NA, np, length(mnames))
    for (i, o) in enumerate(out)
        o.m === nothing && continue
        for (j, k) in enumerate(mnames)
            pos = findfirst(==(k), o.m[1])
            M[i, j] = pos === nothing ? NA : o.m[2][pos]
        end
    end
    tab = SL.RFrame("id" => collect(1:np))
    for k in names(design); tab[k] = design[k]; end
    for (j, k) in enumerate(mnames); tab[k] = M[:, j]; end
    tab["error"] = Union{Missing,String}[o.err for o in out]
    R = nothing; dates = nothing
    if keep_ret
        ref = okm[1].date
        dates = ref[2:end]
        Rm = fill(NA, length(dates), np)
        pos = Dict(d => i for (i, d) in enumerate(dates))
        for (i, o) in enumerate(out)
            o.ret === nothing && continue
            for (r, dv) in enumerate(o.date[2:end])
                kk = get(pos, dv, nothing)
                kk === nothing || (Rm[kk, i] = o.ret[r])
            end
        end
        R = SL.NamedMat(Rm; colnames = ["p$j" for j in 1:np])
    end
    return SL.RList("results" => tab, "returns" => R, "dates" => dates, "space" => space,
                    "params" => collect(String, keys(space)), "method" => method, "objective" => objective,
                    "maximize" => maximize, "builder" => builder, "sim_args" => sim_args, "burn_in" => burn_in,
                    "metrics" => mnames, "elapsed" => time() - t0; class = "SimLevParamSearch")
end

# ═════════════════════════════════════════════════════════════════════════════
# Nachbarschaften und Plateau
# ═════════════════════════════════════════════════════════════════════════════

"`match(x, table)` (1-basiert, `nothing` = NA)."
function _match(x, table)
    tab = collect(_vec(table))
    return [findfirst(t -> _same(v, t), tab) for v in x]
end

"`as.numeric(factor(col))` (Stufen sortiert)."
function _factor_codes(col)
    vals = collect(col)
    lev = sort(unique([v for v in vals if !OF._isna(v)]); alg = MergeSort, lt = SimLev.RStats.r_isless)   # Stufen wie factor(): R's Kollation
    pos = Dict(v => i for (i, v) in enumerate(lev))
    return Float64[OF._isna(v) ? NA : Float64(pos[v]) for v in vals]
end

"Euklidische Abstände wie `as.matrix(stats::dist(Z))`."
function _dist_matrix(Z::Matrix{Float64})
    n, nc = size(Z)
    D = zeros(n, n)
    for i in 1:n, j in 1:n
        i == j && continue
        s = 0.0; cnt = 0
        for c in 1:nc
            a = Z[i, c]; b = Z[j, c]
            (isnan(a) || isnan(b)) && continue
            dev = a - b
            isnan(dev) && continue
            s += dev * dev; cnt += 1
        end
        D[i, j] = cnt == 0 ? NA : (cnt != nc ? sqrt(s / (cnt / nc)) : sqrt(s))
    end
    D
end

function _ps_grid_nb(Lm::Matrix{Int}, Lok::BitMatrix, nr::Int, np_::Int, radius)
    out = Vector{Vector{Int}}()
    for i in 1:nr
        ok = Int[]
        for r in 1:nr
            good = true
            for c in 1:np_
                (!Lok[r, c] || !Lok[i, c] || abs(Lm[r, c] - Lm[i, c]) > radius) && (good = false; break)
            end
            good && push!(ok, r)
        end
        push!(out, ok)
    end
    return out
end

# Rasternachbarn über die Zellen der (2 radius + 1)^d Versätze (seit 1.6.4, B-074; R `.ps_neighbours`): dieselben
# Zeilen wie _ps_grid_nb (alle Stufen vorhanden, Abstand <= radius je Dimension), aufsteigend; `nothing`, wenn es
# mindestens so viele Versätze wie Punkte gibt (dann paarweise wie bisher)
function _ps_grid_nb_box(Lm::Matrix{Int}, Lok::BitMatrix, nr::Int, np_::Int, radius, nl::Vector{Int})
    (nr == 0 || np_ == 0 || !(radius isa Real) || !isfinite(radius) || radius < 0) && return nothing
    r = Int(floor(radius))
    (Float64(2r + 1)^np_ > nr || prod(Float64.(nl)) > 2.0^52) && return nothing
    mult = ones(Int, np_)
    for c in 2:np_
        mult[c] = mult[c-1] * nl[c-1]
    end
    okr = [all(c -> Lok[i, c], 1:np_) for i in 1:nr]
    cells = Dict{Int,Vector{Int}}()
    for i in 1:nr
        okr[i] || continue
        key = 0
        for c in 1:np_
            key += (Lm[i, c] - 1) * mult[c]
        end
        push!(get!(() -> Int[], cells, key), i)
    end
    w = 2r + 1
    noff = w^np_
    offs = Matrix{Int}(undef, noff, np_)
    for o in 0:noff-1
        t = o
        for c in 1:np_
            offs[o+1, c] = t % w - r
            t = div(t, w)
        end
    end
    out = [Int[] for _ in 1:nr]
    for i in 1:nr
        okr[i] || continue
        acc = out[i]
        for o in 1:noff
            key = 0; inb = true
            for c in 1:np_
                l = Lm[i, c] + offs[o, c]
                (l < 1 || l > nl[c]) && (inb = false; break)
                key += (l - 1) * mult[c]
            end
            inb || continue
            hit = get(cells, key, nothing)
            hit === nothing || append!(acc, hit)
        end
        sort!(acc)
    end
    return out
end

"Nachbarschaften im Parameterraum (`.ps_neighbours`): je Punkt 1-basierte Zeilennummern."
function _ps_neighbours(x; radius = 1, k = 5)
    params = OF._strs(x["params"])
    res = x["results"]
    nr = SL.nrow(res)
    if x["method"] == "grid"
        L = [_match(res[p], _ps_levels(x["space"][p])) for p in params]
        # seit 1.6.3 Stufen als Int-Matrix mit Merker für fehlende Stufen (bis 1.6.2 Union-Vektoren je Vergleich);
        # gleiche Bedingung, gleiche Reihenfolge der Treffer
        np_ = length(params)
        Lm = zeros(Int, nr, np_); Lok = falses(nr, np_)
        for c in 1:np_, r in 1:nr
            a = L[c][r]
            a === nothing || (Lm[r, c] = a; Lok[r, c] = true)
        end
        nb = _ps_grid_nb_box(Lm, Lok, nr, np_, radius, Int[length(_ps_levels(x["space"][p])) for p in params])
        nb === nothing || return nb
        return _ps_grid_nb(Lm, Lok, nr, np_, radius)
    end
    zs = Vector{Vector{Float64}}()
    for p in params
        col = res[p]
        num = Base.nonmissingtype(eltype(col)) <: Real && !(Base.nonmissingtype(eltype(col)) <: Bool)
        r = OF._rank_avg(num ? OF._tofloat(col) : _factor_codes(col))
        mx = maximum(r); mn = minimum(r)
        push!(zs, mx > mn ? (r .- mn) ./ (mx - mn) : r .* 0)
    end
    Z = nr == 1 ? reshape(Float64[z[1] for z in zs], :, 1) : reduce(hcat, zs)
    D = _dist_matrix(Matrix{Float64}(Z))
    m = min(Int(k), size(Z, 1))
    return [OF._order(D[i, :])[1:m] for i in 1:size(Z, 1)]
end

const _LOWER_BETTER = SimLev.Bootstrap._LOWER_BETTER   # eine Liste (seit 1.6.3)

"""
    param_plateau(x; metric = x.objective, radius = 1, k = 5)

Plateau-Wert: Zielgröße über die Nachbarschaft eines Punkts.

Eine einzelne Spitze im Parameterraum ist oft Zufall. Robuster ist ein Punkt, dessen Nachbarn ebenfalls gut
abschneiden. Beim Raster sind Nachbarn alle Punkte, die sich in jeder Dimension um höchstens `radius`
Rasterstufen unterscheiden; bei Zufallssuche/LHS die `k` nächsten Punkte im rangskalierten Raum.

# Argumente
- `x`: `SimLevParamSearch` aus `param_search()` (gespeicherte Renditen sind nicht nötig).
- `metric`: Name einer Kennzahlspalte von `x["results"]` (Standard: Zielgröße der Suche, `x["objective"]`).
  Seit 1.6.4 muss es eine Spalte von x\$results sein.
- `radius`: Maximaler Abstand in Rasterstufen je Dimension (ganze Zahl, Standard 1); nur `method = "grid"`.
  Seit 1.6.4 eine ganze Zahl ≥ 0.
- `k`: Anzahl Nachbarn inklusive Punkt selbst (ganze Zahl, Standard 5); nur `method = "random"` und `"lhs"`.
  Seit 1.6.4 eine ganze Zahl ≥ 1.

# Rückgabe
Tabelle (RFrame) je Punkt mit `id`, `value` (Kennzahl des Punkts), `plateau_mean` (Mittel der Kennzahl über
die Nachbarschaft, fehlende Werte ignoriert), `plateau_min` (ungünstigster Wert der Nachbarschaft: bei der
Zielgröße je nach `x["maximize"]` das Minimum bzw. Maximum; bei anderen Kennzahlen das Maximum für
`max_drawdown`, `avg_drawdown`, `dd_q50`, `dd_q90`, `ulcer_index` und `longest_drawdown` (kleiner = besser),
sonst das Minimum) und `neighbours` (Anzahl Punkte der Nachbarschaft). Die Einheit entspricht der Kennzahl.

# Details
Rasterstufen sind die Positionen in den Rasterwerten jeder Dimension des Suchraums. Im rangskalierten Raum
wird jede Dimension über ihre Ränge auf 0 bis 1 abgebildet (nicht numerische Parameter über ihre Faktorcodes)
und der euklidische Abstand verwendet. Der Punkt selbst gehört immer zu seiner Nachbarschaft.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 3000
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
d["A"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.011 .* randn(rng, n))
st = create_strategy(A = asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell"))
ps = param_search(d, p -> (strategy = st, signal = df -> signal_sma(df["A"]; n = p["n"], band = p["band"])),
                  param_space(n = [50, 100, 200], band = [0, 2]); burn_in = 250)
println(param_plateau(ps))
```
"""
function param_plateau(x; metric = nothing, radius = 1, k = 5)
    (x isa SL.RList && SL.inherits(x, "SimLevParamSearch")) || SimLev.chk_stop("klasse", "param_plateau", "x", "param_search()")
    metric === nothing && (metric = x["objective"])
    # seit 1.6.4: metric als Spalte der Ergebnisse, radius und k als ganze Zahlen
    metric = SL.chk_name1(metric, "param_plateau", "metric")
    metric in names(x["results"]) || SL.chk_stop("e2.spalte_von", "param_plateau", "metric", "x\$results")
    radius = SL.chk_int1(radius, "param_plateau", "radius"; lo = 0)
    k = SL.chk_int1(k, "param_plateau", "k")
    tab = x["results"]
    v = OF._tofloat(tab[metric])
    nb = _ps_neighbours(x; radius = radius, k = k)
    lower_better = metric == x["objective"] ? !(get(x, "maximize", nothing) === true) : metric in _LOWER_BETTER
    function worst(a)
        a = filter(!isnan, a)
        isempty(a) && return lower_better ? -Inf : Inf
        return lower_better ? maximum(a) : minimum(a)
    end
    return SL.RFrame("id" => tab["id"], "value" => v,
                     "plateau_mean" => Float64[SL.r_mean(v[j]; na_rm = true) for j in nb],
                     "plateau_min" => Float64[worst(v[j]) for j in nb],
                     "neighbours" => Int[length(j) for j in nb])
end

# ═════════════════════════════════════════════════════════════════════════════
# summary / print / plot
# ═════════════════════════════════════════════════════════════════════════════

_select(df::SL.RFrame, cols) = SL.RFrame((c => df[c] for c in cols)...; nrow = SL.nrow(df))

function _summary_ps(object; top = 10, kw...)
    tab = copy(object["results"])
    obj = String(object["objective"])
    pl = param_plateau(object)
    tab["plateau"] = pl["plateau_mean"]
    mx = get(object, "maximize", nothing) === true
    ord = OF._order(OF._tofloat(tab[obj]); decreasing = mx)
    ordp = OF._order(OF._tofloat(tab["plateau"]); decreasing = mx)
    std = ["cagr", "max_drawdown", "sharpe", "ulcer_index", "trades"]
    params = OF._strs(object["params"])
    cols = vcat("id", params, [c for c in std if haskey(tab, c)], obj in std ? String[] : [obj], "plateau")
    topt = _select(SL.rows(tab, ord[1:min(Int(top), length(ord))]), cols)
    nf = haskey(tab, "error") ? count(e -> !OF._isna(e), tab["error"]) : 0
    return SL.RList("top" => topt, "best" => SL.rows(tab, ord[1:1]), "best_plateau" => SL.rows(tab, ordp[1:1]),
                    "n" => SL.nrow(tab), "n_failed" => nf, "objective" => obj, "method" => object["method"],
                    "params" => params, "elapsed" => get(object, "elapsed", nothing);
                    class = "summary.SimLevParamSearch")
end

_isnumcol(c) = (T = Base.nonmissingtype(eltype(c)); T <: Real && !(T <: Bool))
_fmt1(v) = v === missing ? "NA" : OF._formatv(v isa AbstractString ? v : [v])[1]

function _print_summary_ps(io::IO, x)
    print(io, OF._spf("SimLev-Parametersuche (%s): %d Punkte, %d fehlgeschlagen, %.1f s\n", x["method"], x["n"],
                      x["n_failed"], Float64(x["elapsed"])))
    print(io, "Zielgröße: $(x["objective"])\n\n")
    y = copy(x["top"])
    params = OF._strs(x["params"])
    for k in ("cagr", "max_drawdown")
        haskey(y, k) && (y[k] = OF._spfv("%.2f %%", 100 .* OF._tofloat(y[k])))
    end
    for k in names(y)
        k in vcat("id", params, "cagr", "max_drawdown") && continue
        _isnumcol(y[k]) && (y[k] = OF._spfv("%.3f", OF._tofloat(y[k])))
    end
    print(io, OF._print_df(y), "\n")
    (haskey(y, "cagr") || x["objective"] == "cagr") && print(io, "cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts\n")
    fmtp(r) = join(["$p = $(_fmt1(r[p][1]))" for p in params], ", ")
    b = x["best"]; bp = x["best_plateau"]; obj = x["objective"]
    print(io, OF._spf("\nBester Punkt:   #%d (%s), %s = %.3f\n", Int(b["id"][1]), fmtp(b), obj, OF._f64(b[obj][1])))
    print(io, OF._spf("Bestes Plateau: #%d (%s), %s = %.3f, Nachbarschaft = %.3f\n", Int(bp["id"][1]), fmtp(bp), obj,
                      OF._f64(bp[obj][1]), OF._f64(bp["plateau"][1])))
    nothing
end

"R `print.SimLevParamSearch(x, ...)`: druckt `summary(x, ...)`; Schlüsselwörter gehen an summary (z. B. `top`)."
function _print_ps(io::IO, x; kw...)
    _print_summary_ps(io, _summary_ps(x; kw...))
    return nothing
end

function _plot_ps(x; metric = nothing, params = nothing, fun = maximum, kw...)
    tab = x["results"]
    metric === nothing && (metric = x["objective"])
    params = params === nothing ? OF._strs(x["params"])[1:min(2, end)] : OF._strs(params)
    agg(v) = (w = filter(isfinite, v); isempty(w) ? NA : fun(w))
    vals = OF._tofloat(tab[metric])
    # seit 1.6.4 (Entscheidung 40): ohne endlichen Wert der Zielgröße ein Fehler wie in R (bis 1.6.3 ein leeres Bild)
    any(isfinite, vals) || SL.chk_stop("grafik_leer", "plot", metric)
    f = _res_fig(700, 460)
    if length(params) == 1
        g = tab[params[1]]
        lev = sort(unique(collect(g)); alg = MergeSort, lt = SimLev.RStats.r_isless)
        a = Float64[agg(vals[[_same(e, l) for e in g]]) for l in lev]
        xs = Float64[_is_num(l) ? Float64(l) : i for (i, l) in enumerate(lev)]
        p = _res_panel(f, 70, 40, 600, 360, _res_range(xs), _res_range(a); title = "$metric nach $(params[1])",
                       xlab = params[1], ylab = metric)
        _res_line!(f, p, xs, a); _res_points!(f, p, xs, a)
        return (_res_finish(f), SL.RList("profile" => SL.RFrame("x" => lev, "value" => a)))
    end
    if x["method"] != "grid"
        xs = OF._tofloat(tab[params[1]]); ys = OF._tofloat(tab[params[2]])
        # seit 1.6.4 wie R (B-063, Entscheidung 99): 64 Stufen über range(v), Stufe round(1 + 63 (v - lo) /
        # max(hi - lo, 1e-12)), begrenzt auf 1 … 64 (bis 1.6.3 stetig über mindestens [0, 1]); NaN grau wie bisher
        fin = filter(!isnan, vals)
        lo, hi = isempty(fin) ? (0.0, 1.0) : (minimum(fin), maximum(fin))
        pal = _res_pal()
        cols = [isnan(v) ? "#cccccc" : pal[Int(clamp(round(1 + 63 * (v - lo) / max(hi - lo, 1e-12)), 1.0, 64.0))] for v in vals]
        p = _res_panel(f, 70, 40, 600, 360, _res_range(xs), _res_range(ys); title = "$metric (Farbe; blau = hoch)",
                       xlab = params[1], ylab = params[2])
        _res_points!(f, p, xs, ys; color = cols, r = 5)
        return (_res_finish(f), SL.RList("scatter" => SL.RFrame("x" => xs, "y" => ys, "value" => vals)))
    end
    g1 = tab[params[1]]; g2 = tab[params[2]]
    l1 = sort(unique(collect(g1)); alg = MergeSort, lt = SimLev.RStats.r_isless)
    l2 = sort(unique(collect(g2)); alg = MergeSort, lt = SimLev.RStats.r_isless)
    M = fill(NA, length(l1), length(l2))
    for (i, a) in enumerate(l1), (j, b) in enumerate(l2)
        sel = [_same(u, a) && _same(w, b) for (u, w) in zip(g1, g2)]
        any(sel) && (M[i, j] = agg(vals[sel]))
    end
    fin = filter(!isnan, vec(M))
    lo, hi = isempty(fin) ? (0.0, 1.0) : extrema(fin)
    p = _res_panel(f, 70, 40, 600, 360, (0.5, length(l1) + 0.5), (0.5, length(l2) + 0.5); title = "$metric (blau = hoch)",
                   xlab = params[1], ylab = params[2], xticks = collect(1.0:length(l1)), xticklabels = OF._formatv(l1),
                   yticks = collect(1.0:length(l2)), yticklabels = OF._formatv(l2), grid = false)
    sc = metric in ("cagr", "ttwror", "max_drawdown", "avg_drawdown") ? 100 : 1
    # seit 1.6.4 wie R's image() mit 64 Farben (B-063): zlim = range(M), bei Breite 0 erweitert, Stufe
    # floor(63 z + 0.5) (bis 1.6.3 stetig)
    pal = _res_pal()
    zl0, zl1 = lo, hi
    zl1 - zl0 == 0 && ((zl0, zl1) = zl0 == 0 ? (-1.0, 1.0) : (zl0 - 0.4 * abs(zl0), zl0 + 0.4 * abs(zl0)))
    ci = Int[]; cj = Int[]
    for i in eachindex(l1), j in eachindex(l2)
        v = M[i, j]
        isnan(v) && continue
        push!(ci, i); push!(cj, j)
        zi = floor(Int, 63 * ((v - zl0) / (zl1 - zl0)) + 0.5)
        _res_rect!(f, p, i - 0.5, j - 0.5, i + 0.5, j + 0.5; fill = 0 <= zi < 64 ? pal[zi+1] : "none")
        length(M) <= 300 && _res_text!(f, _res_tx(p, i), _res_ty(p, j) + 4, OF._spf(sc == 100 ? "%.1f" : "%.2f", sc * v); size = 9)
    end
    # gezeichnete Zellen (Zielgröße unskaliert): x = Stufe von params[1], y = Stufe von params[2]
    data = SL.RList("heatmap" => SL.RFrame("x" => l1[ci], "y" => l2[cj], "value" => Float64[M[i, j] for (i, j) in zip(ci, cj)]))
    return (_res_finish(f), data)
end

function __init__()
    SL.register_print!("SimLevParamSpace", _print_space)
    SL.register_print!("SimLevParamSearch", _print_ps)
    SL.register_summary!("SimLevParamSearch", _summary_ps)
    SL.register_print!("summary.SimLevParamSearch", _print_summary_ps)
    SL.register_plot!("SimLevParamSearch", SL._plot_method(_plot_ps, "SimLevParamSearch"))
end

end # module
