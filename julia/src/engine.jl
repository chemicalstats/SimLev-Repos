# ─────────────────────────────────────────────────────────────────────────────
# Backtest-Engine (Port von simulation() aus SimLev 0.5.0)
#
# Die Struktur folgt den Phasen des R-Pakets (simulation.R, sim_validate.R,
# sim_prepare.R, sim_actions.R, sim_loop.R, sim_evaluate.R), damit beide
# Implementierungen Zeile für Zeile vergleichbar bleiben und bitgleich rechnen:
#
#   1. _sim_check_inputs   Eingabeprüfung, Steuer- und Gebühreneinstellungen
#   2. _sim_prepare_data   Kalenderraster, LOCF; _sim_build_state (sim_mem);
#      _sim_build_calendar (Termine und Flags); _sim_init_weights; _sim_build_schedule
#   3. Run                 Zahlungs- und Abrechnungshelfer (sim_actions.R)
#   4. _sim_run_days       Tagesschleife mit den Tagesschritten _sim_day_*
#   5. _sim_close_years    Abschluss des letzten Jahres
#   6. _sim_returns, _sim_risk_stats, _sim_undefined_metrics, _sim_result
#
# Tagesindizes (`time`) sind wie in R 1-basiert. Hier stehen die Handels- und
# Steuerfunktionen aus simulation.R; die Phasen in sim_*.jl.
# ─────────────────────────────────────────────────────────────────────────────

include("tax_tariff.jl")

const _DOUBLE_LINE = "═"^62

"Sentinel für nicht angegebene Argumente (R: `missing(arg)`)."
struct _Unset end
const _UNSET = _Unset()
_val(x, d) = x isa _Unset ? d : x

_rmin(a::Real, b::Real) = r_min2(Float64(a), Float64(b))
_rmax(a::Real, b::Real) = r_max2(Float64(a), Float64(b))

"R `isTRUE()`."
_is_true(x) = x isa Bool && x
_is_num(x) = x isa Real && !(x isa Bool)

"`.n_tage()`: \"1 Tag\" bzw. \"n Tage\"."
function _n_tage(n)
    s = n isa AbstractString ? String(n) : string(Int(n))
    return s == "1" ? "1 Tag" : s * " Tage"
end

"Zahlenvektor aus Skalar/Folge (nothing, wenn nicht numerisch)."
function _num_vec(x)
    @nospecialize
    _is_num(x) && return Float64[Float64(x)]
    x isa RVector && (x = x.values)
    if x isa Union{AbstractVector,Tuple}
        vals = collect(Any, x)
        all(v -> _is_num(v) || v === nothing || v === missing, vals) || return nothing
        return Float64[_is_num(v) ? Float64(v) : NA for v in vals]
    end
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# Datumswerte
# ═══════════════════════════════════════════════════════════════════════════

"`as.Date(s, format = \"%Y-%m-%d\")` wie R's strptime (Ziffernfelder, Rest ignoriert)."
function _r_strptime_ymd(s::AbstractString)
    cs = collect(s)
    rp = 1
    function get_number(lo, hi, n)
        while rp <= length(cs) && cs[rp] == ' '
            rp += 1
        end
        (rp > length(cs) || !isdigit(cs[rp])) && return nothing
        val = 0; k = n
        while true
            val = val * 10 + (cs[rp] - '0')
            rp += 1; k -= 1
            (k > 0 && rp <= length(cs) && isdigit(cs[rp])) || break
        end
        (val < lo || val > hi) && return nothing
        return val
    end
    y = get_number(0, 9999, 4)
    (y === nothing || rp > length(cs) || cs[rp] != '-') && return nothing
    rp += 1
    m = get_number(1, 12, 2)
    (m === nothing || rp > length(cs) || cs[rp] != '-') && return nothing
    rp += 1
    d = get_number(1, 31, 2)
    d === nothing && return nothing
    return valid_civil(y, m, d)
end

"`as.Date(x)` für einen Wert (Text JJJJ-MM-TT bzw. JJJJ/MM/TT, Datum, Zahl); nothing = NA."
function _as_date(x)
    @nospecialize
    x === nothing && return nothing
    if x isa Union{AbstractVector,Tuple}
        length(x) == 1 || return nothing
        x = first(x)
    end
    if x isa AbstractString
        z = _r_strptime_ymd(x)
        if z === nothing && occursin(r"^\s*\d{1,4}/\d{1,2}/\d", x)
            z = _r_strptime_ymd(replace(x, "/" => "-"; count = 2))
        end
        return z
    end
    x isa Date && return to_days(x)
    x isa DateTime && return to_days(Date(x))
    if _is_num(x)
        isnan(Float64(x)) && return nothing
        return Int(floor(Float64(x)))
    end
    return nothing
end

function _date_or_fail(x)
    z = _as_date(x)
    z === nothing && error("character string is not in a standard unambiguous format")
    return z
end

# ═══════════════════════════════════════════════════════════════════════════
# Gebühren (R: .fee_env, .fee_spec, .fee_amount, .fee_volume)
# ═══════════════════════════════════════════════════════════════════════════

struct FeeSpec
    fixed::Float64
    percent::Float64
    min::Float64
    max::Float64
end

function _fee_spec(x)
    @nospecialize
    x === nothing && return nothing
    _is_num(x) && (x = ["fixed" => x])
    _is_mapping(x) || error("order_fee/dca_fee: Zahl (EUR je Order) oder list(fixed, percent, min, max).")
    ps = _kvpairs(x)
    unk = [p.first for p in ps if !(p.first in ("fixed", "percent", "min", "max"))]
    if !isempty(ps) && (any(p -> isempty(p.first), ps) || !isempty(unk))
        error("order_fee/dca_fee: unbekannte oder unbenannte Felder (" * join(isempty(unk) ? ["ohne Namen"] : unk, ", ") *
              "); erlaubt sind fixed, percent, min, max.")
    end
    d = Dict(ps)
    g(k, dflt) = (v = get(d, k, nothing); v === nothing ? dflt : Float64(v))
    s = FeeSpec(g("fixed", 0.0), g("percent", 0.0) / 100, g("min", 0.0), g("max", Inf))
    (s.fixed < 0 || s.percent < 0 || s.min < 0 || s.max < s.min) && error("Gebühren müssen nicht negativ sein (min <= max).")
    (s.fixed == 0 && s.percent == 0 && s.min == 0) && return nothing
    return s
end

_fee_amount(f::FeeSpec, volume::Float64) = _rmin(_rmax(f.fixed + f.percent * volume, f.min), f.max)

function _fee_volume(f::FeeSpec, money::Float64)
    v = (money - f.fixed) / (1 + f.percent)
    fee = f.fixed + f.percent * v
    if fee < f.min
        v = money - f.min
    elseif fee > f.max
        v = money - f.max
    end
    return _rmax(0.0, v)
end

# ═══════════════════════════════════════════════════════════════════════════
# Termine und Flags
# ═══════════════════════════════════════════════════════════════════════════

function _calculate_dates_flags(mode, span, unit, days, dates::Vector{Int}, value, anchor, start_date,
                                skip_start, liquidate)
    @nospecialize
    n = length(dates)
    if !_truthy_mode(mode) || unit === nothing || (value !== nothing && value <= 0)
        return falses(n)
    end
    span === nothing && (span = 1)
    unit = match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = match_arg(anchor, ("start", "end"), "anchor")
    dmin, dmax = minimum(dates), maximum(dates)
    start = start_date === nothing ? dmin : _date_or_fail(start_date)
    day_list = days === nothing ? nothing : _num_vec(days)
    schedule = Float64[]
    sy, sm, _ = ymd(start)
    if unit == "month" || unit == "quarter"
        step = Int(span) * (unit == "quarter" ? 3 : 1)
        f = days_from_civil(sy, sm, 1)
        base_seq = Int[]
        k = 0
        while true
            z = add_months_first(f, k * step)
            z > dmax && break
            push!(base_seq, z)
            k += 1
        end
        if day_list === nothing
            append!(schedule, Float64.(base_seq))
        else
            for m0 in base_seq
                yr, mon, _ = ymd(m0)
                for dd in day_list
                    if anchor == "start"
                        r = _r_strptime_ymd(string(yr, "-", mon, "-", r_as_character(dd)))
                        push!(schedule, r === nothing ? NA : Float64(r))
                    elseif unit == "month"
                        month_end = mon == 12 ? days_from_civil(yr + 1, 1, 1) - 1 : days_from_civil(yr, mon + 1, 1) - 1
                        d_end = Float64(month_end) - (dd - 1)
                        push!(schedule, d_end < m0 ? NA : d_end)
                    else
                        end_mon, end_yr = mon + 3, yr
                        if end_mon > 12
                            end_mon -= 12; end_yr = yr + 1
                        end
                        quarter_end = days_from_civil(end_yr, end_mon, 1) - 1
                        push!(schedule, Float64(quarter_end) - (dd - 1))
                    end
                end
            end
        end
    else
        base_years = Int[]
        y = sy
        while days_from_civil(y, 1, 1) <= dmax
            push!(base_years, y)
            y += Int(span)
        end
        if day_list === nothing
            append!(schedule, Float64[days_from_civil(y, 1, 1) for y in base_years])
        else
            for y in base_years, dd in day_list
                if anchor == "start"
                    r = _r_strptime_ymd(string(y, "-1-", r_as_character(dd)))
                    push!(schedule, r === nothing ? NA : Float64(r))
                else
                    push!(schedule, Float64(days_from_civil(y, 12, 31)) - (dd - 1))
                end
            end
        end
    end
    sset = Set{Int}()
    for s in schedule
        (isnan(s) || s != floor(s)) && continue
        z = Int(s)
        (z < dmin || z > dmax) && continue
        skip_start == true && z == dmin && continue
        liquidate == true && z == dmax && continue
        push!(sset, z)
    end
    return BitVector([z in sset for z in dates])
end
_truthy_mode(m) = m isa Bool ? m : (m isa Real ? m != 0 : false)

function _calculate_split_flags(sim::Sim, base::Float64, mode, n::Int, split_thresh)
    @nospecialize
    (!_truthy_mode(mode) || split_thresh === nothing) && return falses(n)
    lo, hi = Float64(split_thresh[1]), Float64(split_thresh[2])
    flag = falses(n)
    for a in eachindex(sim.names)
        prices = copy(sim.market[a].asset_price)
        for i in 1:n
            cp = prices[i]
            if cp > hi
                flag[i] = true
                ratio = cp / base
                @inbounds for j in i:n
                    prices[j] = prices[j] / ratio
                end
            elseif cp < lo
                flag[i] = true
                ratio = base / cp
                @inbounds for j in i:n
                    prices[j] = prices[j] * ratio
                end
            end
        end
    end
    return flag
end

function _shift_off_filled(flags::AbstractVector{Bool}, filled::AbstractVector{Bool}, mon::Vector{Int})
    hit = findall(i -> flags[i] && filled[i], eachindex(flags))
    isempty(hit) && return flags
    flags = BitVector(flags)
    n = length(flags)
    for i in hit
        j = _shift_target(i, filled, mon, n)
        flags[i] = false
        1 <= j <= n && (flags[j] = true)
    end
    return flags
end
function _shift_off_filled(flags::Vector{Float64}, filled::AbstractVector{Bool}, mon::Vector{Int})
    hit = findall(i -> flags[i] != 0 && filled[i], eachindex(flags))
    isempty(hit) && return flags
    flags = copy(flags)
    n = length(flags)
    for i in hit
        j = _shift_target(i, filled, mon, n)
        1 <= j <= n && (flags[j] = flags[j] + flags[i])
        flags[i] = 0.0
    end
    return flags
end
function _shift_target(i, filled, mon, n)
    j = i + 1
    while j <= n && filled[j]
        j += 1
    end
    if j > n || mon[j] != mon[i]
        j = i - 1
        while j >= 1 && filled[j]
            j -= 1
        end
    end
    return j
end

# ═══════════════════════════════════════════════════════════════════════════
# Lauf-Kontext (Gebühren, Ausgabe, Konfiguration)
# ═══════════════════════════════════════════════════════════════════════════

mutable struct TariffEnv
    tariff::Any
    zve_all::Union{Nothing,Float64}
    zve::Union{Nothing,Dict{String,Float64}}
    ks::Dict{String,Float64}
    church_k::Float64
    kapest_rate::Float64
    use_gp::Bool
    rows::Vector{RList}
    refund_due::Float64
    due_info::Vector{NamedTuple{(:year, :D, :p23, :ded, :by_p23),Tuple{Int,Float64,Float64,Float64,Bool}}}
end
TariffEnv() = TariffEnv(nothing, nothing, nothing, Dict{String,Float64}(), 0.0, 0.25, false, RList[], 0.0,
                        NamedTuple{(:year, :D, :p23, :ded, :by_p23),Tuple{Int,Float64,Float64,Float64,Bool}}[])

mutable struct Cfg
    tax_mode::String
    start_value::Float64
    tax_rate::Float64
    marginal_tax_rate::Union{Nothing,Float64}
    effective_tax_rate::Float64
    soli_factor_income::Float64
    church_k::Float64
    tariff_env::Union{Nothing,TariffEnv}
    private_sale_threshold::Float64
    sparer_pauschbetrag::Float64
    use_sparer_pauschbetrag::Bool
    fractions::Bool
    fee_order::Union{Nothing,FeeSpec}
    fee_dca::Union{Nothing,FeeSpec}
    fees_on::Bool
    order_fee::Any
    dca_mode::Any
    dca_value::Any
    dca_days::Any
    balance_mode::Any
    balance_days::Any
    balance_thresh::Union{Nothing,Float64}
    balance_thresh_type::String
    base_rate::Any
    risk_free::Any
    harvest_mode::Any
    split_mode::Any
    event_col::Any
    pre_filled::BitVector
    strategy::Vector{Pair{String,Dict{String,Any}}}
end

mutable struct Flags
    flag_date::Vector{Int}
    flag_filled::BitVector
    flag_assets::Vector{String}
    flag_liquidate::BitVector
    flag_rebalance::BitVector
    flag_dca::BitVector
    flag_dca_n::Vector{Float64}
    flag_taxes::BitVector
    flag_event::BitVector
    flag_trade::BitVector
    flag_split::BitVector
    initial_assets::Vector{Int}
    asset_starts::Vector{Int}
    flag_active::BitVector
    asset_start_indices::Vector{Int}
    flag_harvest::BitVector
    flag_fund_fee::BitVector
    strategy_types::Vector{String}
    tax_regimes::Vector{String}
    spread_rates::Vector{Float64}
    flag_slow_path::BitVector
    flag_year_change::BitVector
    flag_vp_settle::BitVector
    individual_days::Vector{Int}
    n_total_days::Int
end

mutable struct Run
    cfg::Cfg
    fl::Flags
    details::Bool
    io::IO
    tax_unpaid_total::Float64
    fee_current::Union{Nothing,FeeSpec}
    fee_paid::Float64
end

@inline _cat(R::Run, s::AbstractString) = print(R.io, s)
_message(s::AbstractString) = println(stderr, s)

# ═══════════════════════════════════════════════════════════════════════════
# Handels- und Steuerfunktionen (simulation.R)
# ═══════════════════════════════════════════════════════════════════════════

"`apply_spread(price, spread, direction)`: Kauf- bzw. Verkaufskurs mit halbem Spread."
apply_spread(price::Real, spread::Real, direction::AbstractString = "buy") =
    direction == "buy" ? Float64(price) * (1 + Float64(spread) / 2) : Float64(price) * (1 - Float64(spread) / 2)

"Wert eines Signals in `&&`-Ausdrücken (Zahl ungleich 0 = TRUE; NA ist ein Fehler)."
@inline function _sig_truthy(s::Signal, i::Int)
    x = s.v[i]
    isnan(x) && error("missing value where TRUE/FALSE needed")
    return x != 0
end
"`isTRUE()` eines Signalwerts (nur logisches TRUE)."
@inline _sig_is_true(s::Signal, i::Int) = s.logical && s.v[i] == 1.0

function _calculate_buy_signal(sim::Sim, a::Int, index::Int)
    style = sim.assets[a].style
    st = sim.status[a]; mk = sim.market[a]
    sig = false
    if style == "signal" && _sig_truthy(mk.signal_buy, index) && st.money > 0 && st.count == 0
        sig = true
    end
    if style == "signal" && st.count > 0 && st.money > 0 && !_sig_is_true(mk.signal_sell, index)
        sig = true
    end
    if style == "bnh" && st.money > 0
        sig = true
    end
    return sig
end

function _calculate_sell_signal(sim::Sim, a::Int, index::Int)
    style = sim.assets[a].style
    sig = false
    if style == "signal" && _sig_truthy(sim.market[a].signal_sell, index) && sim.status[a].count > 0
        sig = true
    end
    style == "bnh" && (sig = false)
    return sig
end

function _perform_trade_buy!(R::Run, sim::Sim, a::Int, index::Int, reason::String, spread::Float64,
                             fractions::Bool; count = nothing)
    mk = sim.market[a]
    market_price = mk.asset_price[index]
    if isnan(market_price) || market_price <= 0
        @warn r_sprintf("perform_trade_buy: ungültiger Kurs (%.4f) für %s am %s; der Kauf wird übersprungen.",
                        market_price, sim.names[a], fmt_date(mk.asset_day[index]))
        return nothing
    end
    trade_price = apply_spread(market_price, spread, "buy")
    local trade_count::Float64
    if count === nothing
        money = sim.status[a].money
        trade_count = fractions ? money / trade_price : floor(money / trade_price)
    else
        trade_count = Float64(count)
    end
    fee = R.fee_current
    if fee !== nothing
        money = sim.status[a].money
        if count === nothing || trade_count * trade_price + _fee_amount(fee, trade_count * trade_price) > money + 1e-9
            vol = _fee_volume(fee, money)
            trade_count = fractions ? vol / trade_price : floor(vol / trade_price)
        end
        trade_count <= 0 && return nothing
        fee_paid = _fee_amount(fee, trade_count * trade_price)
        trade_price = trade_price + fee_paid / trade_count
        R.fee_paid = R.fee_paid + fee_paid
    end
    trade_count <= 0 && return nothing
    perform_trade_buy_cpp!(sim, a, index, trade_count, trade_price, market_price)
    if R.details
        _cat(R, r_sprintf("%s\tKauf %.2fx %s zu %.2f EUR je Anteil am %s\n", reason, trade_count, sim.names[a],
                          trade_price, fmt_date(mk.asset_day[index])))
    end
    return nothing
end

function _perform_trade_sell!(R::Run, sim::Sim, a::Int, index::Int, tax_mode::String, tax_rate::Float64,
                              effective_tax_rate::Float64, use_spb::Bool, tax_regime::Union{Nothing,String},
                              reason::String, spread::Float64; count = nothing, price = nothing)
    mk = sim.market[a]
    name = sim.names[a]
    market_price = mk.asset_price[index]
    trade_price = apply_spread(market_price, spread, "sell")
    current_date = mk.asset_day[index]
    available = sim.status[a].count
    local trade_count::Float64
    if count === nothing
        trade_count = available
    else
        if count > available
            @warn r_sprintf("perform_trade_sell: angeforderte Verkaufsmenge %.4f übersteigt den Bestand %.4f von %s; verkauft wird der gesamte Bestand.",
                            count, available, name)
        end
        trade_count = _rmin(count, available)
    end
    trade_count <= 0 && return nothing
    fee = R.fee_current
    if fee !== nothing
        fee_paid = _fee_amount(fee, trade_count * trade_price)
        trade_count * trade_price - fee_paid <= 0 && return nothing
        trade_price = trade_price - fee_paid / trade_count
        R.fee_paid = R.fee_paid + fee_paid
    end
    tr = sim.trades[a]
    fifo_price = if price === nothing && tax_mode == "person"
        calculate_fifo_price(tr.buys, trade_count, tr.fifo_front)
    else
        price === nothing ? 0.0 : Float64(price)
    end
    trade_gain = (trade_price - fifo_price) * trade_count
    capital_gains_tax = 0.0
    regime = tax_regime === nothing ? "none" : tax_regime
    lot_result = nothing
    if tax_mode == "person"
        regime == "none" && (regime = sim.assets[a].tax_regime)
        totals = sim.totals
        if regime == "investment_fund"
            bonus = sim.assets[a].bonus
            vp_paid = calculate_fifo_vorabpauschale(tr.buys, trade_count, tr.fifo_front)
            adjusted = trade_gain - vp_paid
            res = p20_tax!(adjusted, bonus, totals, effective_tax_rate, use_spb)
            capital_gains_tax = res.tax
            if R.details
                vp_paid > 0 && _cat(R, r_sprintf("\t\t=> Vorabpauschale-Anrechnung (§ 19 InvStG): %.2f EUR\n", vp_paid))
                res.spb_used > 0 && _cat(R, r_sprintf("\t\t=> Sparerpauschbetrag: %.2f EUR (verbleibend: %.2f EUR)\n",
                                                      res.spb_used, totals.sparer_pauschbetrag_remaining))
            end
        elseif regime == "capital_gains"
            res = p20_tax!(trade_gain, 0.0, totals, effective_tax_rate, use_spb)
            capital_gains_tax = res.tax
        elseif regime == "private_sale"
            lot_result = calculate_private_sale_tax(tr.buys, tr.fifo_front, trade_count, trade_price, current_date)
            if R.details
                lot_result.exempt_gain > 0 && _cat(R, r_sprintf("\t\t=> Steuerfreier Gewinn (Haltedauer > 1 Jahr): %.2f EUR\n", lot_result.exempt_gain))
                lot_result.exempt_loss > 0 && _cat(R, r_sprintf("\t\t=> Nicht verrechenbarer Verlust (Haltedauer > 1 Jahr): %.2f EUR\n", lot_result.exempt_loss))
            end
            net_by = lot_result.taxable_gain - lot_result.taxable_loss
            if net_by != 0
                by = totals.private_sale_net_ytd_by
                j = findfirst(p -> p.first == a, by)
                if j === nothing
                    push!(by, a => 0.0 + net_by)
                else
                    by[j] = a => by[j].second + net_by
                end
            end
            if lot_result.taxable_gain > 0
                totals.private_sale_gains_ytd = totals.private_sale_gains_ytd + lot_result.taxable_gain
                R.details && _cat(R, r_sprintf("\t\t=> Steuerpflichtiger Gewinn (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n",
                                               lot_result.taxable_gain, totals.private_sale_gains_ytd))
            end
            if lot_result.taxable_loss > 0
                totals.private_sale_losses_ytd = totals.private_sale_losses_ytd + lot_result.taxable_loss
                R.details && _cat(R, r_sprintf("\t\t=> Verrechenbarer Verlust (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n",
                                               lot_result.taxable_loss, totals.private_sale_losses_ytd))
            end
            capital_gains_tax = 0.0
        end
    end
    calculate_sell_report!(sim, a, index, trade_count, trade_price, market_price, capital_gains_tax)
    tax_mode == "person" && fifo_consume!(sim, a, trade_count)
    if R.details
        _cat(R, r_sprintf("%s\tVerkauf %.2fx %s zu %.2f EUR je Anteil am %s\n", reason, trade_count, name, trade_price,
                          fmt_date(current_date)))
        if tax_mode == "person" && !(regime in ("none", "private_sale"))
            _cat(R, r_sprintf("\t\t=> %s: %.2f EUR; Steuer: %.2f EUR\n", trade_gain < 0 ? "Verlust" : "Gewinn",
                              trade_gain, capital_gains_tax))
        end
    end
    person = tax_mode == "person"
    push!(tr.sells, SellEntry(current_date, trade_count, trade_price, person ? trade_gain : NA,
                              person ? capital_gains_tax : NA, person ? regime : nothing,
                              person ? regime == "private_sale" : false,
                              (person && regime == "private_sale" && lot_result !== nothing) ? lot_result.exempt_gain : NA))
    return nothing
end

function _calculate_sell_count(sim::Sim, a::Int, target::Float64, index::Int, spread::Float64, fractions::Bool,
                               tax_mode::String, tax_rate::Float64, tax_regime::Union{Nothing,String} = nothing)
    market_price = sim.market[a].asset_price[index]
    trade_price = apply_spread(market_price, spread, "sell")
    total_shares = sim.status[a].count
    total_shares <= 0 && return (sell_count = 0.0, fifo_price = 0.0)
    target <= 0 && return (sell_count = 0.0, fifo_price = 0.0)
    tr = sim.trades[a]
    regime = tax_regime === nothing ? sim.assets[a].tax_regime : tax_regime
    regime = tax_mode == "person" ? regime : "none"
    bonus = regime == "investment_fund" ? sim.assets[a].bonus : 0.0
    loss_pool = sim.totals.loss_capital_gains + _rmax(0.0, sim.totals.sparer_pauschbetrag_remaining)
    code = get(REGIME_CODE, regime, 0)
    return sell_count(tr.buys, tr.fifo_front, target, trade_price, total_shares, fractions, code, bonus, loss_pool, tax_rate)
end

function _calculate_flat_rate(sim::Sim, a::Int, index::Int, dates::Vector{Int}, tax_regime, filled)
    regime = tax_regime === nothing ? sim.assets[a].tax_regime : tax_regime
    empty = (total_vp = 0.0, lot_indices = Int[], lot_vps = Float64[])
    regime != "investment_fund" && return empty
    date_index = dates[index]
    yr = year_of(date_index)
    start_of_year = days_from_civil(yr, 1, 1)
    end_of_year = days_from_civil(yr, 12, 31)
    year_start_index = max(1, (start_of_year - dates[1]) + 1)
    rate_index = year_start_index
    if filled !== nothing
        while rate_index < index && filled[rate_index]
            rate_index += 1
        end
        filled[rate_index] && (rate_index = year_start_index)
    end
    prices = sim.market[a].asset_price
    year_start_price = prices[rate_index]
    raw = sim.market[a].base_rates[rate_index] / 100
    base_rate = _rmax(0.0, raw)
    base_rate <= 0 && return empty
    market_price = prices[index]
    tr = sim.trades[a]
    return flat_rate(tr.buys, tr.fifo_front, base_rate, year_start_price, market_price, start_of_year, end_of_year)
end

function _calculate_fund_fees(R::Run, sim::Sim, index::Int, dates::Vector{Int}, funds_fee::Float64, bonus_fee::Float64)
    cur = dates[index]
    event_date = days_from_civil(year_of(cur), 1, 1)
    idx = findall(z -> z >= event_date && z <= cur, dates)
    na = length(sim.names)
    isempty(idx) && return (total_fees = 0.0, total_value = sim.totals.total_value, asset_fees = zeros(na))
    yr = year_of(cur)
    days_in_year = is_leap(yr) ? 366 : 365
    daily_rate = funds_fee / 100 / days_in_year
    basic_fees = Float64[r_sum((sim.report[a].total[i] * daily_rate for i in idx); na_rm = true) for a in 1:na]
    basic_value = r_sum(basic_fees)
    flows_period = r_sum([r_sum(view(sim.report[a].flows, idx)) for a in 1:na])
    total_value = sim.totals.total_value + flows_period
    status_totals = Float64[sim.status[a].total for a in 1:na]
    market_value = r_sum(status_totals; na_rm = true)
    above_mark = market_value > total_value
    bonus_value = above_mark ? (market_value - total_value) * (bonus_fee / 100) : 0.0
    asset_fees = market_value > 0 ? basic_fees .+ bonus_value .* status_totals ./ market_value : basic_fees .+ 0.0
    total_fees = basic_value + bonus_value
    above_mark && (total_value = _rmax(total_value, market_value - total_fees))
    if R.details
        _cat(R, r_sprintf("Fondskosten:\tFondsgebühren %.2f EUR am %s\n\t\t=> Grundgebühr: %.2f EUR; Performancegebühr: %.2f EUR\n",
                          total_fees, fmt_date(cur), basic_value, bonus_value))
    end
    return (total_fees = total_fees, total_value = total_value, asset_fees = asset_fees)
end

function _split!(sim::Sim, a::Int, ratio::Float64, forward::Bool)
    st = sim.status[a]
    current_count, current_price, current_worth = st.count, st.price, st.worth
    if forward
        split_count = current_count * ratio
        split_price = current_price / ratio
    else
        split_count = current_count / ratio
        split_price = current_price * ratio
    end
    tr = sim.trades[a]
    for b in tr.buys
        b.remaining <= 0 && continue
        orig = b.original
        if forward
            b.count = b.count * ratio
            b.price = b.price / ratio
            b.remaining = b.remaining * ratio
            b.original = orig * ratio
        else
            b.count = b.count / ratio
            b.price = b.price * ratio
            b.remaining = b.remaining / ratio
            b.original = orig / ratio
        end
    end
    tr.fifo_front = update_fifo_front(tr.buys, 1)
    st.count = split_count
    st.price = split_price
    st.worth = current_worth
    mk = sim.market[a]
    mk.asset_price = forward ? mk.asset_price ./ ratio : mk.asset_price .* ratio
    return nothing
end

function _perform_asset_split!(R::Run, sim::Sim, a::Int, ratio::Float64, index::Int, type_::String, current_date)
    type_ in ("forward", "reverse") ||
        error("perform_asset_split: type muss \"forward\" oder \"reverse\" sein, nicht $(r_deparse(type_)).")
    ratio <= 0 && error("perform_asset_split: ratio muss > 0 sein (Split-Verhältnis), nicht $(r_format1(ratio)).")
    _split!(sim, a, ratio, type_ == "forward")
    if R.details
        desc = type_ == "forward" ? "1 : " * r_format1(ratio; digits = 5) : r_format1(ratio; digits = 5) * " : 1"
        action = type_ == "forward" ? "Split" : "Reverse-Split"
        ds = current_date === nothing ? "(ohne Datum)" : fmt_date(current_date)
        _cat(R, "Split-Ereignis:\t$action $(sim.names[a]) im Verhältnis $desc am $ds\n")
    end
    return nothing
end

function _perform_gain_harvest!(R::Run, sim::Sim, a::Int, index::Int, tax_regime::String, spread::Float64,
                                fractions::Bool, use_loss_pot::Bool, use_spb::Bool)
    tax_regime in ("investment_fund", "capital_gains") || return nothing
    total = sim.status[a].count
    total <= 0 && return nothing
    room = (use_spb ? sim.totals.sparer_pauschbetrag_remaining : 0.0) + (use_loss_pot ? sim.totals.loss_capital_gains : 0.0)
    room <= 0.01 && return nothing
    market_price = sim.market[a].asset_price[index]
    (isnan(market_price) || market_price <= 0) && return nothing
    sell_price = apply_spread(market_price, spread, "sell")
    trades = sim.trades[a].buys
    front = sim.trades[a].fifo_front
    bonus = tax_regime == "investment_fund" ? sim.assets[a].bonus : 0.0
    fee = R.fee_current
    function taxable(n::Float64, with_fee::Bool = true)
        n <= 0 && return 0.0
        px = sell_price
        if with_fee && fee !== nothing
            px = px - _fee_amount(fee, n * sell_price) / n
        end
        g = (px - calculate_fifo_price(trades, n, front)) * n
        tax_regime == "investment_fund" && (g = g - calculate_fifo_vorabpauschale(trades, n, front))
        return (1 - bonus) * g
    end
    first_lot = _rmin(total, _rmax(1e-9, total * 1e-6))
    taxable(first_lot, false) <= 0 && return nothing
    local n::Float64
    if taxable(total) <= room
        n = total
    else
        lo, hi = 0.0, total
        for _ in 1:60
            mid = (lo + hi) / 2
            if taxable(mid) > room
                hi = mid
            else
                lo = mid
            end
            hi - lo < total * 1e-10 && break
        end
        n = lo
    end
    fractions || (n = floor(n))
    (n <= 0 || taxable(n) <= 0) && return nothing
    if R.details
        _cat(R, r_sprintf("Freibetrag:\tRealisierung von Gewinnen %.2f EUR mit %.4fx %s (freier Sparer-Pauschbetrag/Verlusttopf %.2f EUR)\n",
                          taxable(n), n, sim.names[a], room))
    end
    cfg = R.cfg
    _perform_trade_sell!(R, sim, a, index, cfg.tax_mode, cfg.tax_rate, cfg.effective_tax_rate, use_spb, tax_regime,
                         "Freibetrag:", spread; count = n)
    _perform_trade_buy!(R, sim, a, index, "Freibetrag:", spread, fractions)
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# Tarifweg (taxable_income, tax_tariff)
# ═══════════════════════════════════════════════════════════════════════════

function _check_taxable_income(x, years::Vector{Int})
    @nospecialize
    form = "eine Zahl (zvE in EUR für alle Jahre), ein nach Kalenderjahren benannter Zahlenvektor (z. B. c(\"2024\" = 50000, \"2025\" = 52000)) oder ein data.frame mit den Spalten year und taxable_income"
    nms = nothing
    vals = nothing
    yrname(v) = _is_num(v) ? r_as_character(v) : string(v)
    if x isa RFrame
        nm = lowercase.(names(x))
        yc = something(findfirst(==("year"), nm), findfirst(==("jahr"), nm), Some(nothing))
        vc = nothing
        for c in ("taxable_income", "betrag", "amount", "zve")
            j = findfirst(==(c), nm)
            j !== nothing && (vc = j; break)
        end
        if yc === nothing || vc === nothing
            ncol(x) != 2 && error("simulation: taxable_income als data.frame braucht die Spalten year und taxable_income (oder genau zwei Spalten Jahr, Betrag); vorhanden: $(join(names(x), ", ")).")
            yc, vc = 1, 2
        end
        kind, col = _column(x.cols[vc])
        kind != :numeric && error("simulation: taxable_income: Spalte '$(names(x)[vc])' (Betrag) muss numerisch sein.")
        vals = collect(Float64, col)
        nms = [_isna_val(v) ? "NA" : yrname(v) for v in x.cols[yc]]
    elseif x isa RVector
        vals = _num_vec(x.values)
        x.names !== nothing && (nms = copy(x.names))
    elseif x isa AbstractDict || x isa NamedTuple || x isa AbstractVector{<:Pair}
        ps = x isa AbstractVector{<:Pair} ? [p.first => p.second for p in x] : collect(pairs(x))
        if !isempty(ps) && all(p -> _is_num(p.second), ps)
            vals = Float64[Float64(p.second) for p in ps]
            nms = [yrname(p.first) for p in ps]
        end
    else
        vals = _num_vec(x)
        vals !== nothing && isempty(vals) && (vals = nothing)
    end
    if vals === nothing || x isa AbstractMatrix
        shown = r_format(x isa Union{AbstractVector,Tuple} ? collect(Any, x) : x)
        error("simulation: taxable_income muss $form sein, nicht $(join(first(shown, 3), ", ")).")
    end
    for (i, v) in enumerate(vals)
        isfinite(v) || error("simulation: taxable_income enthält einen ungültigen Wert ($(r_format1(v))" *
                             (nms !== nothing ? " für $(nms[i])" : "") * "); erwartet werden endliche Beträge in EUR.")
    end
    length(vals) == 1 && nms === nothing && return (all = vals[1], by_year = nothing)
    if nms === nothing || any(isempty, nms)
        error("simulation: taxable_income mit $(length(vals)) Werten muss nach Kalenderjahren benannt sein; erwartet wird $form.")
    end
    yy = Int[]
    for nm in nms
        t = strip(nm)
        y = occursin(r"^[-+]?\d+(\.\d*)?([eE][-+]?\d+)?$", t) ? (v = r_as_numeric(t); isfinite(v) ? Int(trunc(v)) : nothing) : nothing
        (y === nothing || string(y) != t) && error("simulation: taxable_income: Name '$nm' ist kein Kalenderjahr (erwartet z. B. \"2024\").")
        push!(yy, y)
    end
    for (i, y) in enumerate(yy)
        y in yy[1:i-1] && error("simulation: taxable_income: Jahr $y kommt mehrfach vor.")
    end
    miss = [y for y in years if !(y in yy)]
    if !isempty(miss)
        error("simulation: taxable_income fehlt für " * (length(miss) == 1 ? "Simulationsjahr" : "Simulationsjahre") * " " *
              join(miss, ", ") * " (angegeben: " * join(sort(yy), ", ") * "); je Kalenderjahr der Simulation (" *
              string(minimum(years)) * " bis " * string(maximum(years)) * ") wird ein Betrag benötigt.")
    end
    return (all = nothing, by_year = Dict{String,Float64}(string(y) => v for (y, v) in zip(yy, vals)))
end

function _tariff_base(env::TariffEnv, year::Int)
    zv = env.zve_all !== nothing ? env.zve_all : (env.zve !== nothing ? get(env.zve, string(year), NA) : NA)
    ks = get(env.ks, string(year), NA)
    isnan(ks) && (ks = 0.0)
    return (zve = zv, ks_prev = ks)
end

function _tariff_full(env::TariffEnv, x::Float64)
    e = _tariff_income_tax(env.tariff, x)
    so = _tariff_soli(env.tariff, e)
    ki = env.church_k * e
    return (est = e, soli = so, kist = ki, total = e + so + ki)
end

function _tariff_diff(env::TariffEnv, x1::Float64, x0::Float64)
    (isnan(x1) || isnan(x0)) && return (est = 0.0, soli = 0.0, kist = 0.0, total = 0.0)
    a = _tariff_full(env, x1)
    b = _tariff_full(env, x0)
    return (est = a.est - b.est, soli = a.soli - b.soli, kist = a.kist - b.kist, total = a.total - b.total)
end

function _tariff_close(R::Union{Run,Nothing}, env::TariffEnv, year::Int, g23::Float64, k_base::Float64,
                       abg_rate::Float64, details::Bool)
    b = _tariff_base(env, year)
    isnan(b.zve) && return NA
    k = _rmax(0.0, k_base)
    abg = k * abg_rate
    kabg = k * env.kapest_rate * env.church_k
    gp_on = env.use_gp && k > 0
    B0 = b.zve - b.ks_prev
    B1 = B0 - kabg
    X0 = _tariff_diff(env, B0 + g23, b.zve).total + abg
    X1 = gp_on ? _tariff_diff(env, B1 + g23 + k, b.zve).total : NA
    fav = gp_on && X1 < X0
    Bx = fav ? B1 : B0
    ded = _tariff_diff(env, Bx, b.zve)
    p23 = _tariff_diff(env, Bx + g23, Bx)
    tk = env.use_gp ? _tariff_diff(env, B1 + g23 + k, B1 + g23) : (est = NA, soli = NA, kist = NA, total = NA)
    tot = _tariff_diff(env, Bx + g23 + (fav ? k : 0.0), b.zve)
    D = (fav ? X1 : X0) - abg
    ks = tot.kist - (fav ? kabg : 0.0)
    env.ks[string(year + 1)] = ks
    paid = _rmax(0.0, b.ks_prev) + (fav ? kabg : 0.0)
    refunded = _rmax(0.0, -b.ks_prev)
    push!(env.rows, RList("year" => year, "taxable_income" => b.zve,
                          "church_tax_paid_deductible" => paid, "church_tax_refunded" => refunded,
                          "church_tax_net_deduction" => paid - refunded,
                          "taxable_income_net" => Bx, "deduction_effect" => ded.total,
                          "gain_p23" => g23, "income_tax_p23" => p23.est, "soli_p23" => p23.soli,
                          "church_tax_p23" => p23.kist, "tax_p23" => p23.total,
                          "capital_income" => k, "abgeltung_burden" => abg, "church_tax_withheld_k" => kabg,
                          "tariff_income_tax_k" => tk.est, "tariff_soli_k" => tk.soli, "tariff_church_tax_k" => tk.kist,
                          "tariff_burden" => tk.total,
                          "burden_without_gp" => X0, "burden_with_gp" => X1, "guenstiger" => fav,
                          "settlement" => D, "refund" => _rmax(0.0, -D), "church_tax_settlement_next_year" => ks))
    if details && R !== nothing
        _cat(R, r_sprintf("  Tarif %d: zvE %.2f EUR - KiSt-Sonderausgaben %.2f EUR (gezahlt %.2f, erstattet %.2f) = %.2f EUR (Wirkung %.2f EUR)\n",
                          year, b.zve, paid - refunded, paid, refunded, Bx, ded.total))
        g23 > 0 && _cat(R, r_sprintf("    § 23: Gewinn %.2f EUR -> Steuerlast ESt %.2f + Soli %.2f + KiSt %.2f = %.2f EUR\n",
                                     g23, p23.est, p23.soli, p23.kist, p23.total))
        if env.use_gp
            _cat(R, r_sprintf("    Günstigerprüfung: K %.2f EUR, Abgeltungsteuer %.2f EUR (KiSt %.2f), Tarif auf K %.2f EUR (ESt %.2f + Soli %.2f + KiSt %.2f); Belastung ohne %.2f / mit %s EUR -> %s\n",
                              k, abg, kabg, tk.total, tk.est, tk.soli, tk.kist, X0,
                              isnan(X1) ? "-" : r_sprintf("%.2f", X1), fav ? "Tarif" : "Abgeltungsteuer bleibt"))
        end
        _cat(R, r_sprintf("    Abrechnung: %s %.2f EUR; KiSt-Bescheid %+.2f EUR (Sonderausgabe %d)\n",
                          D >= 0 ? "Nachzahlung" : "Erstattung", abs(D), ks, year + 1))
    end
    return D
end

function _positive_by(sim::Sim)
    by = sim.totals.private_sale_net_ytd_by
    return Pair{Int,Float64}[p.first => _rmax(p.second, 0.0) for p in by if isfinite(p.second)]
end

function _book_tax_due!(sim::Sim, tax_due::Float64)
    by = _positive_by(sim)
    if isempty(by) || r_sum([p.second for p in by]) <= 0
        by = Pair{Int,Float64}[a => 1.0 for a in eachindex(sim.names)]
    end
    s = r_sum([p.second for p in by])
    due = Pair{Int,Float64}[p.first => tax_due * p.second / s for p in by]
    old = sim.totals.p23_due
    if !isempty(old)
        merged = copy(old)
        for (k, v) in due
            j = findfirst(p -> p.first == k, merged)
            j === nothing ? push!(merged, k => 0.0 + v) : (merged[j] = k => merged[j].second + v)
        end
        due = merged
    end
    sim.totals.p23_due = due
    return nothing
end

function _tariff_book!(sim::Sim, env::TariffEnv, D::Float64)
    (isnan(D) || D == 0) && return nothing
    sim.totals.total_taxes = sim.totals.total_taxes + D
    if D > 0
        rw = env.rows[end]
        by = _positive_by(sim)
        push!(env.due_info, (year = rw["year"], D = D, p23 = rw["tax_p23"], ded = rw["deduction_effect"],
                             by_p23 = !isempty(by) && r_sum([p.second for p in by]) > 0))
        _book_tax_due!(sim, D)
    else
        env.refund_due = env.refund_due - D
        abs(sim.totals.total_taxes) < 1e-9 && (sim.totals.total_taxes = 0.0)
    end
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# Jahreswechsel (handle_year_change)
# ═══════════════════════════════════════════════════════════════════════════

function _handle_year_change!(R::Run, sim::Sim, current_date::Int, tariff_env::Union{Nothing,TariffEnv}, details::Bool)
    cfg = R.cfg
    marginal_tax_rate = cfg.marginal_tax_rate
    private_sale_threshold = cfg.private_sale_threshold
    use_spb = cfg.use_sparer_pauschbetrag
    soli_factor_income = cfg.soli_factor_income
    effective_tax_rate = cfg.effective_tax_rate
    church_factor = cfg.church_k
    totals = sim.totals
    current_year = year_of(current_date)
    stored_year = totals.current_year
    current_year == stored_year && return nothing
    cat_(s) = details && _cat(R, s)
    if details
        cat_("\n" * _DOUBLE_LINE * "\n")
        cat_("  JAHRESWECHSEL: $stored_year -> $current_year\n")
        cat_(_DOUBLE_LINE * "\n")
    end
    ytd_gains = totals.private_sale_gains_ytd
    ytd_losses = totals.private_sale_losses_ytd
    net_saldo = ytd_gains - ytd_losses
    internal_offset = _rmin(ytd_gains, ytd_losses)
    net_ytd_losses = _rmax(0.0, -net_saldo)
    carryforward_offset = 0.0
    net_gain = 0.0
    if net_saldo >= private_sale_threshold && net_saldo > 0
        carryforward_offset = _rmin(net_saldo, totals.loss_private_sales)
        totals.loss_private_sales = totals.loss_private_sales - carryforward_offset
        net_gain = net_saldo - carryforward_offset
        if details && carryforward_offset > 0
            cat_(r_sprintf("  § 23 EStG: Verlustvortrag verwendet: %.2f EUR\n", carryforward_offset))
            cat_(r_sprintf("             Verbleibender Vortrag: %.2f EUR\n", totals.loss_private_sales))
        end
    end
    if details
        cat_("  § 23 EStG Jahresübersicht $stored_year:\n")
        cat_(r_sprintf("    Bruttogewinne (< 1 Jahr):    %10.2f EUR\n", ytd_gains))
        cat_(r_sprintf("    Bruttoverluste (< 1 Jahr):   %10.2f EUR\n", ytd_losses))
        cat_(r_sprintf("    Interne Verrechnung:         %10.2f EUR\n", internal_offset))
        cat_(r_sprintf("    Verlustvortrag-Verrechnung:  %10.2f EUR\n", carryforward_offset))
        cat_("    " * "─"^41 * "\n")
        cat_(r_sprintf("    Netto-Ergebnis:              %10.2f EUR\n", net_saldo - carryforward_offset))
    end
    if net_gain > 0
        tax_due = 0.0
        if tariff_env === nothing
            if marginal_tax_rate === nothing
                @warn r_sprintf("simulation: Paragraf 23 EStG: Gewinne (%.2f EUR) erreichen die Freigrenze (%.2f EUR), ",
                                net_saldo, private_sale_threshold) *
                      "aber 'marginal_tax_rate' ist nicht gesetzt.\n" *
                      "Verwendet wird 42 % (Spitzensteuersatz); marginal_tax_rate in Prozent angeben (z. B. 42)."
                marginal_tax_rate = 0.42
            end
            tax_due = net_gain * marginal_tax_rate * (soli_factor_income + church_factor)
            totals.total_taxes = totals.total_taxes + tax_due
            _book_tax_due!(sim, tax_due)
        end
        if details
            cat_("\n  ⚠ FREIGRENZE ERREICHT!\n")
            cat_(r_sprintf("    Jahressaldo %.2f EUR >= Freigrenze %.2f EUR\n", net_saldo, private_sale_threshold))
            cat_(r_sprintf("    → GESAMTER Gewinn nach Verlustvortrag steuerpflichtig: %.2f EUR (Freigrenze, kein Freibetrag!)\n", net_gain))
            if tariff_env !== nothing
                cat_("    → Steuer nach dem Einkommensteuertarif (ESt + Soli + KiSt des § 23-Zuwachses): siehe Jahresveranlagung unten (Zeile § 23)\n")
            else
                cat_(r_sprintf("    → Steuersatz: %.1f%%%s%s\n", marginal_tax_rate * 100,
                               soli_factor_income > 1 ? r_sprintf(" + %.1f%%%% Soli", (soli_factor_income - 1) * 100) : "",
                               church_factor > 0 ? r_sprintf(" + %.1f%% KiSt", church_factor * 100) : ""))
                cat_(r_sprintf("    → Steuerlast: %.2f EUR\n", tax_due))
            end
        end
    elseif net_ytd_losses > 0
        totals.loss_private_sales = totals.loss_private_sales + net_ytd_losses
        if details
            cat_(r_sprintf("\n  Nettoverlust %.2f EUR → Vortrag ins nächste Jahr\n", net_ytd_losses))
            cat_(r_sprintf("  Gesamter Verlustvortrag: %.2f EUR\n", totals.loss_private_sales))
        end
    elseif 0 < net_saldo < private_sale_threshold
        details && cat_(r_sprintf("\n  ✓ Jahressaldo %.2f EUR < Freigrenze %.2f EUR → STEUERFREI (Verlustvortrag unverändert)\n",
                                  net_saldo, private_sale_threshold))
    else
        details && cat_("\n  Keine steuerpflichtigen § 23 Vorgänge in $stored_year\n")
    end
    if details && use_spb
        spb_annual = totals.sparer_pauschbetrag_annual
        spb_remaining = totals.sparer_pauschbetrag_remaining
        cat_("\n  Sparerpauschbetrag $stored_year:\n")
        cat_(r_sprintf("    Jahresbetrag:    %10.2f EUR\n", spb_annual))
        cat_(r_sprintf("    Verwendet:       %10.2f EUR\n", spb_annual - spb_remaining))
        cat_(r_sprintf("    Verfallen:       %10.2f EUR\n", spb_remaining))
    end
    cgt_loss_added = totals.cgt_loss_added_ytd
    cgt_loss_used = totals.cgt_loss_used_ytd
    cgt_base_taxed = totals.cgt_base_taxed_ytd
    carry_start = totals.cgt_pool_start_ytd
    carry_used = 0.0
    if carry_start > 0
        spb_used_ytd = use_spb ? _rmax(0.0, totals.sparer_pauschbetrag_annual - totals.sparer_pauschbetrag_remaining) : 0.0
        carry_used = _rmin(carry_start, _rmax(0.0, cgt_loss_used + spb_used_ytd + cgt_base_taxed - cgt_loss_added))
    end
    unused_loss = _rmax(0.0, cgt_loss_added - (cgt_loss_used - carry_used))
    unused_loss = _rmin(unused_loss, totals.loss_capital_gains)
    refund_base = _rmin(unused_loss, cgt_base_taxed)
    refund_done = refund_base > 0 && effective_tax_rate > 0
    if refund_done
        refund = refund_base * effective_tax_rate
        na = length(sim.names)
        w = Float64[sim.status[a].actual for a in 1:na]
        sw = r_sum(w)
        w = sw > 0 ? w ./ sw : fill(1 / na, na)
        for a in 1:na
            sim.status[a].money = sim.status[a].money + refund * w[a]
        end
        totals.total_taxes = totals.total_taxes - refund
        totals.loss_capital_gains = totals.loss_capital_gains - refund_base
        details && cat_(r_sprintf("  § 20 EStG: Unterjährige Verlustverrechnung -> Erstattung %.2f EUR in den Geldbestand\n", refund))
    end
    if use_spb
        spb_used_year = _rmax(0.0, totals.sparer_pauschbetrag_annual - totals.sparer_pauschbetrag_remaining)
        taxed_left = cgt_base_taxed - (refund_done ? refund_base : 0.0)
        release = _rmax(0.0, _rmin(spb_used_year, totals.loss_capital_gains - taxed_left))
        if release > 0
            totals.loss_capital_gains = totals.loss_capital_gains - release
            totals.sparer_pauschbetrag_remaining = totals.sparer_pauschbetrag_remaining + release
            totals.sparer_pauschbetrag_used_total = totals.sparer_pauschbetrag_used_total - release
            details && cat_(r_sprintf("  § 20 EStG: Verlust gibt Sparer-Pauschbetrag frei: %.2f EUR (genutzt %d: %.2f EUR, Verlusttopf %.2f EUR)\n",
                                      release, stored_year, spb_used_year - release, totals.loss_capital_gains))
        end
    end
    any_refund = refund_done
    if tariff_env !== nothing
        k_base = _rmax(0.0, cgt_base_taxed - (refund_done ? refund_base : 0.0))
        D = _tariff_close(R, tariff_env, stored_year, net_gain, k_base, effective_tax_rate, details)
        _tariff_book!(sim, tariff_env, D)
        (!isnan(D) && D < 0) && (any_refund = true)
    end
    any_refund && abs(totals.total_taxes) < 1e-9 && (totals.total_taxes = 0.0)
    totals.private_sale_gains_ytd = 0.0
    totals.private_sale_losses_ytd = 0.0
    by = totals.private_sale_net_ytd_by
    for j in eachindex(by)
        by[j] = by[j].first => 0.0
    end
    totals.cgt_base_taxed_ytd = 0.0
    totals.cgt_loss_added_ytd = 0.0
    totals.cgt_loss_used_ytd = 0.0
    totals.cgt_pool_start_ytd = totals.loss_capital_gains
    use_spb && (totals.sparer_pauschbetrag_remaining = cfg.sparer_pauschbetrag)
    totals.current_year = current_year
    if details
        cat_("\n  Tracker zurückgesetzt für Jahr $current_year\n")
        cat_(_DOUBLE_LINE * "\n\n")
    end
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# Kennzahlen
# ═══════════════════════════════════════════════════════════════════════════

"`.xirr_rate()`: interner Zinsfuß p. a. (Brent über u = T log(1 + r))."
function xirr_rate(t::AbstractVector, amount::AbstractVector, end_value::Real, horizon::Real)
    t = collect(Float64, t); amount = collect(Float64, amount)
    end_value = Float64(end_value); horizon = Float64(horizon)
    keep = [isfinite(a) && a != 0 for a in amount]
    t = t[keep]; amount = amount[keep]
    (isempty(amount) || !(horizon > 0) || !isfinite(end_value)) && return NA
    end_value == 0 && all(>=(0), amount) && return -1.0
    e = (horizon .- t) ./ horizon
    g(u) = r_sum(amount[i] * _libm_exp(u * e[i]) for i in eachindex(e)) - end_value
    grid = [-200.0 + 5.0 * i for i in 0:80]
    gv = [g(u) for u in grid]
    k = nothing
    for i in 1:80
        if gv[i+1] * gv[i] <= 0
            k = i; break
        end
    end
    local br, fb
    if k !== nothing
        br = (grid[k], grid[k+1]); fb = (gv[k], gv[k+1])
    else
        (!(gv[1] > 0) || !any(>(0), e)) && return NA
        lo_lim = -800 / minimum(x for x in e if x > 0)
        hi = grid[1]; ghi = gv[1]; lo = hi; glo = ghi
        while glo > 0 && lo > lo_lim
            hi = lo; ghi = glo
            lo = _rmax(2 * lo, lo_lim)
            glo = g(lo)
        end
        glo > 0 && return NA
        br = (lo, hi); fb = (glo, ghi)
    end
    u = r_uniroot(g, br; f_lower = fb[1], f_upper = fb[2], tol = 1e-14, maxiter = 1000).root
    return _libm_expm1(u / horizon)
end

"Stichproben-Schiefe wie `calculate_skewness(x, na.rm = TRUE)`."
function calculate_skewness(x::AbstractVector; na_rm::Bool = true)
    a = collect(Float64, x)
    na_rm && (a = _dropnan(a))
    n = length(a)
    n < 3 && return NA
    mean_x = r_mean(a)
    sd_x = r_sd(a)
    sd_x == 0 && return NA
    return (n / ((n - 1.0) * (n - 2.0))) * r_sum(r_pow(v - mean_x, 3.0) for v in a) / r_pow(sd_x, 3.0)
end

"Stichproben-Kurtosis wie `calculate_kurtosis(x, na.rm = TRUE, excess = TRUE)`."
function calculate_kurtosis(x::AbstractVector; na_rm::Bool = true, excess::Bool = true)
    a = collect(Float64, x)
    na_rm && (a = _dropnan(a))
    n = length(a)
    n < 4 && return NA
    mean_x = r_mean(a)
    sd_x = r_sd(a)
    sd_x == 0 && return NA
    nf = Float64(n)
    kurt = (nf * (nf + 1)) / ((nf - 1) * (nf - 2) * (nf - 3)) * r_sum(r_pow(v - mean_x, 4.0) for v in a) / r_pow(sd_x, 4.0)
    excess && (kurt = kurt - (3 * r_pow(nf - 1, 2.0)) / ((nf - 2) * (nf - 3)))
    return kurt
end

"`calculate_partials(returns, exp = 1, type = c(\"lower\", \"higher\"))`: mittleres Partialmoment."
function calculate_partials(returns::AbstractVector; exp::Real = 1, type::AbstractString = "lower")
    v = Float64[isnan(r) ? r : r_pow(type == "lower" ? r_max2(0.0, -r) : r_max2(0.0, r), Float64(exp)) for r in returns]
    return r_mean(v; na_rm = true)
end

"`calculate_dates_flags()`: logischer Vektor der Termine (Sparplan, Rebalancing) zu `dates`."
function calculate_dates_flags(mode, span, unit, days, dates; value = nothing, anchor = ("start", "end"),
                               start_date = nothing, skip_start = false, liquidate = false)
    d = Int[x isa Date ? to_days(x) : Int(x) for x in dates]
    return _calculate_dates_flags(mode, span, unit, days, d, value, anchor, start_date, skip_start, liquidate)
end

include("sim_phases.jl")
include("sim_loop.jl")
include("sim_evaluate.jl")
