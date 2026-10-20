# Sensitivity – r/R/sensitivity.R (Vorlage python/simlev/sensitivity.py)
#
#  sensitivity_grid()         beliebige simulation()-Argumente im Raster
#  rebalancing_sensitivity()  Rebalancing-Frequenz, Versatz und Bänder
#  lumpsum_vs_dca()           Einmalanlage gegen gestreckten Einstieg
#  leveraged_series()         Hebelreihe aus einem Index (MSCI-Formel)
#  leverage_sensitivity()     Kennzahlen über den Hebel, optimaler Hebel
module Sensitivity

import ..SimLev
using Dates

const SL = SimLev
const NA = SimLev.NA
const OF = SimLev.Overfitting
const PS = SimLev.ParamSearch

export sensitivity_grid, rebalancing_sensitivity, lumpsum_vs_dca, leveraged_series, leverage_sensitivity

_metrics(m) = m === nothing ? SL.Bootstrap.study_metrics : m
_sim(data, strategy, args) = OF._quiet(() -> SL.simulation(data, strategy; Dict{Symbol,Any}(Symbol(k) => v for (k, v) in args)...))

"`table(errs)` als Text `<msg> (<n> x); ...` (Namen sortiert wie R, Kollation `RStats.str_collate`)."
function _table_msg(errs)
    cnt = Dict{String,Int}()
    for e in errs
        OF._isna(e) && continue
        cnt[e] = get(cnt, e, 0) + 1
    end
    return join(["$k ($(cnt[k]) x)" for k in sort(collect(keys(cnt)); alg = MergeSort, lt = SimLev.RStats.r_isless)], "; ")
end

_is_listval(v) = v isa AbstractVector && !(v isa AbstractString)
"Zelle `i` einer Rasterspalte (Listen-Spalte: das Element; R: Länge 1 = Skalar)."
_cell(col, i) = (v = col[i]; v isa SL.RVector ? v.values : v)
_is_na_scalar(v) = (_is_listval(v) && length(v) == 1) ? OF._isna(v[1]) : (!_is_listval(v) && OF._isna(v))

"`expand.grid(grid)` bzw. data.frame unverändert."
function _grid_frame(grid)
    grid isa SL.RFrame && return grid
    kv = OF._kv(grid)
    return PS._expand_grid(String[p.first for p in kv], Any[_is_listval(p.second) ? collect(p.second) : [p.second] for p in kv])
end

# ═════════════════════════════════════════════════════════════════════════════
# sensitivity_grid
# ═════════════════════════════════════════════════════════════════════════════

"""
    sensitivity_grid(data, strategy, grid; sim_args = RList(), metrics = study_metrics,
                     cores = 1, keep_results = false)

Ruft `simulation()` für jede Kombination von `grid` (benannte Liste von
Argumentwerten oder `RFrame` mit einer Zeile je Lauf; `NA`/`missing` lässt
das Argument weg) auf und sammelt die Kennzahlen in einem `RFrame`.
"""
function sensitivity_grid(data, strategy, grid; sim_args = nothing, metrics = nothing, cores = 1,
                          keep_results::Bool = false)
    data = SimLev.as_rframe(data)
    sim_args = sim_args === nothing ? SL.RList() : OF._as_rlist(sim_args)
    metrics = _metrics(metrics)
    design = _grid_frame(grid)
    SL.nrow(design) == 0 && error("Leeres Raster.")
    function run(i)
        a = SL.RList()
        for k in names(design)
            v = _cell(design[k], i)
            _is_na_scalar(v) || (a[k] = v)
        end
        args = OF._modify_list(sim_args, a)
        res = try
            _sim(data, strategy, args)
        catch e
            e isa InterruptException && rethrow()
            return (m = nothing, err = OF._cond_msg(e), res = nothing)
        end
        return (m = OF._metric_pairs(metrics(res)), err = missing, res = keep_results ? res : nothing)
    end
    out = PS._par_lapply(1:SL.nrow(design), run, cores)
    okm = [o.m for o in out if o.m !== nothing]
    isempty(okm) && error("sensitivity_grid: Alle $(length(out)) Läufe fehlgeschlagen: $(_table_msg([o.err for o in out]))")
    mnames = okm[1][1]
    tab = SL.RFrame()
    for k in names(design)
        col = design[k]
        if any(_is_listval, col)
            col = String[_is_listval(v) ? join([OF._as_chr(e) for e in v], "/") : OF._as_chr(v) for v in col]
        end
        tab = _addcol(tab, k, col, SL.nrow(design))
    end
    for (j, k) in enumerate(mnames)
        tab = _addcol(tab, k, Float64[o.m === nothing ? NA : (p = findfirst(==(k), o.m[1]); p === nothing ? NA : o.m[2][p]) for o in out],
                      SL.nrow(design))
    end
    errs = Union{Missing,String}[o.err for o in out]
    all(ismissing, errs) || (tab["error"] = errs)
    keep_results && (SL.attrs(tab)["results"] = Any[o.res for o in out])
    return tab
end
_addcol(tab::SL.RFrame, k, col, n) = SL.ncol(tab) == 0 ? SL.RFrame(k => col; nrow = n) : (tab[k] = col; tab)

# ═════════════════════════════════════════════════════════════════════════════
# Rebalancing
# ═════════════════════════════════════════════════════════════════════════════

const _FREQ = ["monthly" => ("month", 1), "bimonthly" => ("month", 2), "quarterly" => ("quarter", 1),
               "four_monthly" => ("month", 4), "semiannual" => ("month", 6), "yearly" => ("year", 1)]

_num_of(x) = x isa AbstractString ? parse(Float64, x) : Float64(x)
_isna_lgl(v) = v === missing || v === nothing      # logisches NA (R: NA)

"""
    rebalancing_sensitivity(data, strategy; frequencies = (monthly … yearly), offsets = nothing,
                            bands = missing, band_type = "absolute", include_none = true,
                            sim_args = RList(), metrics = study_metrics, cores = 1)

Vergleicht Rebalancing-Frequenzen (`name => (unit, span)`), Versatz vor dem
Periodenende (`offsets`, Kalendertage) und Toleranzbänder (`bands`, Prozent;
`missing`/`NA` = an jedem Termin). Ergebnis: `RFrame` der Klasse
`SimLevSensitivity` (Attribut `kind = "rebalancing"`).
"""
function rebalancing_sensitivity(data, strategy; frequencies = nothing, offsets = nothing, bands = missing,
                                 band_type = nothing, include_none::Bool = true, sim_args = nothing, metrics = nothing,
                                 cores = 1)
    data = SimLev.as_rframe(data)
    band_type = OF._match_arg(band_type, ("absolute", "relative"))
    frequencies = frequencies === nothing ? _FREQ : OF._kv(frequencies)
    sim_args = sim_args === nothing ? SL.RList() : OF._as_rlist(sim_args)
    metrics = _metrics(metrics)
    offs = offsets === nothing ? Any[missing] : Any[e for e in PS._vec(offsets)]
    bnds = Any[e for e in PS._vec(bands)]
    rows = Vector{Any}()
    for (fn, f) in frequencies
        f = collect(f)
        for off in offs, b in bnds
            a = SL.RList("balance_mode" => true, "balance_unit" => String(string(f[1])), "balance_span" => _num_of(f[2]),
                         "balance_thresh_type" => band_type)
            if !OF._isna(off)
                a["balance_anchor"] = "end"; a["balance_days"] = off + 1
            end
            OF._isna(b) || (a["balance_thresh"] = b)
            push!(rows, (label = (fn, off, b, band_type), args = a))
        end
    end
    include_none && push!(rows, (label = ("none", missing, missing, missing), args = SL.RList("balance_mode" => false)))
    function run(i)
        args = OF._modify_list(sim_args, rows[i].args)
        res = try
            _sim(data, strategy, args)
        catch e
            e isa InterruptException && rethrow()
            return OF._cond_msg(e)
        end
        return OF._metric_pairs(metrics(res))
    end
    out = PS._par_lapply(1:length(rows), run, cores)
    ok = [!(o isa AbstractString) for o in out]
    any(ok) || error("rebalancing_sensitivity: Alle $(length(out)) Läufe fehlgeschlagen: $(_table_msg(out))")
    good = out[ok]; lab = [r.label for r in rows[ok]]
    mnames = good[1][1]
    n = length(good)
    tab = SL.RFrame("frequency" => String[l[1] for l in lab],
                    "offset" => _lblcol([l[2] for l in lab]), "band" => _lblcol([l[3] for l in lab]),
                    "band_type" => Union{Missing,String}[l[4] for l in lab]; class = ["SimLevSensitivity", "data.frame"])
    for (j, k) in enumerate(mnames)
        tab[k] = Float64[g[2][j] for g in good]
    end
    SL.attrs(tab)["kind"] = "rebalancing"
    return tab
end
"Beschriftungsspalte: nur logische NA → logisch, sonst numerisch mit NA."
_lblcol(v) = all(_isna_lgl, v) ? Union{Missing,Bool}[missing for _ in v] : Float64[OF._f64(e) for e in v]

# ═════════════════════════════════════════════════════════════════════════════
# Lump Sum vs. DCA
# ═════════════════════════════════════════════════════════════════════════════

_num_str(x) = OF._as_chr(Float64(x))

"`seq.Date(s, by = \"<k> <einheit>\", length.out = 2)[2]` (POSIXlt-Normalisierung)."
function _seq_date_2nd(s::Date, by::AbstractString)
    parts = split(by, " ")
    unit = parts[end]
    k = length(parts) > 1 ? trunc(Int, parse(Float64, parts[1])) : 1
    y, m, d = Dates.yearmonthday(s)
    if startswith(unit, "year")
        y2, m2 = y + k, m
    else
        tot = (m - 1) + k
        y2, m2 = y + fld(tot, 12), mod(tot, 12) + 1
    end
    return Date(y2, m2, 1) + Day(d - 1)
end

_rep_get(rep, a, key) = (r = rep[a]; v = r isa AbstractDict || r isa SL.RList ? r[key] : getproperty(r, Symbol(key)); Float64[Float64(e) for e in v])

"""
    lumpsum_vs_dca(data, strategy; amount = 10000, months = 12, horizon = 10, step = 1,
                   sim_args = RList(), cores = 1)

Einmalanlage gegen Einstieg in `months` Monatsraten für rollierende
Starttermine (Monatserste); Vergleich des Vermögens nach `horizon` Jahren.
Ergebnis: `RFrame` der Klasse `SimLevLumpSum` mit Attributen `summary` und
`settings`.
"""
function lumpsum_vs_dca(data, strategy; amount = 10000, months = 12, horizon = 10, step = 1, sim_args = nothing,
                        cores = 1)
    data = SimLev.as_rframe(data)
    sim_args = sim_args === nothing ? SL.RList() : OF._as_rlist(sim_args)
    own = [k for k in keys(sim_args) if k in ("start_value", "dca_mode", "dca_value", "dca_span", "dca_unit", "dca_skip")]
    isempty(own) || error("lumpsum_vs_dca setzt $(join(own, ", ")) selbst; aus sim_args entfernen (Betrag über amount, Raten über months).")
    data = PS._as_frame(data)
    data["date"] = OF._dates(data["date"], "lumpsum_vs_dca: data\$date")
    data = SL.rows(data, OF._order(Float64[OF._days(v) for v in data["date"]]))
    d = collect(Date, data["date"])
    dn = Float64[OF._days(v) for v in d]
    tm = get(sim_args, "tax_mode", nothing)
    tm isa AbstractString && tm == "person" &&
        @warn "Mit Steuern ist die Fortschreibung des DCA-Depots nach der Einstiegsphase eine Näherung (Index der Einmalanlage)."
    firsts = d[Dates.day.(d) .== 1]
    last_ok = _seq_date_2nd(maximum(d), "-" * _num_str(horizon) * " years")
    starts = firsts[firsts .<= last_ok]
    sel = PS._seq_by(1, length(starts), step)
    starts = starts[Int.(sel)]
    isempty(starts) && error("Historie zu kurz für den Horizont.")
    hz = _num_str(horizon) * " years"; mo = _num_str(months) * " months"
    cache = Dict{String,Vector{Float64}}()
    function px(a, dates)
        haskey(cache, a) || (cache[a] = OF._tofloat(SL.Backcast._fill_na(OF._tofloat(data[a]), "locf")))
        return Float64[cache[a][searchsortedlast(dn, Float64(OF._days(t)))] for t in dates]
    end
    function run(s)
        e = _seq_date_2nd(s, hz) - Day(1)
        e_dca = _seq_date_2nd(s, mo) - Day(1)
        w = SL.rows(data, (d .>= s) .& (d .<= e))
        ls = _sim(w, strategy, OF._modify_list(SL.RList("start_value" => amount), sim_args))
        wd = SL.rows(data, (d .>= s) .& (d .<= e_dca))
        dca = _sim(wd, strategy, OF._modify_list(SL.RList("start_value" => amount / months, "dca_mode" => true,
                                                           "dca_value" => amount / months, "dca_span" => 1,
                                                           "dca_unit" => "month", "dca_skip" => true), sim_args))
        ix = SL.Withdrawal.result_index(ls)
        ixd = collect(Date, ix["date"]); ixv = OF._tofloat(ix["value"])
        k = findfirst(==(maximum(wd["date"])), ixd)
        assets = collect(keys(dca.report))
        rws = k:length(ixd)
        const_ = all(map(assets) do a
            p = px(a, ixd[rws]); u = _rep_get(ls.report, a, "worth")[rws] ./ p
            all(isfinite, u) && all(abs.(u .- u[1]) .<= 1e-9 * max(1, abs(u[1])))
        end)
        dca_end = if const_
            nd = length(dca.worth)
            SL.r_sum(Float64[_rep_get(dca.report, a, "worth")[nd] / px(a, [dca.dates[nd]])[1] * px(a, [ixd[end]])[1] +
                             _rep_get(dca.report, a, "money")[nd] for a in assets])
        else
            dca.worth[end] * ixv[end] / ixv[k]
        end
        return (Float64(ls.worth[end]), Float64(dca_end), const_)
    end
    res = PS._par_lapply(starts, run, cores)
    lump = Float64[r[1] for r in res]; dcav = Float64[r[2] for r in res]
    adv = lump ./ dcav .- 1
    tab = SL.RFrame("start" => starts, "lump_sum" => lump, "dca" => dcav, "advantage" => adv,
                    "exact" => Bool[r[3] for r in res]; class = ["SimLevLumpSum", "data.frame"])
    win = adv .> 0
    SL.attrs(tab)["summary"] = SL.RVector([OF._mean_lgl(collect(win)), SL.r_mean(adv), OF._median(adv),
                                           any(win) ? SL.r_mean(adv[win]) : NA, any(.!win) ? SL.r_mean(adv[.!win]) : NA];
                                          names = ["win_rate", "mean_advantage", "median_advantage", "mlsa", "mlsd"])
    SL.attrs(tab)["settings"] = SL.RList("amount" => amount, "months" => months, "horizon" => horizon)
    return tab
end

function _print_lumpsum(io::IO, x)
    s = SL.attrs(x)["summary"]; st = SL.attrs(x)["settings"]
    amt = SL.RFmt.formatC(st["amount"]; format = "f", digits = 0, big_mark = " ")
    amt = amt isa AbstractString ? String(amt) : String(first(amt))
    print(io, OF._spf("Lump Sum vs. DCA: %d Starttermine, %s in %d Monatsraten, Horizont %g Jahre\n",
                      SL.nrow(x), amt, st["months"], Float64(st["horizon"])))
    print(io, OF._spf("  Einmalanlage vorn:          %.1f %% der Starttermine\n", 100 * s["win_rate"]))
    print(io, OF._spf("  Vorsprung Mittel / Median:  %+.2f %% / %+.2f %%\n", 100 * s["mean_advantage"], 100 * s["median_advantage"]))
    print(io, OF._spf("  MLSA (wenn vorn):           %+.2f %%\n", 100 * s["mlsa"]))
    print(io, OF._spf("  MLSD (wenn hinten):         %+.2f %%\n", 100 * s["mlsd"]))
    nothing
end

# ═════════════════════════════════════════════════════════════════════════════
# Hebel
# ═════════════════════════════════════════════════════════════════════════════

_col(data, k) = data isa SL.RFrame ? data[k] : OF._lget(data, k)

"""
    leveraged_series(data, index; leverage = 2, rate = 0, expense = 0, spread = 0, start = 100)

Täglich zurückgesetzte Hebelreihe (Niveau) aus der Indexspalte `index`:
`r = L x + (1 - L) i T/360 - TER T/365 - s m(L) T/360` (Raten in Prozent
p. a.; `rate` als Zahl, Spaltenname, Vektor, data.frame(date, value) oder
benannter Vektor).
"""
function leveraged_series(data, index; leverage = 2, rate = 0, expense = 0, spread = 0, start = 100)
    data = SimLev.as_rframe(data)
    idx = OF._tofloat(SL.Backcast._fill_na(OF._tofloat(_col(data, String(index))), "locf"))
    dts = Float64[OF._days(v) for v in OF._dates(_col(data, "date"), "data\$date")]
    dd = vcat(1.0, dts[2:end] .- dts[1:end-1])
    x = vcat(0.0, idx[2:end] ./ idx[1:end-1] .- 1)
    rt = OF._tofloat(PS._vec(SL.Backcast._resolve_series(rate, data, "rate")))
    L = Float64(leverage)
    m = max(L - 1, 0.0) + max(-L, 0.0)
    ex = Float64(expense); sp = Float64(spread)
    r = L .* x .+ (1 - L) .* rt ./ 100 .* dd ./ 360 .- ex / 100 .* dd ./ 365 .- sp / 100 * m .* dd ./ 360
    r[1] = 0.0
    ko = findfirst(<=(-1), r)
    ko === nothing || (r[ko:end] .= -1.0)
    v = Float64(start) .* OF._cumprod(1 .+ r)
    v[v .< 0] .= 0.0
    return v
end

"""
    leverage_sensitivity(data, index; leverages = 0.5:0.25:4, rate = 0, expense = 0, spread = 0,
                         strategy = nothing, sim_args = RList(), metrics = study_metrics, cores = 1)

Kennzahlen über den Hebel: je Hebel eine Reihe aus [`leveraged_series`](@ref)
als Asset `LEV` simuliert. Ergebnis: `RFrame` der Klasse
`SimLevSensitivity` mit Attributen `optimal` (Hebel mit maximaler CAGR bzw.
Sharpe Ratio) und `kind = "leverage"`.
"""
function leverage_sensitivity(data, index; leverages = nothing, rate = 0, expense = 0, spread = 0, strategy = nothing,
                              sim_args = nothing, metrics = nothing, cores = 1)
    data = SimLev.as_rframe(data)
    leverages = leverages === nothing ? PS._seq_by(0.5, 4, 0.25) : OF._tofloat(PS._vec(leverages))
    sim_args = sim_args === nothing ? SL.RList() : OF._as_rlist(sim_args)
    metrics = _metrics(metrics)
    strategy === nothing && (strategy = SL.create_strategy("LEV" => SL.asset_config("etf", "bnh"; asset_bonus = 30)))
    dts = OF._dates(_col(data, "date"), "data\$date")
    function run(L)
        lev = leveraged_series(data, index; leverage = L, rate = rate, expense = expense, spread = spread)
        lev[lev .<= 0] .= 1e-8
        df = SL.RFrame("date" => dts, "LEV" => lev)
        res = try
            _sim(df, strategy, sim_args)
        catch e
            e isa InterruptException && rethrow()
            return nothing
        end
        return OF._metric_pairs(metrics(res))
    end
    out = PS._par_lapply(leverages, run, cores)
    ok = [o !== nothing for o in out]
    good = out[ok]
    tab = SL.RFrame("leverage" => leverages[ok]; class = ["SimLevSensitivity", "data.frame"], nrow = count(ok))
    if !isempty(good)
        for (j, k) in enumerate(good[1][1])
            tab[k] = Float64[g[2][j] for g in good]
        end
    end
    SL.attrs(tab)["kind"] = "leverage"
    lv = tab["leverage"]
    jc = haskey(tab, "cagr") ? OF._which_max(tab["cagr"]) : nothing
    js = haskey(tab, "sharpe") ? OF._which_max(tab["sharpe"]) : nothing
    # R: c(cagr = lev[which.max(cagr)], sharpe = ...): ein leeres which.max lässt das Element weg
    on = String[]; ov = Float64[]
    jc === nothing || (push!(on, "cagr"); push!(ov, lv[jc]))
    if haskey(tab, "sharpe")
        js === nothing || (push!(on, "sharpe"); push!(ov, lv[js]))
    else
        push!(on, "sharpe"); push!(ov, NA)
    end
    SL.attrs(tab)["optimal"] = SL.RVector(ov; names = on)
    return tab
end

# ═════════════════════════════════════════════════════════════════════════════
# print / plot
# ═════════════════════════════════════════════════════════════════════════════

function _print_sens(io::IO, x)
    keep = [c for c in ("frequency", "offset", "band", "band_type", "leverage", "cagr", "ttwror", "max_drawdown",
                        "sharpe", "ulcer_index", "taxes", "trades") if haskey(x, c)]
    y = SL.RFrame((c => x[c] for c in keep)...; nrow = SL.nrow(x))
    if haskey(y, "cagr") && haskey(y, "ttwror") && SL.RLinalg.all_equal_numeric(OF._tofloat(y["cagr"]), OF._tofloat(y["ttwror"])) === true
        y = PS._select(y, [c for c in names(y) if c != "ttwror"])
    end
    bt = String[]
    if haskey(y, "band_type")
        btv = y["band_type"]
        sel = haskey(y, "band") ? [!OF._isna(b) for b in y["band"]] : trues(length(btv))
        bt = unique([v === missing ? "NA" : v for v in btv[sel]])
    end
    if haskey(y, "band_type") && length(bt) <= 1
        y = PS._select(y, [c for c in names(y) if c != "band_type"])
        length(bt) == 1 && print(io, "Toleranzbänder: ", bt[1] == "relative" ? "relativ (% des Zielgewichts)" : "absolut (Prozentpunkte)", "\n")
    end
    if haskey(y, "band")
        b = y["band"]
        fb = OF._formatv(b)
        y["band"] = String[OF._isna(b[i]) ? "-" : fb[i] for i in eachindex(b)]
    end
    for k in ("cagr", "ttwror", "max_drawdown"); haskey(y, k) && (y[k] = OF._spfv("%.2f %%", 100 .* OF._tofloat(y[k]))); end
    for k in ("sharpe", "ulcer_index"); haskey(y, k) && (y[k] = OF._spfv("%.3f", OF._tofloat(y[k]))); end
    for k in ("taxes", "trades"); haskey(y, k) && (y[k] = OF._spfv("%.1f", OF._tofloat(y[k]))); end
    print(io, OF._print_df(y), "\n")
    haskey(y, "cagr") && print(io, "cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts\n")
    opt = get(SL.attrs(x), "optimal", nothing)
    if opt !== nothing
        ov = opt isa SL.RVector ? opt.values : opt isa AbstractVector ? opt : [opt]
        o(i) = i <= length(ov) ? OF._f64(ov[i]) : NA          # R: x[i] jenseits der Länge = NA
        print(io, OF._spf("Optimaler Hebel: CAGR %.2f, Sharpe %.2f\n", o(1), o(2)))
    end
    nothing
end

function _plot_sens(x; metric = "cagr", file = nothing, kw...)
    kind = get(SL.attrs(x), "kind", "grid")
    sc = metric in ("cagr", "ttwror", "max_drawdown", "avg_drawdown") ? 100 : 1
    y = sc .* OF._tofloat(x[metric])
    f = OF._fig(720, 460)
    if kind == "leverage"
        lv = OF._tofloat(x["leverage"])
        p = OF._panel(f, 70, 40, 620, 360, OF._range(lv), OF._range(y); title = "$metric nach Hebel", xlab = "Hebel", ylab = metric)
        OF._pline!(f, p, lv, y); OF._ppoints!(f, p, lv, y)
        j = OF._which_max(x[metric])
        j === nothing || OF._pvline!(f, p, lv[j]; width = 1, dash = "2,3")
    else
        n = length(y)
        lab = String[]
        for i in 1:n
            b = x["band"][i]; o = x["offset"][i]
            push!(lab, join([x["frequency"][i], OF._isna(b) ? "" : "±" * OF._as_chr(b), OF._isna(o) ? "" : "-" * OF._as_chr(o) * "d"], " "))
        end
        lo, hi = OF._range(vcat(0.0, y))
        p = OF._panel(f, 160, 40, 530, 380, (lo, hi), (0.5, n + 0.5); title = "Rebalancing-Varianten: $metric", xlab = metric,
                      yticks = collect(1.0:n), yticklabels = reverse(lab), grid = false)
        for (i, v) in enumerate(reverse(y))
            isfinite(v) && OF._prect!(f, p, 0.0, i - 0.35, v, i + 0.35)
        end
    end
    OF._finish(f; file = file)
end

function __init__()
    SL.register_print!("SimLevSensitivity", _print_sens)
    SL.register_plot!("SimLevSensitivity", SL._plot_method(_plot_sens, "SimLevSensitivity"))
    SL.register_print!("SimLevLumpSum", _print_lumpsum)
end

end # module
