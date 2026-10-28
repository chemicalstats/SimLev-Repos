# Rauchprobe der C-Bibliothek slc (Etappe 9.1): läuft immer, auch ohne SIMLEV_LEGACY_TESTS.
# Gegenstück zu python/tests/test_etappe9_slc.py und r/tests/etappe9-smoke.R.
using SimLev
using Test
using Logging

const L9 = SimLev.SLib

@testset "slc: Laden und simlev_seed" begin
    @test simlev_seed(1) == 1
    @test L9.version() == "0.1.0"
    simlev_seed(42)
    # Zustand = erste vier Ausgaben von SplitMix64(42) (= java.util.SplittableRandom(42))
    @test L9.state_hex() == ["bdd732262feb6e95", "28efe333b266f103", "47526757130f9f52", "581ce1ff0e4ae394"]
    @test L9.u64(2) == ["15780b2e0c2ec716", "6104d9866d113a7e"]
    for (bad, txt) in ((1.5, "1.5"), ("a", "\"a\""), (true, "true"), (2^53, "9007199254740992"))
        @test_throws ErrorException("seed: ganze Zahl erwartet (erhalten: $txt)") simlev_seed(bad)
    end
end

@testset "slc: Ströme und Reproduzierbarkeit" begin
    simlev_seed(7); a = L9.runif(5)
    simlev_seed(7); @test L9.runif(5) == a
    s = L9.Stream(7); @test L9.runif(5; stream = s) == a
    u = L9.streams(L9.Stream(7), 3)
    @test length(unique(L9.state_hex.(u))) == 3
    @test all(0 .< L9.runif(1000; stream = u[1]) .< 1)
    @test_throws ErrorException("interner Fehler: globaler Zufallszustand in paralleler Einheit") L9.in_unit(() -> L9.runif(1))
end

@testset "slc: Verteilungen und Meldungen" begin
    @test L9.qnorm(0.975) ≈ 1.959963984540054 rtol = 1e-15
    @test L9.pnorm(-38.0) > 0
    @test L9.lgamma(0.5) ≈ 0.5723649429247001 rtol = 1e-15
    @test L9.pt(2.0, 5.0) ≈ 0.9490302605850709 rtol = 1e-14
    @test L9.qt(0.975, 10.0) ≈ 2.228138851986274 rtol = 1e-14
    @test L9.pbeta(0.3, 2.0, 3.0) ≈ 0.3483 rtol = 1e-12
    r = @test_logs (:warn, "qnorm: NaN erzeugt") L9.qnorm([2.0, 0.5])
    @test isnan(r[1]) && r[2] == 0.0
    @test_throws ErrorException("sample: Stichprobe größer als die Grundgesamtheit (replace = FALSE)") L9.sample(3, 5)
    na = reinterpret(Float64, 0x7FF00000000007A2)
    @test reinterpret(UInt64, L9.pnorm([na])[1]) == 0x7FF00000000007A2     # NA bleibt NA
end
