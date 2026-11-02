# ─────────────────────────────────────────────────────────────────────────────
# Simulationszustand und Rechenkerne
#
# Die Engine-Kerne (core/simulation_core_impl.h, fifo_core_impl.h, tax_core_impl.h) rechnen seit N7
# als geteilte C++-Kerne wie in R und Python (C-ABI-Hülle core/simlev_cabi.cpp, CAbi); vorher
# Julia-Ports (F2). Assets werden über ihren Index (Reihenfolge der Strategie) angesprochen.
# ─────────────────────────────────────────────────────────────────────────────

"Ein Kauf-Lot (FIFO)."
mutable struct Lot
    date::Int
    count::Float64
    price::Float64
    remaining::Float64
    original::Float64
    vp::Float64          # angerechnete Vorabpauschale (§ 19 InvStG)
end

"Ein Verkauf."
struct SellEntry
    event_date::Int
    asset_count::Float64
    asset_price::Float64
    event_gain::Float64
    event_taxes::Float64
    tax_regime::Union{Nothing,String}
    tax_deferred::Bool
    holding_exempt::Float64
end

"Eine Steuerbuchung (Vorabpauschale oder § 23-Steuer)."
struct TaxEntry
    event_date::Int
    assessment_date::Int          # nur Vorabpauschale (sonst 0)
    event_type::String            # "Vorabpauschale" bzw. "Private sale tax"
    flat_rate_gross::Float64
    bonus_applied::Float64
    flat_rate_taxable::Float64
    spb_used::Float64
    taxes_paid::Float64
end

mutable struct Status
    count::Float64
    price::Float64
    worth::Float64
    money::Float64
    total::Float64
    target::Float64
    actual::Float64      # historisch: normalisiertes ZIELgewicht
    differ::Float64      # historisch: aktuelles PORTFOLIOgewicht
end

"Signalspalte: Werte als Double (NA = fehlend); `logical` = Spalte war logisch."
mutable struct Signal
    logical::Bool
    v::Vector{Float64}
end

mutable struct Market
    asset_day::Vector{Int}
    base_rates::Vector{Float64}
    asset_price::Vector{Float64}
    signal_buy::Signal
    signal_sell::Signal
    spread_rate::Float64
end

struct Report
    worth::Vector{Float64}
    money::Vector{Float64}
    flows::Vector{Float64}
    total::Vector{Float64}
    share::Vector{Float64}
end

mutable struct Trades
    buys::Vector{Lot}
    sells::Vector{SellEntry}
    taxes::Vector{TaxEntry}
    fifo_front::Int
end

struct AssetInfo
    class::String
    style::String
    start::Int
    tax_regime::String
    bonus::Float64
    deliverable::Any
end

struct VPPending
    asset::Int
    flat_rate::Float64
    bonus::Float64
    assessment_date::Int
end

mutable struct Totals
    total_taxes::Float64
    loss_capital_gains::Float64
    loss_private_sales::Float64
    private_sale_gains_ytd::Float64
    private_sale_losses_ytd::Float64
    sparer_pauschbetrag_annual::Float64
    sparer_pauschbetrag_remaining::Float64
    sparer_pauschbetrag_used_total::Float64
    current_year::Int
    cgt_base_taxed_ytd::Float64
    cgt_loss_added_ytd::Float64
    cgt_loss_used_ytd::Float64
    cgt_pool_start_ytd::Float64
    vp_pending::Vector{VPPending}                        # leer = nicht vorhanden
    p23_due::Vector{Pair{Int,Float64}}                    # leer = nicht vorhanden
    private_sale_net_ytd_by::Vector{Pair{Int,Float64}}    # § 23-Jahressaldo je Asset
end

struct Sim
    names::Vector{String}
    assets::Vector{AssetInfo}
    status::Vector{Status}
    market::Vector{Market}
    trades::Vector{Trades}
    report::Vector{Report}
    totals::Totals
end


# ═══════════════════════════════════════════════════════════════════════════
# Engine-Kerne: geteilte C++-Kerne (N7)
# ═══════════════════════════════════════════════════════════════════════════
#
# simulation_core_impl.h, fifo_core_impl.h und tax_core_impl.h rechnen über die C-ABI-Hülle
# core/simlev_cabi.cpp (CAbi, ccall) direkt auf diesem Zustand: Status, Lot, Trades und Totals sind
# veränderliche Strukturen, deren Felder die Hülle über ihre Adresse liest und schreibt (Feldlagen unten
# geprüft); Report- und Marktvektoren über ihre Datenzeiger. Ein neues Lot (Kauf) hängt Julia nach dem
# Aufruf an. Die früheren Julia-Ports (mit nan_add/nan_mul in der Operandenfolge des R-Baus) sind
# entfallen; treffen in einer Operation zwei NaN mit verschiedener Nutzlast zusammen (NA und NaN), kann
# das Ergebnis wie in Python die Nutzlast des anderen Operanden tragen (Wert NA bzw. NaN wie zuvor).

const _CA = CAbi.Asset

# Feldlagen der Strukturen wie in der Hülle (simlev_c_layout); sonst schreibt der Kern daneben
let L = CAbi.layout(), fo(T, i) = Int64(fieldoffset(T, i))
    want = Int64[sizeof(Float64) * 8,
                 fo(Lot, 6) + 8, fo(Lot, 1), fo(Lot, 2), fo(Lot, 3), fo(Lot, 4), fo(Lot, 5), fo(Lot, 6),
                 fo(Trades, 4),
                 fo(Totals, 16) + 8, fo(Totals, 9), fo(Totals, 13), fo(Totals, 14),
                 sizeof(_CA), fo(_CA, 11)]
    all(isbitstype, fieldtypes(Status)) && fieldtypes(Status) == ntuple(_ -> Float64, 8) ||
        error("SimLev: Status passt nicht zur C-Hülle")
    fieldtypes(Lot) == (Int, Float64, Float64, Float64, Float64, Float64) || error("SimLev: Lot passt nicht zur C-Hülle")
    fieldtype(Trades, 4) === Int && fieldtype(Totals, 9) === Int || error("SimLev: Trades/Totals passen nicht zur C-Hülle")
    L == want || error("SimLev: Feldlagen der C-Hülle weichen ab: $L statt $want")
end

# Zeile eines Assets; n_days = kürzester der Report- und Kursvektoren
@inline function _casset(sim::Sim, a::Int)
    st = sim.status[a]; rp = sim.report[a]; mk = sim.market[a]; tr = sim.trades[a]
    _CA(pointer_from_objref(st), pointer(rp.worth), pointer(rp.money), pointer(rp.flows), pointer(rp.total),
        pointer(rp.share), pointer(mk.asset_price), pointer(mk.asset_day), pointer_from_objref(tr),
        Ptr{Ptr{Cvoid}}(pointer(tr.buys)), length(tr.buys))
end
@inline function _ndays(sim::Sim, a::Int)
    rp = sim.report[a]; mk = sim.market[a]
    min(length(rp.worth), length(rp.money), length(rp.flows), length(rp.total), length(rp.share),
        length(mk.asset_price), length(mk.asset_day))
end
@inline _need(i::Int, n::Int) = (1 <= i <= n) || throw(BoundsError(1:n, i))

const _CA0 = _CA(C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, 0)
const _NTAB = 8   # bis zu so vielen Assets liegt die Tabelle ohne Heap-Anlage in einem Ref{NTuple}

# Tabelle aller Assets für die Kerne über alle Assets; f(Zeiger, n, n_days) innerhalb von GC.@preserve
@inline function _with_ctab(f, sim::Sim)
    n = length(sim.names)
    nd = typemax(Int)
    @inbounds for a in 1:n
        nd = min(nd, _ndays(sim, a))
    end
    nd = n == 0 ? 0 : nd
    GC.@preserve sim begin
        if n <= _NTAB
            tab = Ref(ntuple(a -> a <= n ? _casset(sim, a) : _CA0, Val(_NTAB)))
            GC.@preserve tab f(Ptr{_CA}(pointer_from_objref(tab)), n, nd)
        else
            tv = _CA[_casset(sim, a) for a in 1:n]
            GC.@preserve tv f(pointer(tv), n, nd)
        end
    end
end

_bptr(buys::Vector{Lot}) = Ptr{Ptr{Cvoid}}(pointer(buys))

function dca_flows_allocation!(sim::Sim, a::Int, flows::Float64, index::Int)
    nd = _ndays(sim, a); _need(index, nd)
    GC.@preserve sim begin
        row = Ref(_casset(sim, a))
        CAbi.check(ccall((:simlev_c_sim_dca_flows, LIBSLC), Cint, (Ref{_CA}, Int64, Int64, Int64, Float64, Int64),
                         row, 1, nd, 0, flows, index))
    end
    return nothing
end

function calculate_buy_report!(sim::Sim, a::Int, index::Int, trade_count::Float64,
                               trade_price::Float64, market_price::Float64)
    nd = _ndays(sim, a); _need(index, nd)
    GC.@preserve sim begin
        row = Ref(_casset(sim, a))
        CAbi.check(ccall((:simlev_c_sim_buy_report, LIBSLC), Cint,
                         (Ref{_CA}, Int64, Int64, Int64, Int64, Float64, Float64, Float64),
                         row, 1, nd, 0, index, trade_count, trade_price, market_price))
    end
    return nothing
end

function calculate_sell_report!(sim::Sim, a::Int, index::Int, trade_count::Float64,
                                trade_price::Float64, market_price::Float64, capital_gains_tax::Float64)
    nd = _ndays(sim, a); _need(index, nd)
    GC.@preserve sim begin
        row = Ref(_casset(sim, a))
        CAbi.check(ccall((:simlev_c_sim_sell_report, LIBSLC), Cint,
                         (Ref{_CA}, Int64, Int64, Int64, Int64, Float64, Float64, Float64, Float64),
                         row, 1, nd, 0, index, trade_count, trade_price, market_price, capital_gains_tax))
    end
    return nothing
end

function calculate_total_report!(sim::Sim, index::Int)
    _with_ctab(sim) do tab, n, nd
        n == 0 || _need(index, nd)
        CAbi.check(ccall((:simlev_c_sim_total_report, LIBSLC), Cint, (Ptr{_CA}, Int64, Int64, Int64),
                         tab, n, nd, index))
    end
    return nothing
end

function perform_trade_buy_cpp!(sim::Sim, a::Int, index::Int, trade_count::Float64,
                                trade_price::Float64, market_price::Float64)
    nd = _ndays(sim, a); _need(index, nd)
    lot = Ref{NTuple{5,Float64}}()
    GC.@preserve sim begin
        row = Ref(_casset(sim, a))
        CAbi.check(ccall((:simlev_c_sim_buy, LIBSLC), Cint,
                         (Ref{_CA}, Int64, Int64, Int64, Int64, Float64, Float64, Float64, Ref{NTuple{5,Float64}}),
                         row, 1, nd, 0, index, trade_count, trade_price, market_price, lot))
    end
    d, c, p, r, o = lot[]
    push!(sim.trades[a].buys, Lot(Int(d), c, p, r, o, 0.0))
    return nothing
end

function perform_market_update!(sim::Sim, index::Int)
    _with_ctab(sim) do tab, n, nd
        n == 0 || _need(index, nd)
        CAbi.check(ccall((:simlev_c_sim_market_update, LIBSLC), Cint, (Ptr{_CA}, Int64, Int64, Int64),
                         tab, n, nd, index))
    end
    return nothing
end

# `portfolio`: früher Arbeitsfeld des Ports (bleibt für die Aufrufer, der Kern hat sein eigenes)
function batch_market_update!(sim::Sim, start_idx::Int, end_idx::Int, portfolio::Vector{Float64})
    end_idx - start_idx + 1 <= 0 && return nothing
    _with_ctab(sim) do tab, n, nd
        n == 0 || (_need(start_idx, nd); _need(end_idx, nd))
        CAbi.check(ccall((:simlev_c_sim_market_update_batch, LIBSLC), Cint, (Ptr{_CA}, Int64, Int64, Int64, Int64),
                         tab, n, nd, start_idx, end_idx))
    end
    return nothing
end

function _calculate_fifo_price(buys::Vector{Lot}, units::Float64, front::Int)
    out = Ref(0.0)
    GC.@preserve buys CAbi.check(ccall((:simlev_c_sim_fifo_price, LIBSLC), Cint,
                                       (Ptr{Ptr{Cvoid}}, Int64, Float64, Int64, Ref{Float64}),
                                       _bptr(buys), length(buys), units, front, out))
    return out[]
end

function _calculate_fifo_vorabpauschale(buys::Vector{Lot}, units::Float64, front::Int)
    out = Ref(0.0)
    GC.@preserve buys CAbi.check(ccall((:simlev_c_sim_fifo_vp, LIBSLC), Cint,
                                       (Ptr{Ptr{Cvoid}}, Int64, Float64, Int64, Ref{Float64}),
                                       _bptr(buys), length(buys), units, front, out))
    return out[]
end

function _calculate_private_sale_tax(buys::Vector{Lot}, front::Int, trade_count::Float64,
                                    sell_price::Float64, current_date::Int)
    out = Ref{NTuple{5,Float64}}()
    GC.@preserve buys CAbi.check(ccall((:simlev_c_sim_private_sale_tax, LIBSLC), Cint,
                                       (Ptr{Ptr{Cvoid}}, Int64, Int64, Float64, Float64, Int64, Ref{NTuple{5,Float64}}),
                                       _bptr(buys), length(buys), front, trade_count, sell_price, current_date, out))
    eg, el, tg, tl, tot = out[]
    return (exempt_gain = eg, exempt_loss = el, taxable_gain = tg, taxable_loss = tl, total_gain = tot)
end

function fifo_consume!(sim::Sim, a::Int, trade_count::Float64)
    GC.@preserve sim begin
        row = Ref(_casset(sim, a))
        CAbi.check(ccall((:simlev_c_sim_fifo_consume, LIBSLC), Cint, (Ref{_CA}, Int64, Int64, Float64),
                         row, 1, 0, trade_count))
    end
    return nothing
end

function _update_fifo_front(buys::Vector{Lot}, front::Int)
    @inbounds while front <= length(buys)
        buys[front].remaining > 0 && return front
        front += 1
    end
    return front
end

"Vorabpauschale je Lot (`flat_rate_rcpp`): Bezug Jahresanfangskurs, Deckel, Zwölftelung."
function flat_rate(buys::Vector{Lot}, front::Int, base_rate::Float64, year_start_price::Float64,
                   market_price::Float64, soy::Int, eoy::Int)
    cap = max(0, length(buys) - front + 1)
    idx = Vector{Int}(undef, cap); vps = Vector{Float64}(undef, cap)
    total = Ref(0.0); nact = Ref(0)
    GC.@preserve buys CAbi.check(ccall((:simlev_c_sim_flat_rate, LIBSLC), Cint,
                                       (Ptr{Ptr{Cvoid}}, Int64, Int64, Float64, Float64, Float64, Int64, Int64,
                                        Ref{Float64}, Ptr{Int64}, Ptr{Float64}, Int64, Ref{Int64}),
                                       _bptr(buys), length(buys), front, base_rate, year_start_price, market_price,
                                       soy, eoy, total, idx, vps, cap, nact))
    resize!(idx, nact[]); resize!(vps, nact[])
    return (total_vp = total[], lot_indices = idx, lot_vps = vps)
end

function p20_tax!(trade_gain::Float64, bonus::Float64, t::Totals, tax_rate::Float64, use_spb::Bool)
    out = Ref{NTuple{2,Float64}}()
    GC.@preserve t CAbi.check(ccall((:simlev_c_sim_p20_tax, LIBSLC), Cint,
                                    (Float64, Float64, Ptr{Cvoid}, Float64, Cint, Ref{NTuple{2,Float64}}),
                                    trade_gain, bonus, pointer_from_objref(t), tax_rate, use_spb, out))
    tax, spb = out[]
    return (tax = tax, spb_used = spb)
end

function vp_tax!(flat_rate_value::Float64, bonus::Float64, t::Totals, tax_rate::Float64, use_spb::Bool)
    out = Ref{NTuple{3,Float64}}()
    GC.@preserve t CAbi.check(ccall((:simlev_c_sim_vp_tax, LIBSLC), Cint,
                                    (Float64, Float64, Ptr{Cvoid}, Float64, Cint, Ref{NTuple{3,Float64}}),
                                    flat_rate_value, bonus, pointer_from_objref(t), tax_rate, use_spb, out))
    tax, spb, ta = out[]
    return (tax = tax, spb_used = spb, taxable_amount = ta)
end

const REGIME_CODE = Dict("none" => 0, "investment_fund" => 1, "capital_gains" => 2, "private_sale" => 3)

"Verkaufsstückzahl für einen Ziel-Nettoerlös (`sell_count_rcpp`)."
function sell_count(buys::Vector{Lot}, front::Int, target::Float64, trade_price::Float64,
                    total_shares::Float64, fractions::Bool, regime::Int, bonus::Float64,
                    loss_pool::Float64, tax_rate::Float64)
    out = Ref{NTuple{2,Float64}}()
    GC.@preserve buys CAbi.check(ccall((:simlev_c_sim_sell_count, LIBSLC), Cint,
                                       (Ptr{Ptr{Cvoid}}, Int64, Int64, Float64, Float64, Float64, Cint, Int64,
                                        Float64, Float64, Float64, Ref{NTuple{2,Float64}}),
                                       _bptr(buys), length(buys), front, target, trade_price, total_shares,
                                       fractions, regime, bonus, loss_pool, tax_rate, out))
    sc, fp = out[]
    return (sell_count = sc, fifo_price = fp)
end
