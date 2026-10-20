# Backcast – r/R/backcast.R (Vorlage python/simlev/backcast.py)
#
# Verlängert die Historie eines ETF/ETP (auch gehebelt oder invers) über
# dessen Auflegung hinaus:
#   1. backcast_fit()  passt die Modellparameter auf dem Überlappungszeitraum
#                      von Produkt und Basisindex an,
#   2. backcast()      rechnet das Produkt zurück und verkettet mit der echten
#                      Kursreihe.
#
# Strukturmodell:
#   r_t = beta * L * x_t + (1 - L) * rate_t * T_t / rate_basis - TER_t * T_t / ter_basis
#       - spread * m(L) * T_t / rate_basis - drag * T_t / 365
# PROZENT-KONVENTION: ter, rate, spread und drag in Prozent p. a.
module Backcast

import ..SimLev
using ..SimLev: RList, RFrame, RVector, NamedMat, nrow, ncol, attrs, NA, isna_strict, rows,
                register_print!, register_summary!, register_plot!, r_class, inherits
using Dates

export backcast_fit, backcast

const DP = SimLev.DataPrep

_libm() = SimLev.RLibm
_stats() = SimLev.RStats

# ═══════════════════════════════════════════════════════════════════════════
# Interne Helfer
# ═══════════════════════════════════════════════════════════════════════════

_isnumval(x) = (x isa Real && !(x isa Bool)) ||
               (x isa AbstractVector && !isempty(x) && DP._is_numeric_col(x))

"""
    _resolve_series(x, data, what; default = 0)

Zeitreihe aus flexibler Nutzerangabe auflösen (Port von `.resolve_series`):
`nothing` (→ `default`), Skalar, Vektor der Länge `nrow(data)`, Spaltenname
in `data`, `RFrame(date, value)` als Stufenfunktion oder benannter Vektor mit
Datumsnamen (Wert gilt ab diesem Datum). Liefert einen Float64-Vektor der
Länge `nrow(data)`.
"""
function _resolve_series(x, data, what; default = 0)
    data = SimLev.as_rframe(data)
    n = DP._nrow(data)
    x === nothing && return fill(Float64(default), n)
    xf = DP._as_frame(x)
    if xf isa RFrame
        ncol(xf) < 2 && error("$(what): data.frame braucht die Spalten date und Wert.")
        nm = names(xf)
        dcol = "date" in nm ? "date" : nm[1]
        vcol = [k for k in nm if k != dcol][1]
        return _step_series(DP._to_date(xf[dcol], "$(what): Datum"), DP._as_numeric(xf[vcol]),
                            DP._to_date(DP._col(data, "date"), what))
    end
    xs = x isa RVector ? x.values : x
    if xs isa AbstractString || (xs isa AbstractVector && length(xs) == 1 && xs[1] isa AbstractString)
        c = xs isa AbstractString ? String(xs) : String(xs[1])
        c in DP._names(data) || error("$(what): Spalte '$(c)' fehlt im Datensatz.")
        v = DP._as_numeric(DP._col(data, c))
        any(isnan, v) && (v = _fill_na(v, "locf"))
        return v
    end
    if DP._is_named_numeric(x)
        nms, vals = DP._named_parts(x)
        nd = DP._names_as_dates_optional(nms)
        if length(vals) >= 1 && !any(isnan, nd)
            return _step_series(nd, vals, DP._to_date(DP._col(data, "date"), what))
        end
        xs = vals
    end
    if _isnumval(xs)
        a = xs isa AbstractVector ? DP._as_numeric(xs) : [Float64(xs)]
        length(a) == 1 && return fill(a[1], n)
        length(a) == n && return a
    end
    error("$(what): nicht interpretierbare Angabe (Skalar, Vektor der Länge $(n), Spaltenname, data.frame(date, Wert) oder benannter Vektor mit Datumsnamen).")
end

"""
    _step_series(from, value, dates)

Stufenfunktion: Wert gilt ab Datum (vor dem ersten Datum: erster Wert).
`from` und `dates` als Datumsvektor oder Float64-Tage.
"""
function _step_series(from, value, dates)
    f = DP._days(from)
    v = DP._as_numeric(value)
    o = DP._stable_order(f)
    f = f[o]; v = v[o]
    d = DP._days(dates)
    out = Vector{Float64}(undef, length(d))
    for i in eachindex(d)
        if isnan(d[i])
            out[i] = NA
        else
            k = searchsortedlast(f, d[i])
            k == 0 && (k = 1)
            out[i] = k <= length(v) ? v[k] : NA
        end
    end
    return out
end

_getel(r, k) = r isa AbstractDict ? r[k] : r isa NamedTuple ? getfield(r, Symbol(k)) : getproperty(r, Symbol(k))

"""
    _fill_na(v, method = "locf"; keep_leading = false)

Fehlende Werte füllen (Port von `.fill_na`): `"locf"`, `"linear"`,
`"stine"` (Stineman über `RImputeTS.na_interpolation`; gilt imputeTS als nicht
installiert, wie in R lineare Interpolation mit Hinweis) oder
`"none"`. Mit `keep_leading = true` bleiben führende NA erhalten, sonst wird
rückwärts gefüllt. Liefert eine Float64-Kopie.
"""
function _fill_na(v, method = ("locf", "linear", "stine", "none"); keep_leading::Bool = false)
    method = DP._match_arg(method, ("locf", "linear", "stine", "none"))
    v = DP._as_numeric(v)
    ok = findall(!isnan, v)
    (method == "none" || isempty(ok) || length(ok) == length(v)) && return v
    first_, last_ = ok[1], ok[end]
    if method == "stine" && !SimLev.RSuggests.has("imputeTS")
        DP.message("Hinweis: Paket 'imputeTS' nicht installiert, verwende lineare Interpolation statt Stineman.")
        method = "linear"
    end
    if method == "locf"
        idx = zeros(Int, length(v))
        idx[ok] .= ok
        for i in 2:length(idx)
            idx[i] < idx[i-1] && (idx[i] = idx[i-1])
        end
        idx[idx .== 0] .= first_
        out = v[idx]
    elseif method == "linear"
        out = copy(v)
        inner = first_:last_
        r = _stats().approx(Float64.(ok), v[ok]; xout = Float64.(collect(inner)))
        out[inner] .= _getel(r, "y")
        last_ < length(v) && (out[last_+1:end] .= v[last_])
        first_ > 1 && (out[1:first_-1] .= v[first_])
    else
        out = copy(v)
        inner = first_:last_
        out[inner] .= Float64.(SimLev.RImputeTS.na_interpolation(v[inner]; option = "stine"))
        last_ < length(v) && (out[last_+1:end] .= v[last_])
        first_ > 1 && (out[1:first_-1] .= v[first_])
    end
    keep_leading && first_ > 1 && (out[1:first_-1] .= NA)
    return out
end

"Vektor um `k` Zeilen verschieben (k > 0: Verzögerung). Port von `.shift`."
function _shift(v, k)
    v = Float64.(v)
    n = length(v)
    k = Int(k)
    k == 0 && return copy(v)
    k > 0 && return vcat(fill(NA, k), v[1:max(n - k, 0)])
    return vcat(v[1-k:n], fill(NA, -k))
end

_sq(e) = [x * x for x in e]

"Verlustfunktionen für den Fit (Port von `.bc_loss`)."
function _bc_loss(e, loss)
    e = [x for x in e if isfinite(x)]
    isempty(e) && return Inf
    loss == "rmse" && return sqrt(SimLev.r_mean(_sq(e)))
    loss == "mse" && return SimLev.r_mean(_sq(e))
    loss == "mae" && return SimLev.r_mean(abs.(e))
    loss == "median" && return _stats().median(abs.(e))
    loss == "max" && return maximum(abs.(e))
    error("Unbekannte loss-Funktion '$(loss)'.")
end

"Grid-Search-Metriken (Port von `.bc_metric_table`): bestes Gitterelement je Metrik."
function _bc_metric_table(err_mat::AbstractMatrix, grid)
    nn(x) = [v for v in x if !isnan(v)]
    metrics = [
        "median_absolute_error" => x -> _stats().median(abs.(nn(x))),
        "mean_absolute_error" => x -> SimLev.r_mean(abs.(nn(x))),
        "mean_squared_error" => x -> SimLev.r_mean(_sq(nn(x))),
        "root_mean_squared_error" => x -> sqrt(SimLev.r_mean(_sq(nn(x)))),
        "max_absolute_error" => x -> (y = nn(x); isempty(y) ? -Inf : maximum(abs.(y))),
        "final_absolute_error" => x -> abs(x[findlast(isfinite, x)]),
    ]
    vals = Float64[]
    for (_, f) in metrics
        s = Float64[f(err_mat[:, j]) for j in 1:size(err_mat, 2)]
        push!(vals, Float64(grid[DP._which_min(s)]))
    end
    return RVector(vals; names = first.(metrics))
end

struct _Prep
    data::RFrame
    n::Int
    dates::Vector{Float64}
    idx::Vector{Float64}
    prod::Vector{Float64}
    x::Vector{Float64}
    dd::Vector{Float64}
    leverage::Float64
    ter::Vector{Float64}
    rate::Vector{Float64}
    ter_cost::Vector{Float64}
    fin::Vector{Float64}
    sp_unit::Vector{Float64}
    dr_unit::Vector{Float64}
end

"Überlappung, Komponenten und Hilfsgrößen vorbereiten (Port von `.bc_prepare`)."
function _bc_prepare(data, product, index, ter, leverage, rate, fx, rate_lag,
                     ter_basis, rate_basis, accrual, index_fill, lag)
    data = DP._as_frame(data)
    data isa RFrame || error("'data' muss ein data.frame sein.")
    "date" in names(data) || error("'data' braucht eine Spalte 'date'.")
    data = copy(data)
    dts = DP._to_date(data["date"], "'data\$date'")
    data["date"] = dts
    dd0 = DP._days(dts)
    any(isnan, dd0) && error("'data\$date' enthält fehlende Daten.")
    any(i -> dd0[i+1] <= dd0[i], 1:length(dd0)-1) &&
        error("'data\$date' muss streng aufsteigend und ohne Duplikate sein.")
    for col in (product, index)
        String(col) in names(data) || error("Spalte '$(col)' fehlt im Datensatz.")
    end
    lv = leverage isa RVector ? leverage.values : leverage
    (_isnumval(lv) && length(lv) == 1 && Float64(first(lv)) != 0) || error("'leverage' muss eine Zahl ungleich 0 sein.")
    L = Float64(first(lv))
    idx = DP._as_numeric(data[String(index)])
    fx !== nothing && (idx = idx .* _resolve_series(fx, data, "fx"))
    any(isnan, idx) && (idx = _fill_na(idx, index_fill; keep_leading = true))
    any(v -> !isnan(v) && v <= 0, idx) && error("Indexwerte müssen positiv sein.")
    prod = DP._as_numeric(data[String(product)])
    for i in eachindex(prod)
        (!isnan(prod[i]) && prod[i] <= 0) && (prod[i] = NA)
    end
    n = nrow(data)
    dd = vcat(1.0, Float64[dd0[i+1] - dd0[i] for i in 1:n-1])
    x = vcat(NA, Float64[idx[i] / idx[i-1] - 1 for i in 2:n])
    lag != 0 && (x = _shift(x, lag))
    ter_v = _resolve_series(ter, data, "ter")
    rate_v = _resolve_series(rate, data, "rate")
    rate_lag != 0 && (rate_v = _fill_na(_shift(rate_v, rate_lag), "locf"))
    ter_cost = if accrual == "geometric"
        Float64[SimLev.r_pow(1 + ter_v[i] / 100, dd[i] / ter_basis) - 1 for i in 1:n]
    else
        Float64[ter_v[i] / 100 * dd[i] / ter_basis for i in 1:n]
    end
    fin = Float64[(1 - L) * rate_v[i] / 100 * dd[i] / rate_basis for i in 1:n]
    m_lev = max(L - 1, 0.0) + max(-L, 0.0)
    return _Prep(data, n, dd0, idx, prod, x, dd, L, ter_v, rate_v, ter_cost, fin,
                 Float64[m_lev / 100 * d / rate_basis for d in dd], Float64[d / 100 / 365 for d in dd])
end

_par(p, k) = Float64(p[k])

"Modellrenditen für einen Parametersatz (Port von `.bc_model_returns`)."
function _bc_model_returns(prep::_Prep, par, model, reg = nothing)
    base = if model == "structural"
        b = _par(par, "beta")
        Float64[b * prep.leverage * prep.x[i] + prep.fin[i] - prep.ter_cost[i] for i in 1:prep.n]
    elseif model == "linear"
        cf = _coef(reg)
        Float64[cf[1] + cf[2] * prep.x[i] for i in 1:prep.n]
    else
        out = fill(NA, prep.n)
        ok = findall(isfinite, prep.x)
        p = _stats().predict_smooth_spline(reg["fit"], prep.x[ok])
        out[ok] .= _getel(p, "y")
        out
    end
    sp = _par(par, "spread"); dr = _par(par, "drag")
    return Float64[base[i] - sp * prep.sp_unit[i] - dr * prep.dr_unit[i] for i in 1:prep.n]
end

_coef(reg) = (c = reg["coef"]; c isa RVector ? c.values : collect(Float64, c))

_cumlog(rr) = SimLev.r_cumsum(Float64[_libm().log1p(max(v, -0.999999)) for v in rr])

"Abweichungsvektor(en) im Fit-Fenster (Port von `.bc_errors`)."
function _bc_errors(r, win, obs, objective, horizon)
    rr = Float64.(r[win])
    rr[1] = 0.0
    for i in eachindex(rr)
        isfinite(rr[i]) || (rr[i] = 0.0)
    end
    ls = _cumlog(rr)
    so = ls[obs.pos]; po = obs.logp
    e_lvl = (so .- so[1]) .- (po .- po[1])
    objective == "level" && return e_lvl
    m = length(so)
    h = max(1, Int(trunc(horizon)))
    e_ret = m > h ? Float64[(so[i+h] - so[i]) - (po[i+h] - po[i]) for i in 1:m-h] : Float64[]
    objective == "return" && return e_ret
    return (level = e_lvl, ret = e_ret)
end

"Zielfunktion (Port von `.bc_objective`)."
function _bc_objective(r, win, obs, objective, horizon, loss, hybrid_weight)
    e = _bc_errors(r, win, obs, objective, horizon)
    objective != "hybrid" && return _bc_loss(e, loss)
    return sqrt(hybrid_weight * SimLev.r_mean(_sq(e.ret)) + (1 - hybrid_weight) * SimLev.r_mean(_sq(e.level)))
end

"Kennzahlen Simulation vs. Produkt (Port von `.bc_diagnostics`)."
function _bc_diagnostics(r, win, obs, dates)
    E = _libm()
    rr = Float64.(r[win])
    rr[1] = 0.0
    for i in eachindex(rr)
        isfinite(rr[i]) || (rr[i] = 0.0)
    end
    ls = _cumlog(rr)
    pos = obs.pos
    so = ls[pos] .- ls[pos[1]]
    po = obs.logp .- obs.logp[1]
    m = length(so)
    d_obs = Float64.(dates[win])[pos]
    yrs = (d_obs[m] - d_obs[1]) / 365.25
    ret_s = Float64[E.exp(so[i+1] - so[i]) - 1 for i in 1:m-1]
    ret_p = Float64[E.exp(po[i+1] - po[i]) - 1 for i in 1:m-1]
    diffs = ret_s .- ret_p
    per_year = yrs > 0 ? (m - 1) / yrs : 252.0
    rel = Float64[1 - E.exp(so[i] - po[i]) for i in 1:m]
    c = length(diffs) > 2 ? Float64(_stats().cor(ret_s, ret_p)) : NA
    out = RList()
    out["n_obs"] = m
    out["years"] = yrs
    out["start"] = DP._date_of(d_obs[1])
    out["end"] = DP._date_of(d_obs[m])
    out["tracking_error"] = SimLev.r_sd(diffs) * sqrt(per_year) * 100
    out["tracking_difference"] = yrs > 0 ? (E.exp(so[m] / yrs) - E.exp(po[m] / yrs)) * 100 : NA
    out["cagr_sim"] = yrs > 0 ? E.expm1(so[m] / yrs) * 100 : NA
    out["cagr_product"] = yrs > 0 ? E.expm1(po[m] / yrs) * 100 : NA
    out["final_deviation"] = E.expm1(so[m] - po[m]) * 100
    out["max_abs_deviation"] = maximum(abs.(rel)) * 100
    out["rmse_level"] = sqrt(SimLev.r_mean(_sq(so .- po))) * 100
    out["correlation"] = c
    out["r_squared"] = length(diffs) > 2 ? c * c : NA
    out["deviation"] = RFrame("date" => DP._as_dates(d_obs), "deviation" => rel)
    return out
end

# ── Listen wie R (modifyList, benannte Listen) ─────────────────────────────

function _as_rlist(x)
    x === nothing && return RList()
    x isa RList && return copy(x)
    out = RList()
    if x isa Union{NamedTuple,AbstractDict}
        for (k, v) in pairs(x)
            out[String(string(k))] = v
        end
    elseif x isa AbstractVector{<:Pair} || x isa Tuple
        for p in x
            out[String(string(p.first))] = p.second
        end
    elseif x isa Pair
        out[String(string(x.first))] = x.second
    elseif x isa RVector && x.names !== nothing
        for (k, v) in zip(x.names, x.values)
            out[k] = v
        end
    else
        return nothing
    end
    return out
end

"`utils::modifyList` für flache Listen (`nothing` entfernt Einträge)."
function _modify_list(base, val)
    out = copy(base)
    for (k, v) in _as_rlist(val)
        v === nothing ? delete!(out, k) : (out[k] = v)
    end
    return out
end

_rlist(ps::Pair...) = RList(ps...)

# ═══════════════════════════════════════════════════════════════════════════
# Öffentliche Funktionen
# ═══════════════════════════════════════════════════════════════════════════

_default_grid() = (n = Int(floor((3 - (-3)) / 0.005 + 1e-10)); Float64[min(-3 + i * 0.005, 3.0) for i in 0:n])
_bounds0() = RList("drag" => [-10.0, 10.0], "spread" => [-5.0, 10.0], "beta" => [0.5, 1.5])

_as_chr_vec(x) = x === nothing ? String[] : x isa AbstractString ? [String(x)] : String[string(v) for v in x]

function _fmt_vec(b)
    F = SimLev.RFmt
    s = F.format(b)
    return s isa AbstractString ? [String(s)] : String[String(v) for v in s]
end

"""
    backcast_fit(data, product, index; ter = 0, leverage = 1, rate = nothing, fx = nothing,
                 model = "structural", fit = "drag", fixed = nothing, objective = "level",
                 loss = "rmse", horizon = 1, hybrid_weight = 0.5, lag = 0, rate_lag = 0,
                 start = nothing, end_ = nothing, method = "optimize", grid = nothing,
                 bounds = nothing, ter_basis = 365, rate_basis = 360, accrual = "linear",
                 index_fill = "locf", validate = true)

Backcast-Modell an ein Produkt anpassen (Argumente wie in R, siehe
`r/man/backcast_fit.Rd`; `end` heißt `end_`). `fixed`: benannte Liste fester
Parameter; `grid`: Standard `seq(-3, 3, by = 0.005)`; `bounds`: benannte
Liste mit Suchintervallen (ergänzt die Standardliste). Liefert eine `RList`
der Klasse `SimLevBackcastFit`.
"""
function backcast_fit(data, product, index; ter = 0, leverage = 1, rate = nothing, fx = nothing,
                      model = ("structural", "linear", "spline"), fit = "drag", fixed = nothing,
                      objective = ("level", "return", "hybrid"), loss = ("rmse", "mse", "mae", "median", "max"),
                      horizon = 1, hybrid_weight = 0.5, lag = 0, rate_lag = 0, start = nothing, end_ = nothing,
                      method = ("optimize", "grid"), grid = nothing, bounds = nothing, ter_basis = 365,
                      rate_basis = 360, accrual = ("linear", "geometric"), index_fill = ("locf", "linear", "stine"),
                      validate::Bool = true)
    data = SimLev.as_rframe(data)
    model = DP._match_arg(model, ("structural", "linear", "spline"))
    objective = DP._match_arg(objective, ("level", "return", "hybrid"))
    loss = DP._match_arg(loss, ("rmse", "mse", "mae", "median", "max"))
    method = DP._match_arg(method, ("optimize", "grid"))
    accrual = DP._match_arg(accrual, ("linear", "geometric"))
    index_fill = DP._match_arg(index_fill, ("locf", "linear", "stine"))
    grid = grid === nothing ? _default_grid() : Float64.(grid isa AbstractVector ? grid : [grid])
    fit = unique(_as_chr_vec(fit))
    (!isempty(fit) && !all(f -> f in ("drag", "spread", "beta"), fit)) &&
        error("'fit' darf nur 'drag', 'spread' und 'beta' enthalten.")
    bl = bounds === nothing ? RList() : _as_rlist(bounds)
    (bl === nothing || (length(bl) > 0 && !all(k -> k in ("drag", "spread", "beta"), keys(bl)))) &&
        error("'bounds' muss eine benannte Liste mit Einträgen drag, spread und/oder beta sein, z. B. list(drag = c(-5, 5)).")
    bounds = _modify_list(_bounds0(), bl)
    for (k, b) in bounds
        ok = _isnumval(b) && length(b) == 2
        bb = ok ? DP._as_numeric(b) : Float64[]
        ok = ok && !any(isnan, bb) && bb[1] < bb[2]
        ok || error("bounds\$$(k) muss c(unten, oben) mit unten < oben sein (ist: $(join(_fmt_vec(b), ", "))).")
        bounds[k] = bb
    end
    if model != "structural" && "beta" in fit
        @warn "'beta' wird bei Regressionsmodellen über die Regression geschätzt und hier ignoriert."
        fit = [f for f in fit if f != "beta"]
    end
    if leverage == 1 && "spread" in fit
        @warn "'spread' ist bei leverage = 1 nicht identifizierbar und wird ignoriert."
        fit = [f for f in fit if f != "spread"]
    end

    lag_auto = lag isa AbstractString && lag == "auto"
    rl = Int(trunc(rate_lag))
    prep = _bc_prepare(data, product, index, ter, leverage, rate, fx, rl, ter_basis, rate_basis,
                       accrual, index_fill, lag_auto ? 0 : Int(trunc(lag)))
    if lag_auto
        pr = vcat(NA, Float64[prep.prod[i] / prep.prod[i-1] - 1 for i in 2:prep.n])
        cand = -2:2
        cors = Float64[]
        for k in cand
            xs = _shift(prep.x, k)
            ok = [isfinite(xs[i]) && isfinite(pr[i]) for i in eachindex(xs)]
            push!(cors, count(ok) < 30 ? NA : Float64(_stats().cor(xs[ok], pr[ok])))
        end
        sg = prep.leverage > 0 ? 1.0 : -1.0
        lag = cand[DP._which_max(sg .* cors)]
        prep = _bc_prepare(data, product, index, ter, leverage, rate, fx, rl, ter_basis, rate_basis,
                           accrual, index_fill, Int(lag))
    end

    has = [!isnan(prep.prod[i]) && !isnan(prep.idx[i]) for i in 1:prep.n]
    if start !== nothing
        s0 = DP._as_date_any(start)[1]
        has = has .& (prep.dates .>= s0)
    end
    if end_ !== nothing
        e0 = DP._as_date_any(end_)[1]
        has = has .& (prep.dates .<= e0)
    end
    count(has) < 20 && error("Zu wenige gemeinsame Beobachtungen von Produkt und Index (mindestens 20).")
    hw = findall(has)
    w0, w1 = hw[1], hw[end]
    win = collect(w0:w1)
    inception = DP._date_of(prep.dates[findfirst(!isnan, prep.prod)])

    make_obs(rws) = (pos = findall(has[rws]); (pos = pos, logp = Float64[_libm().log(v) for v in prep.prod[rws][pos]]))
    obs = make_obs(win)

    function fit_reg(rws)
        model == "structural" && return nothing
        o = findall(has[rws]) .+ (rws[1] - 1)
        o = o[o .> 1]
        y = Float64[prep.prod[i] / prep.prod[i-1] - 1 for i in o]
        xx = prep.x[o]
        ok = [isfinite(y[j]) && isfinite(xx[j]) && !isnan(prep.prod[o[j]-1]) for j in eachindex(o)]
        count(ok) < 20 && error("Zu wenige aufeinanderfolgende Beobachtungen für das Regressionsmodell.")
        if model == "linear"
            X = hcat(ones(count(ok)), xx[ok])
            f = _stats().lm_fit(X, y[ok])
            return RList("coef" => _getel(f, "coefficients"))
        end
        return RList("fit" => _stats().smooth_spline(xx[ok], y[ok]; cv = false))
    end
    reg = fit_reg(win)
    par0 = _modify_list(RList("drag" => 0.0, "spread" => 0.0, "beta" => 1.0), fixed)

    function obj_fun(theta, rws, ob, rg)
        p = copy(par0)
        th = theta isa AbstractVector ? theta : [theta]
        for (k, t) in zip(fit, th)
            p[k] = Float64(t)
        end
        rr = _bc_model_returns(prep, p, model, rg)[rws]
        return _bc_objective(rr, 1:length(rws), ob, objective, horizon, loss, hybrid_weight)
    end

    function run_fit(rws, ob, rg)
        isempty(fit) && return (par = copy(par0), value = obj_fun(Float64[], rws, ob, rg), grid = nothing, metrics = nothing)
        if method == "grid"
            length(fit) != 1 && error("method = 'grid' unterstützt genau einen Parameter in 'fit'.")
            vals = Float64[obj_fun(g, rws, ob, rg) for g in grid]
            best = grid[DP._which_min(vals)]
            err_mat = Matrix{Float64}(undef, length(ob.pos), length(grid))
            for (j, g) in enumerate(grid)
                p = copy(par0); p[fit[1]] = g
                e = _bc_errors(_bc_model_returns(prep, p, model, rg)[rws], 1:length(rws), ob, "level", 1)
                err_mat[:, j] .= [1 - _libm().exp(v) for v in e]
            end
            p = copy(par0); p[fit[1]] = best
            return (par = p, value = minimum(vals), grid = RFrame("value" => copy(grid), "loss" => vals),
                    metrics = _bc_metric_table(err_mat, grid))
        end
        if length(fit) == 1
            b = bounds[fit[1]]
            o = _stats().optimize(t -> obj_fun(t, rws, ob, rg); lower = b[1], upper = b[2], tol = 1e-8)
            p = copy(par0); p[fit[1]] = Float64(_getel(o, "minimum"))
            return (par = p, value = Float64(_getel(o, "objective")), grid = nothing, metrics = nothing)
        end
        st = Float64[_par(par0, k) for k in fit]
        lo = Float64[bounds[k][1] for k in fit]; hi = Float64[bounds[k][2] for k in fit]
        o = _stats().optim(st, t -> obj_fun(t, rws, ob, rg); method = "L-BFGS-B", lower = lo, upper = hi)
        p = copy(par0)
        for (k, t) in zip(fit, _getel(o, "par"))
            p[k] = Float64(t)
        end
        return (par = p, value = Float64(_getel(o, "value")), grid = nothing, metrics = nothing)
    end

    res = run_fit(win, obs, reg)
    r_all = _bc_model_returns(prep, res.par, model, reg)
    diag = _bc_diagnostics(r_all[win], 1:length(win), obs, prep.dates[win])
    diag_naive = _bc_diagnostics(_bc_model_returns(prep, par0, model, reg)[win], 1:length(win), obs, prep.dates[win])

    oos = nothing
    if validate && length(obs.pos) >= 80
        cut_row = win[obs.pos[div(length(obs.pos), 2)]]
        tr_rows = collect(cut_row:w1); te_rows = collect(w0:cut_row)
        ob_tr = make_obs(tr_rows); ob_te = make_obs(te_rows)
        rg_tr = try
            fit_reg(tr_rows)
        catch e
            e isa ErrorException || rethrow()
            nothing
        end
        if model == "structural" || rg_tr !== nothing
            res_tr = run_fit(tr_rows, ob_tr, rg_tr)
            d_te = _bc_diagnostics(_bc_model_returns(prep, res_tr.par, model, rg_tr)[te_rows],
                                   1:length(te_rows), ob_te, prep.dates[te_rows])
            d_te0 = _bc_diagnostics(_bc_model_returns(prep, par0, model, rg_tr)[te_rows],
                                    1:length(te_rows), ob_te, prep.dates[te_rows])
            oos = RList("train" => DP._as_dates([prep.dates[tr_rows[1]], prep.dates[w1]]),
                        "test" => DP._as_dates([prep.dates[w0], prep.dates[cut_row]]),
                        "par" => res_tr.par,
                        "test_rmse_level" => d_te["rmse_level"], "test_tracking_difference" => d_te["tracking_difference"],
                        "test_tracking_error" => d_te["tracking_error"],
                        "naive_rmse_level" => d_te0["rmse_level"],
                        "naive_tracking_difference" => d_te0["tracking_difference"])
        end
    end

    out = RList(; class = ["SimLevBackcastFit"])
    out["params"] = res.par
    out["fitted"] = fit
    out["model"] = model
    out["objective"] = objective
    out["loss"] = loss
    out["loss_value"] = res.value
    out["method"] = method
    out["horizon"] = horizon
    out["lag"] = Int(lag)
    out["diagnostics"] = diag
    out["diagnostics_unfitted"] = diag_naive
    out["grid"] = res.grid
    out["grid_metrics"] = res.metrics
    out["validation"] = oos
    out["regression"] = reg
    out["inception"] = inception
    out["window"] = DP._as_dates([prep.dates[w0], prep.dates[w1]])
    out["drag_per_day"] = _par(res.par, "drag") / 100 / 365 * 100
    out["call_args"] = RList("data" => data, "product" => product, "index" => index, "ter" => ter,
                             "leverage" => leverage, "rate" => rate, "fx" => fx, "rate_lag" => rl,
                             "ter_basis" => ter_basis, "rate_basis" => rate_basis, "accrual" => accrual,
                             "index_fill" => index_fill)
    return out
end

"""
    backcast(fit = nothing; data = nothing, params = nothing, splice = "inception",
             fill = "locf", rebase = nothing, kwargs...)

Produkt-Kursreihe zurückrechnen und verketten. `fit`: Ergebnis von
[`backcast_fit`](@ref) oder `nothing` (dann `data`, `product`, `index` und
Modellangaben als Schlüsselwörter; nur Strukturmodell). Liefert ein `RFrame`
der Klasse `SimLevBackcast` (`date`, `value`, `return`, `model`, `product`,
`source`) mit `attrs`: `fit`, `params`, `splice_date`.
"""
function backcast(fit_pos = nothing; fit = fit_pos, data = nothing, params = nothing, splice = "inception",
                  fill = ("locf", "linear", "stine", "model"), rebase = nothing, kwargs...)
    data = SimLev.as_rframe(data)
    fill = DP._match_arg(fill, ("locf", "linear", "stine", "model"))
    E = _libm()
    if fit === nothing
        dots = RList((String(k) => v for (k, v) in kwargs)...)
        data === nothing && error("Ohne 'fit' muss 'data' angegeben werden.")
        a = _modify_list(RList("ter" => 0, "leverage" => 1, "rate" => nothing, "fx" => nothing, "rate_lag" => 0,
                               "ter_basis" => 365, "rate_basis" => 360, "accrual" => "linear",
                               "index_fill" => "locf"), dots)
        (get(a, "product", nothing) === nothing || get(a, "index", nothing) === nothing) &&
            error("'product' und 'index' müssen angegeben werden.")
        a["data"] = data
        model = something(get(dots, "model", nothing), "structural")
        model != "structural" && error("Ohne Fit ist nur model = 'structural' möglich.")
        reg = nothing
        par = _modify_list(RList("drag" => 0.0, "spread" => 0.0, "beta" => 1.0), params)
        lag = Int(trunc(something(get(dots, "lag", nothing), 0)))
    else
        (fit isa RList && inherits(fit, "SimLevBackcastFit")) || error("'fit' muss ein SimLevBackcastFit-Objekt sein.")
        a = copy(fit["call_args"])
        data !== nothing && (a["data"] = data)
        model, reg, lag = fit["model"], fit["regression"], fit["lag"]
        par = _modify_list(fit["params"], params)
    end
    ga(k) = get(a, k, nothing)
    prep = _bc_prepare(a["data"], a["product"], a["index"], ga("ter"), ga("leverage"), ga("rate"), ga("fx"),
                       Int(trunc(something(ga("rate_lag"), 0))), ga("ter_basis"), ga("rate_basis"), ga("accrual"),
                       ga("index_fill"), lag)
    r_mod = _bc_model_returns(prep, par, model, reg)
    n = prep.n
    prod = prep.prod
    first_idx = findfirst(!isnan, prep.idx)
    obs = findall(!isnan, prod)
    k0 = if (splice isa AbstractString && splice == "none") || isempty(obs)
        0
    elseif splice isa AbstractString && splice == "inception"
        obs[1]
    else
        sd0 = DP._days(DP._to_date(splice, "splice"))
        (length(sd0) != 1 || isnan(sd0[1])) && error("splice: \"inception\", \"none\" oder ein Datum ('JJJJ-MM-TT').")
        cand = [i for i in obs if prep.dates[i] >= sd0[1]]
        isempty(cand) && error("Kein Produktkurs ab dem Verkettungsdatum $(DP._date_str(sd0[1])) vorhanden (letzter Produktkurs am $(DP._date_str(prep.dates[maximum(obs)]))).")
        cand[1]
    end
    lr1(v) = E.log1p(max(isfinite(v) ? v : 0.0, -0.999999))
    r_out = copy(r_mod)
    source = Base.fill("backcast", n)
    if k0 > 0
        seg = k0:n
        last_obs = maximum(obs)
        pv = prod[seg]
        pf = if fill == "model"
            po = findall(!isnan, pv)
            lv = Base.fill(NA, length(seg))
            lv[po] .= [E.log(v) for v in pv[po]]
            lr = Float64[lr1(v) for v in r_mod[seg]]
            for j in 1:length(po)-1
                a0, a1 = po[j], po[j+1]
                if a1 - a0 > 1
                    step = lr[a0+1:a1]
                    adj = ((lv[a1] - lv[a0]) - SimLev.r_sum(step)) / length(step)
                    lv[a0+1:a1-1] .= lv[a0] .+ SimLev.r_cumsum(step .+ adj)[1:a1-a0-1]
                end
            end
            maximum(po) < length(seg) && (lv[maximum(po)+1:end] .= lv[maximum(po)])
            Float64[E.exp(v) for v in lv]
        else
            _fill_na(pv, fill)
        end
        source[seg] .= [isnan(v) ? "filled" : "product" for v in pv]
        last_obs < n && (source[last_obs+1:n] .= "filled")
        r_seg = vcat(NA, Float64[pf[i] / pf[i-1] - 1 for i in 2:length(pf)])
        r_out[seg[2:end]] .= r_seg[2:end]
        r_out[k0] = r_mod[k0]
    end
    lr_all = Float64[lr1(v) for v in r_out]
    lr_mod = Float64[lr1(v) for v in r_mod]
    lr_all[1:first_idx] .= 0.0; lr_mod[1:first_idx] .= 0.0
    cl = SimLev.r_cumsum(lr_all); cm = SimLev.r_cumsum(lr_mod)
    if k0 > 0
        value = Float64[prod[k0] * E.exp(c - cl[k0]) for c in cl]
        model_v = Float64[prod[k0] * E.exp(c - cm[k0]) for c in cm]
    else
        value = Float64[100 * E.exp(c) for c in cl]
        model_v = Float64[100 * E.exp(c) for c in cm]
    end
    if first_idx > 1
        value[1:first_idx-1] .= NA; model_v[1:first_idx-1] .= NA
    end
    if rebase !== nothing
        s = rebase / value[first_idx]
        value = value .* s; model_v = model_v .* s
    end
    ret = vcat(NA, Float64[value[i] / value[i-1] - 1 for i in 2:n])
    out = RFrame("date" => DP._as_dates(prep.dates), "value" => value, "return" => ret, "model" => model_v,
                 "product" => prod, "source" => source; class = ["SimLevBackcast", "data.frame"])
    attrs(out)["fit"] = fit
    attrs(out)["params"] = par
    attrs(out)["splice_date"] = k0 > 0 ? DP._date_of(prep.dates[k0]) : missing
    return out
end

# ═══════════════════════════════════════════════════════════════════════════
# Methoden
# ═══════════════════════════════════════════════════════════════════════════

const _DLINE = "═"^62
const _SLINE = "─"^21

"Druckausgabe von `SimLevBackcastFit` (Text wie `print.SimLevBackcastFit`)."
function format_SimLevBackcastFit(x)
    sp = DP._sprintf
    d = x["diagnostics"]; d0 = x["diagnostics_unfitted"]
    io = IOBuffer()
    print(io, "\n", _DLINE, "\n", "                    SimLev Backcast-Fit                        \n", _DLINE, "\n\n")
    print(io, sp("  Modell:           %s (Ziel: %s, Verlust: %s, Methode: %s)\n", x["model"], x["objective"], x["loss"], x["method"]))
    print(io, sp("  Fit-Fenster:      %s bis %s (%d Beobachtungen, %.1f Jahre)\n",
                 DP._date_str(d["start"]), DP._date_str(d["end"]), d["n_obs"], d["years"]))
    lev = x["call_args"]["leverage"]
    print(io, sp("  Hebel / Lag:      %s / %d Zeilen\n", DP._fmt_num(lev isa AbstractVector ? first(lev) : lev), x["lag"]))
    print(io, "\n  Parameter\n  ", _SLINE, "\n")
    p = x["params"]
    mark(k) = k in x["fitted"] ? "(gefittet)" : "(fest)"
    x["model"] == "structural" && print(io, sp("  Beta:             %.5f %s\n", _par(p, "beta"), mark("beta")))
    Float64(first(lev)) != 1 && print(io, sp("  Spread:           %+.4f %% p. a. %s\n", _par(p, "spread"), mark("spread")))
    print(io, sp("  Drag:             %+.4f %% p. a. %s  (= %+.6f %% je Tag)\n", _par(p, "drag"), mark("drag"), x["drag_per_day"]))
    reg = get(x, "regression", nothing)
    if reg !== nothing && haskey(reg, "coef") && reg["coef"] !== nothing
        cf = _coef(reg)
        print(io, sp("  Regression:       a = %.3e, b = %.5f\n", cf[1], cf[2]))
    end
    print(io, "\n  Abweichung Simulation vs. Produkt     ohne Fit     mit Fit\n  ", _SLINE, "\n")
    row(lbl, a, b, unit = "%") = print(io, sp("  %-34s %9.4f%s %9.4f%s\n", lbl, a, unit, b, unit))
    row("Tracking Error p. a.", d0["tracking_error"], d["tracking_error"])
    row("Tracking Difference p. a.", d0["tracking_difference"], d["tracking_difference"])
    row("Endabweichung kumuliert", d0["final_deviation"], d["final_deviation"])
    row("Max. Pfadabweichung", d0["max_abs_deviation"], d["max_abs_deviation"])
    row("RMSE Log-Niveau", d0["rmse_level"], d["rmse_level"])
    print(io, sp("  %-34s %10.4f  %10.4f\n", "Korrelation Tagesrenditen", d0["correlation"], d["correlation"]))
    v = x["validation"]
    if v !== nothing
        print(io, "\n  Out-of-Sample (Fit jüngere, Test ältere Hälfte)\n  ", _SLINE, "\n")
        te = DP._days(v["test"])
        print(io, sp("  Test-Zeitraum:    %s bis %s\n", DP._date_str(te[1]), DP._date_str(te[2])))
        print(io, sp("  RMSE Log-Niveau:  %.4f %% (ohne Fit: %.4f %%)\n", v["test_rmse_level"], v["naive_rmse_level"]))
        print(io, sp("  Tracking Diff.:   %+.4f %% p. a. (ohne Fit: %+.4f %%)\n",
                     v["test_tracking_difference"], v["naive_tracking_difference"]))
    end
    gm = x["grid_metrics"]
    if gm !== nothing
        print(io, "\n  Gittersuche: bestes Gitterelement je Metrik\n  ", _SLINE, "\n")
        for (k, val) in zip(gm.names, gm.values)
            print(io, sp("  %-26s %+.4f\n", k, val))
        end
    end
    print(io, "\n", _DLINE, "\n")
    return String(take!(io))
end

"`print.SimLevBackcastFit`."
print_SimLevBackcastFit(x; io::IO = stdout) = (print(io, format_SimLevBackcastFit(x)); x)

"`summary.SimLevBackcastFit`: druckt den Fit, liefert Parameter, Kennzahlen (ohne Pfad) und Validierung."
function summary_SimLevBackcastFit(object; io::IO = stdout)
    print(io, format_SimLevBackcastFit(object))
    diag = RList()
    for (k, v) in object["diagnostics"]
        k == "deviation" || (diag[k] = v)
    end
    return RList("params" => object["params"], "diagnostics" => diag, "validation" => object["validation"])
end

"Druckausgabe von `SimLevBackcast` (Kopfzeile und die ersten 6 Zeilen)."
function format_SimLevBackcast(x)
    val = x["value"]
    n_bc = count(i -> x["source"][i] == "backcast" && isfinite(val[i]), 1:nrow(x))
    dd = DP._days(x["date"])
    sd0 = get(attrs(x), "splice_date", missing)
    head = DP._sprintf("SimLev Backcast: %d Zeilen, %s bis %s; %d Backcast-Tage, Verkettung am %s\n",
                       nrow(x), DP._date_str(minimum(dd)), DP._date_str(maximum(dd)), n_bc,
                       sd0 === missing || sd0 === nothing ? "NA" : DP._date_str(sd0))
    h = rows(x, 1:min(6, nrow(x)))
    h.class = String[]
    h.attrs = Dict{String,Any}()
    return head * DP._chomp(SimLev.RFmt.print_data_frame(h))
end

"`print.SimLevBackcast`."
print_SimLevBackcast(x; io::IO = stdout) = (println(io, format_SimLevBackcast(x)); x)

# ── Grafiken (SVG ohne externe Pakete) ─────────────────────────────────────

_svgesc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

"""
    _svg_panel(io, series; x0, y0, w, h, title, xlab, ylab, logy = false, hlines = [], vlines = [])

Ein Liniendiagramm in ein SVG schreiben. `series`: Vektor aus
`(x::Vector{Float64}, y::Vector{Float64}, farbe, linienbreite, strich)`.
"""
function _svg_panel(io, series; x0 = 0, y0 = 0, w = 720, h = 360, title = "", xlab = "", ylab = "",
                    logy = false, hlines = Float64[], vlines = Float64[], xdate = false, legend = Tuple{String,String}[])
    ml, mr, mt, mb = 70, 15, 30, 45
    xs = Float64[]; ys = Float64[]
    for s in series
        for (a, b) in zip(s[1], s[2])
            (isfinite(a) && isfinite(b) && (!logy || b > 0)) && (push!(xs, a); push!(ys, logy ? log10(b) : b))
        end
    end
    isempty(xs) && (xs = [0.0, 1.0]; ys = [0.0, 1.0])
    xlo, xhi = extrema(xs); ylo, yhi = extrema(ys)
    for v in hlines
        yv = logy ? log10(v) : v
        ylo = min(ylo, yv); yhi = max(yhi, yv)
    end
    xhi == xlo && (xhi = xlo + 1); yhi == ylo && (yhi = ylo + 1)
    pad = 0.04 * (yhi - ylo); ylo -= pad; yhi += pad
    px(a) = x0 + ml + (a - xlo) / (xhi - xlo) * (w - ml - mr)
    py(b) = y0 + mt + (yhi - b) / (yhi - ylo) * (h - mt - mb)
    print(io, "<rect x=\"$(x0 + ml)\" y=\"$(y0 + mt)\" width=\"$(w - ml - mr)\" height=\"$(h - mt - mb)\" fill=\"none\" stroke=\"#333\"/>\n")
    print(io, "<text x=\"$(x0 + w / 2)\" y=\"$(y0 + 18)\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"bold\">$(_svgesc(title))</text>\n")
    print(io, "<text x=\"$(x0 + w / 2)\" y=\"$(y0 + h - 8)\" text-anchor=\"middle\" font-size=\"12\">$(_svgesc(xlab))</text>\n")
    print(io, "<text x=\"$(x0 + 14)\" y=\"$(y0 + h / 2)\" text-anchor=\"middle\" font-size=\"12\" transform=\"rotate(-90 $(x0 + 14) $(y0 + h / 2))\">$(_svgesc(ylab))</text>\n")
    for k in 0:4
        yv = ylo + k / 4 * (yhi - ylo)
        lab = logy ? DP._sprintf("%g", 10.0^yv) : DP._sprintf("%g", yv)
        print(io, "<text x=\"$(x0 + ml - 4)\" y=\"$(py(yv) + 4)\" text-anchor=\"end\" font-size=\"10\">$(lab)</text>\n")
        xv = xlo + k / 4 * (xhi - xlo)
        xl = xdate ? DP._date_str(xv) : DP._sprintf("%g", xv)
        print(io, "<text x=\"$(px(xv))\" y=\"$(y0 + h - mb + 14)\" text-anchor=\"middle\" font-size=\"10\">$(xl)</text>\n")
    end
    for v in hlines
        yv = logy ? log10(v) : v
        print(io, "<line x1=\"$(px(xlo))\" x2=\"$(px(xhi))\" y1=\"$(py(yv))\" y2=\"$(py(yv))\" stroke=\"#7f7f7f\" stroke-dasharray=\"5,4\"/>\n")
    end
    for v in vlines
        print(io, "<line x1=\"$(px(v))\" x2=\"$(px(v))\" y1=\"$(y0 + mt)\" y2=\"$(y0 + h - mb)\" stroke=\"#666\" stroke-dasharray=\"2,3\"/>\n")
    end
    for (sx, sy, col, lw) in series
        pts = String[]
        for (a, b) in zip(sx, sy)
            if isfinite(a) && isfinite(b) && (!logy || b > 0)
                push!(pts, string(round(px(a); digits = 2), ",", round(py(logy ? log10(b) : b); digits = 2)))
            end
        end
        isempty(pts) || print(io, "<polyline fill=\"none\" stroke=\"$(col)\" stroke-width=\"$(lw)\" points=\"$(join(pts, " "))\"/>\n")
    end
    for (i, (lab, col)) in enumerate(legend)
        yy = y0 + mt + 14 * i
        print(io, "<line x1=\"$(x0 + ml + 8)\" x2=\"$(x0 + ml + 28)\" y1=\"$(yy - 4)\" y2=\"$(yy - 4)\" stroke=\"$(col)\" stroke-width=\"1.5\"/>\n")
        print(io, "<text x=\"$(x0 + ml + 32)\" y=\"$(yy)\" font-size=\"11\">$(_svgesc(lab))</text>\n")
    end
end

function _svg_doc(f, w, h, file)
    io = IOBuffer()
    print(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$(w)\" height=\"$(h)\" viewBox=\"0 0 $(w) $(h)\" font-family=\"sans-serif\">\n")
    print(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n")
    f(io)
    print(io, "</svg>\n")
    svg = String(take!(io))
    file === nothing || write(file, svg)
    return svg
end

"""
    plot_SimLevBackcastFit(x; file = nothing)

Pfadabweichung im Fit-Fenster (und Verlustkurve der Gittersuche) als SVG
(Text; mit `file` zusätzlich in die Datei geschrieben).
"""
function plot_SimLevBackcastFit(x; file = nothing, width = 720, height = 360)
    dev = x["diagnostics"]["deviation"]
    ng = x["grid"] === nothing ? 1 : 2
    return _svg_doc(width, height * ng, file) do io
        _svg_panel(io, [(DP._days(dev["date"]), dev["deviation"] .* 100, "#2C6E9B", 1)];
                   w = width, h = height, title = "Pfadabweichung im Fit-Fenster", xlab = "Datum",
                   ylab = "1 - Sim/Produkt (%)", hlines = [0.0], xdate = true)
        if ng == 2
            g = x["grid"]
            _svg_panel(io, [(Float64.(g["value"]), Float64.(g["loss"]), "#B5562B", 1)]; y0 = height, w = width, h = height,
                       title = "Gittersuche", xlab = DP._sprintf("%s (%% p. a.)", x["fitted"][1]), ylab = x["loss"],
                       vlines = [_par(x["params"], x["fitted"][1])])
        end
    end
end

"""
    plot_SimLevBackcast(x; log = true, file = nothing)

Verkettete Reihe (Backcast/Produkt), Modellreihe und Verkettungsdatum als SVG.
"""
function plot_SimLevBackcast(x; log = true, file = nothing, width = 720, height = 450)
    val = x["value"]; mdl = x["model"]
    d = DP._days(x["date"])
    ok = isfinite.(val)
    bc = [x["source"][i] == "backcast" && ok[i] for i in eachindex(val)]
    nb = [!bc[i] && ok[i] for i in eachindex(val)]
    sd0 = get(attrs(x), "splice_date", missing)
    vl = sd0 === missing || sd0 === nothing ? Float64[] : DP._days(sd0)
    return _svg_doc(width, height, file) do io
        _svg_panel(io, [(d[ok], mdl[ok], "#A6A6A6", 1), (d[bc], val[bc], "#B5562B", 1.2), (d[nb], val[nb], "#2C6E9B", 1.2)];
                   w = width, h = height, title = "Backcast und Produkt", xlab = "Datum",
                   ylab = log ? "Wert (log. Skala)" : "Wert", logy = log, vlines = vl, xdate = true,
                   legend = [("Backcast", "#B5562B"), ("Produkt", "#2C6E9B"), ("Modell durchgehend", "#A6A6A6")])
    end
end

function __init__()
    register_print!("SimLevBackcastFit", (io, x) -> print(io, format_SimLevBackcastFit(x)))
    register_summary!("SimLevBackcastFit", (x, args...; kw...) -> summary_SimLevBackcastFit(x))
    register_plot!("SimLevBackcastFit", SimLev._plot_method(plot_SimLevBackcastFit, "SimLevBackcastFit"))
    register_print!("SimLevBackcast", (io, x) -> print(io, format_SimLevBackcast(x)))
    register_plot!("SimLevBackcast", SimLev._plot_method(plot_SimLevBackcast, "SimLevBackcast"))
end

end # module
