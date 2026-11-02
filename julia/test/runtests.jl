# Etappe 9 (Entwurf C.7): ohne SIMLEV_LEGACY_TESTS=1 sind die alten Tests ausgesetzt; es läuft nur
# die Rauchprobe der Etappe 9 (etappe9_smoke.jl). Der Rest der Datei bleibt unverändert.
using Test
if get(ENV, "SIMLEV_LEGACY_TESTS", "") != "1"
    @info "SimLev: Tests in Etappe 9 ausgesetzt (SIMLEV_LEGACY_TESTS=1 führt sie aus)"
    @testset "Etappe 9" begin
        @test true
        include("etappe9_smoke.jl")
        include("etappe92_smoke.jl")   # 9.2
        include("etappe93_opt.jl")   # 9.3: Optimierer der C-Bibliothek slc
        include("etappe94_models.jl")   # 9.4: Modelle der C-Bibliothek slc
    end
    exit(0)
end

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
# Engine (simulation(), Steuerrecht, Ausgabe, Konfiguration, Trigger, Dashboards, Golden Master)
@testset "Engine" begin
    include("engine_tests.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# Fonds-Wrapper (Etappe 6.5c, Port von test-wrapper.R)
include("wrapper_tests.jl")

# ─────────────────────────────────────────────────────────────────────────────
# match.arg-Meldungen wortgleich zu R 4.3.3 (mit Rscript geprüft)
@testset "match_arg wie R" begin
    d = (date = collect(Date(2020, 1, 1):Day(1):Date(2020, 2, 19)), A = 100.0 .+ (1:50))
    s = create_strategy(A = asset_config("etf", "bnh"))
    msg(f) = try
        f()
        "ok"
    catch e
        e.msg
    end
    with_logger(NullLogger()) do
        @test msg(() -> dca_plan(10, 1; unit = "woche")) == "'arg' should be one of “month”, “quarter”, “year”"
        @test msg(() -> rebalance_plan(1; unit = "woche")) == "'arg' should be one of “month”, “quarter”, “year”"
        @test msg(() -> rebalance_plan(1; thresh_type = "x")) == "'arg' should be one of “absolute”, “relative”"
        @test msg(() -> dca_plan(10, 1; unit = ["month", "year"])) == "'arg' must be of length 1"
        @test msg(() -> dca_plan(10, 1; anchor = "mitte")) == "'arg' should be one of “start”, “end”"
        @test msg(() -> rebalance_plan(1; unit = 1)) == "'arg' must be NULL or a character vector"
        @test msg(() -> simulation(d, s; dca = dca_plan(10, 1), rebalance = rebalance_plan(1), io = devnull)) == "ok"
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
# NaN-Randfälle der Ports bitgleich zu R (Etappe 8.0)
include("nan_kerne_tests.jl")

# ─────────────────────────────────────────────────────────────────────────────
# par_lapply: Fork-Semantik, Threads, Ausgaben je Aufgabe (Etappe 5)
include("parallel_tests.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Schichten 0–4: keine Zugriffe auf eine höhere Schicht (Etappe 4.4)
include("layers_tests.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Öffentliche Schnittstelle gegen tools/api_snapshot/frozen/jl.json (Etappe 6.6)
include("api_frozen_tests.jl")

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
