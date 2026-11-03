# Planning – Gegenstück zu r/R/planning.R und python/simlev/planning.py
#
#   series_shift_return()  verschiebt historische Renditen auf eine eigene
#                          Renditeannahme (Streuung, Abhängigkeiten und
#                          Verlaufsmuster bleiben erhalten)
#   bootstrap_pooled()     stationärer Block-Bootstrap über mehrere Länder
#                          (Anarkulova, Cederburg & O'Doherty 2022)
#   portfolio_returns()    Periodenrenditen von Kandidaten-Portfolios
#   planning_goal()        dynamische Programmierung für Zielwahrscheinlich-
#                          keiten (Das, Ostrov, Radhakrishnan & Srivastav 2020)
module Planning

import ..SimLev
using ..SimLev: _AnaSvg, _ana_hline, _ana_legend, _ana_panel, _ana_ramp, _ana_rect, _ana_svg_done
using Dates

export series_shift_return, bootstrap_pooled, portfolio_returns, planning_goal

const DA = SimLev.DeepAnalysis
const _NA = SimLev.NA

"Werte und Namen eines numerischen Arguments (Skalar, Vektor, RVector, Dict, Paare)."
function _numvals(x)
    x isa SimLev.RVector && return Any[v for v in x.values], x.names
    x isa AbstractDict && return Any[v for v in values(x)], String[String(string(k)) for k in keys(x)]
    x isa AbstractVector{<:Pair} && return Any[p.second for p in x], String[String(string(p.first)) for p in x]
    x isa NamedTuple && return Any[v for v in values(x)], String[String(k) for k in keys(x)]
    x isa Union{AbstractVector,Tuple} && return Any[v for v in x], nothing
    Any[x], nothing
end
_all_num(a) = all(DA._isnum_el, a)
_as_num(a) = Float64[Float64(e) for e in a]
_cols(columns) = columns isa AbstractString ? [String(columns)] : String[String(c) for c in columns]

# ═══════════════════════════════════════════════════════════════════════════
# series_shift_return
# ═══════════════════════════════════════════════════════════════════════════

"""
    series_shift_return(data, columns, target; type = ["returns", "prices"], ppy = nothing)

Historische Renditen auf eine Renditeannahme verschieben.

Historische Mittelwerte sind für die Zukunft oft zu optimistisch (z. B. US-Aktien des 20. Jahrhunderts). Diese
Funktion verschiebt die logarithmierten Renditen jeder Spalte um eine Konstante, so dass die geometrische
Rendite der Historie der Annahme entspricht. Streuung der Log-Renditen, Schiefe, Abhängigkeiten und zeitliche
Muster bleiben unverändert; ein anschließender `bootstrap()` zieht dann Pfade mit der gewünschten
Renditeerwartung. Eingabe ist ein Tabelle (RFrame) mit Brutto-Renditen je Zeile oder mit Kursniveaus; zurück
kommt derselbe Tabelle (RFrame) mit verschobenen Spalten.

# Argumente
- `data`: Tabelle (RFrame) mit den Spalten aus `columns`; die Spalte `date` (Klasse Date oder in Date
  umwandelbar) wird für den Standardwert von `ppy` und bei `type = "prices"` für die zeitliche Reihenfolge
  gebraucht (Zeilen müssen nicht sortiert sein, die Zeilenreihenfolge des Ergebnisses bleibt erhalten; ohne
  `date` gilt die Zeilenreihenfolge als Zeitfolge). Eine Matrix ist nicht zulässig.
- `columns`: Zeichenvektor mit den Namen der zu verschiebenden Spalten.
- `target`: Geometrische Zielrendite in Prozent p. a. (4 = 4 % p. a.): Skalar (gilt für alle `columns`) oder
  benannter Vektor mit einem Eintrag je Spalte aus `columns` (z. B. `(us = 5, eu = 5)`); fehlt eine Spalte,
  bricht die Funktion ab.
- `type`: Art der Spalten: `"returns"` (Standard; Brutto-Renditen je Zeile, z. B. 1.001 für +0,1 %, wie für
  `bootstrap()`) oder `"prices"` (Kursniveaus; die Verschiebung wird dann als Trend über die Zeilen
  aufmultipliziert).
- `ppy`: Renditen (Zeilen) je Jahr. `nothing` (Standard): bei einem Tabelle (RFrame) mit `date` Anzahl der
  Renditen geteilt durch die Spanne von `date` in Jahren (Tage / 365.25), sonst 252.

# Rückgabe
`data` mit angepassten Spalten. Attribut `shift`: benannter Vektor der angewendeten Verschiebung je Spalte in
Prozent p. a. (geometrisch; negativ = Rendite abgesenkt). Fehlende Werte werden bei der Mittelwertbildung
ignoriert.

# Beispiel
```julia
using SimLev, Dates, Random
d = RFrame("date" => Date(2000, 1, 1) .+ Day.(0:3649), "us" => exp.(3e-4 .+ 0.01 .* randn(MersenneTwister(1), 3650)))
d2 = series_shift_return(d, "us", 4)
println(prod(d2["us"])^(365.25 / 3650) - 1)   # etwa 0.04 = 4 % p. a.
```
"""
function series_shift_return(data, columns, target; type = ["returns", "prices"], ppy = nothing)
    data = SimLev.as_rframe(data)
    type = DA._match_arg(type, ["returns", "prices"])
    DA._is_frame(data) || DA._stop("data muss ein data.frame sein.")
    data = DA._as_frame(data)
    columns = _cols(columns)
    nms = names(data)
    miss = [c for c in unique(columns) if !(c in nms)]
    isempty(miss) || DA._stop(DA._sp("Spalte(n) nicht in data: %s.", join(miss, ", ")))
    tv, tn = _numvals(target)
    (_all_num(tv) && !any(isnan, _as_num(tv))) || DA._stop("target muss numerisch sein (Prozent p. a., z. B. 4).")
    tvf = _as_num(tv)
    tg = Dict{String,Float64}()
    if length(tvf) == 1 && tn === nothing
        for c in columns
            tg[c] = tvf[1]
        end
    elseif tn === nothing || any(c -> !(c in tn), columns)
        lst = tn === nothing ? columns : [c for c in columns if !(c in tn)]
        DA._stop(DA._sp("target braucht einen Skalar oder einen benannten Eintrag je Spalte aus columns; fehlt für: %s.", join(lst, ", ")))
    else
        for (k, v) in zip(tn, tvf)
            haskey(tg, k) || (tg[k] = v)
        end
    end
    n = SimLev.nrow(data)
    dd = "date" in nms ? DA._to_date_days(data["date"], "series_shift_return: data\$date") : nothing
    o = if dd !== nothing
        ok = findall(!isnan, dd); nn = findall(isnan, dd)
        vcat(ok[sortperm(dd[ok]; alg = MergeSort)], nn)
    else
        collect(1:n)
    end
    if type == "prices" && dd !== nothing
        keys_ = [isnan(v) ? :NA : v for v in dd]
        length(unique(keys_)) < length(keys_) &&
            DA._stop("type = 'prices': date enthält doppelte Daten; Kursniveaus brauchen eine eindeutige Zeitfolge.")
    end
    if ppy === nothing
        if dd !== nothing
            ok = filter(!isnan, dd)
            ppy = (n - (type == "prices" ? 1 : 0)) / ((maximum(ok) - minimum(ok)) / 365.25)
        else
            ppy = 252.0
        end
    end
    ppy = Float64(ppy)
    out = copy(data)
    ucol = unique(columns)
    shift = Dict{String,Float64}()
    for k in columns
        v = DA._as_numeric_col(data[k])
        lr = type == "returns" ? SimLev.RLibm.log.(v) : (lv = SimLev.RLibm.log.(v[o]); Float64[lv[i] - lv[i-1] for i in 2:length(lv)])
        g_hist = SimLev.r_mean(lr; na_rm = true)
        g_tgt = SimLev.RLibm.log1p(tg[k] / 100) / ppy
        delta = g_tgt - g_hist
        if type == "returns"
            out[k] = v .* SimLev.RLibm.exp(delta)
        else
            pos = zeros(n); pos[o] = 1:n
            out[k] = Float64[v[i] * SimLev.RLibm.exp(delta * (pos[i] - 1)) for i in 1:n]
        end
        shift[k] = 100 * SimLev.RLibm.expm1(delta * ppy)
    end
    SimLev.attrs(out)["shift"] = SimLev.RVector(Float64[shift[k] for k in ucol]; names = ucol)
    out
end

# ═══════════════════════════════════════════════════════════════════════════
# Periodenrenditen
# ═══════════════════════════════════════════════════════════════════════════

function _period_keys(d, frequency)
    frequency == "month" && return DA._key_month(d)
    if frequency == "quarter"
        return Int[(k ÷ 100) * 10 + ((k % 100) - 1) ÷ 3 for k in DA._key_month(d)]
    end
    DA._key_year(d)
end

"Periodenrenditen (brutto) aus Kursreihen (`.period_gross`): NamedMat Perioden x Spalten."
function _period_gross(df, columns, frequency)
    df = DA._as_frame(df)
    columns = _cols(columns)
    d = DA._to_date_days(df["date"], "data\$date")
    key = _period_keys(d, frequency)
    e = DA._last_of_key(key)
    V = zeros(length(e), length(columns))
    for (j, k) in enumerate(columns)
        V[:, j] = DA._f64(SimLev.Backcast._fill_na(DA._as_numeric_col(df[k]), "locf"; keep_leading = true))[e]
    end
    nr = size(V, 1)
    G = nr >= 1 ? V[2:end, :] ./ V[1:end-1, :] : zeros(0, length(columns))
    ok = [!any(isnan, G[i, :]) for i in 1:size(G, 1)]
    SimLev.NamedMat(G[ok, :]; colnames = columns)
end

_wd_ppy(frequency) = SimLev.Withdrawal._wd_ppy(frequency)

"""
    bootstrap_pooled(datasets, columns; weights = nothing, inflation = nothing,
                     frequency = ["year", "quarter", "month"], n = 1000, years = 30, L = nothing,
                     country_weights = nothing, target = nothing, seed = nothing)

Länder-Bootstrap für lange Horizonte.

Stationärer Block-Bootstrap über mehrere Länder: Jeder Block stammt aus einem zufällig gezogenen Land
(Standard: gleich wahrscheinlich) und beginnt an einer zufälligen Stelle seiner Historie; Blockgrenzen sind
geometrisch verteilt (Politis & Romano 1994). Innerhalb eines Blocks bleiben alle Spalten eines Landes
gemeinsam (Aktien, Anleihen, Inflation). So gehen auch Märkte mit schlechten Phasen (Kriege, Hyperinflation,
lange Baissen) in die Planung ein - US-Daten allein überschätzen langfristige Renditen (Anarkulova, Cederburg
& O'Doherty 2022).

# Argumente
- `datasets`: Benannte Liste von Tabelle (RFrame) (Name = Land), jeweils mit Spalte `date` (Klasse Date oder
  umwandelbar), den Kursspalten aus `columns` (Total-Return-Niveaus, keine Renditen) und ggf. der
  Preisindex-Spalte aus `inflation`. Jedes Land braucht mindestens 2 vollständige Periodenrenditen.
- `columns`: Zeichenvektor der Kursspalten (in allen Ländern gleich benannt).
- `weights`: Vektor der Portfolio-Gewichte (>= 0) mit einem Eintrag je Spalte aus `columns`: benannt mit genau
  diesen Spaltennamen oder unbenannt in der Reihenfolge von `columns` (wird auf Summe 1 normiert; Rebalancing
  auf die Gewichte in jeder Periode). `nothing` (Standard) = gleiche Gewichte. Die Portfoliorendite ist die
  Renditequelle für `withdrawal_simulation()`.
- `inflation`: `nothing` (Standard; keine Inflation, Faktor 1) oder Name einer Preisindex-Spalte (Niveau, z.
  B. CPI), die in allen Ländern vorhanden ist. Sie wird im selben Block wie die Kurse gezogen.
- `frequency`: Periodenlänge: `"year"` (Standard), `"quarter"` oder `"month"`.
- `n`: Anzahl simulierter Pfade (Standard 1000).
- `years`: Länge jedes Pfads in Jahren (Standard 30); ergibt `years` x Perioden je Jahr (1, 4 bzw. 12)
  Perioden.
- `L`: Mittlere Blocklänge in Perioden der gewählten `frequency` (Blocklänge = 1 + geometrisch verteilte Zahl
  mit Mittel `L` - 1). `nothing` (Standard) = 10 Jahre, also 10 Jahre, 40 Quartale bzw. 120 Monate.
- `country_weights`: Numerischer Vektor der Ziehungswahrscheinlichkeiten je Land in der Reihenfolge von
  `datasets` (wird auf Summe 1 normiert). `nothing` (Standard) = alle Länder gleich wahrscheinlich.
- `target`: Optional Renditeannahmen in Prozent p. a. (geometrisch): Skalar für alle `columns` oder benannter
  Vektor je Spalte. Die Verschiebung wird über die gepoolten Renditen aller Länder bestimmt und für alle
  Länder gleich angewendet (wie `series_shift_return()`). `nothing` (Standard) = historische Renditen.
- `seed`: Startwert der Ziehung (Standard `nothing`). Mit Startwert (ganze Zahl, |seed| < 2^53) ist das
  Ergebnis reproduzierbar und der Zufallszustand von SimLev bleibt unverändert; mit `nothing` wird genau
  einmal ein Startwert aus dem Zufallszustand von SimLev gezogen (siehe `simlev_seed()`), wiederholte Aufrufe
  liefern dann verschiedene Ergebnisse. `set.seed()` wirkt nicht.

# Rückgabe
Objekt der Klasse `withdrawal_paths` (Liste) mit `returns` (Matrix Perioden x Pfade der
Brutto-Portfoliorenditen), `inflation` (Matrix gleicher Form, Brutto-Inflation je Periode; ohne `inflation`
überall 1), `frequency`, `source = "pooled_bootstrap"`, `historical = false`, `cape`, `base_rate`,
`start_dates`, `weights` (alle `nothing`) sowie den zusätzlichen Elementen `assets` (benannte Liste der
Brutto-Renditematrizen je Spalte aus `columns`), `countries` (Zeichenmatrix Perioden x Pfade: gezogenes Land)
und `country_names`.

# Details
Die Kursreihen jedes Landes werden zuerst auf Periodenrenditen der gewählten `frequency` verdichtet (Wert am
letzten Datum jeder Kalenderperiode; eine unvollständige letzte Periode zählt mit; nur Perioden ohne fehlende
Werte). Ein Block beginnt an einer zufälligen Periode und läuft am Ende der Landeshistorie zyklisch am Anfang
weiter. Das Ergebnis ist ein `withdrawal_paths`-Objekt und kann direkt an `withdrawal_simulation()`,
`withdrawal_max_rate()` oder `withdrawal_perfect_rate()` übergeben werden.

# Literatur
Anarkulova, A., Cederburg, S. & O'Doherty, M. S. (2022), Stocks for the long run? Evidence from a broad sample
of developed markets, Journal of Financial Economics 143(1), 409-433.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
land(mu) = RFrame("date" => [Date(1950 + k, 12, 31) for k in 0:69],
                  "aktien" => 100 .* cumprod(exp.(mu .+ 0.18 .* randn(rng, 70))),
                  "anleihen" => 100 .* cumprod(exp.(0.02 .+ 0.06 .* randn(rng, 70))),
                  "cpi" => 100 .* cumprod(exp.(0.025 .+ 0.02 .* randn(rng, 70))))
pb = bootstrap_pooled(RList("de" => land(0.05), "us" => land(0.07)), ["aktien", "anleihen"];
                      weights = (aktien = 0.6, anleihen = 0.4), inflation = "cpi", n = 200, years = 30, L = 5, seed = 1)
println(size(pb["returns"]))   # 30 Jahre x 200 Pfade
```
"""
function bootstrap_pooled(datasets, columns; weights = nothing, inflation = nothing,
                          frequency = ["year", "quarter", "month"], n = 1000, years = 30, L = nothing,
                          country_weights = nothing, target = nothing, seed = nothing)
    frequency = DA._match_arg(frequency, ["year", "quarter", "month"])
    dn, dv = DA._is_listlike(datasets) ? DA._list_items(datasets) : (nothing, Any[])
    (dn === nothing || any(==(""), dn)) && DA._stop("datasets muss eine benannte Liste sein (Land -> data.frame).")
    columns = _cols(columns)
    ppy = _wd_ppy(frequency)
    wpair = nothing
    if weights !== nothing
        wv, wn = _numvals(weights)
        if !_all_num(wv) || length(wv) != length(columns) || any(isnan, _as_num(wv)) || any(<(0), _as_num(wv)) ||
           SimLev.r_sum(_as_num(wv)) <= 0
            DA._stop(DA._sp("weights muss je Spalte aus columns (%d) ein Gewicht >= 0 enthalten (Summe > 0).", length(columns)))
        end
        if wn === nothing
            wn = copy(columns)
        elseif Set(wn) != Set(columns)
            DA._stop(DA._sp("Namen von weights (%s) passen nicht zu columns (%s).", join(wn, ", "), join(columns, ", ")))
        end
        wpair = (wn, _as_num(wv))
    end
    cols = inflation === nothing ? columns : vcat(columns, String(inflation))
    G = Matrix{Float64}[Matrix(_period_gross(df, cols, frequency).data) for df in dv]
    any(g -> size(g, 1) < 2, G) && DA._stop("Ein Land hat zu wenige Perioden.")
    ci = Dict{String,Int}()
    for (i, c) in enumerate(cols)
        haskey(ci, c) || (ci[c] = i)
    end
    if target !== nothing
        tv, tn = _numvals(target)
        tvf = _as_num(tv)
        tg = (length(tvf) == 1 && tn === nothing) ? [(c, tvf[1]) for c in columns] :
             tn === nothing ? Tuple{String,Float64}[] : collect(zip(tn, tvf))
        for (k, t) in tg
            j = ci[k]
            all_lr = vcat([SimLev.RLibm.log.(g[:, j]) for g in G]...)
            delta = SimLev.RLibm.log1p(t / 100) / ppy - SimLev.r_mean(all_lr)
            ed = SimLev.RLibm.exp(delta)
            for g in G
                g[:, j] .= g[:, j] .* ed
            end
        end
    end
    Lf = L === nothing ? Float64(10 * ppy) : Float64(L)
    nper = Int(trunc(years * ppy)); nc = length(G)
    cw = country_weights === nothing ? fill(1 / nc, nc) : DA._f64(country_weights)
    cw = cw ./ SimLev.r_sum(cw)
    nrs = [size(g, 1) for g in G]
    nn = Int(n)
    function draw_all(rs)
        out = Tuple{Vector{Int},Vector{Int}}[]
        for _ in 1:nn
            ctry = zeros(Int, nper); row = zeros(Int, nper); t = 1
            while t <= nper
                cidx = Int(first(SimLev.SLib.sample(nc, 1; prob = cw, stream = rs)))
                len = 1 + first(SimLev.SLib.rgeom(1, 1 / Lf; stream = rs))
                nr = nrs[cidx]
                st = Int(first(SimLev.SLib.sample(nr, 1; stream = rs)))
                take = Int(min(len, nper - t + 1))
                for q in 1:take
                    ctry[t-1+q] = cidx
                    row[t-1+q] = ((st - 1 + q - 1) % nr) + 1
                end
                t += take
            end
            push!(out, (ctry, row))
        end
        out
    end
    draw = draw_all(SimLev.SLib.main_stream(seed))        # Hauptstrom
    Gall = reduce(vcat, G)
    off = vcat(0, cumsum(nrs))[1:nc]
    gi = zeros(Int, nper, nn)
    for (j, (c, r)) in enumerate(draw)
        gi[:, j] = off[c] .+ r
    end
    A = Dict{String,Matrix{Float64}}()
    for c in unique(cols)
        A[c] = reshape(Gall[vec(gi), ci[c]], nper, nn)
    end
    wn, wv = wpair === nothing ? (copy(columns), fill(1 / length(columns), length(columns))) : (wpair[1], wpair[2] ./ SimLev.r_sum(wpair[2]))
    Rp = nothing
    for (k, wk) in zip(wn, wv)
        term = wk .* A[k]
        Rp = Rp === nothing ? term : Rp .+ term
    end
    Inf_m = inflation !== nothing ? A[String(inflation)] : ones(nper, nn)
    cmat = Matrix{String}(undef, nper, nn)
    for (j, (c, _)) in enumerate(draw)
        cmat[:, j] = dn[c]
    end
    assets = SimLev.RList()
    for k in columns
        assets[k] = A[k]
    end
    SimLev.RList("returns" => Rp, "inflation" => Inf_m, "cape" => nothing, "base_rate" => nothing, "frequency" => frequency,
                 "historical" => false, "start_dates" => nothing, "weights" => nothing, "source" => "pooled_bootstrap",
                 "assets" => assets, "countries" => cmat, "country_names" => dn; class = ["withdrawal_paths"])
end

# ═══════════════════════════════════════════════════════════════════════════
# portfolio_returns
# ═══════════════════════════════════════════════════════════════════════════

"`A %m% x` (Matrix mal Vektor) wie R (slc-Matrixprodukt)."
function _matvec(A::AbstractMatrix, x::AbstractVector)
    r = SimLev.SLib.matmul(Matrix{Float64}(A), reshape(collect(Float64, x), :, 1))
    DA._vecf(r isa SimLev.NamedMat ? r.data : r)
end

"""
    portfolio_returns(data, candidates; frequency = ["year", "quarter", "month"])

Periodenrenditen von Kandidaten-Portfolios (feste Gewichte, Rebalancing je Periode).

Berechnet aus Kursreihen die Brutto-Periodenrenditen mehrerer Kandidaten-Portfolios mit festen Gewichten
(Rebalancing auf die Gewichte zu Beginn jeder Periode). Eingabe ist ein Tabelle (RFrame) mit Spalte `date`
(Klasse Date) und Kursspalten (Niveaus, keine Renditen); Periodenwerte sind die Kurse am letzten Datum jeder
Kalenderperiode (fehlende Kurse werden fortgeschrieben, eine unvollständige letzte Periode zählt mit). Das
Ergebnis dient als Szenario-Stichprobe für `planning_goal()`.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` und allen in `candidates` genannten Kursspalten (Niveaus).
- `candidates`: Liste von benannten Gewichtsvektoren (Namen = Kursspalten; je Kandidat auf Summe 1 normiert),
  z. B. aus `lapply(seq(0, 1, 0.1), function(a) (aktien = a, anleihen = 1 - a))`. Die Listennamen werden
  Spaltennamen des Ergebnisses; ohne Namen `"P1"`, `"P2"`, ...
- `frequency`: Periodenlänge und Rebalancing-Rhythmus: `"year"` (Standard), `"quarter"` oder `"month"`.

# Rückgabe
Numerische Matrix Perioden x Kandidaten mit Brutto-Renditen (z. B. 1.05 = +5 %); nur Perioden, in denen alle
beteiligten Kursspalten Werte haben.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 3650
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["anleihen"] = 100 .* cumprod(1 .+ 1e-4 .+ 0.002 .* randn(rng, n))
cand = RList("a20" => RList("aktien" => 0.2, "anleihen" => 0.8), "a60" => RList("aktien" => 0.6, "anleihen" => 0.4))
println(size(portfolio_returns(d, cand)))
```
"""
function portfolio_returns(data, candidates; frequency = ["year", "quarter", "month"])
    data = SimLev.as_rframe(data)
    frequency = DA._match_arg(frequency, ["year", "quarter", "month"])
    cn, cands = DA._is_listlike(candidates) ? DA._list_items(candidates) : (nothing, Any[candidates])
    cn === nothing && (cn = ["P$i" for i in eachindex(cands)])
    ws = Tuple{Vector{String},Vector{Float64}}[]
    for w in cands
        wv, wn = _numvals(w)
        push!(ws, (wn === nothing ? String[] : wn, _as_num(wv)))
    end
    a = unique(vcat([wn for (wn, _) in ws]...))
    G = _period_gross(data, a, frequency)
    Gm = G.data
    M = zeros(size(Gm, 1), length(ws))
    for (j, (wn, wv)) in enumerate(ws)
        sub = Gm[:, [findfirst(==(k), a) for k in wn]]
        M[:, j] = _matvec(sub, wv ./ SimLev.r_sum(wv))
    end
    SimLev.NamedMat(M; colnames = cn)
end

# ═══════════════════════════════════════════════════════════════════════════
# planning_goal
# ═══════════════════════════════════════════════════════════════════════════

_fmt_vals(v) = join(DA._format(v isa Union{AbstractVector,Tuple} ? (all(DA._isnum_el, v) ? DA._f64(v) : collect(v)) : v), ", ")

"`as.matrix(returns)` → (Matrix, Spaltennamen, numerisch?)."
function _as_matrix(r)
    if r isa SimLev.NamedMat
        return r.data, r.colnames, eltype(r.data) <: Real && !(eltype(r.data) <: Bool)
    elseif r isa SimLev.RFrame
        isnum = all(c -> DA._col_is_numeric(c), r.cols)
        isnum || return nothing, nothing, false
        M = isempty(r.cols) ? zeros(SimLev.nrow(r), 0) : reduce(hcat, [DA._as_numeric_col(c) for c in r.cols])
        return reshape(M, SimLev.nrow(r), length(r.cols)), names(r), true
    elseif r isa AbstractMatrix
        isnum = eltype(r) <: Real && !(eltype(r) <: Bool)
        return isnum ? Matrix{Float64}(r) : nothing, nothing, isnum
    elseif r isa AbstractVector
        isnum = all(DA._isnum_el, r)
        return isnum ? reshape(DA._f64(r), :, 1) : nothing, r isa SimLev.RVector ? nothing : nothing, isnum
    end
    nothing, nothing, false
end

"""
    planning_goal(returns, start_value, goal, horizon; contributions = 0, n_grid = 301,
                  n_sim = 5000, seed = nothing)

Zielbasierte Allokation per dynamischer Programmierung (Das et al. 2020).

Bestimmt für jeden Zeitpunkt und jedes Vermögen das Portfolio aus einer Kandidatenliste, das die
Wahrscheinlichkeit maximiert, zum Horizont ein Zielvermögen zu erreichen (Das et al. 2020). Ein- und
Auszahlungen je Periode sind möglich; mit Auszahlungen und `goal = 0` wird die Wahrscheinlichkeit maximiert,
dass das Geld bis zum Horizont reicht. Die Renditen werden je Periode aus der Stichprobe `returns` gezogen
(unabhängig über die Zeit; Zeilen = Szenarien, gemeinsam über die Kandidaten). Die Wertfunktion wird auf einem
logarithmischen Vermögensraster gespeichert und dazwischen linear in log(Vermögen) auf der Probit-Skala
(`qnorm` der Wahrscheinlichkeit) interpoliert; in der letzten Periode wird die 0/1-Zielbedingung exakt
ausgewertet.

# Argumente
- `returns`: Numerische Matrix (Szenarien x Kandidaten) von Brutto-Periodenrenditen (z. B. 1.05 = +5 %), z. B.
  aus `portfolio_returns()` (historische Perioden) oder aus Bootstrap-Pfaden. Jede Zeile ist ein gleich
  wahrscheinliches Szenario für eine Periode. Spaltennamen benennen die Kandidaten (fehlen sie: `"P1"`,
  `"P2"`, ...); für die Grafik aufsteigend nach Risiko sortieren.
- `start_value`: Startvermögen (Geldbetrag, > 0).
- `goal`: Zielvermögen zum Horizont (Geldbetrag in denselben Einheiten wie `start_value`; real oder nominal,
  passend zu den Renditen). Erfolg heißt Endvermögen >= `goal`.
- `horizon`: Anzahl Perioden bis zum Ziel (ganze Zahl >= 1; Periodenlänge wie die Zeilen von `returns`, z. B.
  Jahre bei Jahresrenditen). Nicht zu verwechseln mit `horizon` in `withdrawal_simulation()` (Objekt aus
  `withdrawal_horizon()` oder Jahre).
- `contributions`: Zahlung je Periode als Geldbetrag (Standard 0): Skalar oder Vektor (wird mit `rep_len()`
  auf `horizon` Perioden gebracht); positiv = Einzahlung, negativ = Entnahme, jeweils zu Periodenbeginn vor
  der Rendite.
- `n_grid`: Anzahl Punkte des logarithmischen Vermögensrasters (Standard 301, mindestens 2; dazu Ziel und
  Startwert); mehr Punkte = genauer, aber langsamer.
- `n_sim`: Anzahl Pfade der Vorwärtssimulation der optimalen Politik (Standard 5000).
- `seed`: Startwert für die Vorwärtssimulation (Standard `nothing`). Mit Startwert (ganze Zahl, |seed| < 2^53)
  ist das Ergebnis reproduzierbar und der Zufallszustand von SimLev bleibt unverändert; mit `nothing` wird
  genau einmal ein Startwert aus dem Zufallszustand von SimLev gezogen (siehe `simlev_seed()`), wiederholte
  Aufrufe liefern dann verschiedene Ergebnisse. `set.seed()` wirkt nicht.

# Rückgabe
Objekt der Klasse `SimLevGoalPlan` (Liste):

- `probability`: Zielwahrscheinlichkeit der gefundenen Politik als Anteil (0.8 = 80 Prozent): Erfolgsquote der
  Vorwärtssimulation (`mean(simulation["success"])`, siehe Details, Verzerrung).
- `probability_se`: Standardfehler von `probability` (Anteil, aus `n_sim`).
- `probability_dp`: Wert der dynamischen Programmierung (Anteil; Näherung, meist über dem Optimum).
- `static`: Benannter Vektor: Zielwahrscheinlichkeit (Anteil), wenn durchgehend derselbe Kandidat gehalten
  wird.
- `policy`: Ganzzahlige Matrix Perioden x Rasterpunkte: Nummer des optimalen Kandidaten (Spalte von
  `returns`).
- `grid`: Vermögensraster (Geldbeträge, aufsteigend; Länge `n_grid` plus Ziel und Startwert).
- `value`: Liste der Länge `horizon + 1`: Element `t` ist die Zielwahrscheinlichkeit je Rasterpunkt zu Beginn
  von Periode `t` (letztes Element: 0/1 am Horizont).
- `simulation`: Liste mit `terminal` (Endvermögen je Pfad), `choice` (Matrix Perioden x Pfade: gewählter
  Kandidat) und `success` (logisch: nie ruiniert und Endvermögen >= `goal`).
- `goal`, `start_value`, `horizon`: Eingaben.
- `contributions`: Zahlungen je Periode (Länge `horizon`).
- `candidates`: Namen der Kandidaten.

Ausgabe mit `print()`, Grafik der Politik mit `plot()`.

# Details
Das Raster reicht logarithmisch gleichabständig von `max(1e-6, m / 1000)` (m = kleinster positiver Wert von
`goal` und `start_value`) bis `20 * max(goal, start_value)`; `goal` (falls > 0) und `start_value` sind
zusätzlich exakte Rasterpunkte. Fällt das Vermögen nach einer Zahlung auf 0 oder darunter, gilt der Pfad als
gescheitert. Bei Gleichstand (Unterschied unter 1e-9) wählt die Politik den Kandidaten mit der geringsten
Streuung der Log-Renditen. Die Vorwärtssimulation wendet die Politik auf `n_sim` zufällige Pfade an (Kandidat
des nächstniedrigeren Rasterpunkts des Vermögens vor der Zahlung).

Verzerrung: Der DP-Wert (`probability_dp`) ist eine Näherung des Optimums und liegt typischerweise darüber,
weil die interpolierte Wertfunktion die Zielstufe zwischen den Rasterpunkten glättet und das Maximum über
Kandidaten diese Fehler bevorzugt (bei grobem Raster einige Prozentpunkte). Gemeldet wird daher als
`probability` die in der Vorwärtssimulation erreichte Erfolgsquote der gefundenen Politik: eine unverzerrte
Schätzung der Zielwahrscheinlichkeit einer tatsächlich umsetzbaren Politik, also im Erwartungswert höchstens
das Optimum (Stichprobenfehler `probability_se`). Weicht der DP-Wert um mehr als 4 Standardfehler plus 1
Prozentpunkt davon ab, warnt die Funktion (`n_grid` erhöhen). Auch `static` beruht auf der interpolierten
Wertfunktion und kann leicht überschätzt sein.

# Literatur
Das, S. R., Ostrov, D., Radhakrishnan, A. & Srivastav, D. (2020), Dynamic portfolio allocation in goals-based
wealth management, Computational Management Science 17, 613-640.

# Beispiel
```julia
using SimLev, Random
rng = MersenneTwister(1); a = [0.2 0.6 1.0]
R = exp.((0.01 .+ 0.04 .* a) .+ (0.02 .+ 0.16 .* a) .* randn(rng, 500, 3))
gp = planning_goal(R, 100000, 150000, 10; contributions = 2000, n_grid = 101, n_sim = 1000, seed = 1)
println(gp["probability"])
```
"""
function planning_goal(returns, start_value, goal, horizon; contributions = 0, n_grid = 301, n_sim = 5000, seed = nothing)
    returns = SimLev.as_rframe(returns)
    R, cn0, isnum = _as_matrix(returns)
    S, K = R === nothing ? (0, 0) : size(R)
    if !isnum || S == 0 || K == 0 || any(!isfinite, R) || any(<(0), R)
        DA._stop("returns muss eine Matrix (Szenarien x Kandidaten) endlicher Brutto-Renditen >= 0 ohne NA sein (z. B. 1.05).")
    end
    num1(v) = (a = v isa Union{AbstractVector,Tuple} ? collect(v) : [v]; length(a) == 1 && DA._isnum_el(a[1]) && isfinite(Float64(a[1])))
    v1(v) = Float64(DA._first(v))
    (num1(start_value) && v1(start_value) > 0) || DA._stop(DA._sp("start_value muss ein Geldbetrag > 0 sein (erhalten: %s).", _fmt_vals(start_value)))
    (num1(goal) && v1(goal) >= 0) || DA._stop(DA._sp("goal muss ein Geldbetrag >= 0 sein (erhalten: %s).", _fmt_vals(goal)))
    (num1(horizon) && v1(horizon) >= 1 && v1(horizon) == round(v1(horizon))) ||
        DA._stop(DA._sp("horizon muss eine ganze Zahl >= 1 sein (Anzahl Perioden; erhalten: %s).", _fmt_vals(horizon)))
    (num1(n_grid) && v1(n_grid) >= 2) || DA._stop(DA._sp("n_grid muss eine ganze Zahl >= 2 sein (erhalten: %s).", _fmt_vals(n_grid)))
    (num1(n_sim) && v1(n_sim) >= 1) || DA._stop(DA._sp("n_sim muss eine ganze Zahl >= 1 sein (erhalten: %s).", _fmt_vals(n_sim)))
    cv = contributions isa Union{AbstractVector,Tuple} ? collect(contributions) : Any[contributions]
    (_all_num(cv) && !isempty(cv) && all(isfinite, _as_num(cv))) ||
        DA._stop("contributions muss ein endlicher Geldbetrag oder Vektor von Geldbeträgen sein.")
    start_value = v1(start_value); goal = v1(goal); horizon = Int(v1(horizon))
    ngrid = v1(n_grid); nsim = Int(trunc(v1(n_sim)))
    cn = cn0 !== nothing ? cn0 : ["P$j" for j in 1:K]
    cvf = _as_num(cv)
    cf = Float64[cvf[mod1(i, length(cvf))] for i in 1:horizon]
    wmax = max(goal, start_value) * 20
    pos = [v for v in (goal, start_value) if v > 0]
    wmin = max(1e-6, minimum(pos) / 1000)
    lg = DA._vecf(SimLev.RStats.seq_len_out(SimLev.RLibm.log(wmin), SimLev.RLibm.log(wmax), Int(ceil(ngrid))))
    pts = SimLev.RLibm.exp.(lg)
    goal > 0 && push!(pts, goal)
    push!(pts, start_value)
    grid = sort(unique(pts))
    ng = length(grid)
    lgrid = SimLev.RLibm.log.(grid)
    # Rückwärtsrekursion im Kern (core/research_core_impl.h, goal_dp; bis 1.4.3 hier in Julia); Gleichstand
    # (innerhalb 1e-9): Kandidat mit der geringsten Streuung der Log-Renditen
    lr = SimLev.RLibm.log.(max.(R, 1e-300))
    sds = Float64[SimLev.r_sd(lr[:, j]) for j in 1:K]
    risk_rank = zeros(Int, K); risk_rank[sortperm(sds; alg = MergeSort)] = 1:K
    dp = SimLev.DependenceCore.goal_dp(R, grid, cf, goal, wmin, wmax, start_value, Float64.(K + 1 .- risk_rank))
    for _ in 1:dp.collapsed                         # wie stats::approx bei gleichen log(grid)-Werten
        @warn "collapsing to unique 'x' values"
    end
    static = dp.static
    pol = dp.policy
    Vt = Any[dp.value[:, t] for t in 1:horizon+1]
    p_dp = dp.p_dp
    function run(rs)
        W = fill(start_value, nsim)
        choice = zeros(Int, horizon, nsim)
        ruined = fill(false, nsim)
        for t in 1:horizon
            base = W .+ cf[t]
            alive = (base .> 0) .& .!ruined
            ruined = ruined .| .!alive
            g = [max(1, min(ng, searchsortedlast(lgrid, SimLev.RLibm.log(max(w, wmin))))) for w in W]
            k = pol[t, g]
            choice[t, :] = k
            draw = Vector{Int}(SimLev.SLib.sample(S, nsim; replace = true, stream = rs))
            W = Float64[alive[i] ? base[i] * R[draw[i], k[i]] : 0.0 for i in 1:nsim]
        end
        SimLev.RList("terminal" => W, "choice" => choice, "success" => .!ruined .& (W .>= goal))
    end
    sim = run(SimLev.SLib.main_stream(seed))              # Hauptstrom
    p_sim = DA._mean_lgl(sim["success"])
    se = sqrt(p_sim * (1 - p_sim) / nsim)
    tol = 4 * sqrt(max(p_sim * (1 - p_sim), 1 / nsim) / nsim) + 0.01
    if abs(p_dp - p_sim) > tol
        @warn DA._sp("planning_goal: DP-Wert %.1f %% weicht von der Vorwärtssimulation %.1f %% ab; probability ist der simulierte Wert (n_grid erhöhen).",
                     100 * p_dp, 100 * p_sim)
    end
    SimLev.RList("probability" => p_sim, "probability_se" => se, "probability_dp" => p_dp,
                 "static" => SimLev.RVector(static; names = cn), "policy" => pol, "grid" => grid, "value" => Vt,
                 "simulation" => sim, "goal" => goal, "start_value" => start_value, "horizon" => horizon,
                 "contributions" => cf, "candidates" => cn; class = ["SimLevGoalPlan"])
end

_eur(v) = DA._strs(SimLev.RFmt.formatC(DA._rround.(DA._f64(v isa AbstractVector ? v : [v])); format = "d", big_mark = " "))

"`print.SimLevGoalPlan`."
function _print_goalplan(io::IO, x)
    cf = DA._f64(x["contributions"])
    pay = any(!=(0), cf) ? ", Zahlungen " * join(_eur(unique(cf)), "/") * " je Periode" : ""
    print(io, DA._sp("Zielplanung: Ziel %s in %d Perioden, Start %s%s\n", _eur(x["goal"])[1], Int(x["horizon"]),
                     _eur(x["start_value"])[1], pay))
    pse = get(x, "probability_se", nothing)
    print(io, DA._sp("Zielwahrscheinlichkeit dynamisch: %.1f %% (Vorwärtssimulation, SE %.1f Prozentpunkte; DP-Wert %.1f %%)\n",
                     100 * x["probability"], 100 * (pse === nothing ? _NA : pse), 100 * x["probability_dp"]))
    st = x["static"]; sv = DA._f64(st.values)
    best = DA._which_max(sv)
    print(io, DA._sp("Bester fester Kandidat: %s mit %.1f %%\n\n", st.names[best], 100 * sv[best]))
    DA._print_vector(io, SimLev.RVector(Float64[DA._rround(100 * v, 1) for v in sv]; names = st.names))
    cands = DA._strs(x["candidates"])
    first_ = vec(x["simulation"]["choice"][1, :])
    cnt = [count(==(j), first_) for j in eachindex(cands)]
    print(io, "\nWahl im ersten Schritt: ", cands[DA._which_max(Float64.(cnt))], "\n")
    nothing
end

"`plot.SimLevGoalPlan` (SVG): optimale Kandidatenwahl je Periode und Vermögen (log10)."
function _plot_goalplan(x; file = nothing)
    g = DA._f64(x["grid"]); goal = Float64(x["goal"])
    keep = findall(v -> v >= goal / 20 && v <= goal * 3, g)
    P = x["policy"][:, keep]
    K = length(DA._strs(x["candidates"])); H = Int(x["horizon"])
    pal = _ana_ramp(["#2C6E9B", "#F2E9DC", "#B5562B"], max(K, 1))
    lg = log10.(g[keep])
    s = _AnaSvg(900, 520)
    yr = isempty(lg) ? (0.0, 1.0) : (minimum(lg), maximum(lg))
    p = _ana_panel(s, 0, 0, 800, 520, (0.5, H + 0.5), yr; title = "Optimale Wahl je Zeit und Vermögen",
                   xlab = "Periode", ylab = "Vermögen (log10)", xticks = collect(1:H))
    for t in 1:H, (q, y) in enumerate(lg)
        lo = q == 1 ? y : (lg[q-1] + y) / 2; hi = q == length(lg) ? y : (lg[q+1] + y) / 2
        _ana_rect(s, p, t - 0.5, lo, t + 0.5, hi; fill = pal[clamp(P[t, q], 1, length(pal))])
    end
    goal > 0 && _ana_hline(s, p, log10(goal); col = "#000", dash = "5,4")
    _ana_legend(s, p, DA._strs(x["candidates"]), pal; x = 800.0, y = 50.0, box = true)
    # gezeichnete Zellen: Periode, Vermögen (Gitterwert, nicht log10), gewählter Kandidat (Nummer und Name)
    cands = DA._strs(x["candidates"])
    nq = length(keep)
    per = Int[t for t in 1:H for _ in 1:nq]
    ch = Int[Int(P[t, q]) for t in 1:H for q in 1:nq]
    data = SimLev.RList("policy" => SimLev.RFrame("period" => per, "wealth" => Float64[g[keep][q] for _ in 1:H for q in 1:nq],
                                                  "choice" => ch, "candidate" => String[cands[clamp(c, 1, K)] for c in ch]))
    return (_ana_svg_done(s, file), data)
end

function __init__()
    SimLev.register_print!("SimLevGoalPlan", _print_goalplan)
    SimLev.register_plot!("SimLevGoalPlan", SimLev._plot_method(_plot_goalplan, "SimLevGoalPlan"))
end

end # module
