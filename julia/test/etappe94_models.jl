# Rauchprobe der Modelle der C-Bibliothek slc (Etappe 9.4): läuft immer, auch ohne
# SIMLEV_LEGACY_TESTS. Gegenstück zu r/tests/etappe94-models.R und python/tests/test_etappe9_models.py;
# die Gleichheit mit R und Python prüft tools/gleichlauf/.
using SimLev
using Test

const LM = SimLev.SLib

@testset "slc_models: GARCH, GPD, DCC, MS-GARCH, Bootstrap" begin
    s = LM.Stream(7)
    z = LM.rnorm(1500; stream = s)
    e = zeros(1500); v = 1e-4; ep = 0.0
    for t in 1:1500
        t > 1 && (v = 2e-6 + 0.08 * ep^2 + 0.9 * v)
        ep = sqrt(v) * z[t]; e[t] = 3e-4 + ep
    end
    f = LM.garch11_fit(e)
    @test f["convergence"] == 0 && abs(f["alpha"] - 0.08) < 0.05 && abs(f["beta"] - 0.9) < 0.05
    @test abs(f["loglik"] + LM.garch11_nll(e, [f["mu"], f["omega"], f["alpha"], f["beta"]])) < 1e-8
    g = LM.fit_garch11(e; gjr = true)
    @test g["method"] == "ml" && g["alpha"] + g["gamma"] >= 0   # N1: γ < 0 zulässig
    @test LM.fit_garch11(fill(1e-3, 30))["method"] == "konstant"
    @test_throws ErrorException LM.garch11_fit(e[1:9])
    x = 0.01 .* expm1.(-0.2 .* log.(LM.runif(400; stream = s))) ./ 0.2
    p = LM.gpd_fit(x)
    @test p["convergence"] == 0 && abs(p["shape"] - 0.2) < 0.15
    Z = reshape(LM.rnorm(600; stream = s), 300, 2)
    Q = [1.0 0; 0 1]; Q[1, 2] = Q[2, 1] = sum((Z[:, 1] .- sum(Z[:, 1]) / 300) .* (Z[:, 2] .- sum(Z[:, 2]) / 300)) /
        sqrt(sum((Z[:, 1] .- sum(Z[:, 1]) / 300) .^ 2) * sum((Z[:, 2] .- sum(Z[:, 2]) / 300) .^ 2))
    d = LM.dcc_fit(Z, Q)
    @test d["a"] >= 0 && d["b"] >= 0 && d["a"] + d["b"] < 0.999
    m = LM.ms_garch_fit(e[1:600], 2, "sGARCH")
    @test isfinite(m["loglik"]) && all(r -> r in (1, 2), m["regimes"])
    # N1: analytischer Gradient gegen zentrale Differenzen (Schritt 1e-5 max(|x|, 1))
    th = LM.ms_garch_starts(e[1:600], 2, "gjrGARCH"; all = true)[:, 3]
    gr = LM.ms_garch_grad(th, e[1:600], 2, "gjrGARCH")
    gn = map(eachindex(th)) do i
        h = 1e-5 * max(abs(th[i]), 1.0); a = copy(th); b = copy(th); a[i] += h; b[i] -= h
        (LM.ms_garch_nll(a, e[1:600], 2, "gjrGARCH") - LM.ms_garch_nll(b, e[1:600], 2, "gjrGARCH")) / (2h)
    end
    @test gr["value"] == LM.ms_garch_nll(th, e[1:600], 2, "gjrGARCH")
    @test maximum(abs.(gr["gradient"] .- gn)) < 1e-5 * max(maximum(abs.(gn)), 1.0)
    i1 = LM.boot_idx_stationary(300, 50, 10; stream = LM.Stream(1))
    i2 = LM.boot_idx_stationary(300, 50, 10; stream = LM.Stream(1))
    @test i1 == i2 && all(1 .<= i1 .<= 300)
    @test_throws ErrorException LM.boot_idx_block(10, 5, 20, false; stream = s)
end
