# ParamSearch – r/R/param_search.R (Vorlage python/simlev/param_search.py)
#
#  param_space() / param_range()   Suchraum (diskret oder kontinuierlich)
#  param_search()                  Raster, Zufallssuche oder Latin Hypercube;
#                                  simulation() je Punkt, Kennzahlen und
#                                  tägliche TWR-Renditen
#  plateau()                       Nachbarschafts-Glättung der Zielgröße
module ParamSearch

import ..SimLev
using Dates

const SL = SimLev
const NA = SimLev.NA
const OF = SimLev.Overfitting

export param_space, param_range, param_search, plateau

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

Suchraum für [`param_search`](@ref): je Parameter eine benannte Dimension
mit diskreten Werten (Vektor) oder einem Bereich aus [`param_range`](@ref).
Ergebnis: `RList` der Klasse `SimLevParamSpace`.
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
    return SL.RList(items...; class = "SimLevParamSpace")
end

_fmt_any(v) = join(OF._formatv(v), ", ")

"""
    param_range(lower, upper; n = 5, step = nothing, integer = false, log = false)

Stetiger Bereich einer Dimension (Klasse `SimLevParamRange`): Raster mit `n`
Punkten bzw. Schrittweite `step` (`method = "grid"`), sonst gleichverteilte
(bei `log = true` log-gleichverteilte) Ziehung zwischen `lower` und `upper`.
"""
function param_range(lower, upper; n = 5, step = nothing, integer::Bool = false, log::Bool = false)
    (_is_num(lower) && _is_num(upper) && !(upper < lower)) || error("param_range: lower <= upper erforderlich.")
    log && lower <= 0 && error("param_range: log = TRUE erfordert lower > 0.")
    if step === nothing && !(_is_num(n) && isfinite(n) && n >= 1 && n == OF._r_round(n))
        error("param_range: n (Anzahl Rasterpunkte) muss eine ganze Zahl >= 1 sein (erhalten: $(_fmt_any(n))).")
    end
    if step !== nothing && !(_is_num(step) && isfinite(step) && step > 0)
        error("param_range: step muss eine Zahl > 0 sein (erhalten: $(_fmt_any(step))).")
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
function _ps_design(space, method, n, constraint)
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
                    s = Float64[Float64(v) for v in SL.RRng.sample_int(m)]
                    U[:, j] = (s .- Float64[Float64(v) for v in _vec(SL.RRng.runif(m))]) ./ m
                else
                    U[:, j] = Float64[Float64(v) for v in _vec(SL.RRng.runif(m))]
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
    a = OF._lget(sp, "args")
    args = OF._modify_list(sim_args === nothing ? SL.RList() : sim_args, a === nothing ? SL.RList() : a)
    kw = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in args)
    st = OF._lget(sp, "strategy")
    return OF._quiet(() -> SL.simulation(df, st; kw...))
end

"`.par_lapply(X, FUN, cores)`."
function _par_lapply(X, f, cores)
    (cores <= 1 || length(X) <= 1) && return Any[f(x) for x in X]
    return collect(Any, SL.Bootstrap._par_lapply(collect(X), f, cores))
end

"`.with_rng_restore(expr, seed = seed)` mit explizit übergebenem `seed`."
_with_rng(f, seed) = seed === nothing ? f() : SL.Bootstrap._with_rng_restore(f; seed = seed)

# ═════════════════════════════════════════════════════════════════════════════
# Parametersuche
# ═════════════════════════════════════════════════════════════════════════════

"""
    param_search(data, builder, space; strategy = nothing, method = "grid", n = 50,
                 constraint = nothing, sim_args = RList(), burn_in = 0,
                 metrics = study_metrics, objective = "sharpe", maximize = true,
                 cores = 1, seed = nothing, keep_returns = true)
    param_search(data; space, strategy, ...)

Wertet eine Strategie für jeden Punkt eines Parameterraums mit `simulation()`
aus. `builder(p)` erhält eine benannte Liste `p` (`RList`) und liefert eine
Strategie oder eine Spezifikation `(strategy, signal, args, map, data)`
(RList, NamedTuple oder Dict). Ohne `builder` werden die Parameter als
Argumente von `simulation()` für `strategy` verwendet. Ergebnis: `RList` der
Klasse `SimLevParamSearch` (`results`, `returns`, `dates`, …).
"""
param_search(data, builder_pos = nothing; builder = builder_pos, space, kw...) = param_search(data, builder, space; kw...)
function param_search(data, builder, space; strategy = nothing, method = nothing, n = 50, constraint = nothing,
                      sim_args = nothing, burn_in = 0, metrics = nothing, objective = "sharpe", maximize = true,
                      cores = 1, seed = nothing, keep_returns::Bool = true)
    data = SimLev.as_rframe(data)
    method = OF._match_arg(method, ("grid", "random", "lhs"))
    sim_args = sim_args === nothing ? SL.RList() : OF._as_rlist(sim_args)
    metrics === nothing && (metrics = SL.Bootstrap.study_metrics)
    (space isa SL.RList && SL.inherits(space, "SimLevParamSpace")) || (space = param_space(OF._kv(space)...))
    if builder === nothing
        strategy === nothing && error("param_search: 'builder' oder 'strategy' angeben.")
        fixed = strategy
        builder = p -> SL.RList("strategy" => fixed, "args" => p)
    end
    design = _with_rng(() -> _ps_design(space, method, n, constraint), seed)
    t0 = time()
    function run(i)
        p = _row_list(design, i)
        res = try
            _run_spec(data, _as_spec(builder(p)), sim_args, burn_in)
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
        mp = OF._metric_pairs(m)
        if keep_returns
            ix = SL.Withdrawal.result_index(res)
            v = Float64[Float64(e) for e in ix["value"]]
            return (m = mp, err = missing, date = collect(Date, ix["date"]), ret = v[2:end] ./ v[1:end-1] .- 1)
        end
        return (m = mp, err = missing, date = nothing, ret = nothing)
    end
    out = _par_lapply(1:SL.nrow(design), run, cores)
    okm = [o for o in out if o.m !== nothing]
    isempty(okm) && error("param_search: alle Punkte fehlgeschlagen, z. B.: $(out[1].err)")
    mnames = okm[1].m[1]
    objective in mnames || error("objective '$objective' nicht in metrics(): $(join(mnames, ", "))")
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
    if keep_returns
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

"Nachbarschaften im Parameterraum (`.ps_neighbours`): je Punkt 1-basierte Zeilennummern."
function _ps_neighbours(x; radius = 1, k = 5)
    params = OF._strs(x["params"])
    res = x["results"]
    nr = SL.nrow(res)
    if x["method"] == "grid"
        L = [_match(res[p], _ps_levels(x["space"][p])) for p in params]
        out = Vector{Vector{Int}}()
        for i in 1:nr
            ok = Int[]
            for r in 1:nr
                good = true
                for c in eachindex(params)
                    a = L[c][r]; b = L[c][i]
                    (a === nothing || b === nothing || abs(a - b) > radius) && (good = false; break)
                end
                good && push!(ok, r)
            end
            push!(out, ok)
        end
        return out
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

const _LOWER_BETTER = ("max_drawdown", "avg_drawdown", "dd_q50", "dd_q90", "ulcer_index", "longest_drawdown")

"""
    plateau(x; metric = x.objective, radius = 1, k = 5)

Plateau-Wert je Punkt einer Parametersuche: Mittel (`plateau_mean`) und
ungünstigster Wert (`plateau_min`) der Kennzahl über die Nachbarschaft
(Raster: höchstens `radius` Stufen je Dimension; sonst die `k` nächsten
Punkte im rangskalierten Raum). Ergebnis: `RFrame`.
"""
function plateau(x; metric = nothing, radius = 1, k = 5)
    (x isa SL.RList && SL.inherits(x, "SimLevParamSearch")) || error("x muss ein SimLevParamSearch sein.")
    metric === nothing && (metric = x["objective"])
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
    pl = plateau(object)
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

_print_ps(io::IO, x) = _print_summary_ps(io, _summary_ps(x))

function _plot_ps(x; metric = nothing, params = nothing, fun = maximum, file = nothing, kw...)
    tab = x["results"]
    metric === nothing && (metric = x["objective"])
    params = params === nothing ? OF._strs(x["params"])[1:min(2, end)] : OF._strs(params)
    agg(v) = (w = filter(isfinite, v); isempty(w) ? NA : fun(w))
    vals = OF._tofloat(tab[metric])
    f = OF._fig(700, 460)
    if length(params) == 1
        g = tab[params[1]]
        lev = sort(unique(collect(g)); alg = MergeSort, lt = SimLev.RStats.r_isless)
        a = Float64[agg(vals[[_same(e, l) for e in g]]) for l in lev]
        xs = Float64[_is_num(l) ? Float64(l) : i for (i, l) in enumerate(lev)]
        p = OF._panel(f, 70, 40, 600, 360, OF._range(xs), OF._range(a); title = "$metric nach $(params[1])",
                      xlab = params[1], ylab = metric)
        OF._pline!(f, p, xs, a); OF._ppoints!(f, p, xs, a)
        return OF._finish(f; file = file)
    end
    if x["method"] != "grid"
        xs = OF._tofloat(tab[params[1]]); ys = OF._tofloat(tab[params[2]])
        lo, hi = extrema(filter(!isnan, vals); init = (0.0, 1.0))
        cols = [isnan(v) ? "#cccccc" : OF._ramp((v - lo) / max(hi - lo, 1e-12)) for v in vals]
        p = OF._panel(f, 70, 40, 600, 360, OF._range(xs), OF._range(ys); title = "$metric (Farbe; blau = hoch)",
                      xlab = params[1], ylab = params[2])
        OF._ppoints!(f, p, xs, ys; color = cols, r = 5)
        return OF._finish(f; file = file)
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
    p = OF._panel(f, 70, 40, 600, 360, (0.5, length(l1) + 0.5), (0.5, length(l2) + 0.5); title = "$metric (blau = hoch)",
                  xlab = params[1], ylab = params[2], xticks = collect(1.0:length(l1)), xticklabels = OF._formatv(l1),
                  yticks = collect(1.0:length(l2)), yticklabels = OF._formatv(l2), grid = false)
    sc = metric in ("cagr", "ttwror", "max_drawdown", "avg_drawdown") ? 100 : 1
    for i in eachindex(l1), j in eachindex(l2)
        v = M[i, j]
        isnan(v) && continue
        OF._prect!(f, p, i - 0.5, j - 0.5, i + 0.5, j + 0.5; fill = OF._ramp((v - lo) / max(hi - lo, 1e-12)))
        length(M) <= 300 && OF._text!(f, OF._tx(p, i), OF._ty(p, j) + 4, OF._spf(sc == 100 ? "%.1f" : "%.2f", sc * v); size = 9)
    end
    return OF._finish(f; file = file)
end

function __init__()
    SL.register_print!("SimLevParamSpace", _print_space)
    SL.register_print!("SimLevParamSearch", _print_ps)
    SL.register_summary!("SimLevParamSearch", _summary_ps)
    SL.register_print!("summary.SimLevParamSearch", _print_summary_ps)
    SL.register_plot!("SimLevParamSearch", SL._plot_method(_plot_ps, "SimLevParamSearch"))
end

end # module
