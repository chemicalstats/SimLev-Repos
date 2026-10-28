# Rauchprobe der Optimierer der C-Bibliothek slc (Etappe 9.3): läuft immer, auch ohne
# SIMLEV_LEGACY_TESTS. Gegenstück zu r/tests/etappe93-opt.R und python/tests/test_etappe9_opt.py;
# die Gleichheit mit R und Python prüft tools/gleichlauf/.
using SimLev
using Test

const LO = SimLev.SLib
fr93(x) = LO.opt_testfn(1, x)
gr93(x) = LO.opt_testfn(1, x; grad = true)[2]

@testset "slc_opt: Verfahren und direkter C-Weg" begin
    for m in ("Nelder-Mead", "BFGS", "L-BFGS-B")
        o = LO.optim([-1.2, 1.0], fr93; method = m)
        @test o["convergence"] == 0 && o["value"] < 1e-12 && maximum(abs.(o["par"] .- 1)) < 1e-5
        @test o["counts"].names == ["function", "gradient"]
        @test ismissing(o["counts"][2]) == (m == "Nelder-Mead")
        c = LO.minimize_test(1, [-1.2, 1.0]; method = m)
        @test c["par"] == o["par"] && c["value"] === o["value"] && c["evaluations"] == o["evaluations"]
    end
end

@testset "slc_opt: Gradient, Schranken, Steuerwerte" begin
    o = LO.optim([-1.2, 1.0], fr93, gr93; method = "BFGS")
    @test o["convergence"] == 0 && o["value"] < 1e-15 && o["evaluations"] == o["counts"][1]
    o = LO.optim(zeros(4), x -> LO.opt_testfn(8, x); method = "L-BFGS-B", lower = -1, upper = 1)
    @test o["convergence"] == 0 && o["par"] == [1.0, -1.0, 1.0, -1.0] && abs(o["value"] - 2.5) < 1e-14
    o = LO.optim([-1.2, 1.0], fr93; control = Dict("maxit" => 10))
    @test o["convergence"] == 1 && o["counts"][1] == 10
    o = LO.optim([1.0, 1.0], x -> 3 - (x[1] - 2)^2 - (x[2] + 1)^2; method = "BFGS", control = Dict("fnscale" => -1))
    @test abs(o["value"] - 3) < 1e-12 && maximum(abs.(o["par"] .- [2, -1])) < 1e-6
end

@testset "slc_opt: NaN, Fehler, numerischer Gradient" begin
    o = LO.optim([3.0, 3.0, 3.0], x -> LO.opt_testfn(7, x); method = "BFGS")
    @test o["convergence"] == 0 && abs(o["value"] - sum(1 .+ log.(1:3))) < 1e-10
    @test_throws ErrorException("BFGS: Zielfunktion am Startwert nicht endlich") LO.optim([1.0, 1.0], x -> NaN; method = "BFGS")
    @test_throws ErrorException("optim: Schranken nur mit L-BFGS-B bzw. PBFGS (nicht BFGS)") LO.optim([1.0, 1.0], fr93; method = "BFGS", lower = 0.0)
    @test_throws ErrorException("optim: unbekannte Steuerwerte 'abstol'") LO.optim([1.0, 1.0], fr93; control = Dict("abstol" => 1))
    x = [0.3, -0.7, 1.1]
    @test maximum(abs.(LO.numgrad_test(1, x) .- LO.opt_testfn(1, x; grad = true)[2])) < 1e-6
    @test LO.numgrad_test(8, [1.0, 2.0]; lower = [1.0, -Inf], upper = [1.0, Inf])[1] == 0.0
end
