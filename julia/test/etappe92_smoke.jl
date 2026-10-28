# Rauchprobe der Etappe 9.2 der C-Bibliothek slc (lineare Algebra, Matrixprodukt, kleinste Quadrate,
# Stineman, Glättungsspline, Kerndichte): läuft immer, auch ohne SIMLEV_LEGACY_TESTS. Gegenstück zu
# r/tests/etappe92-smoke.R und python/tests/test_etappe9_linalg.py; die Gleichheit der Sprachen
# prüft tools/gleichlauf/ (Modul slc_linalg).
using SimLev
using Test

const L92 = SimLev.SLib

@testset "slc 9.2: lineare Algebra" begin
    a = [4.0 2.0; 2.0 3.0]
    @test L92.chol(a) == [2.0 1.0; 0.0 sqrt(2.0)]
    @test isapprox(L92.solve_spd(a, [1.0, 2.0]), [-0.125, 0.75]; atol = 1e-15)
    @test isapprox(L92.logdet_spd(a), log(8.0); atol = 1e-15)
    e = L92.eigen_sym(a)
    @test isapprox(e["values"], [(7 + sqrt(17)) / 2, (7 - sqrt(17)) / 2]; atol = 1e-15)
    @test L92.eigen_sym(a; only_values = true)["vectors"] === nothing
    @test_throws ErrorException L92.chol([1.0 2.0; 2.0 1.0])
    x = reshape(collect(1.0:6.0), 2, 3)
    @test L92.matmul(x, permutedims(x)) == x * permutedims(x)
    @test L92.crossprod(x) == permutedims(x) * x
    @test L92.matmul([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]) == reshape([14.0], 1, 1)
end

@testset "slc 9.2: Modelle, Interpolation, Dichte" begin
    t = collect(1.0:5.0)
    f = L92.lsfit(hcat(ones(5), t, 2 .* t), [1.0, 3.0, 2.0, 5.0, 4.0])
    @test f["rank"] == 2 && f["pivot"] == Int32[1, 2, 3] && isnan(f["coefficients"][3])
    @test isapprox(f["coefficients"][1:2], [0.6, 0.8]; atol = 1e-14)
    @test L92.logit_irls(hcat(ones(6), collect(1.0:6.0)), [0.0, 0.0, 1.0, 0.0, 1.0, 1.0])["converged"]
    s = L92.stineman([1.0, 2.0, 4.0], [1.0, 3.0, 2.0], [1.0, 1.5, 4.0, 5.0])
    @test s[1] == 1.0 && s[3] == 2.0 && isnan(s[4]) && 1 < s[2] < 3
    sp = L92.smspline_fit(collect(1.0:10.0), sin.(1.0:10.0))
    @test length(sp["x"]) == 10 && 2 < sp["df"] < 10
    @test_throws ErrorException L92.smspline_fit([1.0, 2.0, 3.0, 3.0], [1.0, 2.0, 3.0, 4.0])
    k = L92.kde([-1.0, 0.0, 2.0, 3.0, 3.5])
    @test length(k["x"]) == 512 && abs(sum(k["y"]) * (k["x"][2] - k["x"][1]) - 1) < 1e-3
end
