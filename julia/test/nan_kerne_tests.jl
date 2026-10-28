# Julia-Ports in NaN-Randfällen bitgleich zu R (Etappe 8.0)
#
# Feste Randfälle mit NA, NaN, Division durch 0 und NaN-Vorzeichen für die Kerne, deren
# Julia-Port vor Etappe 8.0 in Zufallsvergleichen gegen R im NaN-Bitmuster abwich
# (cdar, hmm, dcc, garch_filter, rolling_vol, Engine-Kerne, boot_wild, boot_garch,
# boot_ms_garch, rtruncnorm). Erwartete Werte aus R 4.3.3 mit SimLev als Bitmuster
# (dieselben Fälle wie python/tests/test_reine_kerne_nan.py).

const _NA = SimLev.NA
const _NAN = NaN
_hx(v) = UInt64[reinterpret(UInt64, Float64(x)) for x in vec(collect(v))]

function _jsim()
    S = SimLev
    sig = S.Signal(false, Float64[])
    st = [S.Status(_NAN, 1.0, _NA, _NAN, 0.0, 0.0, 0.5, 0.5), S.Status(2.0, _NA, _NAN, _NA, 1.0, 0.0, 0.5, 0.5)]
    mk = [S.Market(collect(16000:16002), Float64[], [_NA, 2.0, _NAN], sig, sig, 0.0),
          S.Market(collect(16000:16002), Float64[], [_NAN, _NA, 3.0], sig, sig, 0.0)]
    tr = [S.Trades(S.Lot[], S.SellEntry[], S.TaxEntry[], 1) for _ in 1:2]
    rp = [S.Report(zeros(3), zeros(3), zeros(3), zeros(3), zeros(3)) for _ in 1:2]
    tot = S.Totals(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0, 0.0, 0.0, 0.0, S.VPPending[], Pair{Int,Float64}[],
                   Pair{Int,Float64}[])
    S.Sim(["a", "b"], [S.AssetInfo("", "", 0, "none", 0.0, nothing) for _ in 1:2], st, mk, tr, rp, tot)
end

function _jeng(f!)
    sim = _jsim()
    f!(sim)
    out = Pair{String,Vector{UInt64}}[]
    for (a, nm) in enumerate(sim.names), f in (:count, :price, :worth, :money, :total, :differ)
        push!(out, "/sim/status/$nm/$f" => _hx([getfield(sim.status[a], f)]))
    end
    for (a, nm) in enumerate(sim.names), f in (:worth, :money, :flows, :total, :share)
        push!(out, "/sim/report/$nm/$f" => _hx(getfield(sim.report[a], f)))
    end
    out
end

_jlots() = [SimLev.Lot(16000, 3.0, _NA, 2.0, 3.0, 0.0), SimLev.Lot(16100, 1.0, _NAN, 1.0, 1.0, 0.0),
            SimLev.Lot(18321, 2.0, 5.0, 2.0, 2.0, 0.5)]
_nt(prefix, r) = [prefix * String(k) => _hx([v]) for (k, v) in pairs(r)]
function _jtax(f, x, bonus, usedtot)
    T = SimLev.Totals(_NA, 0.0, 0.0, 0.0, 0.0, 0.0, 100.0, usedtot, 0, _NA, 0.0, _NAN, 0.0, SimLev.VPPending[],
                      Pair{Int,Float64}[], Pair{Int,Float64}[])
    r = f(x, bonus, T, 0.26375, true)
    vcat(_nt("/res/", r), ["/totals/$k" => _hx([getfield(T, Symbol(k))]) for k in
         ("loss_capital_gains", "cgt_loss_added_ytd", "cgt_loss_used_ytd", "cgt_base_taxed_ytd",
          "sparer_pauschbetrag_remaining", "sparer_pauschbetrag_used_total", "total_taxes")])
end
function _jrng(seed, f, args...)
    SimLev.RRng.set_seed(seed)
    r = f(args...)
    u = SimLev.RRng.runif(1)
    r isa SimLev.RList ? ["//ret" => _hx(r["ret"]), "/" => _hx(u)] : ["/" => _hx(r), "/" => _hx(u)]
end
const _ZB = [0.5, _NA, -1.2, _NAN, 0.3, 1.1]
const _ZC = reshape([0.1, _NAN, _NA, -0.4, 0.2, 0.0], 6, 1)
const _PQ = [5e-324, 1e-320, 2.5e-318, 1e-317, 2.0e-317, 2.4e-317]

const CASES = Dict{String,Function}(
    "cvar_T0" => () -> ["" => _hx(SimLev.OptimizeCore.min_cvar_core(zeros(0, 2), 0.05, [0, 0], [1, 1], [0.5, 0.5], 0.01, [0.01], 5))],
    "cdar_nan" => () -> ["" => _hx(SimLev.OptimizeCore.min_cdar_core([0.01 0.02; _NA _NA; -0.02 0.0; _NAN 0.01; 0.03 -0.03;
                                                                      0.01 _NAN], 0.2, [0, 0], [1, 1], 15))],
    "hmm_nan" => function ()
        r = SimLev.DependenceCore.hmm_forward_backward([0.5 0.3; 0.0 0.0; _NA _NAN; 0.2 0.4], [0.9 0.1; 0.2 0.8], [0.6, 0.4])
        ["/$k" => _hx(r[k]) for k in ("filtered", "smoothed", "xi", "scale")]
    end,
    "dcc_nan" => function ()
        r = SimLev.DependenceCore.dcc_filter([0.5 0.8; _NA _NAN; 1.2 0.1; -0.3 -1.0; _NAN _NA], 0.05, 0.9, [1 0.3; 0.3 1], true)
        ["/nll" => _hx([r["nll"]]), "/R" => _hx(r["R"])]
    end,
    "garch_filter_nan" => () -> ["" => _hx(SimLev.BootstrapCore.garch_filter([0.01, _NA, -0.02, _NAN, 0.005, _NA, _NAN],
                                                                              1e-6, 0.05, 0.9, 0.1, 1e-4))],
    "dca" => () -> _jeng(s -> SimLev.dca_flows_allocation!(s, 1, _NA, 1)),
    "buy_report" => () -> _jeng(s -> SimLev.calculate_buy_report!(s, 2, 2, _NA, _NAN, _NA)),
    "sell_report" => () -> _jeng(s -> SimLev.calculate_sell_report!(s, 2, 2, _NAN, _NA, _NAN, 1.0)),
    "total_report" => () -> _jeng(s -> SimLev.calculate_total_report!(s, 2)),
    "market_update" => () -> _jeng(s -> SimLev.perform_market_update!(s, 3)),
    "market_update_batch" => () -> _jeng(s -> SimLev.batch_market_update!(s, 1, 3, Float64[])),
    "fifo_price" => () -> ["/res" => _hx([SimLev._calculate_fifo_price(_jlots(), 4.0, 1)])],
    "private_sale_tax" => () -> _nt("/res/", SimLev._calculate_private_sale_tax(_jlots(), 1, 5.0, _NAN, 18700)),
    "sell_count_tp0" => () -> _nt("/res/", SimLev.sell_count(_jlots(), 1, 10.0, 0.0, 5.0, false, 2, 0.0, 0.0, 0.25)),
    "sell_count_nan" => () -> _nt("/res/", SimLev.sell_count(_jlots(), 3, _NAN, 2.0, 5.0, false, 1, 0.3, 0.0, 0.25)),
    "p20_tax" => () -> _jtax(SimLev.p20_tax!, _NA, 0.0, _NAN),
    "vp_tax" => () -> _jtax(SimLev.vp_tax!, _NAN, 0.3, _NA),
    "boot_wild" => () -> _jrng(7, SimLev.BootstrapCore.boot_wild, [1.01 0.99; _NA 1.02; _NAN _NAN; 1.0 _NA; 0.98 1.01], 2),
    "boot_garch" => () -> _jrng(11, SimLev.BootstrapCore.boot_garch, 12, 0, 2, 0.0003, 2e-6, 0.08, 0.9, 0.05, 1e-4, _ZB,
                                [1, 2, 3, 4, 5, 6], [1], [0.0002], [1e-6], [0.05], [0.9], [true], [1e-4], _ZC),
    "boot_ms_garch" => () -> _jrng(13, SimLev.BootstrapCore.boot_ms_garch, 12, 0, 2, 2, [0.0003, -0.0002], [2e-6, 5e-6],
                                   [0.05, 0.1], [0.9, 0.85], [0.05, 0.0], [0.1, 0.0], [0.05, 0.0], [0.95 0.05; 0.1 0.9],
                                   [0.0 0.5; 0.3 0.0], [1e-4, 2e-4], [0.6, 0.4], [[1, 2, 3], [4, 5, 6]], _ZB, [1], [0.0002],
                                   [1e-6], [0.05], [0.9], [false], [1e-4], _ZC),
    "truncnorm" => () -> _jrng(5, SimLev.RTruncnorm.rtruncnorm, 8.0, [-1.0, -Inf, 0.5, -2.0, 1.0, -Inf, -1.0, 2.0],
                               [1.0, 0.5, Inf, -1.0, 3.0, -0.2, 0.0, 2.5], [_NA, _NAN, _NA, 0.0, _NAN, _NA, 0.0, _NAN],
                               [_NAN, _NA, _NAN, _NA, _NA, _NAN, _NA, _NA]),
    "qnorm_tief" => () -> ["" => _hx([SimLev.RNmath.qnorm5(p, 0.0, 1.0, true, false) for p in _PQ])],
)

# R 4.3.3 / SimLev (erzeugt mit scratchpad/e80y/tgen/gen.py)
const EXPECTED = Dict{String,Vector{Pair{String,Vector{UInt64}}}}(
    "cvar_T0" => [
        "" => UInt64[0x0, 0x0],
    ],
    "cdar_nan" => [
        "" => UInt64[0x3fe0000000000000, 0x3fe0000000000000],
    ],
    "hmm_nan" => [
        "/filtered" => UInt64[0x3fe6db6db6db6db7, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000, 0x3fd2492492492492, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000],
        "/smoothed" => UInt64[0x7ff80000000007a2, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000, 0x7ff80000000007a2, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000],
        "/xi" => UInt64[0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000],
        "/scale" => UInt64[0x3fdae147ae147ae1, 0x0, 0xfff8000000000000, 0xfff8000000000000],
    ],
    "dcc_nan" => [
        "/nll" => UInt64[0x7ff80000000007a2],
        "/R" => UInt64[0x3fd3333333333333, 0x3fd41401a8034ed1, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2],
    ],
    "garch_filter_nan" => [
        "" => UInt64[0x3f1a36e2eb1c432d, 0x3f192a737110e454, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff80000000007a2],
    ],
    "dca" => [
        "/sim/status/a/count" => UInt64[0x7ff8000000000000],
        "/sim/status/a/price" => UInt64[0x3ff0000000000000],
        "/sim/status/a/worth" => UInt64[0x7ff00000000007a2],
        "/sim/status/a/money" => UInt64[0x7ff80000000007a2],
        "/sim/status/a/total" => UInt64[0x7ff80000000007a2],
        "/sim/status/a/differ" => UInt64[0x3fe0000000000000],
        "/sim/status/b/count" => UInt64[0x4000000000000000],
        "/sim/status/b/price" => UInt64[0x7ff00000000007a2],
        "/sim/status/b/worth" => UInt64[0x7ff8000000000000],
        "/sim/status/b/money" => UInt64[0x7ff00000000007a2],
        "/sim/status/b/total" => UInt64[0x3ff0000000000000],
        "/sim/status/b/differ" => UInt64[0x3fe0000000000000],
        "/sim/report/a/worth" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/money" => UInt64[0x7ff80000000007a2, 0x0, 0x0],
        "/sim/report/a/flows" => UInt64[0x7ff00000000007a2, 0x0, 0x0],
        "/sim/report/a/total" => UInt64[0x7ff80000000007a2, 0x0, 0x0],
        "/sim/report/a/share" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/worth" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/money" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/total" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/share" => UInt64[0x0, 0x0, 0x0],
    ],
    "buy_report" => [
        "/sim/status/a/count" => UInt64[0x7ff8000000000000],
        "/sim/status/a/price" => UInt64[0x3ff0000000000000],
        "/sim/status/a/worth" => UInt64[0x7ff00000000007a2],
        "/sim/status/a/money" => UInt64[0x7ff8000000000000],
        "/sim/status/a/total" => UInt64[0x0],
        "/sim/status/a/differ" => UInt64[0x3fe0000000000000],
        "/sim/status/b/count" => UInt64[0x7ff80000000007a2],
        "/sim/status/b/price" => UInt64[0x7ff00000000007a2],
        "/sim/status/b/worth" => UInt64[0x7ff80000000007a2],
        "/sim/status/b/money" => UInt64[0x7ff80000000007a2],
        "/sim/status/b/total" => UInt64[0x7ff80000000007a2],
        "/sim/status/b/differ" => UInt64[0x3fe0000000000000],
        "/sim/report/a/worth" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/money" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/total" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/share" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/worth" => UInt64[0x0, 0x7ff80000000007a2, 0x0],
        "/sim/report/b/money" => UInt64[0x0, 0x7ff80000000007a2, 0x0],
        "/sim/report/b/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/total" => UInt64[0x0, 0x7ff80000000007a2, 0x0],
        "/sim/report/b/share" => UInt64[0x0, 0x0, 0x0],
    ],
    "sell_report" => [
        "/sim/status/a/count" => UInt64[0x7ff8000000000000],
        "/sim/status/a/price" => UInt64[0x3ff0000000000000],
        "/sim/status/a/worth" => UInt64[0x7ff00000000007a2],
        "/sim/status/a/money" => UInt64[0x7ff8000000000000],
        "/sim/status/a/total" => UInt64[0x0],
        "/sim/status/a/differ" => UInt64[0x3fe0000000000000],
        "/sim/status/b/count" => UInt64[0x7ff8000000000000],
        "/sim/status/b/price" => UInt64[0x7ff8000000000000],
        "/sim/status/b/worth" => UInt64[0x7ff8000000000000],
        "/sim/status/b/money" => UInt64[0x7ff8000000000000],
        "/sim/status/b/total" => UInt64[0x7ff8000000000000],
        "/sim/status/b/differ" => UInt64[0x3fe0000000000000],
        "/sim/report/a/worth" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/money" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/total" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/share" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/worth" => UInt64[0x0, 0x7ff8000000000000, 0x0],
        "/sim/report/b/money" => UInt64[0x0, 0x7ff8000000000000, 0x0],
        "/sim/report/b/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/total" => UInt64[0x0, 0x7ff8000000000000, 0x0],
        "/sim/report/b/share" => UInt64[0x0, 0x0, 0x0],
    ],
    "total_report" => [
        "/sim/status/a/count" => UInt64[0x7ff8000000000000],
        "/sim/status/a/price" => UInt64[0x4000000000000000],
        "/sim/status/a/worth" => UInt64[0x7ff8000000000000],
        "/sim/status/a/money" => UInt64[0x7ff8000000000000],
        "/sim/status/a/total" => UInt64[0x7ff8000000000000],
        "/sim/status/a/differ" => UInt64[0x0],
        "/sim/status/b/count" => UInt64[0x4000000000000000],
        "/sim/status/b/price" => UInt64[0x7ff00000000007a2],
        "/sim/status/b/worth" => UInt64[0x7ff80000000007a2],
        "/sim/status/b/money" => UInt64[0x7ff00000000007a2],
        "/sim/status/b/total" => UInt64[0x7ff80000000007a2],
        "/sim/status/b/differ" => UInt64[0x0],
        "/sim/report/a/worth" => UInt64[0x0, 0x7ff8000000000000, 0x0],
        "/sim/report/a/money" => UInt64[0x0, 0x7ff8000000000000, 0x0],
        "/sim/report/a/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/total" => UInt64[0x0, 0x7ff8000000000000, 0x0],
        "/sim/report/a/share" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/worth" => UInt64[0x0, 0x7ff80000000007a2, 0x0],
        "/sim/report/b/money" => UInt64[0x0, 0x7ff00000000007a2, 0x0],
        "/sim/report/b/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/total" => UInt64[0x0, 0x7ff80000000007a2, 0x0],
        "/sim/report/b/share" => UInt64[0x0, 0x0, 0x0],
    ],
    "market_update" => [
        "/sim/status/a/count" => UInt64[0x7ff8000000000000],
        "/sim/status/a/price" => UInt64[0x7ff8000000000000],
        "/sim/status/a/worth" => UInt64[0x7ff8000000000000],
        "/sim/status/a/money" => UInt64[0x7ff8000000000000],
        "/sim/status/a/total" => UInt64[0x7ff8000000000000],
        "/sim/status/a/differ" => UInt64[0x0],
        "/sim/status/b/count" => UInt64[0x4000000000000000],
        "/sim/status/b/price" => UInt64[0x4008000000000000],
        "/sim/status/b/worth" => UInt64[0x4018000000000000],
        "/sim/status/b/money" => UInt64[0x7ff00000000007a2],
        "/sim/status/b/total" => UInt64[0x7ff80000000007a2],
        "/sim/status/b/differ" => UInt64[0x0],
        "/sim/report/a/worth" => UInt64[0x0, 0x0, 0x7ff8000000000000],
        "/sim/report/a/money" => UInt64[0x0, 0x0, 0x7ff8000000000000],
        "/sim/report/a/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/total" => UInt64[0x0, 0x0, 0x7ff8000000000000],
        "/sim/report/a/share" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/worth" => UInt64[0x0, 0x0, 0x4018000000000000],
        "/sim/report/b/money" => UInt64[0x0, 0x0, 0x7ff00000000007a2],
        "/sim/report/b/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/total" => UInt64[0x0, 0x0, 0x7ff80000000007a2],
        "/sim/report/b/share" => UInt64[0x0, 0x0, 0x0],
    ],
    "market_update_batch" => [
        "/sim/status/a/count" => UInt64[0x7ff8000000000000],
        "/sim/status/a/price" => UInt64[0x7ff8000000000000],
        "/sim/status/a/worth" => UInt64[0x7ff8000000000000],
        "/sim/status/a/money" => UInt64[0x7ff8000000000000],
        "/sim/status/a/total" => UInt64[0x7ff8000000000000],
        "/sim/status/a/differ" => UInt64[0x0],
        "/sim/status/b/count" => UInt64[0x4000000000000000],
        "/sim/status/b/price" => UInt64[0x4008000000000000],
        "/sim/status/b/worth" => UInt64[0x4018000000000000],
        "/sim/status/b/money" => UInt64[0x7ff00000000007a2],
        "/sim/status/b/total" => UInt64[0x7ff80000000007a2],
        "/sim/status/b/differ" => UInt64[0x0],
        "/sim/report/a/worth" => UInt64[0x7ff80000000007a2, 0x7ff8000000000000, 0x7ff8000000000000],
        "/sim/report/a/money" => UInt64[0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000],
        "/sim/report/a/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/a/total" => UInt64[0x7ff80000000007a2, 0x7ff8000000000000, 0x7ff8000000000000],
        "/sim/report/a/share" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/worth" => UInt64[0x7ff8000000000000, 0x7ff80000000007a2, 0x4018000000000000],
        "/sim/report/b/money" => UInt64[0x7ff00000000007a2, 0x7ff00000000007a2, 0x7ff00000000007a2],
        "/sim/report/b/flows" => UInt64[0x0, 0x0, 0x0],
        "/sim/report/b/total" => UInt64[0x7ff8000000000000, 0x7ff80000000007a2, 0x7ff80000000007a2],
        "/sim/report/b/share" => UInt64[0x0, 0x0, 0x0],
    ],
    "fifo_price" => [
        "/res" => UInt64[0x7ff8000000000000],
    ],
    "private_sale_tax" => [
        "/res/exempt_gain" => UInt64[0x0],
        "/res/exempt_loss" => UInt64[0x7ff8000000000000],
        "/res/taxable_gain" => UInt64[0x0],
        "/res/taxable_loss" => UInt64[0x0],
        "/res/total_gain" => UInt64[0x7ff8000000000000],
    ],
    "sell_count_tp0" => [
        "/res/sell_count" => UInt64[0x4014000000000000],
        "/res/fifo_price" => UInt64[0x7ff80000000007a2],
    ],
    "sell_count_nan" => [
        "/res/sell_count" => UInt64[0x0],
        "/res/fifo_price" => UInt64[0x4014000000000000],
    ],
    "p20_tax" => [
        "/res/tax" => UInt64[0x7ff80000000007a2],
        "/res/spb_used" => UInt64[0x7ff80000000007a2],
        "/totals/loss_capital_gains" => UInt64[0x7ff80000000007a2],
        "/totals/cgt_loss_added_ytd" => UInt64[0x0],
        "/totals/cgt_loss_used_ytd" => UInt64[0x7ff8000000000000],
        "/totals/cgt_base_taxed_ytd" => UInt64[0x7ff80000000007a2],
        "/totals/sparer_pauschbetrag_remaining" => UInt64[0x7ff80000000007a2],
        "/totals/sparer_pauschbetrag_used_total" => UInt64[0x7ff80000000007a2],
        "/totals/total_taxes" => UInt64[0x7ff80000000007a2],
    ],
    "vp_tax" => [
        "/res/tax" => UInt64[0x0],
        "/res/spb_used" => UInt64[0x7ff8000000000000],
        "/res/taxable_amount" => UInt64[0x7ff8000000000000],
        "/totals/loss_capital_gains" => UInt64[0x7ff8000000000000],
        "/totals/cgt_loss_added_ytd" => UInt64[0x0],
        "/totals/cgt_loss_used_ytd" => UInt64[0x7ff8000000000000],
        "/totals/cgt_base_taxed_ytd" => UInt64[0x7ff80000000007a2],
        "/totals/sparer_pauschbetrag_remaining" => UInt64[0x7ff8000000000000],
        "/totals/sparer_pauschbetrag_used_total" => UInt64[0x7ff8000000000000],
        "/totals/total_taxes" => UInt64[0x7ff00000000007a2],
    ],
    "boot_wild" => [
        "/" => UInt64[0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff8000000000000, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff80000000007a2, 0x7ff8000000000000],
        "/" => UInt64[0x3fc5fbd74a800000],
    ],
    "boot_garch" => [
        "//ret" => UInt64[0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff80000000007a2, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000],
        "/" => UInt64[0x3fed07a496600000],
    ],
    "boot_ms_garch" => [
        "//ret" => UInt64[0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x3fefe26135589ea8, 0x3fefe3ac2fe77031, 0x3fefe4e599f6c85e, 0x3ff000d1b71758e2, 0x3fefe74442c14197, 0x3ff000d1b71758e2, 0x3ff006e29b7d3b37, 0x3ff006a363c3875c, 0x3ff00667f8f346f2, 0x3ff000d1b71758e2, 0x3ff005fa6690ef0e, 0x3ff005c96e0514ea],
        "/" => UInt64[0x3fb635db46000000],
    ],
    "truncnorm" => [
        "/" => UInt64[0x7ff80000000007a2, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff8000000000000, 0x7ff80000000007a2, 0x7ff8000000000000, 0x7ff8000000000000],
        "/" => UInt64[0x3fee9ba626800000],
    ],
    "qnorm_tief" => [
        "" => UInt64[0xc0433bd3f27fcd03, 0xc0432272b3016ccd, 0xc0430ff53aba0c7a, 0xc0430b4df761d462, 0xc04308f9e8a70938, 0xc043085d13ee2ed5],
    ],
)

@testset "NaN-Randfälle der Ports bitgleich zu R" begin
    for name in sort(collect(keys(CASES)))
        @test CASES[name]() == EXPECTED[name]
    end
end
