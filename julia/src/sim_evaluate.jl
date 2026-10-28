# ─────────────────────────────────────────────────────────────────────────────
# simulation(), Phase 6: Auswertung (sim_evaluate.R) und Hauptfunktion
# ─────────────────────────────────────────────────────────────────────────────

struct _Returns
    total_worth::Vector{Float64}
    total_flows::Vector{Float64}
    twr_index::Vector{Float64}
    invested::Vector{Float64}
    has_ext_flows::Bool
    cagr::Float64
    ttwror::Float64
    why_ret::Dict{String,Tuple{String,String}}
    open_tax_debt::Float64
    ret_dd::Float64
    dd_series::Vector{Float64}
    running_max::Vector{Float64}
    drawdowns::Vector{Float64}
    max_drawdown::Float64
    risk_returns::Vector{Float64}
    returns_filled_mask::BitVector
    ann_factor::Float64
    ann_periods::Float64
    n_days_sim::Int
end

function _sim_returns(R::Run, sim::Sim, start_date::Int, stopp_date::Int, start_value::Float64)
    fl = R.fl
    flag_date = fl.flag_date
    na = length(fl.flag_assets)
    total_worth = r_rowsums([sim.report[a].total for a in 1:na]; na_rm = true)
    total_flows = r_rowsums([sim.report[a].flows for a in 1:na]; na_rm = true)
    start_worth = total_worth[1]
    n_days_sim = length(total_worth)
    stopp_worth = total_worth[n_days_sim]
    ann_factor = Float64(stopp_date - start_date) / 365.25
    cagr = (start_worth > 0 && ann_factor > 0) ? r_pow(stopp_worth / start_worth, 1 / ann_factor) - 1 : NA
    n = n_days_sim
    local period_return::Vector{Float64}
    if n >= 2
        period_return = Vector{Float64}(undef, n)
        prev_total = Vector{Float64}(undef, n)
        prev_total[1] = NA
        period_return[1] = NA
        @inbounds for i in 2:n
            pc = total_worth[i] - total_worth[i-1] - total_flows[i]
            pt = total_worth[i-1]
            prev_total[i] = pt
            period_return[i] = (!isnan(pt) && pt > 0) ? pc / pt : 0.0
        end
        fday = [i for i in 2:n if !isnan(total_flows[i]) && total_flows[i] != 0]
        if !isempty(fday)
            v_pre = zeros(length(fday))
            for a in 1:na
                rep_a = sim.report[a]
                px = sim.market[a].asset_price
                for (k, i) in enumerate(fday)
                    w_prev = rep_a.worth[i-1]
                    gr = px[i] / px[i-1]
                    v_pre[k] = v_pre[k] + ((w_prev != 0 && isfinite(gr)) ? w_prev * gr : 0.0) + rep_a.money[i-1]
                end
            end
            for (k, i) in enumerate(fday)
                pt = prev_total[i]
                g1 = (!isnan(pt) && pt > 0) ? v_pre[k] / pt : 1.0
                den = v_pre[k] + total_flows[i]
                g2 = (isfinite(den) && den > 0) ? total_worth[i] / den : 1.0
                period_return[i] = g1 * g2 - 1
            end
        end
        period_return[1] = NA
    else
        period_return = [NA]
    end
    ttwror = ann_factor > 0 ? r_pow(r_prod((1 + x for x in period_return); na_rm = true), 1 / ann_factor) - 1 : NA
    has_ext_flows = n_days_sim >= 2 && any(i -> !isnan(total_flows[i]) && total_flows[i] != 0, 2:n_days_sim)
    fl0 = Float64[isnan(x) ? 0.0 : x for x in total_flows]
    invested = start_value .+ r_cumsum(fl0)
    twr_growth = n_days_sim >= 2 ? Float64[(g = 1 + period_return[i]; isfinite(g) ? g : 1.0) for i in 2:n] : Float64[]
    twr_index = r_cumprod([1.0; twr_growth])
    start_gross = NA
    fi = Int[]
    if has_ext_flows
        fi = [i for i in 2:n_days_sim if !isnan(total_flows[i]) && total_flows[i] != 0]
        t_fl = Float64[(flag_date[i] - start_date) / 365.25 for i in fi]
        start_gross = start_value + fl0[1]
        cagr = ann_factor > 0 ? xirr_rate([0.0; t_fl], [start_gross; total_flows[fi]], stopp_worth, ann_factor) : NA
        if isnan(cagr) && ann_factor > 0 && !(isfinite(stopp_worth) && stopp_worth < 0)
            @warn r_sprintf("simulation: geldgewichtete Rendite (cagr) mit Einzahlungen nicht bestimmbar (Startwert %.2f EUR, Einzahlungen %.2f EUR, Endwert %.2f EUR): kein interner Zinsfuß gefunden; cagr = NA.",
                            start_gross, r_sum(total_flows[fi]), stopp_worth)
        end
    end
    open_tax_debt = R.tax_unpaid_total > 0 ? r_sum([_rmax(0.0, -sim.status[a].money) for a in 1:na]) : 0.0
    neg_detail = open_tax_debt > 0 ? r_sprintf("Endwert %.2f EUR negativ: offene Steuerschuld %.2f EUR", stopp_worth, open_tax_debt) :
                 r_sprintf("Endwert %.2f EUR negativ", stopp_worth)
    _isnan_strict(x) = isnan(x) && !isna_strict(x)
    if isfinite(stopp_worth) && stopp_worth < 0
        has_ext_flows || (cagr = NA)
        _isnan_strict(ttwror) && (ttwror = NA)
        @warn r_sprintf("simulation: Endwert negativ (%.2f EUR, %s); Verlust über 100 %%: cagr und ttwror sind nicht definiert (NA), Drawdowns auf 100 %% begrenzt.",
                        stopp_worth, open_tax_debt > 0 ? r_sprintf("offene Steuerschuld %.2f EUR", open_tax_debt) : "nicht gedeckte Steuerschuld")
    elseif _isnan_strict(ttwror)
        ttwror = NA
        if !(has_ext_flows && any(<=(0), twr_index))
            @warn "simulation: zeitgewichteter Wertindex wird negativ (Tagesrendite unter -100 %); ttwror ist nicht definiert (NA)."
        end
    end
    function why_na(metric)
        ann_factor <= 0 && return ("too_short", "Zeitraum $(_n_tage(n_days_sim)), Laufzeit 0 Jahre (Einzeltag)")
        isfinite(stopp_worth) && stopp_worth < 0 && return ("negative_end_value", neg_detail)
        if metric == "cagr" && has_ext_flows
            return ("no_irr_solution", r_sprintf("kein interner Zinsfuß: Startwert %.2f EUR, Einzahlungen %.2f EUR, Endwert %.2f EUR",
                                                 start_gross, r_sum(total_flows[fi]), stopp_worth))
        end
        metric == "cagr" && !(start_worth > 0) && return ("zero_start_value", r_sprintf("Depotwert am Starttag %.2f EUR", start_worth))
        i0 = findfirst(<=(0), twr_index)
        if i0 !== nothing
            return ("nonpositive_twr_index", r_sprintf("zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %%)",
                                                       fmt_date(flag_date[i0]), 100 * period_return[i0]))
        end
        return ("not_finite", "Rechnung ergibt keinen endlichen Wert")
    end
    why_ret = Dict{String,Tuple{String,String}}()
    isnan(cagr) && (why_ret["cagr"] = why_na("cagr"))
    isnan(ttwror) && (why_ret["ttwror"] = why_na("ttwror"))
    if ann_factor <= 0
        @warn "simulation: Zeitraum $(_n_tage(n_days_sim)) (Laufzeit 0 Jahre): cagr und ttwror sind nicht definiert (NA)."
    elseif !has_ext_flows && isnan(cagr) && haskey(why_ret, "cagr") && why_ret["cagr"][1] == "zero_start_value"
        @warn r_sprintf("simulation: Depotwert am Starttag %.2f EUR: cagr ist nicht definiert (NA).", start_worth)
    end
    ret_dd = has_ext_flows ? ttwror : cagr
    dd_series = has_ext_flows ? twr_index : total_worth
    running_max = r_cummax(dd_series)
    drawdowns = Float64[isnan(running_max[i]) ? NA : (running_max[i] > 0 ? (running_max[i] - dd_series[i]) / running_max[i] : 0.0)
                        for i in eachindex(dd_series)]
    if has_ext_flows && any(<=(0), twr_index)
        i0 = findfirst(<=(0), twr_index)
        @warn r_sprintf("simulation: zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %% bei Depotwert %.2f EUR am Vortag und Einzahlung %.2f EUR); TTWROR und die zeitgewichteten Drawdowns sind nicht aussagekräftig (Drawdowns auf 100 %% begrenzt).",
                        fmt_date(flag_date[i0]), 100 * period_return[i0], total_worth[i0-1], total_flows[i0])
        drawdowns = Float64[isnan(d) ? d : r_min2(d, 1.0) for d in drawdowns]
    end
    if any(d -> !isnan(d) && d > 1, drawdowns)
        i0 = findfirst(d -> !isnan(d) && d > 1, drawdowns)
        if !(isfinite(stopp_worth) && stopp_worth < 0)
            @warn r_sprintf("simulation: Depotwert am %s negativ (%.2f EUR, Steuerschuld); Drawdowns auf 100 %% begrenzt.",
                            fmt_date(flag_date[i0]), total_worth[i0])
        end
        drawdowns = Float64[isnan(d) ? d : r_min2(d, 1.0) for d in drawdowns]
    end
    dd_ok = [d for d in drawdowns if !isnan(d)]
    max_drawdown = isempty(dd_ok) ? -Inf : maximum(dd_ok)
    isfinite(max_drawdown) || (max_drawdown = 0.0)
    portfolio_returns = Float64[(r = (total_worth[i+1] - total_worth[i]) / total_worth[i]; isfinite(r) ? r : 0.0) for i in 1:n-1]
    ttwror_returns = Float64[(r = period_return[i]; isfinite(r) ? r : 0.0) for i in 2:length(period_return)]
    has_flows = any(x -> !isnan(x) && x != 0, total_flows)
    risk_returns = has_flows ? ttwror_returns : portfolio_returns
    flag_filled = fl.flag_filled
    returns_filled_mask = length(flag_filled) == length(risk_returns) + 1 ? BitVector(flag_filled[2:end]) : falses(length(risk_returns))
    if length(returns_filled_mask) == length(risk_returns) && any(returns_filled_mask)
        risk_returns = risk_returns[.!returns_filled_mask]
    end
    ann_periods = (ann_factor > 0 && length(risk_returns) > 0) ? length(risk_returns) / ann_factor : 365.25
    return _Returns(total_worth, total_flows, twr_index, invested, has_ext_flows, cagr, ttwror, why_ret, open_tax_debt,
                    ret_dd, dd_series, running_max, drawdowns, max_drawdown, risk_returns, returns_filled_mask,
                    ann_factor, ann_periods, n_days_sim)
end

function _sim_risk_stats(r::_Returns, risk_free, fr::_Frame)
    @nospecialize
    risk_returns = r.risk_returns
    mask = r.returns_filled_mask
    days_per_year = r.ann_periods
    n_days_sim = r.n_days_sim
    drawdowns, dd_series, running_max = r.drawdowns, r.dd_series, r.running_max
    max_drawdown, ret_dd = r.max_drawdown, r.ret_dd
    daily_mean = r_mean(risk_returns; na_rm = true)
    daily_sd = r_sd(risk_returns; na_rm = true)
    isfinite(daily_mean) || (daily_mean = 0.0)
    isfinite(daily_sd) || (daily_sd = 0.0)
    daily_cv = daily_mean != 0 ? abs(daily_sd / daily_mean) : NA
    risk_free === nothing && (risk_free = 0)
    local rf_full::Vector{Float64}
    if risk_free isa AbstractString
        haskey(fr, risk_free) || error("risk_free: Spalte '$risk_free' fehlt im Datensatz.")
        col = fr.cols[risk_free]
        k = fr.kinds[risk_free]
        rf_full = k == :numeric ? copy(col) :
                  k == :logical ? Float64[x === missing ? NA : Float64(x) for x in col] :
                  k == :character ? Float64[x === missing ? NA : r_as_numeric(x) for x in col] :
                  Float64[x isa Real ? Float64(x) : NA for x in col]
    else
        rf_full = fill(Float64(risk_free), n_days_sim)
    end
    rf_full = Float64[isfinite(x) ? x / 100 : 0.0 for x in rf_full]
    rf_returns = length(rf_full) >= 2 ? rf_full[2:end] : Float64[]
    length(mask) == length(rf_returns) && any(mask) && (rf_returns = rf_returns[.!mask])
    if length(rf_returns) != length(risk_returns)
        rf_returns = fill(isempty(rf_returns) ? 0.0 : r_mean(rf_returns), length(risk_returns))
    end
    inv_dpy = 1 / days_per_year
    excess = Float64[risk_returns[i] - (r_pow(1 + rf_returns[i], inv_dpy) - 1) for i in eachindex(risk_returns)]
    rf_effective = isempty(rf_returns) ? 0.0 : r_mean(rf_returns) * 100
    mean_excess = r_mean(excess; na_rm = true)
    sd_excess = r_sd(excess; na_rm = true)
    isfinite(mean_excess) || (mean_excess = 0.0)
    isfinite(sd_excess) || (sd_excess = 0.0)
    downside_sd_excess = if any(<(0), excess)
        sqrt(r_mean((m = r_min2(x, 0.0); m * m) for x in excess; na_rm = true))
    else
        0.0
    end
    sqrt_dpy = sqrt(days_per_year)
    sharpe = sd_excess > 0 ? (mean_excess * days_per_year) / (sd_excess * sqrt_dpy) : NA
    sortino = downside_sd_excess > 0 ? (mean_excess * days_per_year) / (downside_sd_excess * sqrt_dpy) : NA
    calmar = (max_drawdown > 0 && !isnan(ret_dd)) ? ret_dd / max_drawdown : NA
    ulcer_index = sqrt(r_mean((d * d for d in drawdowns); na_rm = true))
    isfinite(ulcer_index) || (ulcer_index = 0.0)
    martin_ratio = (ulcer_index > 0 && !isnan(ret_dd)) ? ret_dd / ulcer_index : NA
    serenity = (ulcer_index > 0 && max_drawdown > 0 && !isnan(ret_dd)) ? ret_dd / (ulcer_index * max_drawdown) : NA
    gains = r_sum((x for x in risk_returns if x > 0); na_rm = true)
    losses = abs(r_sum((x for x in risk_returns if x < 0); na_rm = true))
    omega = losses > 0 ? gains / losses : NA
    gain_to_pain = losses > 0 ? r_sum(risk_returns; na_rm = true) / losses : NA
    dd_active = [d for d in drawdowns if !isnan(d) && d > 0]
    average_drawdown = isempty(dd_active) ? 0.0 : r_mean(dd_active)
    longest_dd = 0
    current_dd = 0
    recovery_times = Int[]
    in_dd = false
    dd_start = 0
    for i in eachindex(dd_series)
        below = dd_series[i] < running_max[i]
        if below
            current_dd += 1
            current_dd > longest_dd && (longest_dd = current_dd)
        else
            current_dd = 0
        end
        if below
            if !in_dd
                dd_start = i; in_dd = true
            end
        elseif in_dd
            push!(recovery_times, i - dd_start)
            in_dd = false
        end
    end
    avg_recovery_time = isempty(recovery_times) ? NA : r_mean_int(recovery_times)
    statistics = RList("mean" => daily_mean, "sd" => daily_sd, "cv" => daily_cv, "risk_free" => rf_effective,
                       "skewness" => calculate_skewness(risk_returns), "kurtosis" => calculate_kurtosis(risk_returns),
                       "lpm" => calculate_partials(risk_returns; type = "lower"),
                       "hpm" => calculate_partials(risk_returns; type = "higher"),
                       "sharpe" => sharpe, "sortino" => sortino, "calmar" => calmar, "omega" => omega,
                       "gain_to_pain" => gain_to_pain, "serenity" => serenity, "martin_ratio" => martin_ratio,
                       "max_drawdown" => max_drawdown, "average_drawdown" => average_drawdown, "ulcer_index" => ulcer_index,
                       "longest_drawdown" => longest_dd, "avg_recovery_time" => avg_recovery_time)
    return statistics, longest_dd
end

function _sim_undefined_metrics(r::_Returns, statistics::RList, longest_dd::Int, sim::Sim)
    n_r = length(r.risk_returns)
    ann_factor, n_days_sim = r.ann_factor, r.n_days_sim
    few(k) = ("too_short", n_r == 0 ? "keine Tagesrendite (Einzeltag)" :
                           "nur $n_r $(n_r == 1 ? "Tagesrendite" : "Tagesrenditen"), mindestens $k nötig")
    ret_name = r.has_ext_flows ? "ttwror" : "cagr"
    inherit() = (w = r.why_ret[ret_name]; (w[1], "$ret_name nicht definiert: $(w[2])"))
    no_dd = ("no_drawdown", "kein Drawdown im Zeitraum (max_drawdown 0)")
    zero_vol = ("zero_volatility", "Standardabweichung der $n_r Tagesrenditen ist 0 (konstanter Verlauf)")
    rd_na = isnan(r.ret_dd)
    function why_stat(m)
        m == "cv" && return n_r == 0 ? few(1) : ("zero_mean_return", "mittlere Tagesrendite ist 0")
        m == "skewness" && return n_r < 3 ? few(3) : zero_vol
        m == "kurtosis" && return n_r < 4 ? few(4) : zero_vol
        m in ("lpm", "hpm") && return few(1)
        m == "sharpe" && return n_r < 2 ? few(2) : ("zero_volatility", "Standardabweichung der $n_r Überschussrenditen ist 0")
        m == "sortino" && return n_r < 1 ? few(1) : ("no_negative_returns", "keine negativen Überschussrenditen (Downside-Abweichung 0)")
        m in ("calmar", "serenity") && return rd_na ? inherit() : no_dd
        m in ("omega", "gain_to_pain") && return n_r < 1 ? few(1) : ("no_negative_returns", "keine negativen Tagesrenditen")
        m == "martin_ratio" && return rd_na ? inherit() : ("no_drawdown", "kein Drawdown im Zeitraum (Ulcer Index 0)")
        if m == "avg_recovery_time"
            ann_factor <= 0 && return ("too_short", "Zeitraum $(_n_tage(n_days_sim)), Laufzeit 0 Jahre (Einzeltag)")
            return ("no_recovery", longest_dd == 0 ? "kein Drawdown im Zeitraum" :
                                   "Drawdown bis zum Ende nicht aufgeholt (längster Drawdown $(_n_tage(longest_dd)))")
        end
        return ("not_finite", "Rechnung ergibt keinen endlichen Wert")
    end
    nms = sim.names
    buys = RVector(Float64[ann_factor > 0 ? length(sim.trades[a].buys) / ann_factor : NA for a in eachindex(nms)]; names = nms)
    sells = RVector(Float64[ann_factor > 0 ? length(sim.trades[a].sells) / ann_factor : NA for a in eachindex(nms)]; names = nms)
    um = Pair{String,Tuple{String,String}}[]
    for (m, v) in (("cagr", r.cagr), ("ttwror", r.ttwror))
        isnan(v) && push!(um, m => r.why_ret[m])
    end
    for (m, v) in statistics
        v isa AbstractFloat && isnan(v) && push!(um, m => why_stat(m))
    end
    for (m, v) in (("buys", buys), ("sells", sells))
        any(isnan, v.values) && push!(um, m => ("too_short", "Zeitraum $(_n_tage(n_days_sim)), Laufzeit 0 Jahre: keine Anzahl je Jahr (Einzeltag)"))
    end
    undefined_metrics = RFrame("metric" => String[p.first for p in um], "reason" => String[p.second[1] for p in um],
                               "detail" => String[p.second[2] for p in um]; class = ["data.frame"])
    return undefined_metrics, buys, sells
end

function _sim_compact_trades(sim::Sim)
    return RList([sim.names[a] => (buys = sim.trades[a].buys, sells = sim.trades[a].sells, taxes = sim.trades[a].taxes)
                  for a in eachindex(sim.names)]...)
end

function _sim_result(R::Run, sim::Sim, r::_Returns, statistics::RList, undefined_metrics::RFrame, buys::RVector, sells::RVector)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    flag_date = fl.flag_date
    tax_mode = cfg.tax_mode
    te = cfg.tariff_env
    open_lots = nothing
    if tax_mode == "person"
        open_lots = RList()
        for (a, nm) in enumerate(sim.names)
            lots = [b for b in sim.trades[a].buys if b.remaining > 0]
            sp_ = get(cfg.strategy[a].second, "spread", nothing)
            open_lots[nm] = RList("lots" => RFrame("date" => Date[from_days(b.date) for b in lots],
                                                   "units" => Float64[b.remaining for b in lots],
                                                   "price" => Float64[b.price for b in lots],
                                                   "vp" => Float64[b.vp for b in lots]; class = ["data.frame"]),
                                  "regime" => fl.tax_regimes[a], "partial_exemption" => 100 * sim.assets[a].bonus,
                                  "cash" => sim.status[a].money,
                                  "spread" => sp_ === nothing ? 0.0 : sp_,
                                  "order_fee" => cfg.order_fee)
        end
    end
    t = sim.totals
    tax_report = RList("total_taxes_paid" => t.total_taxes, "loss_carryforward_capital" => t.loss_capital_gains,
                       "loss_carryforward_private" => t.loss_private_sales,
                       "sparer_pauschbetrag_annual" => t.sparer_pauschbetrag_annual,
                       "sparer_pauschbetrag_used" => t.sparer_pauschbetrag_used_total,
                       "sparer_pauschbetrag_tax_saved" => t.sparer_pauschbetrag_used_total * cfg.effective_tax_rate,
                       "open_tax_debt" => r.open_tax_debt)
    if te !== nothing && !isempty(te.rows)
        cols = keys(te.rows[1])
        tax_report["tariff_years"] = RFrame([c => (c == "year" ? Int[rw[c] for rw in te.rows] :
                                                   c == "guenstiger" ? Bool[rw[c] for rw in te.rows] :
                                                   Float64[rw[c] for rw in te.rows]) for c in cols]...; class = ["data.frame"])
    end
    if tax_mode == "person"
        use_spb = cfg.use_sparer_pauschbetrag
        ny = t.current_year
        nyd = RList("year" => ny,
                    "sparer_pauschbetrag_used" => use_spb ? _rmax(0.0, t.sparer_pauschbetrag_annual - t.sparer_pauschbetrag_remaining) : 0.0,
                    "sparer_pauschbetrag_remaining" => use_spb ? t.sparer_pauschbetrag_remaining : 0.0,
                    "loss_carryforward_capital" => t.loss_capital_gains,
                    "loss_carryforward_private" => t.loss_private_sales,
                    "capital_income_taxed" => t.cgt_base_taxed_ytd,
                    "loss_capital_added" => t.cgt_loss_added_ytd,
                    "loss_capital_used" => t.cgt_loss_used_ytd,
                    "loss_capital_start" => t.cgt_pool_start_ytd,
                    "private_sale_net" => t.private_sale_gains_ytd - t.private_sale_losses_ytd)
        if te !== nothing
            ks = get(te.ks, string(ny), NA)
            nyd["church_tax_settlement"] = isnan(ks) ? 0.0 : ks
            nyd["tariff_assessed"] = any(rw -> rw["year"] == ny, te.rows)
        end
        tax_report["next_year"] = nyd
    end
    report = RList()
    for (a, nm) in enumerate(sim.names)
        rp = sim.report[a]
        report[nm] = RList("worth" => rp.worth, "money" => rp.money, "flows" => rp.flows, "total" => rp.total, "share" => rp.share)
    end
    res = RList(; class = ["SimLevResult"])
    res["dates"] = Date[from_days(z) for z in flag_date]
    res["filled"] = Vector{Bool}(fl.flag_filled)
    res["worth"] = r.total_worth
    res["twr_index"] = r.twr_index
    res["invested"] = r.invested
    res["external_flows"] = r.has_ext_flows
    res["cagr"] = r.cagr
    res["ttwror"] = r.ttwror
    res["drawdowns"] = r.drawdowns
    res["statistics"] = statistics
    res["buys"] = buys
    res["sells"] = sells
    res["report"] = report
    res["tax_report"] = tax_report
    res["undefined_metrics"] = undefined_metrics
    res["open_lots"] = open_lots
    cfg.fees_on && (res["fees_paid"] = R.fee_paid)
    _is_true(cfg.harvest_mode) && (res["harvest_days"] = Date[from_days(flag_date[i]) for i in findall(fl.flag_harvest)])
    cfg.wrappers !== nothing && length(cfg.wrappers) > 0 && (res["wrappers"] = cfg.wrappers)   # nur mit details = true
    return SimLevResult(res, _sim_compact_trades(sim))
end

# ── Hauptfunktion ──────────────────────────────────────────────────────────

"""
    simulation(data, strategy; start_value = 10000, costs = sim_costs(), dca = nothing,
               rebalance = nothing, splits = nothing, tax = nothing, risk_free = 0,
               fractions = true, liquidate = false, details = false, io = stdout)

Portfolio-Simulation (Backtest) mit Sparplan, Rebalancing und deutscher
Besteuerung; bitgleiche Portierung von `simulation()` aus dem R-Paket SimLev
0.5.0. Die Einstellungen kommen als Bausteine (Etappe 6.3): `costs =
sim_costs()` (Standard), `dca = dca_plan()`, `rebalance = rebalance_plan()`,
`splits = split_rule()`, `tax = tax_profile()` (mit `income = income_rate()`
oder `income_tariff()` und `harvest = harvest_rule()`); `nothing` heißt aus. Den
alten Fondsmodus (`funds = funds_costs()`) gibt es seit Etappe 6.5c nicht mehr.
Alle Raten und Schwellen **in Prozent** (`risk_free = 2` …).

`data`: RFrame, NamedTuple, Dict oder Pair-Vektor mit Spalte `date` (Date)
und je Asset einer Kursspalte. `strategy`: Ergebnis von `create_strategy()`
oder eine benannte Liste (Dict, NamedTuple, Pair-Vektor) von Asset-
Konfigurationen. `risk_free`: Zahl in Prozent p. a. oder Spaltenname in `data`.

Hinweise (R: `message()`) gehen nach `stderr`, Warnungen über `@warn`, Fehler
als `ErrorException` (Texte wie in R). Die `details`-Ausgabe geht nach `io`.
Rückgabe: [`SimLevResult`](@ref).
"""
function simulation(data, strategy; start_value = 10000, costs = sim_costs(), dca = nothing, rebalance = nothing,
                    splits = nothing, tax = nothing, risk_free = 0, fractions = true,
                    liquidate = false, details = false, io::IO = stdout)
    @nospecialize
    flat = _sim_from_blocks(costs, dca, rebalance, splits, tax)
    return _simulation_flat(data, strategy; start_value = start_value, risk_free = risk_free, fractions = fractions,
                            liquidate = liquidate, details = details, io = io, _blocks = true, flat...)
end

"""
    _simulation_flat(data, strategy; start_value, spread, details, liquidate, dca_mode, …, io)

Engine mit den flachen Argumenten bis Etappe 6.2 (R: `.simulation_flat`).
`simulation()` übersetzt die Bausteine mit `_sim_from_blocks` hierher
(`_blocks = true`: Prüfungen der Bausteine entfallen, Meldungen nennen die
Bausteine). Die Aufrufer mit `sim_args` gehen seit Etappe 6.4 über
`simulation()` (`_sim_args_set`, `_sim_call` in sim_blocks.jl).
`tax_tariff`: `nothing`, Dateipfad oder `tax_tariff()`.
"""
function _simulation_flat(data, strategy; start_value = 10000, spread = nothing, details = false, liquidate = false,
                    dca_mode = false, dca_value = nothing, dca_span = nothing, dca_days = nothing,
                    dca_unit = ("month", "quarter", "year"), dca_anchor = ("start", "end"), dca_start = nothing,
                    dca_skip = false, balance_mode = false, balance_span = nothing, balance_days = nothing,
                    balance_unit = ("month", "quarter", "year"), balance_anchor = ("start", "end"),
                    balance_start = nothing, balance_skip = false, balance_dca = false, balance_thresh = nothing,
                    balance_thresh_type = ("absolute", "relative"), tax_mode = ("none", "person"),
                    tax_rate = _UNSET, marginal_tax_rate = _UNSET, use_guenstigerpruefung = false,
                    private_sale_threshold = 1000, sparer_pauschbetrag = 1000, use_sparer_pauschbetrag = true,
                    include_soli_on_income_tax = _UNSET, soli_rate_income_tax = _UNSET, base_rate = nothing,
                    base_rate_flex = false, base_rate_data = nothing, fractions = true, risk_free = 0, split_mode = false, split_thresh = nothing, event_col = nothing,
                    event_mode = _UNSET, event_weight = nothing, church_tax = 0, order_fee = nothing,
                    dca_fee = nothing, harvest_mode = false, harvest_day = "12-15", harvest_loss_pot = true,
                    taxable_income = nothing, tax_tariff = nothing, io::IO = stdout, _blocks::Bool = false)
    @nospecialize
    given = _Given(Dict("tax_rate" => !(tax_rate isa _Unset), "marginal_tax_rate" => !(marginal_tax_rate isa _Unset),
                        "include_soli_on_income_tax" => !(include_soli_on_income_tax isa _Unset),
                        "soli_rate_income_tax" => !(soli_rate_income_tax isa _Unset),
                        "event_mode" => !(event_mode isa _Unset)))
    _blocks && (given = _Given(Dict(k => false for k in keys(given.d))))
    tax_rate = _val(tax_rate, 26.375)
    marginal_tax_rate = _val(marginal_tax_rate, nothing)
    include_soli_on_income_tax = _val(include_soli_on_income_tax, false)
    soli_rate_income_tax = _val(soli_rate_income_tax, 5.5)
    event_mode = _val(event_mode, ("additional", "replace"))
    details = details == true
    cfg, fr = _sim_check_inputs(data, strategy, start_value, spread, details, dca_mode, dca_value, dca_span, dca_days,
                                balance_mode, balance_days, balance_thresh, balance_thresh_type, tax_mode, tax_rate,
                                marginal_tax_rate, use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                                use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax, base_rate,
                                fractions, risk_free, split_mode, split_thresh, event_col, church_tax,
                                order_fee, dca_fee, harvest_mode, harvest_day, taxable_income, tax_tariff, given, io,
                                _blocks)
    split_thresh !== nothing && (split_thresh = _num_vec(split_thresh))
    start_date, stopp_date = _sim_prepare_data(fr, cfg.pre_filled, base_rate_flex, base_rate_data, _blocks)
    sim = _sim_build_state(fr, cfg.strategy, cfg.start_value, start_date, stopp_date, cfg.sparer_pauschbetrag,
                           cfg.use_sparer_pauschbetrag, cfg.base_rate, base_rate_flex, base_rate_data, _blocks)
    fl, ew = _sim_build_calendar(fr, sim, cfg.strategy, start_date, stopp_date, liquidate, cfg.dca_mode, dca_span,
                                 dca_unit, cfg.dca_days, cfg.dca_value, dca_anchor, dca_start, dca_skip, cfg.balance_mode,
                                 balance_span, balance_unit, cfg.balance_days, balance_anchor, balance_start,
                                 balance_skip, cfg.event_col, event_mode, event_weight, cfg.split_mode, split_thresh,
                                 _blocks, cfg.no_split)
    cfg.event_col !== nothing && (event_weight = ew)
    event_weight isa Union{Nothing,Vector{Pair{String,Any}}} || (event_weight = Pair{String,Any}[p for p in _kvpairs(event_weight)])
    _sim_init_weights!(sim, fl, cfg.start_value)
    _sim_build_schedule!(sim, fl, cfg.tax_mode, cfg.harvest_mode, harvest_day)
    R = Run(cfg, fl, details, io, 0.0, nothing, 0.0)
    _sim_run_days!(R, sim, fr, liquidate, event_weight, split_thresh, balance_dca, harvest_loss_pot)
    _sim_close_years!(R, sim, stopp_date)
    ret = _sim_returns(R, sim, start_date, stopp_date, cfg.start_value)
    statistics, longest_dd = _sim_risk_stats(ret, cfg.risk_free, fr)
    um, buys, sells = _sim_undefined_metrics(ret, statistics, longest_dd, sim)
    return _sim_result(R, sim, ret, statistics, um, buys, sells)
end

