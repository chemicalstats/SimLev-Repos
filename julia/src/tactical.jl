# Tactical – taktische Allokation über zeitvariable Zielgewichte (r/R/tactical.R)
#
# Gewichts-Erzeuger (liefern ein `SimLevWeights`: `RFrame` mit `date` und je
# Anlage einer Spalte Zielgewicht, Klasse `["SimLevWeights", "data.frame"]`,
# Attribute in `attrs(w)`):
#   tactical_rules()          geordnete Bedingungen → Zielportfolio, Rückfall
#   tactical_rotation()       Momentum-Rotation: Top-N, Dual Momentum, Canary-Schutz
#   target_volatility()       Zielvolatilität (Moreira & Muir 2017)
#   conditional_volatility()  nur in extremen Volatilitätsphasen skalieren
#   glidepath()               Gewichte zeitlich zwischen zwei Allokationen
#   blend_weights()           Kern-Satellit: Mischung mehrerer Gewichtsreihen
#   signal_state()            Kauf-/Verkaufssignale → dauerhafter Zustand
#   momentum_score()          Momentum-Score je Anlage
# Ausführung:
#   tactical_simulation()     übersetzt die Gewichte in event_col/event_weight
#                             von simulation()
#
# Bedingungen als Text in tactical_rules(): Ausdruck in R-Syntax, ausgewertet
# vom gemeinsamen Auswerter `SimLev.RExpr` (R's Vorrang einschließlich des
# schwach bindenden einstelligen `!`, dreiwertige NA-Logik, `%in%`, `%%`,
# Funktionen wie abs, sqrt, exp, log, round, is.na, ifelse, pmin, pmax …).
# Variablen: Spalten von `data`, danach `env` (Standard `Main`); unbekannte
# Funktionen werden in `env` gesucht.
module Tactical

import ..SimLev
using ..SimLev: RList, RFrame, RVector, NamedMat, NA, isna_strict, F80
using Dates

export signal_state, momentum_score, tactical_rules, tactical_rotation, target_volatility, conditional_volatility,
       glidepath, blend_weights, tactical_simulation, print_SimLevWeights, plot_SimLevWeights

# ═══════════════════════════════════════════════════════════════════════════
# R-Hilfen
# ═══════════════════════════════════════════════════════════════════════════

_match_arg(arg, choices) = SimLev.DataPrep._match_arg(arg, choices)
_sprintf(fmt, args...) = (s = SimLev.RFmt.sprintf(fmt, args...); s isa AbstractString ? String(s) : String(first(s)))
_to_date(x, what = "date") = SimLev.DataPrep._to_date(x, what)
_fill_na(v, method = "locf"; keep_leading = false) =
    Float64[Float64(z) for z in SimLev.Backcast._fill_na(Float64[Float64(z) for z in v], method; keep_leading = keep_leading)]
_message(msg) = SimLev.DataPrep.message(msg)
_warn(msg) = (@warn msg; nothing)

function _fmt1(x)
    r = SimLev.RFmt.format(x)
    r isa AbstractString ? [String(r)] : String[String(s) for s in r]
end

_ldsum(x) = SimLev.r_sum(x)
_sqrt(x::Float64) = x < 0 ? NaN : sqrt(x)
_dnum(d::Date) = Float64(Dates.value(d))
_dnum(::Missing) = NA

_unique(v) = (out = similar(v, 0); for s in v; s in out || push!(out, s); end; out)
_setdiff(a, b) = _unique([x for x in a if !(x in b)])

"`findInterval(x, vec)` für aufsteigendes `vec`: Anzahl der Elemente von vec <= x."
_find_interval(x::AbstractVector, v::AbstractVector) = Int[searchsortedlast(v, xi) for xi in x]

function _rowsums(A::AbstractMatrix{Float64})
    n, p = size(A)
    out = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        s = F80(0.0)
        for j in 1:p
            s = s + SimLev._ldq(A[i, j])
        end
        out[i] = Float64(s)
    end
    out
end
function _rowmeans(A::AbstractMatrix{Float64})
    n, p = size(A)
    out = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        s = F80(0.0)
        for j in 1:p
            s = s + SimLev._ldq(A[i, j])
        end
        out[i] = Float64(s / F80(p))
    end
    out
end
function _colmeans(A::AbstractMatrix{Float64})
    n, p = size(A)
    out = Vector{Float64}(undef, p)
    for j in 1:p
        s = F80(0.0)
        @inbounds for i in 1:n
            s = s + SimLev._ldq(A[i, j])
        end
        out[j] = n == 0 ? NaN : Float64(s / F80(n))
    end
    out
end
_mean_lgl(x) = SimLev.r_mean_int(Int[v ? 1 : 0 for v in x])

# R's pmin/pmax mit NA-Weitergabe (Skalar a, Vektorwert b)
_pmin(a::Float64, b::Float64) = isnan(b) ? b : isnan(a) ? a : (b < a ? b : a)
_pmax(a::Float64, b::Float64) = isnan(b) ? b : isnan(a) ? a : (b > a ? b : a)

"Spalten-/Elementzugriff auf data.frame-artige Eingaben."
_df_names(x::RFrame) = names(x)
_df_names(x::NamedTuple) = String[String(k) for k in keys(x)]
_df_names(x::AbstractDict) = String[string(k) for k in keys(x)]
_df_names(x) = String[]
_col(x::RFrame, k) = x[String(k)]
_col(x::NamedTuple, k) = getfield(x, Symbol(k))
_col(x::AbstractDict, k) = haskey(x, k) ? x[k] : x[Symbol(k)]
_has(x, k) = String(k) in _df_names(x)
_nrow(x::RFrame) = SimLev.nrow(x)
_nrow(x) = (nm = _df_names(x); isempty(nm) ? 0 : length(_col(x, nm[1])))

"`as.numeric` einer Spalte (missing → NA)."
_num(v) = Float64[z === missing || z === nothing ? NA : Float64(z) for z in (v isa RVector ? v.values : v)]

_isna(v) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))

"Benannter Vektor → (Namen oder `nothing`, Float64-Werte)."
function _named(x)
    x === nothing && return (nothing, Float64[])
    f(v) = _isna(v) ? NA : Float64(v)
    x isa RVector && return (x.names === nothing ? nothing : copy(x.names), Float64[f(v) for v in x.values])
    x isa Union{AbstractDict,NamedTuple} && return (String[string(k) for k in keys(x)], Float64[f(v) for v in values(x)])
    x isa Pair && return ([string(x.first)], [f(x.second)])
    (x isa AbstractVector && !isempty(x) && all(p -> p isa Pair, x)) &&
        return (String[string(p.first) for p in x], Float64[f(p.second) for p in x])
    x isa Real && return (nothing, [f(x)])
    (nothing, Float64[f(v) for v in x])
end
function _is_numeric_named(x)
    x isa RVector && return x.names !== nothing && eltype(x.values) <: Union{Real,Missing} && !(eltype(x.values) <: Bool)
    x isa Union{AbstractDict,NamedTuple} && return length(x) > 0 && all(v -> v isa Real && !(v isa Bool), values(x))
    x isa Pair && return x.second isa Real
    (x isa AbstractVector && !isempty(x) && all(p -> p isa Pair && p.second isa Real, x)) && return true
    false
end

"Zeichenvektor (`nothing` → leer)."
_chr_vec(x) = x === nothing ? String[] : x isa Union{AbstractString,Symbol} ? [String(x)] : String[string(v) for v in x]

"`as.integer(x)` (NA bei Unlesbarem); Vektor."
function _as_int(x)
    vals = x isa Union{AbstractVector,Tuple} ? collect(x) : [x]
    out = Union{Int,Missing}[]
    for v in vals
        if v === nothing || v === missing
            push!(out, missing)
        elseif v isa Bool
            push!(out, Int(v))
        else
            f = v isa AbstractString ? tryparse(Float64, strip(v)) : (v isa Real ? Float64(v) : nothing)
            push!(out, (f === nothing || !isfinite(f) || abs(f) >= 2147483648) ? missing : Int(trunc(f)))
        end
    end
    out
end

_isweights(x) = x isa RFrame && SimLev.inherits(x, "SimLevWeights")

"Gewichtsmatrix einer SimLevWeights (ohne `date`)."
_wmat(w::RFrame, cols = names(w)[2:end]) =
    isempty(cols) ? zeros(SimLev.nrow(w), 0) : reduce(hcat, [_num(w[c]) for c in cols])

# ═══════════════════════════════════════════════════════════════════════════
# SimLevWeights
# ═══════════════════════════════════════════════════════════════════════════

"""
    _as_weights(dates, W, source = "")

`.as_weights`: Gewichts-Frame bauen und prüfen (nicht endliche und negative
Werte → 0, Zeilen auf Summe 1); `W` Matrix, `NamedMat` oder `RFrame`.
"""
function _as_weights(dates, W, source = "")
    if W isa RFrame
        return _as_weights_m(dates, reduce(hcat, [_num(W[c]) for c in names(W)]), names(W), source)
    elseif W isa NamedMat
        return _as_weights_m(dates, Matrix{Float64}(W.data), W.colnames, source)
    end
    M = W isa AbstractVector ? reshape(_num(W), :, 1) : Float64[_isna(v) ? NA : Float64(v) for v in W]
    _as_weights_m(dates, M, nothing, source)
end

function _as_weights_m(dates, M::AbstractMatrix, cols, source = "")
    M = Matrix{Float64}(M)
    M[.!isfinite.(M)] .= 0.0
    M[M .< 0] .= 0.0
    s = _rowsums(M)
    bad = count(<=(0), s)
    bad > 0 && error("Gewichte: $bad Zeilen ohne positive Gewichte.")
    M = M ./ s
    cols === nothing && (cols = size(M, 2) > 1 ? ["X$j" for j in 1:size(M, 2)] : ["W"])
    d = _to_date(dates, "date")
    out = RFrame(vcat("date", String[String(c) for c in cols]), AbstractVector[d, (M[:, j] for j in 1:size(M, 2))...];
                 class = ["SimLevWeights", "data.frame"])
    SimLev.attrs(out)["source"] = source
    out
end

"""
    _period_last(dates, every)

`.period_last`: Zeilennummern (1-basiert) der letzten Zeile jeder Periode
(`"day"`, `"week"` = ISO-Woche, `"month"`, `"quarter"`, `"year"`).
"""
function _period_last(dates, every)
    every in ("day", "week", "month", "quarter", "year") || error("every: 'day', 'week', 'month', 'quarter' oder 'year'.")
    d = dates isa AbstractVector{Date} ? dates : _to_date(dates, "date")
    n = length(d)
    every == "day" && return collect(1:n)
    n == 0 && return Int[]
    key = Vector{Int}(undef, n)
    for i in 1:n
        z = d[i]
        if every == "week"
            th = z + Day(4 - Dates.dayofweek(z))
            key[i] = Dates.year(th) * 100 + Dates.week(z)
        elseif every == "month"
            key[i] = Dates.year(z) * 12 + Dates.month(z)
        elseif every == "quarter"
            key[i] = Dates.year(z) * 4 + div(Dates.month(z) - 1, 3)
        else
            key[i] = Dates.year(z)
        end
    end
    Int[i for i in 1:n if i == n || key[i+1] != key[i]]
end

"`.hold_rows` auf einer Matrix: Werte an Entscheidungszeilen bis zur nächsten halten (davor NA)."
function _hold_rows_m(n::Integer, rows, M::AbstractMatrix)
    idx = _find_interval(collect(1:n), collect(rows))
    out = fill(NA, n, size(M, 2))
    for i in 1:n
        idx[i] > 0 && (out[i, :] = M[idx[i], :])
    end
    out
end

"""
    _hold_rows(n, rows, M)

`.hold_rows`: Werte der Zeilen von `M` an den Entscheidungszeilen `rows` bis
zur nächsten Entscheidung halten (`NamedMat` mit den Spaltennamen von `M`).
"""
function _hold_rows(n, rows, M)
    cn = M isa NamedMat ? M.colnames : M isa RFrame ? names(M) : nothing
    A = M isa NamedMat ? Float64.(M.data) : M isa RFrame ? reduce(hcat, [_num(M[c]) for c in names(M)]) : Float64.(M)
    out = _hold_rows_m(Int(n), Int[Int(r) for r in (rows isa Real ? [rows] : rows)], A)
    cn === nothing ? out : NamedMat(out; colnames = cn)
end

# ═══════════════════════════════════════════════════════════════════════════
# signal_state, momentum_score
# ═══════════════════════════════════════════════════════════════════════════

_sig_part(s, k) = s isa NamedTuple ? getfield(s, Symbol(k)) : s isa AbstractDict ? (haskey(s, k) ? s[k] : s[Symbol(k)]) :
                  getproperty(s, Symbol(k))
_has_buy(w) = (w isa RList && haskey(w, "buy") && w["buy"] !== nothing) ||
              (w isa NamedTuple && haskey(w, :buy) && w.buy !== nothing) ||
              (w isa AbstractDict && !(w isa RList) && (haskey(w, "buy") || haskey(w, :buy)))

"Logischer Vektor mit NA → (Werte, NA-Maske)."
function _lgl(v)
    a = v isa Union{AbstractVector,Tuple} ? collect(v) : [v]
    na = Bool[x === missing || x === nothing || (x isa AbstractFloat && isnan(x)) for x in a]
    val = Bool[na[i] ? false : Bool(a[i] != 0) for i in eachindex(a)]
    (val, na)
end

"""
    signal_state(signal; initial = false)

Signale in einen dauerhaften Zustand übersetzen: `true` ab einem Kaufsignal
bis zum nächsten Verkaufssignal; Zeilen mit beiden Signalen `false` (oder
beiden `true`, oder NA) ändern den Zustand nicht. `signal`: `RList`/
`NamedTuple`/`Dict` mit `buy` und `sell`.
"""
function signal_state(signal; initial = false)
    b, bna = _lgl(_sig_part(signal, "buy"))
    s, sna = _lgl(_sig_part(signal, "sell"))
    n = length(b)
    if length(s) != n
        s = [s[mod1(i, length(s))] for i in 1:n]
        sna = [sna[mod1(i, length(sna))] for i in 1:n]
    end
    ev = Int[(bna[i] || sna[i]) ? 0 : (b[i] && !s[i]) ? 1 : (s[i] && !b[i]) ? -1 : 0 for i in 1:n]
    idx = findall(!=(0), ev)
    st = fill(Bool(initial), n)
    if !isempty(idx)
        k = _find_interval(collect(1:n), idx)
        for i in 1:n
            k[i] > 0 && (st[i] = ev[idx[k[i]]] == 1)
        end
    end
    st
end

"Rückblickzeilen (1-basiert, 0 = keine) je Rückblick in Monaten."
function _momentum_back(d::Vector{Date}, lookbacks)
    dv = Float64[_dnum(z) for z in d]
    back = Vector{Vector{Int}}()
    for m in lookbacks
        mi = _as_int(m)[1]
        tg = Vector{Float64}(undef, length(d))
        for i in eachindex(d)
            y = Dates.year(d[i]); mon = Dates.month(d[i]) - 1; mday = Dates.day(d[i])
            mo = mon - mi
            y2 = y + fld(mo, 12); mo2 = mod(mo, 12)
            first_ = Date(y2, mo2 + 1, 1)
            nxt = Date(y2 + div(mo2 + 1, 12), mod(mo2 + 1, 12) + 1, 1)
            tg[i] = _dnum(first_) + min(mday, Dates.value(nxt - first_)) - 1
        end
        push!(back, _find_interval(tg, dv))
    end
    back
end

"""
    momentum_score(data, assets; lookbacks = [1, 3, 6, 12], type = "average")

Momentum-Score: mittlere Rendite über mehrere Rückblicke (Kalendermonate, auf
das Monatsende begrenzt) je Anlage; `type = "13612w"` gewichtet
(12 r₁ + 4 r₃ + 2 r₆ + r₁₂) / 4. Ergebnis `NamedMat` Zeilen × `assets` (NA,
solange die Historie zu kurz ist).
"""
function momentum_score(data, assets; lookbacks = [1, 3, 6, 12], type = nothing)
    data = SimLev.as_rframe(data)
    type = _match_arg(type, ["average", "13612w"])
    d = _to_date(_has(data, "date") ? _col(data, "date") : nothing, "momentum_score: data\$date")
    n = length(d)
    assets = _chr_vec(assets)
    miss = _setdiff(assets, _df_names(data))
    isempty(miss) || error("momentum_score: Kursspalte(n) fehlen: " * join(miss, ", "))
    type == "13612w" && (lookbacks = [1, 3, 6, 12])
    lb = lookbacks isa Union{AbstractVector,Tuple} ? collect(lookbacks) : [lookbacks]
    back = _momentum_back(collect(Date, d), lb)
    S = Matrix{Float64}(undef, n, length(assets))
    for (j, a) in enumerate(assets)
        x = _fill_na(_num(_col(data, a)), "locf"; keep_leading = true)
        R = Matrix{Float64}(undef, n, length(back))
        for (c, k) in enumerate(back)
            for i in 1:n
                R[i, c] = k[i] > 0 ? x[i] / x[k[i]] - 1 : NA
            end
        end
        if type == "13612w"
            for i in 1:n
                S[i, j] = (12 * R[i, 1] + 4 * R[i, 2] + 2 * R[i, 3] + R[i, 4]) / 4
            end
        else
            S[:, j] = _rowmeans(R)
        end
    end
    NamedMat(S; colnames = assets)
end

# ═══════════════════════════════════════════════════════════════════════════
# tactical_rules
# ═══════════════════════════════════════════════════════════════════════════

"Bedingung als Text in R-Syntax auswerten (`SimLev.RExpr`): Spalten von `data`, dann Variablen aus `env`."
function _eval_when(s::AbstractString, data, env)
    cols = data isa Union{RFrame,NamedTuple,AbstractDict} ? data :
           Dict{String,Any}(c => _col(data, c) for c in _df_names(data))
    SimLev.RExpr.eval_r(s, cols; env = env)
end

"`as.logical(v)` mit NA → FALSE."
function _as_logical(v)
    a = v isa Union{AbstractVector,Tuple} ? collect(v isa RVector ? v.values : v) : [v]
    out = falses(length(a))
    for (i, x) in enumerate(a)
        (x === nothing || x === missing) && continue
        if x isa AbstractString
            out[i] = x in ("TRUE", "true", "T", "True")
        elseif x isa Real
            (x isa AbstractFloat && isnan(x)) && continue
            out[i] = x != 0
        end
    end
    collect(out)
end

_rget(r, k) = r isa NamedTuple ? (haskey(r, Symbol(k)) ? getfield(r, Symbol(k)) : nothing) :
              r isa AbstractDict ? (haskey(r, k) ? r[k] : haskey(r, Symbol(k)) ? r[Symbol(k)] : nothing) :
              getproperty(r, Symbol(k))

"""
    tactical_rules(data, rules, default; env = Main)

Regelbasierte taktische Allokation: geordnete Bedingungen wählen je Zeile ein
Zielportfolio, die erste zutreffende Regel gewinnt, sonst gilt `default`.
`rules`: Vektor von Regeln (`RList`, `NamedTuple` oder `Dict` mit `when` und
`weights`). `when`: logischer Vektor der Länge `nrow(data)`, Text (Ausdruck
in R-Syntax, siehe Modulkopf; Spalten von `data` als Variablen, dann
Variablen aus `env` – ein Modul oder eine Zuordnung Name → Wert),
`list(buy, sell)` (über [`signal_state`](@ref)) oder Funktion `data -> Vektor`;
NA gilt als `false`. Ergebnis `SimLevWeights` mit `attrs` `regime` (Nummer der
aktiven Regel, 0 = `default`) und `source`.
"""
function tactical_rules(data, rules, default; env = Main)
    data = SimLev.as_rframe(data)
    n = _nrow(data)
    rules = rules === nothing ? Any[] : collect(rules)
    nm_all = String[]
    for r in rules
        nm, _ = _named(_rget(r, "weights"))
        nm === nothing || append!(nm_all, nm)
    end
    dn, _ = _named(default)
    assets = _unique(vcat(nm_all, dn === nothing ? String[] : dn))
    cond = falses(n, length(rules))
    for (j, r) in enumerate(rules)
        w = _rget(r, "when")
        v = if w isa AbstractString
            _eval_when(w, data, env)
        elseif _has_buy(w)
            signal_state(w)
        elseif w isa Function
            w(data)
        else
            w
        end
        v = _as_logical(v)
        length(v) == n || error("Bedingung hat nicht die Länge nrow(data).")
        cond[:, j] = v
    end
    regime = Int[(k = findfirst(@view cond[i, :]); k === nothing ? 0 : k) for i in 1:n]
    function vec_(w)
        nm, vals = _named(w)
        v = zeros(length(assets))
        nm === nothing && return v
        for (k, x) in zip(nm, vals)
            v[findfirst(==(k), assets)] = x
        end
        v
    end
    P = vcat(reshape(vec_(default), 1, :), (reshape(vec_(_rget(r, "weights")), 1, :) for r in rules)...)
    W = P[regime .+ 1, :]
    W = reshape(W, n, length(assets))
    out = _as_weights_m(_col(data, "date"), W, assets, "rules")
    SimLev.attrs(out)["regime"] = regime
    out
end

# ═══════════════════════════════════════════════════════════════════════════
# tactical_rotation
# ═══════════════════════════════════════════════════════════════════════════

"""
    tactical_rotation(data, assets; top = 1, safe = nothing, absolute = true, canary = nothing,
                      breadth = nothing, lookbacks = [1, 3, 6, 12], type = "average",
                      every = "month", weighting = "equal")

Momentum-Rotation, Dual Momentum und Canary-Schutz (Keller & Keuning). An
jedem Entscheidungstermin (Periodenende) die besten `top` Anlagen nach
[`momentum_score`](@ref); absolutes Momentum schichtet negative Plätze in die
beste sichere Anlage um, Canary-Anlagen mit negativem Score verschieben den
Anteil min(1, b/breadth) in `safe`. Ergebnis `SimLevWeights` mit `attrs`
`scores` und `decision_rows`.
"""
function tactical_rotation(data, assets; top = 1, safe = nothing, absolute = true, canary = nothing, breadth = nothing,
                           lookbacks = [1, 3, 6, 12], type = nothing, every = nothing, weighting = nothing)
    data = SimLev.as_rframe(data)
    type = _match_arg(type, ["average", "13612w"])
    every = _match_arg(every, ["month", "week", "quarter"])
    weighting = _match_arg(weighting, ["equal", "inverse_vol"])
    assets = _chr_vec(assets); safe = _chr_vec(safe); canary = _chr_vec(canary)
    (Bool(absolute) || !isempty(canary)) && isempty(safe) && error("absolute bzw. canary brauchen eine sichere Anlage 'safe'.")
    tv = _as_int(top)
    if length(tv) != 1 || tv[1] === missing || tv[1] < 1 || tv[1] > length(assets)
        ft = length(tv) == 1 && tv[1] === missing ? "NA" : join(_fmt1(Float64[t === missing ? NA : Float64(t) for t in tv]), " ")
        length(tv) == 1 && tv[1] !== missing && (ft = string(tv[1]))
        error("top muss zwischen 1 und der Anzahl der Anlagen in assets ($(length(assets))) liegen (ist: $ft).")
    end
    top = tv[1]
    if !isempty(canary) && breadth !== nothing
        bv = breadth isa Union{AbstractVector,Tuple} ? Float64[_isna(b) ? NA : Float64(b) for b in breadth] : [Float64(breadth)]
        if length(bv) != 1 || isnan(bv[1]) || bv[1] < 1
            error("breadth muss mindestens 1 sein (Anzahl Canary-Anlagen mit negativem Score für vollen Schutz; ist: $(join(_fmt1(bv), " "))).")
        end
    end
    allc = _unique(vcat(assets, safe, canary))
    Sm = momentum_score(data, allc; lookbacks = lookbacks, type = type)
    S = Sm.data
    ci = Dict(a => j for (j, a) in enumerate(allc))
    d = _to_date(_col(data, "date"), "data\$date")
    n = length(d)
    rows = _period_last(d, every)
    ja = [ci[a] for a in assets]
    rows = Int[i for i in rows if count(isfinite, S[i, ja]) >= top]
    isempty(rows) && error("Zu kurze Historie für den Rückblick.")
    out_assets = _unique(vcat(assets, safe))
    oi = Dict(a => j for (j, a) in enumerate(out_assets))
    vol = nothing
    if weighting == "inverse_vol"
        vol = Matrix{Float64}(undef, n, length(assets))
        for (j, a) in enumerate(assets)
            x = _fill_na(_num(_col(data, a)), "locf"; keep_leading = true)
            lx = SimLev.RLibm.log(x)
            r = vcat(NA, lx[2:end] .- lx[1:end-1])
            r0 = Float64[isnan(v) ? 0.0 : v for v in r]
            rm = Float64[Float64(v) for v in SimLev.Signals._roll_mean(r0 .* r0, 63)]
            vol[:, j] = Float64[isnan(v) ? v : sqrt(max(v, 1e-12)) for v in rm]
        end
    end
    vi = Dict(a => j for (j, a) in enumerate(assets))
    M = zeros(length(rows), length(out_assets))
    for (ri, i) in enumerate(rows)
        w = zeros(length(out_assets))
        sc = S[i, ja]
        ok = [k for k in eachindex(assets) if isfinite(sc[k])]
        ordk = sort(ok; alg = Base.Sort.MergeSort, lt = (p, q) -> sc[p] > sc[q])
        pick = [assets[k] for k in ordk][1:min(top, length(ok))]
        best_safe = nothing
        if !isempty(safe)
            ss = S[i, [ci[a] for a in safe]]
            if !any(isfinite, ss)
                best_safe = safe[1]
            else
                kk = 0
                for k in eachindex(ss)
                    isnan(ss[k]) && continue
                    (kk == 0 || ss[k] > ss[kk]) && (kk = k)
                end
                best_safe = safe[kk]
            end
        end
        pw = if weighting == "equal"
            fill(1 / length(pick), length(pick))
        else
            iv = 1 ./ vol[i, [vi[a] for a in pick]]
            iv ./ _ldsum(iv)
        end
        cash = 0.0
        if !isempty(canary)
            cv = S[i, [ci[a] for a in canary]]
            b = count(v -> !isnan(v) && v < 0, cv)
            B = breadth === nothing ? Float64(length(canary)) : Float64(breadth isa AbstractVector ? breadth[1] : breadth)
            cash = min(1.0, b / B)
        end
        for (k, p) in enumerate(pick)
            share = pw[k] * (1 - cash)
            spk = S[i, ci[p]]
            if Bool(absolute) && isfinite(spk) && spk < 0
                w[oi[best_safe]] += share
            else
                w[oi[p]] += share
            end
        end
        cash > 0 && (w[oi[best_safe]] += cash)
        M[ri, :] = w
    end
    H = _hold_rows_m(n, rows, M)
    first_ = rows[1]
    H[1:(first_-1), :] .= 0.0
    first_ > 1 && (H[1:(first_-1), oi[isempty(safe) ? assets[1] : safe[1]]] .= 1.0)
    out = _as_weights_m(d, H, out_assets, "rotation")
    SimLev.attrs(out)["scores"] = Sm
    SimLev.attrs(out)["decision_rows"] = rows
    out
end

# ═══════════════════════════════════════════════════════════════════════════
# Zielvolatilität, bedingte Volatilitätssteuerung
# ═══════════════════════════════════════════════════════════════════════════

"`.risk_vol`: Volatilität des Risikoportfolios."
function _risk_vol(data, weights, safe, window, ppy)
    d = _to_date(_col(data, "date"), "data\$date")
    n = length(d)
    if !_isweights(weights)
        _is_numeric_named(weights) || error("weights: SimLevWeights oder benannter Gewichtsvektor erwartet.")
        nm, vals = _named(weights)
        weights = _as_weights_m(d, repeat(reshape(vals, 1, :), n, 1), nm, "static")
    end
    _has(data, safe) || error("Sichere Anlage '$safe' fehlt in data.")
    risky = _setdiff(names(weights)[2:end], [safe])
    miss = _setdiff(risky, _df_names(data))
    isempty(miss) || error("Kursspalte(n) aus weights fehlen in data: " * join(miss, ", "))
    wd = _to_date(weights["date"], "date")
    (SimLev.nrow(weights) != n || !isequal(Float64[_dnum(z) for z in wd], Float64[_dnum(z) for z in d])) &&
        error("weights passt nicht zu data (andere Daten); Gewichte aus demselben Datensatz erzeugen.")
    Wr = _wmat(weights, risky)
    R = zeros(n, length(risky))
    for (j, a) in enumerate(risky)
        x = _fill_na(_num(_col(data, a)), "locf"; keep_leading = true)
        for i in 2:n
            R[i, j] = x[i] / x[i-1] - 1
        end
    end
    R[.!isfinite.(R)] .= 0.0
    rs = _rowsums(Wr)
    Wn = Wr ./ Float64[v > 0 ? v : 1.0 for v in rs]
    pr = n > 0 ? vcat(0.0, _rowsums(Wn[1:end-1, :] .* R[2:end, :])) : Float64[]
    move = abs.(pr) .> 0
    if ppy === nothing
        span = n > 0 ? Float64(Dates.value(d[n] - d[1])) / 365.25 : NaN
        ppy = count(move) / max(span, 1e-9)
    end
    ppy = Float64(ppy)
    vol = fill(NA, n)
    idx = findall(move)
    window = Int(window)
    if length(idx) > window
        v = Float64[Float64(z) for z in SimLev.Signals._roll_var(pr[idx], window)]
        vol[idx] = Float64[isnan(z) ? z : sqrt(max(z, 0.0) * ppy) for z in v]
    end
    (d = d, n = n, risky = risky, Wr = Wr, rs = rs, move = move, ppy = ppy, vol_move = vol,
     vol = _fill_na(vol, "locf"; keep_leading = true))
end

"`.risk_weights`: Risikoteil mit Exposure skalieren, Rest in die sichere Anlage."
function _risk_weights(rv, expo, safe, source)
    W = hcat(rv.Wr .* expo, 1 .- expo .* rv.rs)
    W[W .< 0] .= 0.0
    _as_weights_m(rv.d, W, vcat(rv.risky, safe), source)
end

_g(x) = _sprintf("%g", Float64(x))

"""
    target_volatility(data, weights, safe; target = 10, window = 63, max_exposure = 1,
                      every = "month", ppy = nothing)

Zielvolatilität: Risikoanteil `min(max_exposure, (target/100) / vol)` an den
Terminen von `every`, Rest in `safe`. `weights`: `SimLevWeights` oder
benannter Gewichtsvektor (statisch). Ergebnis `SimLevWeights` mit `attrs`
`exposure` und `volatility`.
"""
function target_volatility(data, weights, safe; target = 10, window = 63, max_exposure = 1, every = nothing, ppy = nothing)
    data = SimLev.as_rframe(data)
    every = _match_arg(every, ["month", "week", "day", "quarter"])
    max_exposure > 1 && error("max_exposure > 1 wäre Kredit; die Engine kennt keine Kreditaufnahme (Hebel über Hebelprodukte abbilden).")
    target < 1 && _warn("target = $(_g(target)) ist sehr klein; target ist in Prozent p. a. (10 = 10 %), nicht als Anteil.")
    rv = _risk_vol(data, weights, safe, window, ppy)
    n = rv.n; vol = rv.vol
    rows = _period_last(rv.d, every)
    rows = rows[isfinite.(vol[rows])]
    isempty(rows) && error("Zu kurze Historie für das Volatilitätsfenster.")
    expo_r = Float64[_pmin(Float64(max_exposure), Float64(target) / 100 / _pmax(1e-6, v)) for v in vol[rows]]
    k = _find_interval(collect(1:n), rows)
    expo = Float64[k[i] > 0 ? expo_r[k[i]] : 0.0 for i in 1:n]
    out = _risk_weights(rv, expo, safe, "target_volatility")
    SimLev.attrs(out)["exposure"] = expo
    SimLev.attrs(out)["volatility"] = vol
    out
end

_quantile7(x, p) = (q = SimLev.RStats.quantile(Float64.(x), Float64(p); names = false, type = 7);
                    q isa Real ? Float64(q) : Float64(first(q isa RVector ? q.values : q)))

"""
    conditional_volatility(data, weights, safe; base = 1, upper = 0.8, lower = 0.2,
                           target = nothing, window = 63, min_exposure = 0, max_exposure = 1,
                           min_history = 3, scaling = "inverse", high_exposure = nothing,
                           low_exposure = nothing, every = "month", ppy = nothing)

Bedingte Volatilitätssteuerung (Bongaerts, Kang & van Dijk 2020): nur wenn
die geschätzte Volatilität über dem `upper`- bzw. unter dem `lower`-Quantil
(expandierend, monatlich, ohne Blick in die Zukunft) liegt, wird der
Risikoanteil gesenkt bzw. erhöht; dazwischen gilt `base`. Ergebnis
`SimLevWeights` mit `attrs` `exposure`, `volatility`, `state`, `thresholds`.
"""
function conditional_volatility(data, weights, safe; base = 1, upper = 0.8, lower = 0.2, target = nothing, window = 63,
                                min_exposure = 0, max_exposure = 1, min_history = 3, scaling = nothing,
                                high_exposure = nothing, low_exposure = nothing, every = nothing, ppy = nothing)
    data = SimLev.as_rframe(data)
    every = _match_arg(every, ["month", "week", "day", "quarter"])
    scaling = _match_arg(scaling, ["inverse", "fixed"])
    max_exposure > 1 && error("max_exposure > 1 wäre Kredit; die Engine kennt keine Kreditaufnahme (Hebel über Hebelprodukte abbilden).")
    (base < 0 || base > max_exposure) && error("base muss zwischen 0 und max_exposure liegen.")
    (min_exposure < 0 || min_exposure > base) && error("min_exposure muss zwischen 0 und base liegen.")
    (upper > 0 && upper < 1) || error("upper muss zwischen 0 und 1 liegen.")
    lower !== nothing && !(lower > 0 && lower < upper) && error("lower muss zwischen 0 und upper liegen.")
    if scaling == "fixed"
        (high_exposure === nothing || (lower !== nothing && low_exposure === nothing)) &&
            error("scaling = 'fixed' braucht high_exposure (und low_exposure, wenn lower gesetzt ist).")
        high_exposure > base && error("high_exposure darf nicht über base liegen.")
        lower !== nothing && (low_exposure < base || low_exposure > max_exposure) &&
            error("low_exposure muss zwischen base und max_exposure liegen.")
    end
    target !== nothing && target < 1 &&
        _warn("target = $(_g(target)) ist sehr klein; target ist in Prozent p. a. (10 = 10 %), nicht als Anteil.")
    lower !== nothing && base >= max_exposure &&
        _message("Hinweis: base = max_exposure; in ruhigen Phasen kann nicht hochskaliert werden (ohne Kredit). base < max_exposure wählen oder lower = NULL setzen.")
    rv = _risk_vol(data, weights, safe, window, ppy)
    d = rv.d; n = rv.n; vol = rv.vol; vm = rv.vol_move
    dv = Float64[_dnum(z) for z in d]
    grid = _period_last(d, "month")
    fin = isfinite.(vm)
    ok = findall(fin)
    first_ok = isempty(ok) ? dv[n] + 1 : dv[ok[1]]
    cs = SimLev.r_cumsum(Float64[fin[i] ? vm[i] : 0.0 for i in 1:n])
    cn = cumsum(Int.(fin))
    th = fill(NA, length(grid), 3)
    for (gi, g) in enumerate(grid)
        (isempty(ok) || (dv[g] - first_ok) / 365.25 < min_history) && continue
        v = vm[ok[ok .<= g]]
        th[gi, 1] = lower === nothing ? NA : _quantile7(v, lower)
        th[gi, 2] = _quantile7(v, upper)
        th[gi, 3] = target === nothing ? cs[g] / cn[g] : Float64(target) / 100
    end
    thresholds = RFrame("date" => d[grid], "lower" => th[:, 1], "upper" => th[:, 2], "target" => th[:, 3])
    if all(isnan, th[:, 2])
        yrs = isempty(ok) ? 0.0 : (dv[n] - first_ok) / 365.25
        _warn(_sprintf("min_history = %g Jahre ist länger als die verfügbare Volatilitätshistorie (%.1f Jahre); es wird nie gesteuert (Risikoanteil = base).",
                       Float64(min_history), yrs))
    end
    kg = _find_interval(collect(1:n), grid)
    cur(j) = Float64[kg[i] > 0 ? th[kg[i], j] : NA for i in 1:n]
    lo_t = cur(1); up_t = cur(2); tg = cur(3)
    state = zeros(Int, n)
    for i in 1:n
        (isfinite(up_t[i]) && isfinite(vol[i]) && vol[i] > up_t[i]) && (state[i] = 1)
        lower !== nothing && isfinite(lo_t[i]) && isfinite(vol[i]) && vol[i] < lo_t[i] && (state[i] = -1)
    end
    rows = _period_last(d, every)
    rows = rows[isfinite.(vol[rows])]
    isempty(rows) && error("Zu kurze Historie für das Volatilitätsfenster.")
    e_r = fill(Float64(base), length(rows))
    s_r = state[rows]
    if scaling == "inverse"
        ratio = Float64[tg[i] / _pmax(1e-6, vol[i]) for i in rows]
        for q in eachindex(rows)
            s_r[q] == 1 && (e_r[q] = base * _pmin(1.0, ratio[q]))
            s_r[q] == -1 && (e_r[q] = base * _pmax(1.0, ratio[q]))
        end
    else
        e_r[s_r .== 1] .= high_exposure
        lower !== nothing && (e_r[s_r .== -1] .= low_exposure)
    end
    e_r = Float64[_pmin(Float64(max_exposure), _pmax(Float64(min_exposure), v)) for v in e_r]
    k = _find_interval(collect(1:n), rows)
    expo = Float64[k[i] > 0 ? e_r[k[i]] : Float64(base) for i in 1:n]
    out = _risk_weights(rv, expo, safe, "conditional_volatility")
    at = SimLev.attrs(out)
    at["exposure"] = expo
    at["volatility"] = vol
    at["state"] = Int[k[i] > 0 ? s_r[k[i]] : 0 for i in 1:n]
    at["thresholds"] = thresholds
    out
end

# ═══════════════════════════════════════════════════════════════════════════
# glidepath, blend_weights
# ═══════════════════════════════════════════════════════════════════════════

"""
    glidepath(data, from_, to; start = nothing, end_ = nothing, every = "year")

Glidepath zwischen zwei Allokationen (R: `from`, `to`, `end`): stufenweise
lineare Bewegung von `from_` nach `to`; eine Stufe beginnt in der ersten
Zeile und an der letzten Zeile jeder Periode von `every` (`"year"`,
`"quarter"`, `"month"`), Gewicht `(1 - p) from + p to` mit dem Zeitanteil `p`
zwischen `start` und `end_`. `data`: `RFrame` mit `date` oder Datumsvektor.
"""
function glidepath(data, from_, to; start = nothing, end_ = nothing, every = nothing)
    data = SimLev.as_rframe(data)
    every = _match_arg(every, ["year", "quarter", "month"])
    src = data isa RFrame ? data["date"] : data isa Union{NamedTuple,AbstractDict} ? _col(data, "date") : data
    d = _to_date(src, "glidepath: Datum")
    fn, fv = _named(from_)
    tn, tv = _named(to)
    a = _unique(vcat(fn === nothing ? String[] : fn, tn === nothing ? String[] : tn))
    f = zeros(length(a)); t = zeros(length(a))
    fn === nothing || for (k, x) in zip(fn, fv); f[findfirst(==(k), a)] = x; end
    tn === nothing || for (k, x) in zip(tn, tv); t[findfirst(==(k), a)] = x; end
    s = _to_date(start === nothing ? d[1] : start, "start")[1]
    e = _to_date(end_ === nothing ? d[end] : end_, "end")[1]
    e < s && error("glidepath: end ($(Dates.format(e, "yyyy-mm-dd"))) liegt vor start ($(Dates.format(s, "yyyy-mm-dd"))); für den umgekehrten Weg from und to tauschen.")
    rows = _unique(vcat(1, _period_last(d, every)))
    sd = _dnum(s); ed = _dnum(e)
    frac = if e > s
        Float64[min(1.0, max(0.0, (_dnum(d[r]) - sd) / (ed - sd))) for r in rows]
    else
        Float64[_dnum(d[r]) >= sd ? 1.0 : 0.0 for r in rows]
    end
    M = zeros(length(frac), length(a))
    for (i, p) in enumerate(frac)
        M[i, :] = (1 - p) .* f .+ p .* t
    end
    H = _hold_rows_m(length(d), rows, M)
    _as_weights_m(d, H, a, "glidepath")
end

"""
    blend_weights(ws...; shares = nothing)

Gewichtsreihen mischen (Kern-Satellit): je Zeile und Anlage
Σₖ sharesₖ · wₖ, dann auf Summe 1 normiert; `ws` sind `SimLevWeights` mit
identischer Spalte `date`, `shares` Anteile je Reihe (Standard gleich).
"""
function blend_weights(ws...; shares = nothing)
    ws = collect(ws)
    (isempty(ws) || !all(_isweights, ws)) && error("blend_weights: ... muss aus SimLevWeights bestehen.")
    shares === nothing && (shares = fill(1 / length(ws), length(ws)))
    sh = shares isa Union{AbstractVector,Tuple} ? Float64[_isna(v) ? NA : Float64(v) for v in shares] : [Float64(shares)]
    if length(sh) != length(ws) || any(isnan, sh) || any(<(0), sh) || _ldsum(sh) <= 0
        error("blend_weights: shares braucht $(length(ws)) nichtnegative Anteile (einen je Gewichtsreihe, z. B. c(0.7, 0.3)); erhalten: $(join(_fmt1(sh), ", ")).")
    end
    d = _to_date(ws[1]["date"], "date")
    dn = Float64[_dnum(z) for z in d]
    for w in ws
        dw = Float64[_dnum(z) for z in _to_date(w["date"], "date")]
        isequal(dw, dn) || error("blend_weights: unterschiedliche Daten.")
    end
    a = _unique(reduce(vcat, [names(w)[2:end] for w in ws]))
    W = zeros(length(d), length(a))
    for (k, w) in enumerate(ws)
        for nm in names(w)[2:end]
            j = findfirst(==(nm), a)
            W[:, j] = W[:, j] .+ sh[k] .* _num(w[nm])
        end
    end
    _as_weights_m(d, W, a, "blend")
end

# ═══════════════════════════════════════════════════════════════════════════
# print / plot
# ═══════════════════════════════════════════════════════════════════════════

_strip_nl(s) = endswith(s, "\n") ? s[1:prevind(s, lastindex(s))] : s

"`print.SimLevWeights`: Mittel, Minimum, Maximum und letztes Gewicht in Prozent, Zahl der Wechsel."
function print_SimLevWeights(io::IO, x)
    cols = names(x)[2:end]
    W = _wmat(x, cols)
    nr = size(W, 1)
    ch = nr > 1 ? _rowsums(abs.(W[2:end, :] .- W[1:end-1, :])) .> 1e-9 : falses(0)
    src = get(SimLev.attrs(x), "source", nothing)
    dts = _to_date(x["date"], "date")
    fd(z) = z === missing ? "NA" : Dates.format(z, "yyyy-mm-dd")
    print(io, "SimLev-Zielgewichte ($(src === nothing ? "" : src)): $nr Tage, $(fd(dts[1])) bis $(fd(dts[nr])), $(count(ch)) Wechsel\n")
    cmin(c) = (v = W[:, c]; any(isnan, v) ? v[findfirst(isnan, v)] : minimum(v))
    cmax(c) = (v = W[:, c]; any(isnan, v) ? v[findfirst(isnan, v)] : maximum(v))
    m = vcat(reshape(_colmeans(W), 1, :), reshape([cmin(c) for c in 1:size(W, 2)], 1, :),
             reshape([cmax(c) for c in 1:size(W, 2)], 1, :), reshape(W[nr, :], 1, :))
    mr = reshape(Float64[Float64(v) for v in SimLev.RFmt.r_round(100 .* m, 1)], size(m))
    pm = SimLev.RFmt.print_matrix(NamedMat(mr; rownames = ["Mittel", "Min", "Max", "Zuletzt"], colnames = cols))
    print(io, _strip_nl(String(pm)), "\n")
    st = get(SimLev.attrs(x), "state", nothing)
    if st !== nothing
        print(io, _sprintf("\nVolatilitätsphasen (Anteil der Tage): niedrig %.0f %%, normal %.0f %%, hoch %.0f %%\n",
                           100 * _mean_lgl(st .== -1), 100 * _mean_lgl(st .== 0), 100 * _mean_lgl(st .== 1)))
    end
    nothing
end
print_SimLevWeights(x) = print_SimLevWeights(stdout, x)

# Farbverlauf wie colorRampPalette(c(...))(n)
function _ramp(n)
    base = [(0x2C, 0x6E, 0x9B), (0x3E, 0x8E, 0x5A), (0xC4, 0x9A, 0x2C), (0xB5, 0x56, 0x2B), (0x8A, 0x5B, 0xA8), (0x4A, 0x4A, 0x4A)]
    n == 1 && return ["#2C6E9B"]
    out = String[]
    for i in 0:(n-1)
        p = i / (n - 1) * (length(base) - 1)
        k = min(Int(floor(p)), length(base) - 2)
        f = p - k
        c = [round(Int, (1 - f) * base[k+1][j] + f * base[k+2][j]) for j in 1:3]
        push!(out, "#" * join(string(v; base = 16, pad = 2) for v in c))
    end
    out
end
_c(v) = string(round(v; digits = 2))
_xml(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

"""
    plot_SimLevWeights(x; file = nothing, width = 900, height = 420, main = "Zielgewichte")

`plot.SimLevWeights`: Zielgewichte als gestapelte Flächen über der Zeit (SVG,
`SimLevDashboard`). Mit `file` wird das SVG gespeichert.
"""
function plot_SimLevWeights(x; file = nothing, width = 900, height = 420, main = "Zielgewichte")
    cols = names(x)[2:end]
    W = _wmat(x, cols)
    d = _to_date(x["date"], "date")
    t = Float64[_dnum(z) for z in d]
    L, R, T, B = 60.0, 140.0, 40.0, 40.0
    pw = width - L - R; ph = height - T - B
    t0, t1 = minimum(t), maximum(t)
    t1 == t0 && (t1 = t0 + 1)
    px(v) = L + pw * (v - t0) / (t1 - t0)
    py(v) = T + ph * (1 - v)
    cl = _ramp(length(cols))
    io = IOBuffer()
    println(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\" font-family=\"sans-serif\">")
    println(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>")
    println(io, "<text x=\"$(L+pw/2)\" y=\"22\" text-anchor=\"middle\" font-size=\"15\" font-weight=\"bold\">$(_xml(main))</text>")
    cum = zeros(length(t))
    for j in eachindex(cols)
        lo = copy(cum)
        cum .+= Float64[isfinite(v) ? v : 0.0 for v in W[:, j]]
        up = join(("$(_c(px(t[i]))),$(_c(py(cum[i])))" for i in eachindex(t)), " ")
        dn = join(("$(_c(px(t[i]))),$(_c(py(lo[i])))" for i in reverse(eachindex(t))), " ")
        println(io, "<polygon points=\"$up $dn\" fill=\"$(cl[j])\" stroke=\"none\"/>")
    end
    for v in 0:0.25:1
        println(io, "<text x=\"$(L-6)\" y=\"$(_c(py(v)+4))\" text-anchor=\"end\" font-size=\"11\">$v</text>")
    end
    years = unique(Dates.year.(d))
    for y in years
        z = _dnum(Date(y, 1, 1))
        (z < t0 || z > t1) && continue
        println(io, "<text x=\"$(_c(px(z)))\" y=\"$(T+ph+16)\" text-anchor=\"middle\" font-size=\"11\">$y</text>")
    end
    println(io, "<text x=\"16\" y=\"$(T+ph/2)\" font-size=\"12\" transform=\"rotate(-90 16 $(T+ph/2))\" text-anchor=\"middle\">Gewicht</text>")
    for (j, c) in enumerate(cols)
        yy = T + (j - 1) * 18
        println(io, "<rect x=\"$(L+pw+12)\" y=\"$yy\" width=\"12\" height=\"12\" fill=\"$(cl[j])\"/>")
        println(io, "<text x=\"$(L+pw+30)\" y=\"$(yy+10)\" font-size=\"11\">$(_xml(c))</text>")
    end
    println(io, "</svg>")
    svg = String(take!(io))
    file === nothing || write(String(file), svg)
    SimLev.SimLevDashboard(svg)
end

# ═══════════════════════════════════════════════════════════════════════════
# tactical_simulation
# ═══════════════════════════════════════════════════════════════════════════

"""
    tactical_simulation(data, weights; rebalance = "switch", tolerance = nothing,
                        tolerance_type = "absolute", lag = 1, asset_args = (;), kwargs...)

Taktische Allokation simulieren: übersetzt die Zielgewichte in
Ereignis-Rebalancing von `simulation()` (`event_col`, `event_mode =
"replace"`, `event_weight`); gehandelt wird an Wechseln (nach `lag` Zeilen,
mit `attrs(data)["filled"]` nur Zeilen mit echten Kursen) und an
Pflegeterminen `rebalance`, optional mit Toleranzband `tolerance` (Prozent).
`asset_args` geht über `strategy_from_weights` an `asset_config`, weitere
Argumente an `simulation()`. Ergebnis wie in R ein `SimLevResult` mit dem
zusätzlichen Element `tactical` (`RList` mit `weights`, `events`,
`switches`, `lag`, `rebalance`; Zugriff `res.tactical` bzw.
`res["tactical"]`).
"""
function tactical_simulation(data, weights; rebalance = nothing, tolerance = nothing, tolerance_type = nothing, lag = 1,
                             asset_args = NamedTuple(), kwargs...)
    data = SimLev.as_rframe(data)
    rebalance = _match_arg(rebalance, ["switch", "month", "quarter", "year"])
    tolerance_type = _match_arg(tolerance_type, ["absolute", "relative"])
    _isweights(weights) || error("weights muss ein SimLevWeights sein.")
    sim_args = Dict{Symbol,Any}(k => v for (k, v) in kwargs)
    bad = [String(k) for (k, _) in kwargs if String(k) in ("event_col", "event_mode", "event_weight", "balance_mode", "balance_thresh")]
    isempty(bad) || error("tactical_simulation steuert $(join(_unique(bad), ", ")) selbst.")
    assets = names(weights)[2:end]
    miss = _setdiff(assets, _df_names(data))
    isempty(miss) || error("Kursspalten fehlen: " * join(miss, ", "))
    d = _to_date(_col(data, "date"), "data\$date")
    wd = Float64[_dnum(z) for z in _to_date(weights["date"], "date")]
    pos = Dict{Float64,Int}()
    for (i, v) in enumerate(wd)
        isnan(v) || haskey(pos, v) || (pos[v] = i)
    end
    k = Int[get(pos, _dnum(z), 0) for z in d]
    Wall = _wmat(weights, assets)
    n = length(d)
    W = Matrix{Float64}(undef, n, length(assets))
    for i in 1:n, j in eachindex(assets)
        W[i, j] = k[i] > 0 ? Wall[k[i], j] : NA
    end
    for j in eachindex(assets)
        W[:, j] = _fill_na(W[:, j], "locf"; keep_leading = false)
    end
    lv = _as_int(lag)
    (length(lv) != 1 || lv[1] === missing || lv[1] < 0) && error("lag muss eine ganze Zahl >= 0 sein.")
    lag = lv[1]
    fl = data isa RFrame ? get(SimLev.attrs(data), "filled", nothing) : nothing
    if lag > 0
        real = trues(n)
        if fl isa AbstractMatrix && size(fl, 1) == n
            fcols = fl isa NamedMat ? fl.colnames : nothing
            fa = fcols === nothing ? String[] : [a for a in assets if a in fcols]
            if !isempty(fa)
                F = Float64[Bool(fl[i, findfirst(==(a), fcols)]) ? 1.0 : 0.0 for i in 1:n, a in fa]
                real = _rowsums(F) .== 0
            end
        end
        tr = findall(real)
        isempty(tr) && (tr = collect(1:n))
        p2 = _find_interval(collect(1:n), tr) .+ lag
        eff = Int[p <= length(tr) ? tr[p] : n + 1 for p in p2]
        W = W[max.(_find_interval(collect(1:n), eff), 1), :]
    end
    change = n > 0 ? vcat(false, _rowsums(abs.(W[2:end, :] .- W[1:end-1, :])) .> 1e-10) : Bool[]
    ev = copy(change)
    rebalance != "switch" && (ev[_period_last(d, rebalance)] .= true)
    if get(sim_args, :dca_mode, nothing) === true
        cal = collect(d[1]:Day(1):d[n])
        gs(key, def) = (v = get(sim_args, key, nothing); v === nothing ? def : v)
        flg = SimLev.calculate_dates_flags(true, gs(:dca_span, 1), gs(:dca_unit, "month"), get(sim_args, :dca_days, nothing),
                                           cal; value = gs(:dca_value, 1), anchor = gs(:dca_anchor, "start"),
                                           start_date = get(sim_args, :dca_start, nothing), skip_start = gs(:dca_skip, false),
                                           liquidate = gs(:liquidate, false))
        flg = Bool[f != 0 for f in flg]
        dd = Float64[_dnum(z) for z in d]
        j = _find_interval(Float64[_dnum(z) for z in cal[flg]] .- 1e-9, dd) .+ 1
        ev[j[j .<= n]] .= true
    end
    n > 0 && (ev[1] = false)
    df = copy(data)
    fl === nothing || (SimLev.attrs(df)["filled"] = fl)
    wcols = [".tw_" * a for a in assets]
    for (j, c) in enumerate(wcols)
        df[c] = W[:, j]
    end
    df[".tev"] = ev
    w0 = Float64[max(v, 1e-9) for v in W[1, :]]
    w0 = w0 ./ _ldsum(w0)
    aa = asset_args isa NamedTuple ? pairs(asset_args) : asset_args isa AbstractDict ? (Symbol(k) => v for (k, v) in asset_args) :
         (Symbol(p.first) => p.second for p in asset_args)
    st = SimLev.DataPrep.strategy_from_weights(RVector(w0; names = assets); aa...)
    args = Dict{Symbol,Any}(:event_col => ".tev", :event_mode => "replace",
                            :event_weight => RList((a => c for (a, c) in zip(assets, wcols))...),
                            :balance_thresh => tolerance, :balance_thresh_type => tolerance_type)
    merge!(args, sim_args)
    res = SimLev.simulation(df, st; args...)
    tw = _as_weights_m(d, W, assets, get(SimLev.attrs(weights), "source", nothing))
    tac = RList("weights" => tw, "events" => d[ev], "switches" => count(change), "lag" => lag, "rebalance" => rebalance)
    res["tactical"] = tac
    res
end

function __init__()
    SimLev.register_print!("SimLevWeights", print_SimLevWeights)
    SimLev.register_plot!("SimLevWeights", SimLev._plot_method(plot_SimLevWeights, "SimLevWeights"))
end

end # module
