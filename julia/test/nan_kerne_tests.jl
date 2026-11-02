# Julia-Ports in NaN-Randfällen bitgleich zu R (Etappe 8.0)
#
# Feste Randfälle mit NA, NaN, Division durch 0 und NaN-Vorzeichen für die Kerne, deren
# Julia-Port vor Etappe 8.0 in Zufallsvergleichen gegen R im NaN-Bitmuster abwich
# (cdar, hmm, dcc, garch_filter, rolling_vol, Engine-Kerne, boot_wild, boot_garch,
# boot_ms_garch, rtruncnorm). Erwartete Werte aus R 4.3.3 mit SimLev als Bitmuster
# (dieselben Fälle wie python/tests/test_reine_kerne_nan.py). N10: Engine-Fälle mit der Regel NA vor NaN
# (core/simlev_core.h); R, Python und Julia liefern seit N10 dieselben Bitmuster (geändert: sell_report,
# market_update_batch, fifo_price, private_sale_tax, p20_tax, vp_tax); die Engine-Fälle sind mit E17 Stufe 1c
# entfallen (Kerne entfernt, Prüfung über tools/gleichlauf/sim_fuzz.R).

const _NA = SimLev.NA
const _NAN = NaN
_hx(v) = UInt64[reinterpret(UInt64, Float64(x)) for x in vec(collect(v))]


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
