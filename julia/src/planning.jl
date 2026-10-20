# Planning – r/R/planning.R (Vorlage python/simlev/planning.py)
#
#   set_expected_return()  verschiebt historische Renditen auf eine eigene
#                          Renditeannahme (Streuung, Abhängigkeiten und
#                          Verlaufsmuster bleiben erhalten)
#   pooled_bootstrap()     stationärer Block-Bootstrap über mehrere Länder
#                          (Anarkulova, Cederburg & O'Doherty 2022)
#   portfolio_returns()    Periodenrenditen von Kandidaten-Portfolios
#   goal_optimize()        dynamische Programmierung für Zielwahrscheinlich-
#                          keiten (Das, Ostrov, Radhakrishnan & Srivastav 2020)
module Planning

import ..SimLev
using Dates

export set_expected_return, pooled_bootstrap, portfolio_returns, goal_optimize

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
# set_expected_return
# ═══════════════════════════════════════════════════════════════════════════

"""
    set_expected_return(data, columns, target; type = ["returns", "prices"], ppy = nothing)

Verschiebt die logarithmierten Renditen der Spalten `columns` so, dass ihre
geometrische Rendite `target` Prozent p. a. beträgt (R: `set_expected_return()`).
Ergebnis: Kopie von `data`; `attrs(x)["shift"]` = angewendete Verschiebung je
Spalte in Prozent p. a.
"""
function set_expected_return(data, columns, target; type = ["returns", "prices"], ppy = nothing)
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
    dd = "date" in nms ? DA._to_date_days(data["date"], "set_expected_return: data\$date") : nothing
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
    pooled_bootstrap(datasets, columns; weights = nothing, inflation = nothing,
                     frequency = ["year", "quarter", "month"], n = 1000, years = 30, L = nothing,
                     country_weights = nothing, target = nothing, seed = nothing)

Länder-Bootstrap für lange Horizonte (R: `pooled_bootstrap()`); Ergebnis ist
ein `withdrawal_paths`-Objekt (`RList`).
"""
function pooled_bootstrap(datasets, columns; weights = nothing, inflation = nothing,
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
    function draw_all()
        out = Tuple{Vector{Int},Vector{Int}}[]
        for _ in 1:nn
            ctry = zeros(Int, nper); row = zeros(Int, nper); t = 1
            while t <= nper
                cidx = Int(DA._first(SimLev.RRng.sample_int(nc, 1; prob = cw)))
                len = 1 + Float64(DA._first(SimLev.RRng.rgeom(1, 1 / Lf)))
                nr = nrs[cidx]
                st = Int(DA._first(SimLev.RRng.sample_int(nr, 1)))
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
    draw = SimLev.Bootstrap._with_rng_restore(draw_all; seed = seed)
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

"`A %*% x` (Matrix mal Vektor) wie R."
function _matvec(A::AbstractMatrix, x::AbstractVector)
    r = SimLev.RLinalg.matprod(Matrix{Float64}(A), reshape(collect(Float64, x), :, 1))
    DA._vecf(r isa SimLev.NamedMat ? r.data : r)
end

"""
    portfolio_returns(data, candidates; frequency = ["year", "quarter", "month"])

Brutto-Periodenrenditen von Kandidaten-Portfolios mit festen Gewichten
(R: `portfolio_returns()`); `candidates`: Liste benannter Gewichtsvektoren.
Ergebnis: NamedMat Perioden x Kandidaten.
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
# goal_optimize
# ═══════════════════════════════════════════════════════════════════════════

"`approx(x, y, xout, rule = 2)\$y`."
function _approx2(x, y, xout)
    r = SimLev.RStats.approx(collect(Float64, x), collect(Float64, y); xout = collect(Float64, xout), rule = 2)
    DA._vecf(DA._rget(r, "y"))
end

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
    goal_optimize(returns, start_value, goal, horizon; contributions = 0, n_grid = 301,
                  n_sim = 5000, seed = nothing)

Zielbasierte Allokation per dynamischer Programmierung (R: `goal_optimize()`).
Ergebnis: `RList` der Klasse `SimLevGoalPlan`.
"""
function goal_optimize(returns, start_value, goal, horizon; contributions = 0, n_grid = 301, n_sim = 5000, seed = nothing)
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
    term(W) = Float64[w >= goal ? 1.0 : 0.0 for w in W]
    V = term(grid)
    pol = zeros(Int, horizon, ng)
    Vt = Vector{Any}(undef, horizon + 1); Vt[horizon+1] = V
    function interp(Vn, W)
        W = W isa AbstractVector ? W : [Float64(W)]
        out = zeros(length(W))
        for i in eachindex(W)
            W[i] >= wmax && (out[i] = wmax >= goal ? 1.0 : 0.0)
            W[i] <= 0 && (out[i] = 0.0)
        end
        mid = findall(w -> w > 0 && w < wmax, W)
        if !isempty(mid)
            z = DA._vecf(SimLev.RNmath.qnorm([min(1 - 1e-12, max(1e-12, v)) for v in Vn]))
            Wm = W[mid]
            pn = DA._vecf(SimLev.RNmath.pnorm(_approx2(lgrid, z, SimLev.RLibm.log.(Wm))))
            alt = goal > 0 ? 0.0 : Float64(Vn[1])
            for (q, i) in enumerate(mid)
                out[i] = Wm[q] < wmin ? alt : pn[q]
            end
        end
        out
    end
    function expect(Vn, base, k, last)
        Rk = R[:, k]
        X = [b * r for b in base, r in Rk]
        xv = vec(X)
        v = reshape(last ? term(xv) : interp(Vn, xv), size(X))
        e = DA._row_means(v)
        e[base .<= 0] .= 0.0
        e
    end
    static = zeros(K)
    for k in 1:K
        Vs = V
        for t in horizon:-1:1
            Vs = expect(Vs, grid .+ cf[t], k, t == horizon)
        end
        static[k] = interp(Vs, start_value)[1]
    end
    lr = SimLev.RLibm.log.(max.(R, 1e-300))
    sds = Float64[SimLev.r_sd(lr[:, j]) for j in 1:K]
    risk_rank = zeros(Int, K); risk_rank[sortperm(sds; alg = MergeSort)] = 1:K
    tie = Float64.(K + 1 .- risk_rank)
    for t in horizon:-1:1
        base = grid .+ cf[t]
        E = reduce(hcat, [expect(V, base, k, t == horizon) for k in 1:K])
        E = reshape(E, ng, K)
        for i in 1:ng
            mx = DA._rmax(E[i, :])
            best_j = 0; best_s = -Inf
            for j in 1:K
                sc = E[i, j] >= mx - 1e-9 ? tie[j] : 0.0
                if sc > best_s
                    best_s = sc; best_j = j
                end
            end
            pol[t, i] = best_j
        end
        V = Float64[E[i, pol[t, i]] for i in 1:ng]
        Vt[t] = V
    end
    p_dp = interp(V, start_value)[1]
    function run()
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
            draw = Int.(DA._vecf(SimLev.RRng.sample_int(S, nsim; replace = true)))
            W = Float64[alive[i] ? base[i] * R[draw[i], k[i]] : 0.0 for i in 1:nsim]
        end
        SimLev.RList("terminal" => W, "choice" => choice, "success" => .!ruined .& (W .>= goal))
    end
    sim = SimLev.Bootstrap._with_rng_restore(run; seed = seed)
    p_sim = DA._mean_lgl(sim["success"])
    se = sqrt(p_sim * (1 - p_sim) / nsim)
    tol = 4 * sqrt(max(p_sim * (1 - p_sim), 1 / nsim) / nsim) + 0.01
    if abs(p_dp - p_sim) > tol
        @warn DA._sp("goal_optimize: DP-Wert %.1f %% weicht von der Vorwärtssimulation %.1f %% ab; probability ist der simulierte Wert (n_grid erhöhen).",
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
    pal = DA._ramp(["#2C6E9B", "#F2E9DC", "#B5562B"], max(K, 1))
    lg = log10.(g[keep])
    s = DA._Svg(900, 520)
    yr = isempty(lg) ? (0.0, 1.0) : (minimum(lg), maximum(lg))
    p = DA._panel(s, 0, 0, 800, 520, (0.5, H + 0.5), yr; title = "Optimale Wahl je Zeit und Vermögen",
                  xlab = "Periode", ylab = "Vermögen (log10)", xticks = collect(1:H))
    for t in 1:H, (q, y) in enumerate(lg)
        lo = q == 1 ? y : (lg[q-1] + y) / 2; hi = q == length(lg) ? y : (lg[q+1] + y) / 2
        DA._rect(s, p, t - 0.5, lo, t + 0.5, hi; fill = pal[clamp(P[t, q], 1, length(pal))])
    end
    goal > 0 && DA._hline(s, p, log10(goal); col = "#000", dash = "5,4")
    DA._legend(s, p, DA._strs(x["candidates"]), pal; x = 800.0, y = 50.0, box = true)
    SimLev.SimLevDashboard(DA._svg_done(s, file))
end

function __init__()
    SimLev.register_print!("SimLevGoalPlan", _print_goalplan)
    SimLev.register_plot!("SimLevGoalPlan", SimLev._plot_method(_plot_goalplan, "SimLevGoalPlan"))
end

end # module
