# ─────────────────────────────────────────────────────────────────────────────
# simulation(), Phasen 3–5: Zahlungs- und Abrechnungshelfer (sim_actions.R),
# Tagesschleife (sim_loop.R) und Abschluss des letzten Jahres
# ─────────────────────────────────────────────────────────────────────────────

# ── Zahlungshelfer (R: .sim_make_actions) ──────────────────────────────────

"Kauf mit Sparplan- bzw. Ordergebühr."
function _buy_with_fee!(R::Run, sim::Sim, a::Int, time::Int, reason::String)
    cfg, fl = R.cfg, R.fl
    sr = fl.spread_rates[a]
    if cfg.fees_on && fl.flag_dca[time] && fl.strategy_types[a] == "bnh"
        money = sim.status[a].money
        dca_part = _rmin(_rmax(0.0, sim.report[a].flows[time]), money)
        if time == 1 && money - dca_part > 0.005
            R.fee_current = cfg.fee_order
            sim.status[a].money = money - dca_part
            _perform_trade_buy!(R, sim, a, time, reason, sr, cfg.fractions)
            sim.status[a].money = sim.status[a].money + dca_part
        end
        R.fee_current = cfg.fee_dca
    end
    _perform_trade_buy!(R, sim, a, time, reason, sr, cfg.fractions)
    cfg.fees_on && (R.fee_current = cfg.fee_order)
    return nothing
end

function _sell!(R::Run, sim::Sim, a::Int, time::Int, reason::String, spread::Float64; count = nothing,
                price = nothing, tax_mode = nothing)
    cfg = R.cfg
    _perform_trade_sell!(R, sim, a, time, tax_mode === nothing ? cfg.tax_mode : tax_mode, cfg.tax_rate,
                         cfg.effective_tax_rate, cfg.use_sparer_pauschbetrag, R.fl.tax_regimes[a], reason, spread;
                         count = count, price = price)
end

"Verkaufsmenge nach Steuer und Gebühr."
function _sell_count_net(R::Run, sim::Sim, a::Int, need::Float64, time::Int; round_up::Bool = false)
    cfg, fl = R.cfg, R.fl
    fr_ = cfg.fractions || round_up
    sc_of(target) = _calculate_sell_count(sim, a, target, time, fl.spread_rates[a], fr_, cfg.tax_mode,
                                          cfg.effective_tax_rate, fl.tax_regimes[a])
    fee = R.fee_current
    target = need
    if fee !== nothing
        px = apply_spread(sim.market[a].asset_price[time], fl.spread_rates[a], "sell")
        for _ in 1:3
            target = need + _fee_amount(fee, _rmax(sc_of(target).sell_count, 1e-12) * px)
        end
    end
    res = sc_of(target)
    if round_up && !cfg.fractions && res.sell_count > 0
        return (sell_count = _rmin(sim.status[a].count, ceil(res.sell_count - 1e-9)), fifo_price = nothing)
    end
    return (sell_count = res.sell_count, fifo_price = res.fifo_price)
end

"Bargeld für Fondskosten beschaffen."
function _raise_cash!(R::Run, sim::Sim, a::Int, need::Float64, time::Int, reason::String)
    cfg = R.cfg
    short = need - sim.status[a].money
    (short <= 0 || sim.status[a].count <= 0) && return nothing
    fee_keep = R.fee_current
    R.fee_current = nothing
    try
        n_sell = if cfg.tax_mode != "person"
            px = sim.market[a].asset_price[time]
            _rmin(sim.status[a].count, cfg.fractions ? short / px : ceil(short / px - 1e-9))
        else
            _calculate_sell_count(sim, a, short, time, 0.0, cfg.fractions, cfg.tax_mode, cfg.effective_tax_rate,
                                  R.fl.tax_regimes[a]).sell_count
        end
        _sell!(R, sim, a, time, reason, 0.0; count = n_sell)
        if !cfg.fractions && sim.status[a].money < need - 1e-9 && sim.status[a].count > 0
            _sell!(R, sim, a, time, reason, 0.0; count = _rmin(1.0, sim.status[a].count))
        end
    finally
        R.fee_current = fee_keep
    end
    return nothing
end

"Zahlung aus einem Asset; Rückgabe: nicht gedeckter Rest."
function _pay_one!(R::Run, sim::Sim, a::Int, amount::Float64, time::Int, label::String)
    cfg, fl = R.cfg, R.fl
    fd = fmt_date(fl.flag_date[time])
    st = sim.status[a]
    money = st.money
    if money >= amount
        st.money = money - amount
        R.details && _cat(R, r_sprintf("Steuerereignis:\tZahlung %s %.2f EUR für %s aus dem Geldbestand am %s\n",
                                       label, amount, sim.names[a], fd))
        return 0.0
    end
    remaining = amount
    if money > 0
        remaining = amount - money
        st.money = 0.0
        R.details && _cat(R, r_sprintf("Steuerereignis:\tTeilzahlung %s %.2f EUR aus dem Geldbestand am %s\n", label, money, fd))
    end
    c0 = st.money
    raised() = sim.status[a].money - c0
    for k in 1:10
        short = remaining - raised()
        (short <= 0.005 || sim.status[a].count <= 0) && break
        sell_result = _sell_count_net(R, sim, a, short, time; round_up = true)
        n_sell = sell_result.sell_count
        if k > 1 || !(n_sell > 0)
            cnt = sim.status[a].count
            n_sell = _rmax(n_sell, cfg.fractions ? _rmin(cnt, 1e-6) : _rmin(1.0, cnt))
        end
        before = raised()
        _sell!(R, sim, a, time, "Steuerereignis:", fl.spread_rates[a]; count = n_sell, price = sell_result.fifo_price)
        raised() <= before && break
    end
    short = remaining - raised()
    unpaid = 0.0
    if short <= 0.005
        sim.status[a].money = sim.status[a].money - remaining
    else
        sim.status[a].money = c0
        unpaid = short
    end
    if R.details && remaining - unpaid > 0
        _cat(R, r_sprintf("\t\t=> Anteile verkauft für den Rest von %.2f EUR (%s)\n", remaining - unpaid, label))
    end
    return unpaid
end

"Steuerzahlung mit Rückgriff auf die übrigen Assets."
function _pay_tax!(R::Run, sim::Sim, a::Int, amount::Float64, time::Int, label::String)
    fl = R.fl
    unpaid = _pay_one!(R, sim, a, amount, time, label)
    if unpaid > 1e-6
        others = [b for b in eachindex(fl.flag_assets) if b != a]
        val = Float64[sim.status[b].count * sim.market[b].asset_price[time] + _rmax(0.0, sim.status[b].money) for b in others]
        order = sortperm(-val; alg = MergeSort)
        for i in order
            b = others[i]
            unpaid <= 1e-6 && break
            val[i] > 0 || continue
            unpaid = _pay_one!(R, sim, b, unpaid, time, label)
        end
    end
    if unpaid > 1e-6
        sim.status[a].money = sim.status[a].money - unpaid
        R.tax_unpaid_total = R.tax_unpaid_total + unpaid
        @warn r_sprintf("simulation: %s von %.2f EUR am %s: das Depot reicht nicht aus; %.2f EUR bleiben als negativer Geldbestand (Steuerschuld) bei '%s'.",
                        label, amount, fmt_date(fl.flag_date[time]), unpaid, sim.names[a])
    end
    return nothing
end

"Vorabpauschale bezahlen und buchen."
function _pay_vp!(R::Run, sim::Sim, a::Int, tax_debt::Float64, time::Int, flat_rate_::Float64, bonus::Float64,
                  spb_used::Float64, assessment_date::Int, prepaid::Float64)
    if prepaid == 0
        _pay_tax!(R, sim, a, tax_debt, time, "Vorabpauschale")
    elseif tax_debt - prepaid > 1e-9
        _pay_tax!(R, sim, a, tax_debt - prepaid, time, "Vorabpauschale")
    elseif tax_debt - prepaid < -1e-9
        sim.status[a].money = sim.status[a].money + (prepaid - tax_debt)
    end
    sim.totals.total_taxes = sim.totals.total_taxes + tax_debt
    push!(sim.trades[a].taxes, TaxEntry(R.fl.flag_date[time], assessment_date, "Vorabpauschale", flat_rate_, bonus,
                                        flat_rate_ * (1 - bonus), spb_used, tax_debt))
    return nothing
end

"§ 23-Steuer bzw. Nachzahlung der Veranlagung."
function _settle_p23!(R::Run, sim::Sim, time::Int)
    te = R.cfg.tariff_env
    due = sim.totals.p23_due
    sim.totals.p23_due = Pair{Int,Float64}[]
    info = te === nothing ? nothing : (isempty(te.due_info) ? nothing : copy(te.due_info))
    te !== nothing && empty!(te.due_info)
    fd = fmt_date(R.fl.flag_date[time])
    label = info !== nothing ? "Steuer aus der Veranlagung " * join((string(i.year) for i in info), "/") : "§ 23-Steuer"
    if R.details && info !== nothing && any(p -> p.second > 0, due)
        for i in info
            rest = i.D - i.p23 - i.ded
            _cat(R, r_sprintf("Steuerereignis:\tVeranlagung %d: Nachzahlung %.2f EUR (davon § 23 %.2f EUR, Kirchensteuer-Sonderausgaben %.2f EUR%s) am %s, aufgeteilt %s\n",
                              i.year, i.D, i.p23, i.ded, abs(rest) >= 0.005 ? r_sprintf(", Günstigerprüfung %.2f EUR", rest) : "", fd,
                              i.by_p23 ? "nach dem § 23-Jahressaldo je Asset" : "zu gleichen Teilen auf die Assets"))
        end
    end
    for (a, v) in due
        v > 0 || continue
        if R.details
            if info !== nothing
                _cat(R, r_sprintf("\t\t=> Anteil %s: %.2f EUR\n", sim.names[a], v))
            else
                _cat(R, r_sprintf("Steuerereignis:\t§ 23 EStG: Steuer %.2f EUR (%s) am %s\n", v, sim.names[a], fd))
            end
        end
        _pay_tax!(R, sim, a, v, time, label)
        push!(sim.trades[a].taxes, TaxEntry(R.fl.flag_date[time], 0, "Private sale tax", NA, NA, NA, NA, v))
    end
    return nothing
end

_gp_pending(R::Run) = R.cfg.tariff_env !== nothing && R.cfg.tariff_env.refund_due > 0

"Erstattung aus der Günstigerprüfung."
function _settle_gp!(R::Run, sim::Sim, time::Int)
    te = R.cfg.tariff_env
    refund = te.refund_due
    te.refund_due = 0.0
    na = length(R.fl.flag_assets)
    w = Float64[sim.status[a].actual for a in 1:na]
    sw = r_sum(w)
    w = sw > 0 ? w ./ sw : fill(1 / na, na)
    for a in 1:na
        sim.status[a].money = sim.status[a].money + refund * w[a]
    end
    R.details && _cat(R, r_sprintf("Steuerereignis:\tGünstigerprüfung: Erstattung %.2f EUR in den Geldbestand am %s\n",
                                   refund, fmt_date(R.fl.flag_date[time])))
    return nothing
end

"Steuer der offenen Vorabpauschalen (bei mehreren gemeinsam über den Verlusttopf)."
function _vp_taxes!(R::Run, sim::Sim, pend::Vector{VPPending})
    cfg = R.cfg
    res = Vector{NamedTuple{(:tax, :spb_used),Tuple{Float64,Float64}}}(undef, length(pend))
    if length(pend) > 1
        taxable = Float64[p.flat_rate * (1 - p.bonus) for p in pend]
        st = r_sum(taxable)
        pooled = vp_tax!(st, 0.0, sim.totals, cfg.effective_tax_rate, cfg.use_sparer_pauschbetrag)
        share = st > 0 ? taxable ./ st : fill(1 / length(pend), length(pend))
        for j in eachindex(pend)
            res[j] = (tax = pooled.tax * share[j], spb_used = pooled.spb_used * share[j])
        end
    elseif length(pend) == 1
        p = pend[1]
        r1 = vp_tax!(p.flat_rate, p.bonus, sim.totals, cfg.effective_tax_rate, cfg.use_sparer_pauschbetrag)
        res[1] = (tax = r1.tax, spb_used = r1.spb_used)
    end
    return res
end

"Zufluss der festgesetzten Vorabpauschalen."
function _settle_vp!(R::Run, sim::Sim, time::Int; prepaid = nothing)
    pend = sim.totals.vp_pending
    sim.totals.vp_pending = VPPending[]
    res = _vp_taxes!(R, sim, pend)
    fd = fmt_date(R.fl.flag_date[time])
    for (j, p) in enumerate(pend)
        result = res[j]
        pre = prepaid === nothing ? 0.0 : prepaid[j]
        if R.details
            _cat(R, r_sprintf("Steuerereignis:\tVorabpauschale %s (festgesetzt %s): %.2f EUR, nach TFS %.2f EUR, SPB %.2f EUR, Steuer %.2f EUR am %s\n",
                              sim.names[p.asset], fmt_date(p.assessment_date), p.flat_rate, p.flat_rate * (1 - p.bonus),
                              result.spb_used, result.tax, fd))
        end
        if result.tax > 0 || pre > 0
            _pay_vp!(R, sim, p.asset, result.tax, time, p.flat_rate, p.bonus, result.spb_used, p.assessment_date, pre)
        end
    end
    return nothing
end

# ── Tagesschleife (sim_loop.R) ─────────────────────────────────────────────

function _sim_run_days!(R::Run, sim::Sim, fr::_Frame, liquidate, event_weight, split_thresh, funds_fee, bonus_fee,
                        balance_dca, harvest_loss_pot)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    flag_date = fl.flag_date
    flag_rebalance = copy(fl.flag_rebalance)
    flag_trade = copy(fl.flag_trade)
    tax_mode = cfg.tax_mode
    details = R.details
    prev_end = 0
    active::Vector{Int} = Int[]
    buf = Float64[]
    for time in fl.individual_days
        time > prev_end + 1 && batch_market_update!(sim, prev_end + 1, time - 1, buf)
        if fl.flag_year_change[time]
            _handle_year_change!(R, sim, flag_date[time], cfg.tariff_env, details)
        end
        if !fl.flag_slow_path[time]
            perform_market_update!(sim, time)
            prev_end = time
            continue
        end
        if fl.flag_active[time] || isempty(active)
            active = [a for a in eachindex(fl.flag_assets) if fl.asset_start_indices[a] <= time]
        end
        cfg.fees_on && (R.fee_current = cfg.fee_order)
        fast = true
        if tax_mode == "person" && fl.flag_vp_settle[time] &&
           (!isempty(sim.totals.vp_pending) || !isempty(sim.totals.p23_due) || _gp_pending(R))
            isempty(sim.totals.vp_pending) || _settle_vp!(R, sim, time)
            isempty(sim.totals.p23_due) || _settle_p23!(R, sim, time)
            _gp_pending(R) && _settle_gp!(R, sim, time)
            calculate_total_report!(sim, time)
            fast = false
        end
        if fl.flag_active[time]
            if _sim_day_activate!(R, sim, time, active)
                flag_rebalance[time] = true
                flag_trade[time] = false
            end
            fast = false
        end
        if fl.flag_split[time]
            _sim_day_split!(R, sim, time, active, split_thresh)
            fast = false
        end
        if fl.flag_dca[time]
            _sim_day_dca!(R, sim, time, active, balance_dca)
            fast = false
        end
        if flag_trade[time]
            _sim_day_trade!(R, sim, time, active) && (fast = false)
        end
        if flag_rebalance[time]
            _sim_day_rebalance!(R, sim, time, active, fr, event_weight)
            fast = false
        end
        if fl.flag_harvest[time]
            _sim_day_harvest!(R, sim, time, active, harvest_loss_pot)
            fast = false
        end
        if fl.flag_taxes[time]
            _sim_day_assess_vp!(R, sim, time, liquidate)
            fast = false
        end
        if fl.flag_fund_fee[time]
            _sim_day_fund_fee!(R, sim, time, funds_fee, bonus_fee)
            fast = false
        end
        if fl.flag_liquidate[time]
            _sim_day_liquidate!(R, sim, time)
            fast = false
        end
        fast && perform_market_update!(sim, time)
        prev_end = time
    end
    prev_end < fl.n_total_days && batch_market_update!(sim, prev_end + 1, fl.n_total_days, buf)
    return nothing
end

function _sim_day_activate!(R::Run, sim::Sim, time::Int, active::Vector{Int})
    fl, cfg = R.fl, R.cfg
    for a in eachindex(fl.flag_assets)
        a in active && continue
        sim.market[a].signal_buy.v[time] = 0.0
        sim.market[a].signal_sell.v[time] = 0.0
    end
    today = fl.flag_date[time]
    late_now = any(a -> fl.asset_starts[a] == today && !(a in fl.initial_assets), eachindex(fl.flag_assets))
    rebalance_now = false
    if _truthy_mode(cfg.balance_mode) || late_now
        cws = r_sum([sim.status[a].actual for a in active])
        for a in active
            sim.status[a].differ = sim.status[a].actual / cws
        end
        if R.details
            new_assets = [fl.flag_assets[a] for a in eachindex(fl.flag_assets) if fl.asset_starts[a] == today]
            isempty(new_assets) || _cat(R, "Marktereignis:\tHandel mit $(join(new_assets, ", ")) ab jetzt möglich.\n")
        end
        rebalance_now = true
    end
    calculate_total_report!(sim, time)
    return rebalance_now
end

function _sim_day_split!(R::Run, sim::Sim, time::Int, active::Vector{Int}, split_thresh)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    lo, hi = Float64(split_thresh[1]), Float64(split_thresh[2])
    held = [a for a in active if sim.status[a].count > 0]
    for a in eachindex(fl.flag_assets)
        a in held && continue
        px0 = sim.market[a].asset_price[time]
        if px0 > hi || px0 < lo
            sim.market[a].asset_price = sim.market[a].asset_price ./ (px0 / 100)
            if R.details
                _cat(R, "Split-Ereignis:\t$(fl.flag_assets[a]) ohne Bestand: Kursreihe $(px0 > hi ? "1 :" : ": 1") " *
                        "$(r_format1(px0 > hi ? px0 / 100 : 100 / px0; digits = 5)) am $(fmt_date(fl.flag_date[time]))\n")
            end
        end
    end
    for a in active
        if sim.status[a].count > 0
            split_price = sim.market[a].asset_price[time]
            split_price > hi && _perform_asset_split!(R, sim, a, split_price / 100, time, "forward", fl.flag_date[time])
            split_price < lo && _perform_asset_split!(R, sim, a, 100 / split_price, time, "reverse", fl.flag_date[time])
            split_cnt = sim.status[a].count
            split_frac = split_cnt - floor(split_cnt + 1e-9)
            if !cfg.fractions && split_frac > 1e-9
                fee_keep = R.fee_current
                R.fee_current = nothing
                _sell!(R, sim, a, time, "Split:", 0.0; count = split_frac)
                R.fee_current = fee_keep
            end
        end
    end
    calculate_total_report!(sim, time)
    return nothing
end

function _sim_day_dca!(R::Run, sim::Sim, time::Int, active::Vector{Int}, balance_dca)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    dca_amount = cfg.dca_value * fl.flag_dca_n[time]
    strat_w = Float64[Float64(cfg.strategy[a].second["asset_share"]) for a in active]
    strat_w = strat_w ./ r_sum(strat_w; na_rm = true)
    if _is_true(balance_dca) && length(active) > 1
        calculate_total_report!(sim, time)
        totals_now = Float64[sim.status[a].total for a in active]
        desired = strat_w .* (r_sum(totals_now; na_rm = true) + dca_amount)
        deficit = Float64[r_max2(0.0, desired[i] - totals_now[i]) for i in eachindex(active)]
        if r_sum(deficit) > dca_amount
            alloc = dca_amount .* deficit ./ r_sum(deficit)
        else
            alloc = deficit .+ (dca_amount - r_sum(deficit)) .* strat_w
        end
        for (i, a) in enumerate(active)
            dca_flows_allocation!(sim, a, alloc[i], time)
        end
    else
        for (i, a) in enumerate(active)
            dca_flows_allocation!(sim, a, strat_w[i] * dca_amount, time)
        end
    end
    if R.details
        parts = join((r_sprintf("%s %.2f EUR", fl.flag_assets[a], sim.report[a].flows[time]) for a in active), "; ")
        _cat(R, r_sprintf("Einzahlung:\t%.2f EUR in das Depot am %s\n\t\t=> ", dca_amount, fmt_date(fl.flag_date[time])) * parts * "\n")
    end
    calculate_total_report!(sim, time)
    return nothing
end

function _sim_day_trade!(R::Run, sim::Sim, time::Int, active::Vector{Int})
    trade_event = false
    for a in active
        f_buy = _calculate_buy_signal(sim, a, time)
        f_sell = _calculate_sell_signal(sim, a, time)
        if f_buy
            _buy_with_fee!(R, sim, a, time, "Handelssignal:")
            trade_event = true
        end
        if f_sell
            _sell!(R, sim, a, time, "Handelssignal:", R.fl.spread_rates[a])
            trade_event = true
        end
    end
    trade_event && calculate_total_report!(sim, time)
    return trade_event
end

function _sim_day_rebalance!(R::Run, sim::Sim, time::Int, active::Vector{Int}, fr::_Frame, event_weight)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    details = R.details
    fd = fmt_date(fl.flag_date[time])
    sr = fl.spread_rates
    balance_thresh = cfg.balance_thresh
    at = Float64[sim.status[a].actual for a in active]
    at = at ./ r_sum(at; na_rm = true)
    targets = at
    if event_weight !== nothing && fl.flag_event[time]
        ow = Float64[]
        for a in active
            j = findfirst(p -> p.first == fl.flag_assets[a], event_weight)
            push!(ow, j === nothing ? NA : Float64(fr.cols[event_weight[j].second][time]))
        end
        if all(isfinite, ow) && r_sum(ow) > 0
            targets = ow ./ r_sum(ow)
        end
    end
    signal_cash_only = Int[]
    for a in active
        if sim.assets[a].style == "signal"
            has_pos = sim.status[a].count > 0
            sig_buy = _sig_is_true(sim.market[a].signal_buy, time)
            sig_sell = _sig_is_true(sim.market[a].signal_sell, time)
            if has_pos && sig_sell
                _sell!(R, sim, a, time, "Rebalancing/Signal-Ausstieg:", sr[a])
                push!(signal_cash_only, a)
            elseif !has_pos && sig_buy
                _perform_trade_buy!(R, sim, a, time, "Rebalancing/Signal-Einstieg:", sr[a], cfg.fractions)
            elseif !has_pos && !sig_buy
                push!(signal_cash_only, a)
            end
        end
    end
    calculate_total_report!(sim, time)
    actual_weights = Float64[sim.status[a].differ for a in active]
    today = fl.flag_date[time]
    force_rebalance = any(==(today), fl.asset_starts)
    if force_rebalance && details
        new_assets = [fl.flag_assets[a] for a in eachindex(fl.flag_assets) if fl.asset_starts[a] == today]
        _cat(R, "Rebalancing:\tErzwungenes Rebalancing am $fd wegen neu handelbarer Assets: $(join(new_assets, ", "))\n")
    end
    local event_rebalance::Bool
    if force_rebalance
        event_rebalance = true
    elseif balance_thresh === nothing
        event_rebalance = true
    else
        deviations = if cfg.balance_thresh_type == "relative"
            Float64[targets[i] != 0 ? abs(actual_weights[i] / targets[i] - 1) : (actual_weights[i] != 0 ? Inf : NA)
                    for i in eachindex(active)]
        else
            Float64[abs(targets[i] - actual_weights[i]) for i in eachindex(active)]
        end
        devs_ok = [x for x in deviations if !isnan(x)]
        max_deviation = isempty(devs_ok) ? -Inf : maximum(devs_ok)
        event_rebalance = max_deviation > balance_thresh
        if details
            if event_rebalance
                _cat(R, r_sprintf("Rebalancing:\tRebalancing am %s (max. Abweichung: %.2f%% > Schwelle: %.2f%%)\n", fd,
                                  max_deviation * 100, balance_thresh * 100))
                for (i, a) in enumerate(active)
                    if deviations[i] > balance_thresh
                        _cat(R, r_sprintf("\t\t=> %s: Ziel=%.1f%%, Ist=%.1f%%, Abweichung=%.2f%%\n", fl.flag_assets[a],
                                          targets[i] * 100, actual_weights[i] * 100, deviations[i] * 100))
                    end
                end
            else
                _cat(R, r_sprintf("Rebalancing:\tKein Rebalancing am %s (max. Abweichung: %.2f%% < Schwelle: %.2f%%)\n", fd,
                                  max_deviation * 100, balance_thresh * 100))
            end
        end
    end
    if event_rebalance
        differ = Float64[targets[i] - actual_weights[i] for i in eachindex(active)]
        total_strategy = r_sum([sim.status[a].total for a in active]; na_rm = true)
        transfer_pool = 0.0
        transfer_value = Float64[abs(differ[i] * total_strategy) for i in eachindex(active)]
        for (i, a) in enumerate(active)
            differ[i] < 0 || continue
            sell_target = transfer_value[i] - _rmax(0.0, sim.status[a].money)
            if sim.status[a].count > 0 && sell_target > 0
                srs = _calculate_sell_count(sim, a, sell_target, time, sr[a], cfg.fractions, cfg.tax_mode,
                                            cfg.effective_tax_rate, fl.tax_regimes[a])
                _sell!(R, sim, a, time, "Rebalancing:", sr[a]; count = srs.sell_count, price = srs.fifo_price)
            end
            available_cash = _rmin(sim.status[a].money, transfer_value[i])
            transfer_pool = transfer_pool + available_cash
            sim.status[a].money = sim.status[a].money - available_cash
            details && _cat(R, r_sprintf("\t\t%.2f EUR von %s in den Rebalancing-Topf\n", available_cash, fl.flag_assets[a]))
        end
        for (i, a) in enumerate(active)
            differ[i] > 0 || continue
            allocation = _rmin(transfer_value[i], transfer_pool)
            if allocation > 0
                sim.status[a].money = sim.status[a].money + allocation
                transfer_pool = transfer_pool - allocation
                details && _cat(R, r_sprintf("Rebalancing:\t%.2f EUR aus dem Rebalancing-Topf an %s\n", allocation, fl.flag_assets[a]))
                if a in signal_cash_only
                    details && _cat(R, r_sprintf("\t\t=> %s hält %.2f EUR als Cash-Reserve (Signal inaktiv)\n",
                                                 fl.flag_assets[a], sim.status[a].money))
                else
                    _perform_trade_buy!(R, sim, a, time, "Rebalancing:", sr[a], cfg.fractions)
                end
            end
        end
        if transfer_pool > 0.01
            details && _cat(R, r_sprintf("\t\tRestverteilung von %.2f EUR aus dem Rebalancing-Topf\n", transfer_pool))
            for (i, a) in enumerate(active)
                redistribution = targets[i] * transfer_pool
                sim.status[a].money = sim.status[a].money + redistribution
                details && _cat(R, r_sprintf("\t\t=> %.2f EUR an %s\n", redistribution, fl.flag_assets[a]))
            end
        end
    end
    for a in active
        st = sim.status[a]
        if !(a in signal_cash_only) && st.money > 0.005 && (sim.assets[a].style != "signal" || st.count > 0)
            _buy_with_fee!(R, sim, a, time, "Rebalancing:")
        end
    end
    calculate_total_report!(sim, time)
    return nothing
end

function _sim_day_harvest!(R::Run, sim::Sim, time::Int, active::Vector{Int}, harvest_loss_pot)
    @nospecialize
    cfg, fl = R.cfg, R.fl
    cfg.fees_on && (R.fee_current = cfg.fee_order)
    for a in active
        _perform_gain_harvest!(R, sim, a, time, fl.tax_regimes[a], fl.spread_rates[a], cfg.fractions,
                               _truthy_mode(harvest_loss_pot), cfg.use_sparer_pauschbetrag)
    end
    calculate_total_report!(sim, time)
    return nothing
end

function _sim_day_assess_vp!(R::Run, sim::Sim, time::Int, liquidate)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    if cfg.tax_mode == "person" && !(liquidate == true && fl.flag_liquidate[time])
        for a in eachindex(fl.flag_assets)
            regime = fl.tax_regimes[a]
            if regime == "investment_fund" && sim.status[a].count > 0
                vp_result = _calculate_flat_rate(sim, a, time, fl.flag_date, regime, fl.flag_filled)
                fr_ = vp_result.total_vp
                buys_l = sim.trades[a].buys
                for (vp_i, lv) in zip(vp_result.lot_indices, vp_result.lot_vps)
                    lot = buys_l[vp_i]
                    lot.vp = lot.vp + lv
                end
                if fr_ > 0
                    push!(sim.totals.vp_pending, VPPending(a, fr_, sim.assets[a].bonus, fl.flag_date[time]))
                    if R.details
                        _cat(R, r_sprintf("Steuerereignis:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (Zufluss und Steuer am ersten Handelstag des Folgejahres)\n",
                                          fl.flag_assets[a], fr_, fmt_date(fl.flag_date[time])))
                    end
                end
            end
        end
    end
    calculate_total_report!(sim, time)
    return nothing
end

function _sim_day_fund_fee!(R::Run, sim::Sim, time::Int, funds_fee, bonus_fee)
    @nospecialize
    fl = R.fl
    calculate_total_report!(sim, time)
    result_fees = _calculate_fund_fees(R, sim, time, fl.flag_date, Float64(funds_fee), Float64(bonus_fee))
    sim.totals.total_value = result_fees.total_value
    for a in eachindex(fl.flag_assets)
        fee_i = result_fees.asset_fees[a]
        (!isfinite(fee_i) || fee_i <= 0) && continue
        sim.status[a].money < fee_i && _raise_cash!(R, sim, a, fee_i, time, "Fondskosten:")
        paid = _rmin(fee_i, _rmax(0.0, sim.status[a].money))
        sim.status[a].money = sim.status[a].money - paid
        R.details && _cat(R, r_sprintf("\t\t=> %.2f EUR Gebühren von %s abgezogen\n", paid, fl.flag_assets[a]))
        push!(sim.trades[a].fees, FeeEntry(fl.flag_date[time], paid))
    end
    calculate_total_report!(sim, time)
    return nothing
end

function _sim_day_liquidate!(R::Run, sim::Sim, time::Int)
    fl, cfg = R.fl, R.cfg
    tax_mode = cfg.tax_mode
    for a in eachindex(fl.flag_assets)
        if sim.status[a].count > 0
            _sell!(R, sim, a, time, "Liquidation:", fl.spread_rates[a]; tax_mode = tax_mode == "person" ? "person" : "none")
            if sim.status[a].count > 0
                @warn r_sprintf("simulation: liquidate = TRUE: Position '%s' (Wert %.2f EUR) wurde nicht verkauft, weil die Ordergebühr den Erlös übersteigt.",
                                fl.flag_assets[a], sim.status[a].worth)
            end
        end
    end
    if tax_mode == "funds"
        calculate_total_report!(sim, time)
        na = length(fl.flag_assets)
        final_value = r_sum([sim.status[a].total for a in 1:na]; na_rm = true)
        deposits = r_sum([r_sum(view(sim.report[a].flows, 1:time)) for a in 1:na])
        total_gains = final_value - cfg.start_value - deposits
        if total_gains > 0
            total_taxes = total_gains * cfg.tax_rate
            cash = Float64[_rmax(0.0, sim.status[a].money) for a in 1:na]
            sc = r_sum(cash)
            tax_weights = sc > 0 ? cash ./ sc : fill(1 / na, na)
            for a in 1:na
                tpa = _rmin(total_taxes * tax_weights[a], cash[a])
                sim.status[a].money = sim.status[a].money - tpa
                sim.totals.total_taxes = sim.totals.total_taxes + tpa
            end
            R.details && _cat(R, r_sprintf("Liquidation:\tSteuern %.2f EUR auf den Gesamtgewinn von %.2f EUR am %s\n",
                                           total_taxes, total_gains, fmt_date(fl.flag_date[time])))
        end
    end
    calculate_total_report!(sim, time)
    return nothing
end

# ── Abschluss des letzten Jahres ───────────────────────────────────────────

function _sim_close_years!(R::Run, sim::Sim, stopp_date::Int)
    fl, cfg = R.fl, R.cfg
    n_total_days = fl.n_total_days
    te = cfg.tariff_env
    next_jan1 = days_from_civil(year_of(stopp_date) + 1, 1, 1)
    final_year_change!(s, env, det) = _handle_year_change!(R, s, next_jan1, env, det)
    if cfg.tax_mode == "person"
        if !isempty(sim.totals.vp_pending)
            vp_year = year_of(sim.totals.vp_pending[1].assessment_date)
            prepaid = nothing
            if sim.totals.current_year <= vp_year
                dry = deepcopy(sim)
                Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                    final_year_change!(dry, nothing, false)
                end
                pend = sim.totals.vp_pending
                res = _vp_taxes!(R, dry, pend)
                prepaid = Float64[r.tax for r in res]
                for (j, p) in enumerate(pend)
                    prepaid[j] > 0 && _pay_tax!(R, sim, p.asset, prepaid[j], n_total_days, "Vorabpauschale")
                end
                final_year_change!(sim, te, R.details)
            end
            _settle_vp!(R, sim, n_total_days; prepaid = prepaid)
        end
        final_year_change!(sim, te, R.details)
        if te !== nothing
            y_last = sim.totals.current_year
            cbt = sim.totals.cgt_base_taxed_ytd
            if te.use_gp && y_last > year_of(stopp_date) && cbt > 0
                D = _tariff_close(R, te, y_last, 0.0, cbt, cfg.effective_tax_rate, R.details)
                _tariff_book!(sim, te, D)
            end
        end
        isempty(sim.totals.p23_due) || _settle_p23!(R, sim, n_total_days)
        te !== nothing && _gp_pending(R) && _settle_gp!(R, sim, n_total_days)
        calculate_total_report!(sim, n_total_days)
    end
    return nothing
end
