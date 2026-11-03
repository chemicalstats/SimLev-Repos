# ─────────────────────────────────────────────────────────────────────────────
# Simulationszustand und Rechenkerne
#
# Zustand der Simulation (Lots, Verkäufe, Status, Markt, Report, Töpfe); die Tagesengine rechnet
# im gemeinsamen C++-Kern core/engine_core_impl.h (sim_engine.jl). Assets werden über ihren Index
# (Reihenfolge der Strategie) angesprochen.
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


# Die Tagesengine rechnet im gemeinsamen Kern core/engine_core_impl.h (sim_engine.jl, flache
# Eingabe); die früheren Engine-Kerne simulation_core_impl.h, fifo_core_impl.h und tax_core_impl.h, die über
# die C-ABI-Hülle direkt auf diesen Strukturen rechneten (Feldlagen geprüft), sind seit 1.4.0 entfallen.

"Bereichsprüfung eines 1-basierten Index (Hüllen der Kerne)."
@inline _need(i::Int, n::Int) = (1 <= i <= n) || throw(BoundsError(1:n, i))

