# Tactical – taktische Allokation über zeitvariable Zielgewichte (r/R/tactical.R)
#
# Gewichts-Erzeuger (liefern ein `SimLevWeights`: `RFrame` mit `date` und je
# Anlage einer Spalte Zielgewicht, Klasse `["SimLevWeights", "data.frame"]`,
# Attribute in `attrs(w)`):
#   tactical_rules()          geordnete Bedingungen → Zielportfolio, Rückfall
#   tactical_rotation()       Momentum-Rotation: Top-N, Dual Momentum, Canary-Schutz
#   tactical_target_volatility()       Zielvolatilität (Moreira & Muir 2017)
#   tactical_conditional_volatility()  nur in extremen Volatilitätsphasen skalieren
#   tactical_glidepath()               Gewichte zeitlich zwischen zwei Allokationen
#   tactical_blend()           Kern-Satellit: Mischung mehrerer Gewichtsreihen
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
using ..SimLev: _alloc_c, _alloc_ramp, _esc
using ..SimLev: RList, RFrame, RVector, NamedMat, NA
using ..SimLev: _sprintf, _ldsum, _colmeans, _rowsums, _mean_lgl, _unique, _setdiff, _isna, _strip_nl,
                _pmax, _pmin   # util.jl, r/rnum.jl
using Dates
using ..SimLev: chk_bool1, chk_date1, chk_df, chk_int1, chk_max, chk_name1, chk_nofactor, chk_num1, chk_stop   # pruefen.jl
_dp() = SimLev.DataPrep   # E5-Hilfen (data_prep.jl, seit 1.6.4)

export signal_state, momentum_score, tactical_rules, tactical_rotation, tactical_target_volatility, tactical_conditional_volatility,
       tactical_glidepath, tactical_blend, tactical_simulation, print_SimLevWeights, plot_SimLevWeights

# ═══════════════════════════════════════════════════════════════════════════
# R-Hilfen
# ═══════════════════════════════════════════════════════════════════════════

_to_date(x, what = "date") = SimLev.DataPrep._to_date(x, what)
_fill_na(v, method = "locf"; keep_leading = false) =
    _f64copy(SimLev.Backcast._fill_na(_f64copy(v), method; keep_leading = keep_leading))
"Float64-Kopie (Funktionsgrenze: die Schleife wird für den Typ von `v` übersetzt; seit 1.6.1)."
_f64copy(v) = Float64[Float64(z) for z in v]
_message(msg) = SimLev.DataPrep.message(msg)
_warn(msg) = (@warn msg; nothing)

_dnum(d::Date) = Float64(Dates.value(d))
_dnum(::Missing) = NA


"`findInterval(x, vec)` für aufsteigendes `vec`: Anzahl der Elemente von vec <= x."
_find_interval(x::AbstractVector, v::AbstractVector) = Int[searchsortedlast(v, xi) for xi in x]

# Zeilen- und Spaltensummen/-mittel wie R in long double über die C-Kerne (core/slc_rbase.cpp)
_rowmeans(A::AbstractMatrix{Float64}) = SimLev._ld_rowsums(A; mean = true)

"Spalten-/Elementzugriff auf data.frame-artige Eingaben."
const _df_names = SimLev.DataPrep._names   # gleiche vier Methoden (seit 1.6.4 eine Fassung)
_col(x::RFrame, k) = x[String(k)]
_col(x::NamedTuple, k) = getfield(x, Symbol(k))
_col(x::AbstractDict, k) = haskey(x, k) ? x[k] : x[Symbol(k)]
_has(x, k) = String(k) in _df_names(x)
_nrow(x::RFrame) = SimLev.nrow(x)
_nrow(x) = (nm = _df_names(x); isempty(nm) ? 0 : length(_col(x, nm[1])))

"`as.numeric` einer Spalte (missing → NA)."
_num(v) = Float64[z === missing || z === nothing ? NA : Float64(z) for z in (v isa RVector ? v.values : v)]


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

"R-Zeichenvektor? Text, Vektor mit Elementtyp Text (auch `Union{Missing,String}`, nur aus `missing`) oder mit mindestens
einem Text (`missing`/`nothing` daneben gilt als `NA_character_`)."
function _is_chr(v)
    v isa AbstractString && return true
    v isa Union{AbstractVector,Tuple} || return false
    T = v isa AbstractVector ? Base.nonnothingtype(nonmissingtype(eltype(v))) : Union{}
    return (T !== Union{} && T <: AbstractString) || any(x -> x isa AbstractString, v)
end

"Logischer Vektor mit NA → (Werte, NA-Maske)."
function _lgl(v)
    a = v isa Union{AbstractVector,Tuple} ? collect(v) : [v]
    na = Bool[x === missing || x === nothing || (x isa AbstractFloat && isnan(x)) for x in a]
    val = Bool[na[i] ? false : Bool(a[i] != 0) for i in eachindex(a)]
    (val, na)
end

# Schlüssel einer Liste (RList, Dict, NamedTuple) als Text; `nothing` für andere Typen
_keys_str(r) = r isa NamedTuple ? [String(k) for k in keys(r)] : r isa AbstractDict ? [string(k) for k in keys(r)] : nothing

"Länge eines Signalvektors (Wahrheitswerte oder Zahlen 0/1, NA erlaubt, eindimensional) oder `nothing`."
function _e5_sigvec_len(@nospecialize(v))
    (v isa SimLev.RFmt.RFactor || v isa AbstractString || v === nothing) && return nothing
    v isa RVector && (v = v.values)
    a = v isa Union{Bool,Real,Missing} ? Any[v] : v isa AbstractVector ? v : nothing
    a === nothing && return nothing
    # Textvektor (auch nur aus missing, z. B. Union{Missing,String}[missing], seit 1.6.4 K43 T3-N10 auch mit nothing im
    # Elementtyp wie _is_chr) wie R NA_character_: kein Signal
    T = Base.nonnothingtype(nonmissingtype(eltype(a)))
    T !== Union{} && T <: AbstractString && return nothing
    for e in a
        (e === missing || e isa Bool) && continue
        (e isa Real && (isnan(Float64(e)) || Float64(e) == 0 || Float64(e) == 1)) && continue
        return nothing
    end
    return length(a)
end

"Signal `(buy, sell)`: beide vorhanden, je Wahrheitswerte oder 0/1 (NA erlaubt), gleich lang (R `.e5_signal`; seit 1.6.4)."
function _e5_signal(@nospecialize(signal), fn, i = nothing)
    ks = _keys_str(signal)
    ok = ks !== nothing && "buy" in ks && "sell" in ks
    if ok
        lb = _e5_sigvec_len(_sig_part(signal, "buy")); ls = _e5_sigvec_len(_sig_part(signal, "sell"))
        ok = lb !== nothing && lb == ls
    end
    ok || (i === nothing ? chk_stop("e5.signal", fn) : chk_stop("e5.when", fn, i))
    return signal
end

"""
    signal_state(signal; initial = false)

Signale in einen dauerhaften Zustand übersetzen.

`true` ab einem Kaufsignal bis zum nächsten Verkaufssignal (wie die Ein-/Ausstiegslogik von `simulation()`).
Zeilen, in denen beide Signale `false` sind (z. B. innerhalb eines Hysterese-Bands) oder beide `true`, ändern
den Zustand nicht. So lassen sich Signale als "investiert ja/nein" auswerten oder als Bedingung in
`tactical_rules()` verwenden (dort geschieht die Umwandlung automatisch).

# Argumente
- `signal`: `RList("buy" => …, "sell" => …)` mit logischen Vektoren gleicher Länge (z. B. aus `signal_sma()`);
  NA vorher durch `false` ersetzen (die Signal-Bausteine liefern keine NA).
  Seit 1.6.4 nur TRUE/FALSE oder 0/1 (NA erlaubt) und gleiche Länge, sonst Fehler.
- `initial`: Logischer Zustand vor dem ersten Signal (Standard `false` = nicht investiert).

# Rückgabe
Logischer Vektor gleicher Länge (`true` = investiert).

# Beispiel
```julia
using SimLev
x = [100, 102, 105, 103, 99, 97, 100, 104]
println(signal_state(RList("buy" => x .> 101, "sell" => x .< 98)))
```
"""
function signal_state(signal; initial = false)
    _e5_signal(signal, "signal_state")                     # seit 1.6.4 (Entscheidung 1; B-024)
    initial = chk_bool1(initial, "signal_state", "initial")
    bv = _sig_part(signal, "buy"); sv = _sig_part(signal, "sell")
    # Text lehnt _e5_signal ab wie R (seit 1.6.4 K43 T3-N10 ohne die Fehler von R's ifelse(b & !s, …), bis dahin bei
    # Textvektoren mit nothing im Elementtyp nur aus missing erreichbar)
    b, bna = _lgl(bv)
    s, sna = _lgl(sv)
    return _signal_state(b, bna, s, sna, initial)
end
# Funktionsgrenze (seit 1.6.1): `_sig_part` liefert `Any`, die Schleifen laufen hier mit festen Typen
function _signal_state(b::Vector{Bool}, bna::Vector{Bool}, s::Vector{Bool}, sna::Vector{Bool}, initial)
    n = length(b)               # buy und sell gleich lang (_e5_signal; seit 1.6.4 K43 T3-N10 ohne Recyceln)
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

Momentum-Score: mittlere Rendite über mehrere Rückblicke (Kalendermonate).

Mittlere Rendite über mehrere Rückblicke (Monate, kalenderbasiert) je Anlage, z. B. der "13612"-Score (1, 3,
6, 12 Monate). Mit `type = "13612w"` gewichtet wie bei Keller & Keuning: (12 r_1 + 4 r_3 + 2 r_6 + r_12) / 4.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Klasse Date) und Kursspalten (Niveaus).
  Seit 1.6.4 Datum aufsteigend ohne NA, Kursspalten numerisch (kein Faktor).
- `assets`: Zeichenvektor der Kursspalten.
- `lookbacks`: Rückblicke in Kalendermonaten (Standard `[1, 3, 6, 12]`); bei `type = "13612w"` ignoriert.
  Seit 1.6.4 ganze Zahlen von 1 bis 1200 (kein Blick in die Zukunft).
- `type`: `"average"` (Standard; ungewichtetes Mittel der Renditen) oder `"13612w"` (gewichtet, Rückblicke
  fest 1, 3, 6, 12).

# Rückgabe
Numerische Matrix Zeilen von `data` x `assets` mit dem Score als Anteil (NA, solange die Historie für den
längsten Rückblick zu kurz ist).

# Details
Die Rendite r_m je Zeile ist der aktuelle Kurs geteilt durch den Kurs der letzten Zeile mit Datum am oder vor
dem Tag m Monate zuvor, minus 1 (als Anteil, 0.05 = 5 %). Hat der Zielmonat weniger Tage, gilt sein letzter
Tag (31.03. minus 1 Monat = 28.02. bzw. 29.02.; in 0.5.0 (Vorfassung vor den Korrekturen) lief der Rückblick wie bei
`seq.Date()` in den Folgemonat über, z. B. auf den 02.03.). Lücken in den Kursen werden per LOCF gefüllt;
Handels- und Kalendertagsdaten funktionieren gleichermassen. Grundlage für `tactical_rotation()`.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 730
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["anleihen"] = 100 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n))
ms = momentum_score(d, ["aktien", "anleihen"])
println(size(ms))
```
"""
function momentum_score(data, assets; lookbacks = [1, 3, 6, 12], type = nothing)
    fn = "momentum_score"
    type = _dp()._e5_match_arg(type, ["average", "13612w"], fn, "type")
    _dp()._e5_data_dates(data, fn, "momentum_score: data\$date")   # seit 1.6.4 (K42 E5)
    data = SimLev.as_rframe(data)
    d = _to_date(_has(data, "date") ? _col(data, "date") : nothing, "momentum_score: data\$date")
    n = length(d)
    assets = _dp()._e5_names(assets, fn, "assets")
    _dp()._e5_lookbacks(lookbacks, fn)                     # seit 1.6.4 ganze Zahlen 1 bis 1200 (B-025)
    miss = _setdiff(assets, _df_names(data))
    isempty(miss) || error("momentum_score: Kursspalte(n) fehlen: " * join(miss, ", "))
    _dp()._e5_numcols(data, assets, fn)                    # Entscheidung 15, B-009
    type == "13612w" && (lookbacks = [1, 3, 6, 12])
    lb = lookbacks isa Union{AbstractVector,Tuple} ? collect(lookbacks) : [lookbacks]
    # seit 1.6.0 im Kern (sl_mom_score: Rückblickzeilen ganzzahlig, LOCF, Renditen, Scores) bei sortierten Daten
    # (Jahre 1000-9000); unsortiert wie findInterval in R ein Fehler
    dd = collect(Date, d)
    dv = Float64[Dates.value(z) - 719163 for z in dd]      # Tage seit 1970-01-01
    lbi = Any[_as_int(m)[1] for m in lb]
    if !isempty(lbi) && any(i -> dv[i+1] < dv[i], 1:length(dv)-1)
        error("'vec' must be sorted non-decreasingly and not contain NAs")
    end
    if n > 0 && !isempty(assets) && !isempty(lbi) && all(v -> v isa Integer && abs(v) <= 12000, lbi) &&
       minimum(dv) >= -354285 && maximum(dv) <= 2568019
        X = Matrix{Float64}(undef, n, length(assets))
        for (j, a) in enumerate(assets)
            X[:, j] = _num(_col(data, a))
        end
        S = SimLev.SLib.mom_score(dv, Cint[Cint(v) for v in lbi], X, type == "13612w")
        return NamedMat(S; colnames = assets)
    end
    back = _momentum_back(dd, lb)
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

# _UserEnv (Umgebung eines Moduls ohne fremde Namen) seit 1.6.4 in util.jl, gemeinsam mit Dependence (T3-R2)
const _UserEnv = SimLev._UserEnv

"Bedingung als Text in R-Syntax auswerten (`SimLev.RExpr`): Spalten von `data`, dann Variablen aus `env`."
function _eval_when(s::AbstractString, data, env)
    cols = data isa Union{RFrame,NamedTuple,AbstractDict} ? data :
           Dict{String,Any}(c => _col(data, c) for c in _df_names(data))
    SimLev.RExpr.eval_r(s, cols; env = env isa Module ? _UserEnv(env) : env)
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

Regelbasierte taktische Allokation.

Geordnete Bedingungen wählen je Tag ein Zielportfolio; die erste zutreffende Regel gewinnt, sonst gilt
`default`. Bedingungen sind logische Vektoren, Ausdrücke als Zeichenkette (ausgewertet in `data`, z. B.
`"inflation > 3"`) oder Signale aus den Signal-Bausteinen (`RList("buy" => …, "sell" => …)`, als Zustand mit
Hysterese).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (und den in Bedingungen verwendeten Spalten, z. B. aus
  `series_align_macro()`).
- `rules`: Liste von Regeln `(when = ..., weights = (A = 0.6, B = 0.4))`, in Prioritätsreihenfolge. `when`:
  logischer Vektor der Länge `nrow(data)`, Zeichenkette mit einem R-Ausdruck (ausgewertet in `data`, dann in
  der aufrufenden Umgebung) oder `RList("buy" => …, "sell" => …)` (wird mit `signal_state()` in einen Zustand
  übersetzt); NA gilt als `false`. `weights`: benannter Vektor Kursspalte -> Gewicht als Anteil.
  Seit 1.6.4 je Regel nur die Felder when und weights; Gewichte endlich und >= 0. `when` darf auch eine Funktion
  von `data` sein (wie in R seit 1.6.4); Regeltexte gelten in allen drei Sprachen im gemeinsamen Umfang (Spalten,
  Variablen und eigene Funktionen aus `env` ohne die Namen aus `Base`/`Core`, Operatoren, `if` und die Funktionen
  von `SimLev.RExpr`; R lehnt seit 1.6.4 Texte außerhalb davon ebenso ab).
- `default`: Benannter Gewichtsvektor (Anteile) für Zeilen, in denen keine Regel zutrifft.
- `env`: Modul, in dem freie Variablen und Funktionen der Bedingungen gesucht werden (Standard `Main`; seit 1.6.4
  ohne die Namen aus `Base`/`Core`).

# Rückgabe
`SimLevWeights`: Tabelle (RFrame) mit `date` und je Anlage einer Spalte Zielgewicht (Anteil, Zeilensumme 1),
mit Attributen `regime` (Nummer der aktiven Regel je Zeile, 0 = `default`) und `source`. `print()` zeigt
Mittel, Minimum, Maximum und letztes Gewicht in Prozent sowie die Zahl der Wechsel, `plot()` die Gewichte als
gestapelte Flächen.

# Details
Entschieden wird in jeder Zeile (kein Rhythmus); das Zielgewicht gilt als nach Schluss des Tages bekannt.
Gehandelt wird erst in `tactical_simulation()`, dort mit Verzögerung `lag` und optionalem Pflegerhythmus
`rebalance`. Gewichte werden je Zeile auf die Summe 1 normiert (negative Werte als 0); Anlagen, die nur in
anderen Regeln vorkommen, erhalten 0.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 500
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["A"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["B"] = 100 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n))
w = tactical_rules(d, [(when = signal_sma(d["A"], 200), weights = (A = 1,))], (B = 1,))
println(w)
```
"""
function tactical_rules(data, rules, default; env = Main)
    fn = "tactical_rules"
    _dp()._e5_data_dates(data, fn, "date")                 # seit 1.6.4 (K42 E5)
    data = SimLev.as_rframe(data)
    n = _nrow(data)
    (rules isa Union{AbstractVector,Tuple} && !(rules isa AbstractVector{<:Pair})) ||   # leer: nur default
        chk_stop("liste", fn, "rules")
    rules = collect(rules)
    for (i, r) in enumerate(rules)
        ks = _keys_str(r)
        (ks !== nothing && "when" in ks && "weights" in ks) || chk_stop("e5.regel", fn, i)
        bad = [k for k in ks if !(k in ("when", "weights"))]   # Entscheidung 11 sinngemäß
        isempty(bad) || chk_stop("e5.regel_feld", fn, bad[1], i)
        _dp()._e5_weights(_rget(r, "weights"), fn, "rules[[$i]]\$weights")
        w = _rget(r, "when")
        if _keys_str(w) !== nothing
            _e5_signal(w, fn, i)
        elseif !(w isa AbstractString || w isa Function || _is_chr(w) || _e5_sigvec_len(w) !== nothing)
            chk_stop("e5.when", fn, i)
        end
    end
    _dp()._e5_weights(default, fn, "default")
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
        elseif _is_chr(w)
            # R: eval(parse(text = w)) – jedes Element ein Ausdruck (NA als "NA"), Ergebnis der letzte (seit 1.6.3;
            # bis 1.6.2 wurde ein Textvektor als logischer Vektor gelesen)
            vv = Any[]
            for z in w
                vv = _eval_when(z isa AbstractString ? z : "NA", data, env)
            end
            vv
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

Momentum-Rotation, Dual Momentum und Canary-Schutz.

An jedem Entscheidungstermin (Periodenende) werden die Anlagen nach ihrem Momentum-Score sortiert und die
besten `top` gehalten.

- **Absolutes Momentum** (`absolute = true`, Dual Momentum nach Antonacci): Ein gewählter Platz mit negativem
  Score geht an die beste sichere Anlage aus `safe`.
- **Canary/Breite** (`canary`, Keller & Keuning): Bei b Canary-Anlagen mit negativem Score geht der Anteil
  min(1, b / B) an die sichere Anlage (B = `breadth`).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Klasse Date) und Kursspalten (Niveaus) aller Anlagen aus
  `assets`, `safe` und `canary`.
- `assets`: Zeichenvektor der Risikoanlagen für die Rotation.
- `top`: Anzahl gehaltener Anlagen (Standard 1; 1 bis Anzahl `assets`).
  Seit 1.6.4 ganze Zahl ohne Abschneiden.
- `safe`: Zeichenvektor der sicheren Anlage(n); bei mehreren wird die mit dem besten Score gewählt. Pflicht,
  wenn `absolute = true` (Standard) oder `canary` gesetzt ist (sonst Fehler).
- `absolute`: Logisch: absoluten Momentum-Filter anwenden (Standard `true`; Score < 0 => sichere Anlage).
- `canary`: Optional Zeichenvektor der Canary-Anlagen (Standard `nothing` = kein Canary-Schutz).
- `breadth`: Schutzschwelle B als Anzahl Anlagen (mindestens 1; Standard `nothing` = Anzahl Canary-Anlagen).
  Seit 1.6.4 ganze Zahl.
- `lookbacks`, `type`: Siehe `momentum_score()` (Rückblicke in Monaten; `"average"` oder `"13612w"`).
- `every`: Entscheidungsrhythmus: `"month"` (Standard), `"week"` (ISO-Woche) oder `"quarter"`.
- `weighting`: Gewichtung der gewählten Anlagen: `"equal"` (Standard) oder `"inverse_vol"` (umgekehrt
  proportional zur Wurzel der mittleren quadrierten Log-Renditen der letzten 63 Zeilen).
  Seit 1.6.4 liegen die Termine dann erst ab Zeile 63 (volles Fenster; bis 1.6.3 brach jeder frühere Termin ab,
  mit Wochen- und Monatskursen auch mit den Standardrückblicken).

# Rückgabe
`SimLevWeights` (Tabelle (RFrame) mit `date` und Zielgewichten je Anlage aus `assets` und `safe`, Anteile) mit
Attributen `scores` (Matrix der Momentum-Scores aller Anlagen je Zeile) und `decision_rows` (Zeilennummern der
Entscheidungstermine).

# Details
Entscheidungstermine sind die letzten vorhandenen Zeilen jeder Periode von `every`, ab dem ersten Termin, an
dem mindestens `top` Anlagen einen Score haben. Das Zielgewicht gilt ab dem Termin bis zum nächsten; davor
liegt alles in `safe[1]` (ohne `safe` in `assets[1]`). `every` legt nur den Entscheidungsrhythmus fest;
gehandelt wird in `tactical_simulation()` (Verzögerung `lag`, Pflegerhythmus `rebalance`).

# Literatur
Antonacci, G. (2014), Dual Momentum Investing; Keller, W. J. & Keuning, J. W. (2018), Breadth Momentum and the
Canary Universe: Defensive Asset Allocation (DAA), SSRN 3212862.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1460
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["anleihen"] = 100 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n))
d["geld"] = 100 .* cumprod(fill(1 + 0.01 / 365, n))
println(tactical_rotation(d, ["aktien", "anleihen"]; safe = "geld"))
```
"""
function tactical_rotation(data, assets; top = 1, safe = nothing, absolute = true, canary = nothing, breadth = nothing,
                           lookbacks = [1, 3, 6, 12], type = nothing, every = nothing, weighting = nothing)
    fn = "tactical_rotation"
    type = _dp()._e5_match_arg(type, ["average", "13612w"], fn, "type")
    every = _dp()._e5_match_arg(every, ["month", "week", "quarter"], fn, "every")
    weighting = _dp()._e5_match_arg(weighting, ["equal", "inverse_vol"], fn, "weighting")
    # seit 1.6.4 (K42 E5): Datum, Namen, Wahrheitswert, ganze Zahlen; Meldungen ohne Eingabewert (Entscheidung 8)
    _dp()._e5_data_dates(data, fn, "momentum_score: data\$date")
    data = SimLev.as_rframe(data)
    assets = _dp()._e5_names(assets, fn, "assets")
    safe = (v = _dp()._e5_names(safe, fn, "safe"; null_ok = true); v === nothing ? String[] : v)
    canary = (v = _dp()._e5_names(canary, fn, "canary"; null_ok = true); v === nothing ? String[] : v)
    absolute = chk_bool1(absolute, fn, "absolute")
    _dp()._e5_lookbacks(lookbacks, fn)
    (absolute || !isempty(canary)) && isempty(safe) && error("absolute bzw. canary brauchen eine sichere Anlage 'safe'.")
    top = Int(chk_int1(top, fn, "top"; lo = 1))
    top > length(assets) && error("top muss zwischen 1 und der Anzahl der Anlagen in assets ($(length(assets))) liegen.")
    breadth === nothing || (breadth = chk_int1(breadth, fn, "breadth"; lo = 1))
    allc = _unique(vcat(assets, safe, canary))
    Sm = momentum_score(data, allc; lookbacks = lookbacks, type = type)
    S = Sm.data
    ci = Dict(a => j for (j, a) in enumerate(allc))
    d = _to_date(_col(data, "date"), "data\$date")
    n = length(d)
    rows = _period_last(d, every)
    ja = [ci[a] for a in assets]
    rows = Int[i for i in rows if count(isfinite, S[i, ja]) >= top]
    # inverse_vol: Termine erst ab Zeile 63, wenn das Fenster der Schwankung voll ist (seit 1.6.4, Entscheidung 144;
    # bis 1.6.3 Abbruch "Zeilen ohne positive Gewichte" bei jedem früheren Termin)
    weighting == "inverse_vol" && (rows = Int[i for i in rows if i >= 63])
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

"Gemeinsame Prüfung der Volatilitätssteuerung (R `.e5_risk_check`; seit 1.6.4, K42 E5)."
function _e5_risk_check(fn, data, weights, safe, window, ppy)
    _dp()._e5_data_dates(data, fn, "data\$date")
    if !_isweights(weights)
        _is_numeric_named(weights) || error("weights: SimLevWeights oder benannter Gewichtsvektor erwartet.")
        _dp()._e5_weights(weights, fn, "weights")
    end
    safe = chk_name1(safe, fn, "safe")
    window = chk_int1(window, fn, "window"; lo = 2)
    ppy = chk_num1(ppy, fn, "ppy"; lo = 0, lo_open = true, null_ok = true)
    wn = _isweights(weights) ? names(weights)[2:end] : (nm = _named(weights)[1]; nm === nothing ? String[] : nm)
    nms = _df_names(data)
    _dp()._e5_numcols(data, [c for c in _unique(vcat(wn, [String(safe)])) if c in nms], fn)
    return safe, window, ppy
end

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
    tactical_target_volatility(data, weights, safe; target = 10, window = 63, max_exposure = 1,
                      every = "month", ppy = nothing)

Zielvolatilität: Risikoanteil `min(max_exposure, (target / 100) / vol)`.

Skaliert den Risikoteil einer Gewichtsreihe so, dass die geschätzte Volatilität des Risikoportfolios dem Ziel
entspricht; der Rest geht in die sichere Anlage. Die Volatilität wird aus den Tagesrenditen der Risikoanlagen
mit den aktuellen Gewichten über `window` Zeilen mit Kursbewegung geschätzt (Tage ohne Bewegung, etwa
Wochenenden, zählen nicht).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Klasse Date) und Kursspalten (Niveaus) der Risikoanlagen und der
  sicheren Anlage.
- `weights`: Gewichte des Risikoportfolios: `SimLevWeights` (z. B. aus `tactical_rotation()`) oder benannter
  Gewichtsvektor (Anteile, statisch). Eine darin enthaltene sichere Anlage zählt nicht zum Risikoteil.
- `safe`: Name der Kursspalte der sicheren Anlage (Zeichenkette).
- `target`: Zielvolatilität in Prozent p. a. (10 = 10 %; Standard 10). Werte unter 1 ergeben eine Warnung
  (vermutlich als Anteil angegeben).
- `window`: Fensterlänge der Volatilitätsschätzung in Zeilen mit Kursbewegung (Standard 63).
  Seit 1.6.4 ganze Zahl >= 2.
- `max_exposure`: Höchster Risikoanteil als Anteil (Standard 1 = ohne Hebel; Werte > 1 sind nicht erlaubt, da
  die Engine keinen Kredit kennt).
- `every`: Anpassungsrhythmus des Risikoanteils: `"month"` (Standard), `"week"`, `"day"` oder `"quarter"`.
- `ppy`: Tage mit Kursbewegung je Jahr für die Annualisierung. Standard `nothing` = aus den Daten ermittelt
  (Zahl der Tage mit Bewegung geteilt durch die Länge des Zeitraums in Jahren, z. B. rund 252 bei Börsentagen,
  365 bei einem Index, der auch am Wochenende notiert).

# Rückgabe
`SimLevWeights` (Tabelle (RFrame) mit `date` und Zielgewichten der Risikoanlagen und von `safe`, Anteile) mit
Attributen `exposure` (Risikoanteil je Zeile, Anteil) und `volatility` (geschätzte Volatilität des
Risikoportfolios je Zeile, Anteil p. a., 0.15 = 15 %).

# Details
Der Risikoanteil (Exposure) ist `min(max_exposure, (target / 100) / vol)` mit der geschätzten Volatilität
`vol` als Anteil p. a.; er wird an den Terminen von `every` (letzte vorhandene Zeile je Periode) neu gesetzt
und bis zum nächsten Termin gehalten. Vor dem ersten Termin mit vollem Fenster ist der Risikoanteil 0 (alles
in `safe`); anders als bei `tactical_conditional_volatility()`, wo vorher der Grundanteil `base` gilt (hier
gibt es keinen Grundanteil). `every` legt nur den Anpassungsrhythmus der Zielgewichte fest; gehandelt wird in
`tactical_simulation()`.

# Literatur
Moreira, A. & Muir, T. (2017), Volatility-Managed Portfolios, Journal of Finance 72(4).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1460
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["anleihen"] = 100 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n))
d["geld"] = 100 .* cumprod(fill(1 + 0.01 / 365, n))
tv = tactical_target_volatility(d, (aktien = 0.8, anleihen = 0.2), "geld"; target = 8)
println(tv)
```
"""
function tactical_target_volatility(data, weights, safe; target = 10, window = 63, max_exposure = 1, every = nothing, ppy = nothing)
    fn = "tactical_target_volatility"
    every = _dp()._e5_match_arg(every, ["month", "week", "day", "quarter"], fn, "every")
    safe, window, ppy = _e5_risk_check(fn, data, weights, safe, window, ppy)   # seit 1.6.4 (K42 E5)
    data = SimLev.as_rframe(data)
    target = chk_num1(target, fn, "target"; lo = 0, lo_open = true)
    max_exposure = chk_num1(max_exposure, fn, "max_exposure"; lo = 0)
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
    tactical_conditional_volatility(data, weights, safe; base = 1, upper = 0.8, lower = 0.2,
                           target = nothing, window = 63, min_exposure = 0, max_exposure = 1,
                           min_history = 3, scaling = "inverse", high_exposure = nothing,
                           low_exposure = nothing, every = "month", ppy = nothing)

Bedingte Volatilitätssteuerung: nur in extremen Phasen skalieren.

Wie `tactical_target_volatility()`, aber nur in extremen Volatilitätsphasen: Liegt die geschätzte Volatilität
des Risikoportfolios über ihrem `upper`-Quantil, wird der Risikoanteil gesenkt, liegt sie unter dem
`lower`-Quantil, wird er erhöht; dazwischen bleibt er beim Grundanteil `base`. Das spart die meisten
Umschichtungen (und damit Steuern und Kosten) der ständigen Steuerung (Bongaerts, Kang & van Dijk 2020).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Klasse Date) und Kursspalten (Niveaus) der Risikoanlagen und der
  sicheren Anlage.
- `weights`: Gewichte des Risikoportfolios: `SimLevWeights` (z. B. aus `tactical_rotation()`) oder benannter
  Gewichtsvektor (Anteile, statisch). Eine darin enthaltene sichere Anlage zählt nicht zum Risikoteil.
- `safe`: Name der Kursspalte der sicheren Anlage (Zeichenkette).
- `base`: Grundanteil des Risikoportfolios in normalen Phasen als Anteil (0 bis `max_exposure`; Standard 1).
- `upper`: Quantil-Wahrscheinlichkeit (zwischen 0 und 1), ab der die Volatilität als hoch gilt (Standard 0.8 =
  oberstes Fünftel der bisherigen Werte).
- `lower`: Quantil-Wahrscheinlichkeit (zwischen 0 und `upper`), unter der sie als niedrig gilt (Standard 0.2);
  `nothing` schaltet das Hochskalieren ab.
- `target`: Vergleichsvolatilität in Prozent p. a. (10 = 10 %); Standard `nothing` = Mittel der bisherigen
  Volatilität (expandierend, monatlich aktualisiert).
- `window`: Fensterlänge der Volatilitätsschätzung in Zeilen mit Kursbewegung (Standard 63).
- `min_exposure`, `max_exposure`: Untere und obere Grenze des Risikoanteils als Anteil (Standard 0 und 1;
  `min_exposure` höchstens `base`, `max_exposure` höchstens 1).
- `min_history`: Mindesthistorie der Volatilitätsschätzung in Jahren (Standard 3), bevor gesteuert wird. Ist
  sie länger als die vorhandene Historie, wird nie gesteuert (mit Warnung).
  Seit 1.6.4 höchstens 100 Jahre.
- `scaling`: `"inverse"` (Standard): Anteil `base * target / vol`; `"fixed"`: feste Anteile `high_exposure`
  und `low_exposure`.
- `high_exposure`, `low_exposure`: Feste Risikoanteile (Anteile) für `scaling = "fixed"` in hohen bzw.
  niedrigen Phasen; `high_exposure` höchstens `base`, `low_exposure` zwischen `base` und `max_exposure`
  (Pflicht, wenn `lower` gesetzt ist).
- `every`: Anpassungsrhythmus des Risikoanteils: `"month"` (Standard), `"week"`, `"day"` oder `"quarter"`.
- `ppy`: Tage mit Kursbewegung je Jahr für die Annualisierung. Standard `nothing` = aus den Daten ermittelt
  (Zahl der Tage mit Bewegung geteilt durch die Länge des Zeitraums in Jahren, z. B. rund 252 bei Börsentagen,
  365 bei einem Index, der auch am Wochenende notiert).

# Rückgabe
`SimLevWeights` (Tabelle (RFrame) mit `date` und Zielgewichten, Anteile) mit Attributen `exposure`
(Risikoanteil je Zeile, Anteil), `volatility` (geschätzte Volatilität, Anteil p. a.), `state` (Phase am
letzten Anpassungstermin, je Zeile fortgeschrieben: -1 niedrig, 0 normal, 1 hoch) und `thresholds` (Tabelle
(RFrame) mit `date`, `lower`, `upper` und `target` als Anteile p. a., wie sie zum jeweiligen Monatsende
bekannt waren; NA vor `min_history`).

# Details
Die Quantile und der langfristige Vergleichswert werden nur aus der Volatilität bis zum jeweiligen Tag
berechnet (expandierendes Fenster, monatlich aktualisiert) – ohne Blick in die Zukunft. Vor `min_history`
Jahren Historie gilt der Grundanteil.

In einer extremen Phase ist der Risikoanteil `base * target / vol`, oben höchstens `base`, unten mindestens
`base`, begrenzt auf `[min_exposure, max_exposure]`. Weil die Engine keinen Kredit kennt, ist `max_exposure`
höchstens 1; Hochskalieren setzt daher `base < max_exposure` voraus.

Einheiten: `base`, `min_exposure`, `max_exposure`, `high_exposure` und `low_exposure` sind Anteile des Depots
(0.8 = 80 %), `upper` und `lower` Quantil-Wahrscheinlichkeiten (0 bis 1), `target` Prozent p. a. (10 = 10 %).
Die geschätzte Volatilität und die Schwellen in `thresholds` sind Anteile p. a. (0.15 = 15 %). Vor dem ersten
Termin von `every` gilt der Grundanteil `base`.

# Literatur
Bongaerts, D., Kang, X. & van Dijk, M. (2020), Conditional Volatility Targeting, Financial Analysts Journal
76(4), 54-71.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 4380
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* exp.(cumsum(0.0002 .+ 0.01 .* exp.(sin.((1:n) ./ 300)) .* randn(rng, n)))
d["geld"] = 100 .* cumprod(fill(1 + 0.01 / 365, n))
cv = tactical_conditional_volatility(d, (aktien = 1,), "geld"; base = 0.8)
println(cv)
```
"""
function tactical_conditional_volatility(data, weights, safe; base = 1, upper = 0.8, lower = 0.2, target = nothing, window = 63,
                                min_exposure = 0, max_exposure = 1, min_history = 3, scaling = nothing,
                                high_exposure = nothing, low_exposure = nothing, every = nothing, ppy = nothing)
    fn = "tactical_conditional_volatility"
    every = _dp()._e5_match_arg(every, ["month", "week", "day", "quarter"], fn, "every")
    scaling = _dp()._e5_match_arg(scaling, ["inverse", "fixed"], fn, "scaling")
    # seit 1.6.4 (K42 E5): einzelne endliche Zahlen vor den Bereichsprüfungen (B-012: NaN lief in Julia still)
    safe, window, ppy = _e5_risk_check(fn, data, weights, safe, window, ppy)
    data = SimLev.as_rframe(data)
    base = chk_num1(base, fn, "base"); upper = chk_num1(upper, fn, "upper")
    min_exposure = chk_num1(min_exposure, fn, "min_exposure"); max_exposure = chk_num1(max_exposure, fn, "max_exposure")
    lower = chk_num1(lower, fn, "lower"; null_ok = true); target = chk_num1(target, fn, "target"; null_ok = true)
    high_exposure = chk_num1(high_exposure, fn, "high_exposure"; null_ok = true)
    low_exposure = chk_num1(low_exposure, fn, "low_exposure"; null_ok = true)
    target === nothing || chk_num1(target, fn, "target"; lo = 0, lo_open = true)
    min_history = chk_num1(min_history, fn, "min_history"; lo = 0)
    chk_max(min_history, 100, fn, "min_history")             # Entscheidung 46
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
        v = vm[ok[1:searchsortedlast(ok, g)]]   # ok aufsteigend: dieselben Zeilen wie ok[ok .<= g]
        if lower === nothing
            th[gi, 2] = _quantile7(v, upper)
        else   # seit 1.6.3 beide Schwellen in einem Aufruf (eine Teilsortierung; Ordnungsstatistiken und Formel je p gleich)
            q2 = SimLev.RStats.quantile(Float64.(v), Float64[lower, upper]; names = false, type = 7)
            th[gi, 1] = Float64(q2[1]); th[gi, 2] = Float64(q2[2])
        end
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
# tactical_glidepath, tactical_blend
# ═══════════════════════════════════════════════════════════════════════════

"""
    tactical_glidepath(data, from_, to; start = nothing, end_ = nothing, every = "year")

Glidepath zwischen zwei Allokationen.

Erzeugt Zielgewichte, die sich stufenweise linear von `from` nach `to` bewegen, z. B. von aktienlastig zu
anleihenlastig bis zum Rentenbeginn. Eine Stufe beginnt in der ersten Zeile und an der letzten vorhandenen
Zeile jeder Periode von `every`; ihr Gewicht ist (1 - p) · from + p · to mit dem Zeitanteil p des Datums
zwischen `start` (0) und `end` (1), begrenzt auf 0 bis 1. Vor `start` gilt `from`, nach `end` gilt `to`; bei
`start = end` wechselt die erste Stufe an oder nach diesem Datum direkt auf `to`, `end` vor `start` ist ein
Fehler. Das Ergebnis geht in `tactical_simulation()` oder als Kern in `tactical_blend()`.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (z. B. der Datensatz für `simulation()`) oder Datumsvektor.
- `to`: Benannte Gewichtsvektoren (Anteile) am Anfang und Ende; Anlagen, die nur in einem vorkommen, erhalten
  im anderen 0. Je Zeile auf Summe 1 normiert.
- `start`, `end_`: Beginn und Ende des Uebergangs (Date oder `"JJJJ-MM-TT"`; `end_`, weil `end` in Julia ein
  Schlüsselwort ist; Standard `nothing` = erstes bzw. letztes Datum).
  Seit 1.6.4 keine Zahl.
- `every`: Rhythmus der Stufen: `"year"` (Standard), `"quarter"` oder `"month"`.

# Rückgabe
`SimLevWeights` (Tabelle (RFrame) mit `date` und Zielgewichten je Anlage, Anteile).

# Beispiel
```julia
using SimLev, Dates
gp = tactical_glidepath(collect(Date(2025, 1, 1):Day(1):Date(2045, 12, 31)),
                        (aktien = 0.9, anleihen = 0.1), (aktien = 0.4, anleihen = 0.6))
println(gp)
```
"""
function tactical_glidepath(data, from_, to; start = nothing, end_ = nothing, every = nothing)
    fnm = "tactical_glidepath"
    every = _dp()._e5_match_arg(every, ["year", "quarter", "month"], fnm, "every")
    # seit 1.6.4 (K42 E5): Datum ohne NA und aufsteigend, Gewichte benannt endlich >= 0, start/end Datum
    if data isa RFrame
        d = _dp()._e5_data_dates(data, fnm, "tactical_glidepath: Datum")
    else
        (data isa Union{NamedTuple,AbstractDict}) && chk_df(data, fnm, "data")
        chk_nofactor(data, fnm, "data")
        (data === nothing || (data isa Union{AbstractVector,Tuple} && isempty(data))) && chk_stop("zeilen_keine", fnm, "data")
        d = _to_date(data, "tactical_glidepath: Datum")
        dd = Float64[v === missing ? NaN : Float64(Dates.value(v - Date(1970, 1, 1))) for v in d]
        _dp()._e5_sorted(dd) || chk_stop("e5.datum_vektor", fnm, "data")
    end
    _dp()._e5_weights(from_, fnm, "from"); _dp()._e5_weights(to, fnm, "to")
    start = chk_date1(start, fnm, "start"; null_ok = true); end_ = chk_date1(end_, fnm, "end"; null_ok = true)
    fn, fv = _named(from_)
    tn, tv = _named(to)
    a = _unique(vcat(fn === nothing ? String[] : fn, tn === nothing ? String[] : tn))
    f = zeros(length(a)); t = zeros(length(a))
    fn === nothing || for (k, x) in zip(fn, fv); f[findfirst(==(k), a)] = x; end
    tn === nothing || for (k, x) in zip(tn, tv); t[findfirst(==(k), a)] = x; end
    s = _to_date(start === nothing ? d[1] : start, "start")[1]
    e = _to_date(end_ === nothing ? d[end] : end_, "end")[1]
    e < s && error("tactical_glidepath: end liegt vor start; für den umgekehrten Weg from und to tauschen.")   # seit 1.6.4 ohne Daten
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
    tactical_blend(ws...; shares = nothing)

Gewichtsreihen mischen (Kern-Satellit): je Zeile und Anlage `sum_k shares_k * w_k`, dann auf Summe 1 normiert.

Mischt mehrere Zielgewichtsreihen zu einer, z. B. einen statischen Kern oder `tactical_glidepath()` mit einem
taktischen Satelliten aus `tactical_rotation()`: Je Zeile und Anlage ist das Gewicht Σ_k shares_k · w_k,
anschließend auf Summe 1 normiert. Anlagen, die in einer Reihe fehlen, zählen dort mit 0. Alle Reihen müssen
dieselben Daten haben (z. B. aus demselben Datensatz erzeugt).

# Argumente
- `ws...`: `SimLevWeights` (in der Regel zwei oder mehr) mit identischer Spalte `date` (Namen werden nicht
  verwendet).
- `shares`: Numerischer Vektor der Anteile je Reihe in der Reihenfolge von `...` (z. B. `[0.7, 0.3]`; genau
  ein nichtnegativer Wert je Reihe); Standard `nothing` = gleiche Anteile.

# Rückgabe
`SimLevWeights` (Tabelle (RFrame) mit `date` und Zielgewichten aller Anlagen, Anteile) für
`tactical_simulation()`.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1460
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["anleihen"] = 100 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n))
d["geld"] = 100 .* cumprod(fill(1 + 0.01 / 365, n))
kern = tactical_glidepath(d, (aktien = 0.8, anleihen = 0.2), (aktien = 0.5, anleihen = 0.5))
satellit = tactical_rotation(d, ["aktien", "anleihen"]; safe = "geld")
println(tactical_blend(kern, satellit; shares = [0.7, 0.3]))
```
"""
function tactical_blend(ws...; shares = nothing)
    ws = collect(ws)
    (isempty(ws) || !all(_isweights, ws)) && error("tactical_blend: ... muss aus SimLevWeights bestehen.")
    shares === nothing && (shares = fill(1 / length(ws), length(ws)))
    sv = shares isa Union{AbstractVector,Tuple} ? collect(Any, shares) : Any[shares]
    num = !(shares isa SimLev.RFmt.RFactor) && all(v -> v isa Real && !(v isa Bool), sv)
    sh = num ? Float64[Float64(v) for v in sv] : Float64[]
    if !num || length(sh) != length(ws) || !all(isfinite, sh) || any(<(0), sh) || _ldsum(sh) <= 0
        # seit 1.6.4 ohne Eingabewert, endlich (Entscheidung 8)
        error("tactical_blend: shares braucht $(length(ws)) nichtnegative Anteile (einen je Gewichtsreihe, z. B. c(0.7, 0.3)).")
    end
    d = _to_date(ws[1]["date"], "date")
    dn = Float64[_dnum(z) for z in d]
    for w in ws
        dw = Float64[_dnum(z) for z in _to_date(w["date"], "date")]
        isequal(dw, dn) || error("tactical_blend: unterschiedliche Daten.")
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

# Grafik: Bausteine `_alloc_*` (Stil Allokationsgrafiken) in svg.jl.

"""
    plot_SimLevWeights(x; file = nothing, width = 900, height = 420, main = "Zielgewichte")

`plot.SimLevWeights`: Zielgewichte als gestapelte Flächen über der Zeit (SVG).
Liefert `(svg, data)` mit `data["weights"]` (`date` und je Anlage eine Spalte);
über `r_plot` entsteht daraus ein `SimLevPlot`.
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
    cl = _alloc_ramp(length(cols))
    io = IOBuffer()
    println(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\" font-family=\"sans-serif\">")
    println(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>")
    println(io, "<text x=\"$(L+pw/2)\" y=\"22\" text-anchor=\"middle\" font-size=\"15\" font-weight=\"bold\">$(_esc(main))</text>")
    cum = zeros(length(t))
    # seit 1.6.4 (B-082, Entscheidung 93) die Koordinatentexte zwischengespeichert: x einmal je Tag, y einmal je Höhe
    # (gleicher Text: dieselbe Rechnung)
    xs = [_alloc_c(px(t[i])) for i in eachindex(t)]
    yc = Dict{Float64,String}()
    ys(v) = get!(() -> _alloc_c(py(v)), yc, v)
    for j in eachindex(cols)
        lo = copy(cum)
        cum .+= Float64[isfinite(v) ? v : 0.0 for v in W[:, j]]
        up = join(("$(xs[i]),$(ys(cum[i]))" for i in eachindex(t)), " ")
        dn = join(("$(xs[i]),$(ys(lo[i]))" for i in reverse(eachindex(t))), " ")
        println(io, "<polygon points=\"$up $dn\" fill=\"$(cl[j])\" stroke=\"none\"/>")
    end
    for v in 0:0.25:1
        println(io, "<text x=\"$(L-6)\" y=\"$(_alloc_c(py(v)+4))\" text-anchor=\"end\" font-size=\"11\">$v</text>")
    end
    years = unique(Dates.year.(d))
    for y in years
        z = _dnum(Date(y, 1, 1))
        (z < t0 || z > t1) && continue
        println(io, "<text x=\"$(_alloc_c(px(z)))\" y=\"$(T+ph+16)\" text-anchor=\"middle\" font-size=\"11\">$y</text>")
    end
    println(io, "<text x=\"16\" y=\"$(T+ph/2)\" font-size=\"12\" transform=\"rotate(-90 16 $(T+ph/2))\" text-anchor=\"middle\">Gewicht</text>")
    for (j, c) in enumerate(cols)
        yy = T + (j - 1) * 18
        println(io, "<rect x=\"$(L+pw+12)\" y=\"$yy\" width=\"12\" height=\"12\" fill=\"$(cl[j])\"/>")
        println(io, "<text x=\"$(L+pw+30)\" y=\"$(yy+10)\" font-size=\"11\">$(_esc(c))</text>")
    end
    println(io, "</svg>")
    svg = String(take!(io))
    file === nothing || write(String(file), svg)
    # dargestellte Werte: Zielgewichte je Anlage (vor dem Stapeln, NA unverändert)
    data = SimLev.RList("weights" => SimLev.RFrame("date" => collect(Date, d),
                                                   (String(c) => W[:, j] for (j, c) in enumerate(cols))...))
    return (svg, data)
end

# ═══════════════════════════════════════════════════════════════════════════
# tactical_simulation
# ═══════════════════════════════════════════════════════════════════════════

"""
    tactical_simulation(data, weights; rebalance = "switch", tolerance = nothing,
                        tolerance_type = "absolute", lag = 1, asset_args = (;), kwargs...)

Taktische Allokation simulieren.

Übersetzt eine Zielgewichtsreihe in Ereignis-Rebalancing von `simulation()`: An Wechselterminen (Zielgewicht
ändert sich) und an optionalen Pflegeterminen wird auf die Zielgewichte umgeschichtet, mit Steuern, Spreads
und allen weiteren Einstellungen der Engine. Die Engine selbst bleibt unverändert (`event_col`, `event_mode =
"replace"`, `event_weight`).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Klasse Date) und Kursspalten (Niveaus) aller Anlagen der
  Gewichte (z. B. mit `series_align()` vorbereitet). Fehlende Kalendertage füllt `simulation()` selbst.
- `weights`: `SimLevWeights` (aus `tactical_rules()`, `tactical_rotation()`, `tactical_target_volatility()`,
  `tactical_conditional_volatility()`, `tactical_glidepath()`, `tactical_blend()` oder `portfolio_rolling()`).
  Daten von `data`, die in `weights` fehlen, übernehmen das letzte bekannte Zielgewicht.
- `rebalance`: Pflegerhythmus: `"switch"` (Standard; nur bei Wechseln), `"month"`, `"quarter"` oder `"year"`.
- `tolerance`: Toleranzband in Prozent (5 = 5 %; Standard `nothing` = an jedem Termin handeln).
- `tolerance_type`: Messung der Abweichung für `tolerance`: `"absolute"` (Standard; Prozentpunkte des
  Gewichts: bei 5 und Ziel 40 % wird gehandelt, wenn eine Anlage unter 35 % oder über 45 % liegt) oder
  `"relative"` (Prozent des Zielgewichts).
- `lag`: Verzögerung in Zeilen von `data` (ganze Zahl >= 0, Standard 1); mit Attribut `filled` in Zeilen mit
  echten Kursen.
  Seit 1.6.4 ohne Abschneiden (1.5 und Text sind ein Fehler).
- `asset_args`: Liste von Argumenten für `asset_config()` (über `strategy_from_weights()`), z. B. `(spread =
  0.1, partial_exemption = (aktien = 30, geld = 0))`. Ein unbenannter einzelner Wert gilt für alle Anlagen;
  benannte Vektoren werden je Anlage zugeordnet (auch mit einem Element, siehe `strategy_from_weights()`).
- `kwargs...`: Weitere Argumente für `simulation()` (z. B. `tax = tax_profile()`, `start_value`, `dca =
  dca_plan(...)`). Das Rebalancing (`rebalance_plan(event_col, event_mode = "replace", skip = true,
  event_weight, thresh = tolerance, thresh_type = tolerance_type)`) steuert die Funktion selbst; Pfade
  `"rebalance.*"` und die alten `event_col`, `event_mode`, `event_weight`, `balance_mode`, `balance_thresh`
  sind ein Fehler.

# Rückgabe
`SimLevResult` wie von `simulation()` mit zusätzlichem Element `tactical`, einer Liste mit `weights`
(gehandelte, um `lag` verschobene Zielgewichte als `SimLevWeights`), `events` (Daten der Umschichtungstermine
aus Wechseln, Pflege und Sparplan, vor Anwendung von `tolerance`), `switches` (Zahl der Zielwechsel), `lag`
und `rebalance`. Das Ergebnis lässt sich mit `result_analysis()` oder `result_index()` weiterverarbeiten.

# Details
- `every` vs. `rebalance`: Das Argument `every` der Gewichts-Erzeuger (`tactical_rotation()`,
  `tactical_target_volatility()`, `tactical_glidepath()` usw.) bestimmt, wann sich das Zielgewicht ändern
  kann. `rebalance` hier bestimmt, wann zusätzlich ohne Zielwechsel auf die aktuellen Zielgewichte
  zurückgeführt wird. Gehandelt wird an jedem Wechsel (nach `lag`) und an den Pflegeterminen.
- `lag`: Ein Zielgewicht, das nach Schluss von Tag t bekannt ist, wird nach `lag` Zeilen von `data` gehandelt
  (Standard 1 = nächste Zeile, bei Kalendertagsdaten also der nächste Kalendertag; 0 = am selben Schlusskurs,
  wie bei vielen Online-Backtestern). Trägt `data` das Attribut `filled` aus `series_align()`, zählen nur
  Zeilen, in denen alle Anlagen der Gewichte echte (nicht gefüllte) Kurse haben: Ein Signal vom Freitag wird
  mit `lag = 1` am Montag gehandelt, nicht am Samstag zum Freitagskurs. Das Attribut wird an `simulation()`
  weitergereicht.
- `rebalance`: `"switch"` (Standard; nur bei Wechseln) oder ein Rhythmus (`"month"`, `"quarter"`, `"year"`;
  jeweils letzte vorhandene Zeile der Periode), zu dem zusätzlich auf die aktuellen Zielgewichte zurückgeführt
  wird.
- `tolerance`: Toleranzband in Prozent (wird als `rebalance_plan(thresh = tolerance)` an `simulation()`
  übergeben); an Terminen, an denen keine Anlage stärker als das Band vom Ziel abweicht, wird nicht gehandelt.
  Gilt auch für Wechseltermine.
- Umschichtungen nutzen die Rebalancing-Logik der Engine, die mit den Ist-Gewichten des letzten
  Bewertungsstands (Vortag) rechnet; nach einem Wechsel können daher Reste in der Größenordnung der
  Tagesbewegung (meist unter einem Prozent) in der verlassenen Anlage bleiben. Ein Pflegerhythmus (`rebalance
  = "month"`) gleicht sie aus.
- Sparpläne (`dca = dca_plan(...)`) zahlen nach den Startgewichten ein; der Sparplantag wird zum
  Rebalancing-Termin, so dass die Rate sofort auf die aktuellen Zielgewichte verteilt wird.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1460
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["anleihen"] = 100 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n))
d["geld"] = 100 .* cumprod(fill(1 + 0.01 / 365, n))
w = tactical_rules(d, [(when = signal_sma(d["aktien"], 200; band = 1), weights = (aktien = 1,))], (geld = 1,))
res = tactical_simulation(d, w; rebalance = "switch", lag = 1,
                          asset_args = (partial_exemption = (aktien = 30, geld = 0),))
println(res["tactical"]["switches"])
```
"""
function tactical_simulation(data, weights; rebalance = nothing, tolerance = nothing, tolerance_type = nothing, lag = 1,
                             asset_args = NamedTuple(), kwargs...)
    fn = "tactical_simulation"
    rebalance = _dp()._e5_match_arg(rebalance, ["switch", "month", "quarter", "year"], fn, "rebalance")
    tolerance_type = _dp()._e5_match_arg(tolerance_type, ["absolute", "relative"], fn, "tolerance_type")
    _dp()._e5_data_dates(data, fn, "data\$date")           # seit 1.6.4 (K42 E5)
    data = SimLev.as_rframe(data)
    _isweights(weights) || error("weights muss ein SimLevWeights sein.")
    lag = chk_int1(lag, fn, "lag"; lo = 0)                  # seit 1.6.4 ohne Abschneiden (Entscheidung 19)
    (asset_args === nothing || asset_args isa Union{NamedTuple,AbstractDict}) || chk_stop("liste", fn, "asset_args")
    bad = [String(k) for (k, _) in kwargs if String(k) in ("event_col", "event_mode", "event_weight", "balance_mode", "balance_thresh") ||
           startswith(String(k), "rebalance.")]
    isempty(bad) || error("tactical_simulation steuert $(join(_unique(bad), ", ")) selbst.")
    sim_args = SimLev._sim_args_set(RList(), RList((String(k) => v for (k, v) in kwargs)...), "tactical_simulation")
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
    lag = Int(lag)
    fl = data isa RFrame ? get(SimLev.attrs(data), "filled", nothing) : nothing
    if lag > 0
        real = trues(n)
        # seit 1.6.4 (T3-N1) auch als RFrame, wie series_align es ablegt (bis 1.6.3 nur Matrix: gefüllte Tage nie
        # erkannt, Wechsel auch auf LOCF-Tagen); wie R nur mit Spaltennamen
        Fm, fcols, fnr = fl isa Union{AbstractMatrix,RFrame} ? SimLev._filled_matrix(fl) : (nothing, nothing, 0)
        if Fm !== nothing && fnr == n && fcols !== nothing
            fa = [a for a in assets if a in fcols]
            if !isempty(fa)
                F = Float64[Fm[i, findfirst(==(a), fcols)] ? 1.0 : 0.0 for i in 1:n, a in fa]
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
    dp = get(sim_args, "dca", nothing)
    if dp !== nothing
        cal = collect(d[1]:Day(1):d[n])
        liq = get(sim_args, "liquidate", nothing)
        flg = SimLev.calculate_dates_flags(true, dp["span"], dp["unit"], dp["days"], cal; value = dp["value"],
                                           anchor = dp["anchor"], start_date = dp["start"], skip_start = dp["skip"],
                                           liquidate = liq === nothing ? false : liq)
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
    # Ereignis-Rebalancing nur an den Terminen, ohne Umschichten am ersten Tag (skip = true)
    rb = SimLev.rebalance_plan(; event_col = ".tev", event_mode = "replace", skip = true,
                               event_weight = RList((a => c for (a, c) in zip(assets, wcols))...), thresh = tolerance,
                               thresh_type = tolerance_type)
    res = SimLev._sim_call(df, st, RList("rebalance" => rb, SimLev._sim_kv(sim_args)...))
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
