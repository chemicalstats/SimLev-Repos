using SimLev
using Test
using Dates
using Random
using Logging

include("golden_tools.jl")
include("reftree.jl")
const _MODDIR = joinpath(@__DIR__, "..", "..", "golden", "modules")
const _FULL = SimLev.REnv.full_tests()
const _QUICK_PER_MODULE = 4

function _quick_pick(files)
    n = length(files)
    n <= _QUICK_PER_MODULE && return files
    idx = unique(round.(Int, range(1, n; length = _QUICK_PER_MODULE)))
    return files[idx]
end


@testset "SimLev" begin

# ─────────────────────────────────────────────────────────────────────────────
@testset "80-Bit long double (F80) gegen BigFloat" begin
    rng = MersenneTwister(1)
    gen() = (k = rand(rng, 1:4);
             k == 1 ? (rand(rng) - 0.5) * 10.0^rand(rng, -20:20) :
             k == 2 ? 1 + (rand(rng) - 0.5) * 10.0^(-rand(rng, 0:15)) :
             k == 3 ? round(100 * exp(randn(rng)); digits = rand(rng, 0:6)) : Float64(rand(rng, -50:50)))
    nbad = 0
    setprecision(BigFloat, 64) do
        for _ in 1:4000
            a = SimLev.F80(gen()); b = BigFloat(Float64(a))
            for _ in 1:12
                x = gen(); op = rand(rng, 1:4)
                fa = op == 1 ? a + SimLev.F80(x) : op == 2 ? a - SimLev.F80(x) : op == 3 ? a * SimLev.F80(x) : a / SimLev.F80(x)
                fb = op == 1 ? b + x : op == 2 ? b - x : op == 3 ? b * x : b / x
                nbad += !(Float64(fa) === Float64(fb) || (isnan(Float64(fa)) && isnan(Float64(fb))))
                a, b = fa, fb
            end
        end
    end
    @test nbad == 0
    # Zwischenergebnisse mit 64 Bit Mantisse, danach Rundung auf 53 Bit – wie die x87-FPU
    @test Float64(SimLev.F80(1.0) + SimLev.F80(2.0^-53) + SimLev.F80(2.0^-60)) == nextfloat(1.0)
    @test (1.0 + 2.0^-53) + 2.0^-60 == 1.0
    @test Float64(SimLev.F80(1.0) + SimLev.F80(2.0^-53) + SimLev.F80(2.0^-65)) == 1.0   # doppelte Rundung
end

# ─────────────────────────────────────────────────────────────────────────────
# Engine (simulation(), Steuerrecht, Ausgabe, Konfiguration, Trigger, Dashboards, Golden Master)
@testset "Engine" begin
    include("engine_tests.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# match.arg-Meldungen wortgleich zu R 4.3.3 (mit Rscript geprüft)
@testset "match_arg wie R" begin
    d = (date = collect(Date(2020, 1, 1):Day(1):Date(2020, 2, 19)), A = 100.0 .+ (1:50))
    s = create_strategy(A = asset_config("etf", "bnh"))
    msg(; kw...) = try
        simulation(d, s; dca_mode = true, dca_value = 10, dca_span = 1, balance_mode = true, balance_span = 1, io = devnull, kw...)
        "ok"
    catch e
        e.msg
    end
    with_logger(NullLogger()) do
        @test msg(dca_unit = "woche") == "'arg' should be one of “month”, “quarter”, “year”"
        @test msg(balance_unit = "woche") == "'arg' should be one of “month”, “quarter”, “year”"
        @test msg(tax_mode = "x") == "'arg' should be one of “none”, “person”, “funds”"
        @test msg(balance_thresh_type = "x") == "'arg' should be one of “absolute”, “relative”"
        @test msg(dca_unit = ["month", "year"]) == "'arg' must be of length 1"
        @test msg(dca_anchor = "mitte") == "'arg' should be one of “start”, “end”"
        @test msg(balance_unit = 1) == "'arg' must be NULL or a character vector"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Gemeinsamer R-Syntax-Auswerter (Bedingungen als Text)
include("rexpr_tests.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Öffentliche Schnittstelle: Schlüsselwortformen, Grafik-API, Eingabeformen,
# NA/NaN in Kumulationen, Plattform-Bibliotheken
include("api_tests.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Eigene MS-GARCH-Schätzung (Port von r/tests/testthat/test-ms-garch.R)
include("ms_garch_tests.jl")

# ─────────────────────────────────────────────────────────────────────────────
# par_lapply: Fork-Semantik, Threads, Ausgaben je Aufgabe (Etappe 5)
include("parallel_tests.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Schichten 0–4: keine Zugriffe auf eine höhere Schicht (Etappe 4.4)
include("layers_tests.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Referenzfälle der Module (golden/modules): standardmäßig eine schnelle
# Auswahl (je Modul bis zu `_QUICK_PER_MODULE` gleichmäßig verteilte Fälle),
# vollständig mit SIMLEV_FULL_TESTS=1.
if isdir(_MODDIR)
    @testset "Referenzfälle golden/modules$(_FULL ? "" : " (Auswahl)")" begin
        for m in sort([d for d in readdir(_MODDIR) if isdir(joinpath(_MODDIR, d))])
            files = list_ref_cases(joinpath(_MODDIR, m))
            _FULL || (files = _quick_pick(files))
            @testset "$m" begin
                for f in files
                    errs = try
                        run_ref_case(read_ref_case(joinpath(_MODDIR, m, f)))
                    catch e
                        ["Werkzeugfehler: " * sprint(showerror, e)]
                    end
                    isempty(errs) || println("FAIL $m/$f\n    ", first(join(errs, "\n"), 1500))
                    @test isempty(errs)
                end
            end
        end
    end
end

end
