# N10: Julia-Lauf der Zufallsprüfung der Engine-Kerne (Fälle aus engine_nan_fuzz.py gen); schreibt <ordner>/jl.txt.
#   julia --project=julia tools/gleichlauf/engine_nan_fuzz.jl <ordner>
using SimLev
using SimLev: Lot, Status, Market, Signal, Trades, Report, Totals, Sim, AssetInfo, SellEntry, TaxEntry, VPPending

const S_NA = reinterpret(Float64, 0x7ff00000000007a2)
const S_qNA = reinterpret(Float64, 0x7ff80000000007a2)
const S_mNA = reinterpret(Float64, 0xfff80000000007a2)
const S_NaN = reinterpret(Float64, 0x7ff8000000000000)
const S_mNaN = reinterpret(Float64, 0xfff8000000000000)
const S_Inf = Inf
const S_mInf = -Inf
const S_m0 = -0.0

const D = ARGS[1]
include(joinpath(D, "cases.jl"))

const STATUS = (:count, :price, :worth, :money, :total, :target, :actual, :differ)
const REPORT = (:worth, :money, :flows, :total, :share)
const TOTALS = (:total_taxes, :loss_capital_gains, :sparer_pauschbetrag_remaining, :sparer_pauschbetrag_used_total,
                :cgt_base_taxed_ytd, :cgt_loss_added_ytd, :cgt_loss_used_ytd)

hx(x::Real) = string(reinterpret(UInt64, Float64(x)), base = 16, pad = 16)
function ln!(out, id, path, xs; ints = false)
    v = ints ? ["i" * string(Int(x)) for x in xs] : [hx(x) for x in xs]
    push!(out, string(id, " ", path, " ", join(v, " ")))
end

function mksim(c)
    sig = Signal(false, Float64[])
    n = length(c.names)
    mk = [Market(copy(c.days[i]), Float64[], copy(c.prices[i]), sig, sig, 0.0) for i in 1:n]
    tr = [Trades(copy(c.buys[i]), SellEntry[], TaxEntry[], c.front[i]) for i in 1:n]
    rp = [Report(map(copy, c.report[i])...) for i in 1:n]
    tot = Totals(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0, 0.0, 0.0, 0.0, VPPending[], Pair{Int,Float64}[],
                 Pair{Int,Float64}[])
    Sim(copy(c.names), [AssetInfo("", "", 0, "none", 0.0, nothing) for _ in 1:n], c.status, mk, tr, rp, tot)
end

function emit_sim!(out, id, sim)
    for (i, a) in enumerate(sim.names)
        for f in STATUS
            ln!(out, id, "status/$a/$f", [getfield(sim.status[i], f)])
        end
        for f in REPORT
            ln!(out, id, "report/$a/$f", getfield(sim.report[i], f))
        end
        t = sim.trades[i]
        ln!(out, id, "trades/$a/fifo_front", [t.fifo_front]; ints = true)
        ln!(out, id, "trades/$a/n", [length(t.buys)]; ints = true)
        for (j, l) in enumerate(t.buys)
            ln!(out, id, "trades/$a/$j", [Float64(l.date), l.count, l.price, l.remaining, l.original, l.vp])
        end
    end
end

function run()
    out = String[]
    for c in CASES
        id, k, a = c.id, c.k, c.a
        try
            if hasproperty(c, :names)
                sim = mksim(c)
                if k == "dca"
                    SimLev.dca_flows_allocation!(sim, a.name, a.flows, a.index)
                elseif k == "buy_report"
                    SimLev.calculate_buy_report!(sim, a.name, a.index, a.tc, a.tp, a.mp)
                elseif k == "sell_report"
                    SimLev.calculate_sell_report!(sim, a.name, a.index, a.tc, a.tp, a.mp, a.cgt)
                elseif k == "total_report"
                    SimLev.calculate_total_report!(sim, a.index)
                elseif k == "buy"
                    SimLev.perform_trade_buy_cpp!(sim, a.name, a.index, a.tc, a.tp, a.mp)
                elseif k == "market_update"
                    SimLev.perform_market_update!(sim, a.index)
                elseif k == "market_update_batch"
                    SimLev.batch_market_update!(sim, a.s, a.e, Float64[])
                elseif k == "fifo_consume"
                    SimLev.fifo_consume!(sim, a.name, a.tc)
                end
                emit_sim!(out, id, sim)
            elseif hasproperty(c, :totals)
                t0 = c.totals
                T = Totals(t0.total_taxes, t0.loss_capital_gains, 0.0, 0.0, 0.0, 0.0, t0.sparer_pauschbetrag_remaining,
                           t0.sparer_pauschbetrag_used_total, 0, t0.cgt_base_taxed_ytd, t0.cgt_loss_added_ytd,
                           t0.cgt_loss_used_ytd, 0.0, VPPending[], Pair{Int,Float64}[], Pair{Int,Float64}[])
                f = k == "p20_tax" ? SimLev.p20_tax! : SimLev.vp_tax!
                r = f(a.x, a.bonus, T, a.rate, a.spb)
                for (key, v) in pairs(r)
                    ln!(out, id, "res/$key", [v])
                end
                for f in TOTALS
                    ln!(out, id, "totals/$f", [getfield(T, f)])
                end
            else
                b = deepcopy(c.lots)
                if k == "fifo_price"
                    ln!(out, id, "res", [SimLev._calculate_fifo_price(b, a.units, a.front)])
                elseif k == "fifo_vp"
                    ln!(out, id, "res", [SimLev._calculate_fifo_vorabpauschale(b, a.units, a.front)])
                elseif k == "private_sale_tax"
                    r = SimLev._calculate_private_sale_tax(b, a.front, a.tc, a.sp, a.date)
                    for (key, v) in pairs(r)
                        ln!(out, id, "res/$key", [v])
                    end
                elseif k == "flat_rate"
                    r = SimLev.flat_rate(b, a.front, a.br, a.ysp, a.mp, a.soy, a.eoy)
                    ln!(out, id, "res/total_vp", [r.total_vp])
                    ln!(out, id, "res/lot_indices", r.lot_indices; ints = true)
                    ln!(out, id, "res/lot_vps", r.lot_vps)
                elseif k == "sell_count"
                    r = SimLev.sell_count(b, a.front, a.target, a.tp, a.shares, a.fractions, a.regime, a.bonus, a.pool,
                                          a.rate)
                    for (key, v) in pairs(r)
                        ln!(out, id, "res/$key", [v])
                    end
                end
            end
        catch e
            push!(out, "$id FEHLER $(typeof(e))")
        end
    end
    write(joinpath(D, "jl.txt"), join(out, "\n") * "\n")
    println("Julia: ", length(out), " Zeilen")
end
run()
