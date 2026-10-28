# Tests der eigenen MS-GARCH-Schätzung (SimLev.MsGarch._ms_garch_fit; Kern
# SimLev.BootstrapCore.ms_garch_filter) und der Verfahren "ms_garch",
# "ms_ar_garch_m" und "tvtp_ms_garch" von bootstrap(). Port von
# r/tests/testthat/test-ms-garch.R; die Datensätze werden mit dem
# R-Zufallsgenerator (SimLev.RRng) genau wie dort simuliert.

const _MS_TRUE = (om = [2e-6, 2e-5], al = [0.02, 0.05], ga = [0.04, 0.10], be = [0.92, 0.85],
                  P = [0.99 0.01; 0.03 0.97])

"2-Regime-MS-GJR-GARCH nach Haas, Mittnik und Paolella (2004) wie `sim_ms_gjr` im R-Test."
function _sim_ms_gjr(n, om, al, ga, be, P, seed)
    RNG = SimLev.RRng
    RNG.set_seed(seed)
    K = length(om)
    hk = om ./ (1 .- al .- ga ./ 2 .- be)
    s = 1; y = zeros(n); st = zeros(Int, n)
    for t in 1:n
        if t > 1
            s = Int(RNG.sample_int(K, 1; prob = P[s, :])[1])
            e = y[t-1]
            hk = om .+ (al .+ ga .* (e < 0 ? 1.0 : 0.0)) .* (e * e) .+ be .* hk
        end
        st[t] = s
        y[t] = sqrt(hk[s]) * Float64(RNG.rnorm(1)[1])
    end
    y, st
end

@testset "MS-GARCH (eigene Schätzung)" begin
    MG = SimLev.MsGarch; C = SimLev.BootstrapCore; RNG = SimLev.RRng
    p = _MS_TRUE
    ysim, ssim = _sim_ms_gjr(3000, p.om, p.al, p.ga, p.be, p.P, 2)

    @testset "Filter folgt der Hamilton-Rekursion" begin
        RNG.set_seed(1)
        y = Float64.(RNG.rnorm(50, 0, 0.01))
        om = [1e-6, 5e-6]; al = [0.05, 0.1]; be = [0.9, 0.8]; ga = [0.02, 0.05]
        P = [0.95 0.05; 0.1 0.9]; xi0 = [2 / 3, 1 / 3]; h1 = SimLev.r_var(y)
        f = C.ms_garch_filter(y, om, al, be, ga, P, xi0, h1)
        n = length(y); h = zeros(n, 2); pred = zeros(n, 2); filt = zeros(n, 2); ll = 0.0; xi = copy(xi0)
        for t in 1:n
            h[t, :] = t == 1 ? fill(h1, 2) : om .+ (al .+ ga .* (y[t-1] < 0)) .* y[t-1]^2 .+ be .* h[t-1, :]
            phi = exp.(-0.5 .* y[t]^2 ./ h[t, :]) ./ sqrt.(2pi .* h[t, :])
            pred[t, :] = xi
            ft = sum(xi .* phi)
            filt[t, :] = xi .* phi ./ ft
            ll += log(ft)
            xi = transpose(P) * filt[t, :]
        end
        @test isapprox(f["h"], h; rtol = 1e-14)
        @test isapprox(f["pred"], pred; rtol = 1e-12)
        @test isapprox(f["filt"], filt; rtol = 1e-12)
        @test isapprox(f["loglik"], ll; rtol = 1e-12)
        @test isapprox(f["lB"], -0.5 .* y .^ 2 ./ h .- 0.5 .* log.(2pi .* h); rtol = 1e-12)
        @test C.ms_garch_filter(y, [-1, -1], [0, 0], [0, 0], [0, 0], P, xi0, -1)["loglik"] == -Inf
    end

    @testset "Schätzung deterministisch und stimmig" begin
        y = ysim[1:1000]
        RNG.set_seed(123); s0 = RNG.get_random_seed()
        f1 = MG._ms_garch_fit(y, 2, "gjrGARCH")
        @test RNG.get_random_seed() == s0
        f2 = MG._ms_garch_fit(y, 2, "gjrGARCH")
        @test collect(keys(f1)) == ["omega", "alpha", "beta", "gamma", "P", "regimes", "s2", "loglik", "convergence"]
        @test all(isequal(f1[k], f2[k]) for k in keys(f1))
        for (model, K) in (("gjrGARCH", 2), ("sGARCH", 2), ("sGARCH", 3), ("gjrGARCH", 3))
            f = (model, K) == ("gjrGARCH", 2) ? f1 : MG._ms_garch_fit(y, K, model)
            @test length(f["s2"]) == length(y) && all(v -> isfinite(v) && v > 0, f["s2"])
            @test size(f["P"]) == (K, K) && all(abs.(sum(f["P"]; dims = 2) .- 1) .< 1e-12) && all(f["P"] .>= 0)
            unc = f["omega"] ./ (1 .- f["alpha"] .- f["gamma"] ./ 2 .- f["beta"])
            @test issorted(unc)
            @test isfinite(f["loglik"])
            @test eltype(f["regimes"]) <: Integer && length(f["regimes"]) == length(y)
            @test all(r -> 1 <= r <= K, f["regimes"])
            @test all(f["alpha"] .+ f["gamma"] ./ 2 .+ f["beta"] .< 1)
            model == "sGARCH" && @test f["gamma"] == zeros(K)
        end
    end

    @testset "Schätzung trifft bekannte Parameter" begin
        # Grenzen wie im R-Test (Probelauf in R: Verhältnisse 1.074 bzw. 1.146, Diagonale 0.9921 / 0.9742)
        f = MG._ms_garch_fit(ysim, 2, "gjrGARCH")
        ratio = (f["omega"] ./ (1 .- f["alpha"] .- f["gamma"] ./ 2 .- f["beta"])) ./ (p.om ./ (1 .- p.al .- p.ga ./ 2 .- p.be))
        @test 0.75 < ratio[1] < 1.25 && 0.6 < ratio[2] < 1.7
        @test abs(f["P"][1, 1] - 0.99) < 0.01 && abs(f["P"][2, 2] - 0.97) < 0.04
        @test count(f["regimes"] .== ssim) / length(ssim) > 0.8
        @test f["convergence"] == 0
    end

    @testset "Fehlermeldungen auf Deutsch" begin
        y = ysim[1:300]
        @test_throws r"muss \"sGARCH\" oder \"gjrGARCH\" sein \(erhalten: eGARCH\)" MG._ms_garch_fit(y, 2, "eGARCH")
        @test_throws r"ganze Zahl >= 2" MG._ms_garch_fit(y, 1, "sGARCH")
        @test_throws r"ganze Zahl >= 2 sein \(erhalten: 2.5\)" MG._ms_garch_fit(y, 2.5, "sGARCH")
    end

    @testset "Verfahren laufen ohne weitere Pakete" begin
        n = 600
        us = 1 .+ 3e-4 .+ ysim[1:n]
        RNG.set_seed(4)
        d = (us = us, eu = us .* (1 .+ Float64.(RNG.rnorm(n, 0, 0.004))))
        cfg = SimLev.Bootstrap.bootstrap_config((us = "us", eu = "eu"), regime_index = "us")
        run(m; params = (;)) = begin
            path = tempname()
            b = open(path, "w") do io
                redirect_stderr(io) do
                    with_logger(NullLogger()) do
                        SimLev.Bootstrap.bootstrap(d, cfg, m; n = 2, seed = 1, progress = false, params = params)
                    end
                end
            end
            b, read(path, String)
        end
        for m in ("ms_garch", "ms_ar_garch_m", "tvtp_ms_garch")
            b, _ = run(m)
            @test length(b["paths"]) == 2
            P1 = b["paths"][1]
            P1 = P1 isa SimLev.NamedMat ? P1.data : P1
            @test size(P1) == (n + 1, 2) && all(isfinite, P1)
            b2, _ = run(m)
            @test all(isequal(a isa SimLev.NamedMat ? a.data : a, c isa SimLev.NamedMat ? c.data : c)
                      for (a, c) in zip(b["paths"], b2["paths"]))
        end
        _, msg = run("ms_garch"; params = (ms_garch_model = "sGARCH",))
        @test occursin("MS-GARCH(2, sGARCH): P(stay)", msg)
        @test_throws r"Vorberechnung fehlgeschlagen: MS-GARCH: Varianzmodell" run("ms_garch"; params = (ms_garch_model = "eGARCH",))
        @test_throws r"ganze Zahl >= 2" run("tvtp_ms_garch"; params = (tvtp_n_regimes = 1,))
    end
end
