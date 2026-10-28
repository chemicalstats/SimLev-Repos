# Fonds-Wrapper (Etappe 6.5c, src/wrapper.jl): Port von r/tests/testthat/test-wrapper.R und
# python/tests/test_wrapper.py. Erwartet: `using SimLev`, `using Test, Dates, Logging`.
using Test, Dates, Logging

@testset "Fonds-Wrapper" begin
    SL = SimLev
    RNG = SimLev.RRng
    quiet(f) = with_logger(NullLogger()) do
        redirect_stderr(devnull) do
            f()
        end
    end
    function messages(f)
        mktemp() do path, io
            v = redirect_stderr(io) do
                f()
            end
            flush(io)
            txt = read(path, String)
            v, isempty(txt) ? String[] : String.(split(chomp(txt), "\n"))
        end
    end
    function warns(f)
        lg = TestLogger(min_level = Logging.Warn)
        v = with_logger(lg) do
            redirect_stderr(devnull) do
                f()
            end
        end
        v, String[string(l.message) for l in lg.logs if l.level == Logging.Warn]
    end
    errmsg(f) = try
        quiet(f); ""
    catch e
        e isa ErrorException ? e.msg : sprint(showerror, e)
    end
    "all.equal-artige Toleranz (mittlere relative Abweichung)"
    close(a, b, tol) = (den = sum(abs, b) / length(b); sum(abs.(a .- b)) / length(b) / (den > 0 ? den : 1.0) < tol)
    function wdata(n = 500, seed = 7)
        RNG.set_seed(seed)
        A = 100 .* SL.RBase.r_cumprod(1 .+ RNG.rnorm(n, 4e-4, 0.011))
        B = 50 .* SL.RBase.r_cumprod(1 .+ RNG.rnorm(n, 1e-4, 0.004))
        C = 80 .* SL.RBase.r_cumprod(1 .+ RNG.rnorm(n, 2e-4, 0.006))
        RFrame("date" => collect(Date(2019, 11, 1):Day(1):Date(2019, 11, 1) + Day(n - 1)), "A" => A, "B" => B, "C" => C)
    end
    inner() = create_strategy("A" => asset_config("etf", "bnh", 0.6), "B" => asset_config("etf", "bnh", 0.4))
    certif(w; kw...) = create_strategy("Z" => asset_config("certificate"; wrapper = w, kw...))

    @testset "Plausibilität: ohne Kosten und Spreads = innere Strategie" begin
        d = wdata()
        w = wrapper_config(inner(); costs = funds_costs(0, 0))
        r_w = quiet(() -> simulation(d, certif(w)))
        r_i = quiet(() -> simulation(d, inner()))
        @test close(r_w.worth, r_i.worth, 1e-10)
        rb = rebalance_plan(; unit = "quarter")
        r_w2 = quiet(() -> simulation(d, certif(wrapper_config(inner(); rebalance = rb, costs = funds_costs(0, 0), volume = 10000))))
        r_i2 = quiet(() -> simulation(d, inner(); rebalance = rb))
        @test close([r_w2.worth[end]], [r_i2.worth[end]], 1e-10)
        r_w3 = quiet(() -> simulation(d, certif(wrapper_config(inner(); rebalance = rb, costs = funds_costs(0, 0)))))
        @test close([r_w3.worth[end]], [r_i2.worth[end]], 1e-6)
    end

    @testset "Handbeispiel: Gebühr je Kalendertag, Schaltjahr, Abgrenzung, Festschreibung" begin
        dates = Date.(["2020-02-27", "2020-02-28", "2020-03-02", "2020-12-30", "2020-12-31", "2021-01-04",
                       "2021-06-30", "2021-12-31", "2022-01-03"])
        A = [100.0, 101, 103, 110, 112, 111, 95, 120, 121]
        fee, pf = 1.0, 20.0
        w = wrapper_config(create_strategy("A" => asset_config("etf")); costs = funds_costs(fee, pf))
        x = wrapper_nav(RFrame("date" => dates, "A" => A), w)
        @test inherits(x, "SimLevWrapperNav")
        @test names(x) == ["date", "nav", "gross", "fee", "perf_fee", "perf_paid", "hwm"]
        U, H, Gp, dp, n = 100.0, 100.0, 100.0, Dates.value(dates[1]), length(A)
        nav, fe, acc, paid, hwm = (zeros(n) for _ in 1:5)
        for t in 1:n
            D = year(dates[t]) % 4 == 0 ? 366 : 365
            a = U * (A[t] / A[1] * 100 / Gp)
            fe[t] = a * (fee / 100 * (Dates.value(dates[t]) - dp) / D)
            U = a - fe[t]
            acc[t] = pf / 100 * max(0.0, U - H)
            nav[t] = U - acc[t]
            if t < n && year(dates[t+1]) != year(dates[t])
                paid[t] = acc[t]; U = nav[t]; H = max(H, U)
            end
            hwm[t] = H; Gp = A[t] / A[1] * 100; dp = Dates.value(dates[t])
        end
        for (col, ref) in (("nav", nav), ("fee", fe), ("perf_fee", acc), ("perf_paid", paid), ("hwm", hwm))
            @test close(x[col], ref, 1e-12)
        end
        @test close(x["gross"], A ./ A[1] .* 100, 1.5e-8)
        a3 = (x["nav"][2] + x["perf_fee"][2]) * A[3] / A[2]
        @test isapprox(x["fee"][3], a3 * 0.01 * 3 / 366; rtol = 1e-12)
        @test (x["perf_paid"] .> 0) == [false, false, false, false, true, false, false, true, false]
        @test isapprox(x["hwm"][5], x["nav"][5]; rtol = 1e-15)
        @test x["perf_fee"][6] == 0 && x["perf_fee"][9] > 0 && x["fee"][1] == 0
        @test attrs(x)["inner"] isa SimLevResult && attrs(x)["wrapper"] === w
    end

    @testset "Startkosten: Ordergebühr mit volume, innerer Spread" begin
        d = wdata(60)
        w = wrapper_config(inner(); costs = funds_costs(0, 0), order_fee = (fixed = 5, percent = 0.1), volume = 1e6)
        @test isapprox(wrapper_nav(d, w)["nav"][1], 100 * ((6e5 - 5) / 1.001 + (4e5 - 5) / 1.001) / 1e6; rtol = 1e-12)
        ws = quiet(() -> wrapper_config(create_strategy("A" => asset_config("etf", "bnh", 1; spread = 0.2)); costs = funds_costs(0, 0)))
        @test wrapper_nav(d, ws)["nav"][1] < 100
    end

    @testset "NA-Tage, späterer Beginn, Wochenenden" begin
        d = wdata(200)
        w = wrapper_config(inner(); costs = funds_costs(0.95, 10))
        dn = copy(d)
        for c in ("A", "B"); v = copy(dn[c]); v[[20, 21]] .= SL.NA; dn[c] = v; end
        x = quiet(() -> wrapper_nav(dn, w))
        @test !any(in(dn["date"][[20, 21]]), x["date"])
        i = findfirst(==(dn["date"][19]), x["date"])
        @test x["date"][i+1] == dn["date"][22]
        @test isapprox(x["fee"][i+1], (x["nav"][i] + x["perf_fee"][i]) * x["gross"][i+1] / x["gross"][i] * (0.95 / 100 * 3 / 365); rtol = 1e-12)
        dl = copy(d)
        for c in ("A", "B"); v = copy(dl[c]); v[1:5] .= SL.NA; dl[c] = v; end
        @test quiet(() -> wrapper_nav(dl, w))["date"][1] == d["date"][6]
        r = quiet(() -> simulation(dl, create_strategy("Z" => asset_config(; share = 0.5, wrapper = w), "C" => asset_config(; share = 0.5))))
        @test r.report["Z"]["worth"][1:5] == zeros(5)
        @test occursin("In der ersten Zeile", errmsg(() -> simulation(dl, create_strategy("Z" => asset_config(; wrapper = w)))))
        dw = SL.rows(d, dayofweek.(d["date"]) .<= 5)
        xw = quiet(() -> wrapper_nav(dw, w))
        mo = findall(==(1), dayofweek.(xw["date"]))[2]
        @test isapprox(xw["fee"][mo], (xw["nav"][mo-1] + xw["perf_fee"][mo-1]) * xw["gross"][mo] / xw["gross"][mo-1] * (0.95 / 100 * 3 / 365); rtol = 1e-12)
    end

    @testset "Fehler, Hinweis, Meldungen und Warnungen der inneren Rechnung" begin
        d = wdata(100)
        w = wrapper_config(inner())
        @test occursin("verschachtelte Wrapper", errmsg(() -> wrapper_config(create_strategy("Z" => asset_config(; wrapper = w)))))
        @test occursin("nur trading = \"bnh\"", errmsg(() -> asset_config("etf", "signal"; signal_buy = "b", signal_sell = "s", wrapper = w)))
        @test occursin("nur trading = \"bnh\"", errmsg(() -> simulation(d, RList("Z" => RList("asset_class" => "etf", "trading" => "signal",
                                                                          "share" => 1, "signal_buy" => "b", "signal_sell" => "s", "wrapper" => w)))))
        d2 = copy(d); d2["Z"] = 1.0
        @test occursin("keine Spalte gleichen Namens", errmsg(() -> simulation(d2, create_strategy("Z" => asset_config(; wrapper = w)))))
        @test occursin("keine Spalte gleichen Namens", errmsg(() -> strategy_validate(create_strategy("Z" => asset_config(; wrapper = w)), d2)))
        @test strategy_validate(create_strategy("Z" => asset_config(; wrapper = w)), d)
        @test occursin("'B' fehlen", errmsg(() -> strategy_validate(create_strategy("Z" => asset_config(; wrapper = w)),
                                                                    RFrame("date" => d["date"], "A" => d["A"]))))
        for of in (1, (percent = 0.1, min = 1), (percent = 0.1, max = 5))
            @test occursin("Fondsvolumen 'volume'", errmsg(() -> wrapper_config(inner(); order_fee = of)))
        end
        @test errmsg(() -> wrapper_config(inner(); order_fee = (percent = 0.1,))) == ""
        @test occursin("'volume' muss", errmsg(() -> wrapper_config(inner(); volume = 0)))
        @test occursin("funds_costs", errmsg(() -> wrapper_config(inner(); costs = sim_costs())))
        @test occursin("rebalance_plan", errmsg(() -> wrapper_config(inner(); rebalance = 1)))
        @test occursin("create_strategy", errmsg(() -> wrapper_config(1)))
        @test occursin("summieren sich", errmsg(() -> wrapper_config(create_strategy("A" => asset_config(; share = 0.5)))))
        @test occursin("wrapper_config", errmsg(() -> asset_config(; wrapper = 1)))
        @test occursin("wrapper_config", errmsg(() -> wrapper_nav(d, inner())))
        @test occursin("split_rule", errmsg(() -> wrapper_nav(d, w; splits = 1)))
        _, m = messages(() -> wrapper_config(create_strategy("A" => asset_config(; spread = 0.1))))
        @test m == ["Hinweis: wrapper_config: innere Assets mit Spread > 0: 'A' (0.1 %); der Spread gilt in der inneren Rechnung (Kauf und Umschichten)."]
        @test messages(() -> wrapper_config(inner()))[2] == String[]
        wf = wrapper_config(inner(); costs = funds_costs(0.95, 10))
        dn = copy(d)
        for c in ("A", "B"); v = copy(dn[c]); v[[11, 12]] .= SL.NA; dn[c] = v; end
        _, m = messages(() -> simulation(dn, certif(wf)))
        @test m[1] == "Hinweis: Wrapper 'Z' (innere Rechnung): 'A': 2 fehlende Kurse (NA) per LOCF gefüllt."
        @test m[end] == "Hinweis: 'Z': 2 fehlende Kurse (NA) per LOCF gefüllt."
        dw = SL.rows(d, dayofweek.(d["date"]) .<= 5)
        _, m = messages(() -> simulation(dw, certif(wf)))
        @test length(m) == 2 && m[1] == "Hinweis: Wrapper 'Z' (innere Rechnung): " * m[2][length("Hinweis: ")+1:end]
        @test messages(() -> SL.RParallel.suppress_messages(() -> simulation(dw, certif(wf))))[2] == String[]
        _, wl = warns(() -> simulation(SL.rows(d, 1:1), certif(wf)))
        @test startswith(wl[1], "simulation: Wrapper 'Z' (innere Rechnung): simulation: Zeitraum 1 Tag")
        @test startswith(wl[2], "simulation: Zeitraum 1 Tag")
        dm = copy(d); dm["A"] = fill(-1.0, nrow(d))
        @test startswith(errmsg(() -> wrapper_nav(dm, w)), "wrapper_nav (innere Rechnung): simulation: Kursspalte 'A' enthält ungültige Kurse")
    end

    @testset "Ordergebühren: Zustand je Lauf, innere Rechnung lässt den äußeren unverändert" begin
        # Julia hält die Ordergebühren je Lauf (Run.fee_current/fee_paid), nicht im Paket (R: .fee_env).
        # Prüfung über das Ergebnis: Wrapper mit innerer Ordergebühr = dieselbe Rechnung mit dem
        # Anteilswert als gewöhnlicher Kursspalte (gleiche äußere Ordergebühren, gleiche Werte)
        d = wdata(200)
        w = wrapper_config(inner(); rebalance = rebalance_plan(), costs = funds_costs(0.5, 5), order_fee = (fixed = 2, percent = 0.1), volume = 1e5)
        st = create_strategy("Z" => asset_config("certificate"; share = 0.5, wrapper = w), "C" => asset_config(; share = 0.5))
        r1 = quiet(() -> simulation(d, st; costs = sim_costs(; order_fee = 1), rebalance = rebalance_plan()))
        dZ = copy(d); dZ["Z"] = wrapper_nav(d, w)["nav"]
        r0 = quiet(() -> simulation(dZ, create_strategy("Z" => asset_config("certificate"; share = 0.5), "C" => asset_config(; share = 0.5));
                                    costs = sim_costs(; order_fee = 1), rebalance = rebalance_plan()))
        @test r1["fees_paid"] === r0["fees_paid"] && r1["fees_paid"] > 0
        @test r1.worth == r0.worth
    end

    @testset "simulation(): details, keine Splits auf den Anteilswert" begin
        d = wdata(300)
        w = wrapper_config(inner(); rebalance = rebalance_plan(; unit = "quarter"), costs = funds_costs(0.95, 10))
        st = create_strategy("Z" => asset_config("certificate"; share = 0.7, spread = 0.3, wrapper = w), "C" => asset_config(; share = 0.3))
        r0 = quiet(() -> simulation(d, st; tax = tax_profile()))
        @test !haskey(r0, "wrappers")
        r1 = quiet(() -> simulation(d, st; tax = tax_profile(), details = true, io = devnull))
        @test inherits(r1.wrappers["Z"], "SimLevWrapperNav")
        @test r1.worth == r0.worth
        @test collect(keys(r1)) == [collect(keys(r0)); "wrappers"]
        nv = wrapper_nav(d, w)
        u = r0.report["Z"]["worth"] ./ nv["nav"]
        @test all(abs.(u .- u[1]) .< 1e-9 * u[1])
        RNG.set_seed(3)
        dsp = copy(d); dsp["A"] = 100 .* SL.RBase.r_cumprod(1 .+ RNG.rnorm(300, 3e-3, 0.005))
        nvs = wrapper_nav(dsp, w; splits = split_rule([50, 115]))
        @test maximum(nvs["nav"]) > 115
        @test close(nvs["nav"], wrapper_nav(dsp, w)["nav"], 1e-7)
        io = IOBuffer()
        rs = quiet(() -> simulation(dsp, certif(w); splits = split_rule([50, 115]), fractions = false, details = true, io = io))
        @test !occursin("Split", String(take!(io)))
        us = rs.report["Z"]["worth"] ./ nvs["nav"]
        @test all(abs.(us .- us[1]) .< 1e-9 * us[1])
        io = IOBuffer()
        quiet(() -> simulation(RFrame("date" => nvs["date"], "N" => nvs["nav"]), create_strategy("N" => asset_config());
                               splits = split_rule([50, 115]), fractions = false, details = true, io = io))
        @test occursin("Split", String(take!(io)))
    end

    @testset "strategy_update_asset und strategy_add_asset mit Wrapper" begin
        w = wrapper_config(inner())
        st = create_strategy("Z" => asset_config("etf"; wrapper = w))
        st2 = strategy_update_asset(st, "Z"; asset_class = "certificate", spread = 0.5)
        @test st2["Z"]["tax_regime"] == "capital_gains" && inherits(st2["Z"]["wrapper"], "SimLevWrapperConfig")
        @test occursin("nur trading", errmsg(() -> strategy_update_asset(st, "Z"; trading = "signal", signal_buy = "a", signal_sell = "b")))
        st3 = strategy_update_asset(create_strategy("A" => asset_config()), "A"; wrapper = w)
        @test inherits(st3["A"]["wrapper"], "SimLevWrapperConfig")
        @test collect(keys(strategy_update_asset(st3, "A"; wrapper = nothing)["A"])) == collect(keys(asset_config()))
        st4 = strategy_add_asset(create_strategy("C" => asset_config(; share = 0.5)), "Z", asset_config(; share = 0.5, wrapper = w))
        @test collect(keys(st4)) == ["C", "Z"]
        @test !haskey(asset_config(), "wrapper")
        @test SL._strategy_columns(st4) == ["C", "A", "B"]
        @test SL._strategy_columns(inner()) == ["A", "B"]
    end

    @testset "Aufrufer: planning_lumpsum_vs_dca, withdrawal_simulation" begin
        d = wdata(900)
        w = wrapper_config(inner(); costs = funds_costs(0.5, 0))
        pl = planning_lumpsum_vs_dca(d, create_strategy("Z" => asset_config(; wrapper = w)); amount = 1200, months = 4, horizon = 1, step = 6)
        @test all(pl["exact"])
        nv = wrapper_nav(d, w)
        ws = withdrawal_simulation(nv, withdrawal_rule("percent"; rate = 4); years = 1, frequency = "quarter")
        @test inherits(ws, "SimLevWithdrawal")
        co = withdrawal_cohorts(nv; price = "nav", years = 1, frequency = "quarter")
        ws2 = withdrawal_simulation(co, withdrawal_rule("percent"; rate = 4))
        @test names(ws["paths"]) == names(ws2["paths"]) && all(c -> isequal(ws["paths"][c], ws2["paths"][c]), names(ws["paths"]))
    end

    @testset "Auswahl (rows): gewöhnliche Tabelle ohne Klasse und Attribute (Etappe 8.0)" begin
        x = wrapper_nav(wdata(400), wrapper_config(inner(); costs = funds_costs(0.95, 10)))
        @test SL.r_class(x) == ["SimLevWrapperNav", "data.frame"]
        @test sort(collect(keys(SL.attrs(x)))) == ["inner", "wrapper"]
        for s in (SL.rows(x, 1:5), SL.rows(x, x.nav .> 100), SL.rows(x, 1:SL.nrow(x)))
            @test isempty(SL.r_class(s))
            @test isempty(SL.attrs(s))
        end
        @test SL.rows(x, 10:20).nav == x.nav[10:20]
        @test SL.inherits(copy(x), "SimLevWrapperNav")              # Kopie ist keine Auswahl
        # andere Klassen behalten bei rows() Klasse und Attribute
        y = RFrame("a" => [1.0, 2.0]; class = ["SimLevFoo", "data.frame"], attrs = Dict{String,Any}("k" => 1))
        @test SL.r_class(SL.rows(y, [2])) == ["SimLevFoo", "data.frame"] && SL.attrs(SL.rows(y, [2]))["k"] == 1
        rule = SL.withdrawal_rule("percent"; rate = 4)
        @test SL.inherits(quiet(() -> SL.withdrawal_simulation(x, rule; years = 1, frequency = "quarter")), "SimLevWithdrawal")
        @test startswith(errmsg(() -> SL.withdrawal_simulation(SL.rows(x, 30:400), rule; years = 1, frequency = "quarter")),
                         "x ist eine Tabelle mit Spalte 'date'")
        wp = quiet(() -> SL.withdrawal_cohorts(SL.rows(x, 30:400); price = "nav", inflation = 2, years = 1, frequency = "quarter"))
        @test SL.inherits(quiet(() -> SL.withdrawal_simulation(wp, rule)), "SimLevWithdrawal")
    end

    @testset "strategy_from_weights / portfolio_template mit wrapper je Asset (Etappe 8.0)" begin
        w = wrapper_config(inner(); costs = funds_costs(0.95, 10))
        w2 = wrapper_config(create_strategy("C" => asset_config("etf", "bnh", 1)))
        has(st) = [k => haskey(a, "wrapper") for (k, a) in st]
        sfw = SL.strategy_from_weights
        @test has(sfw(SL.named("x" => 0.5, "y" => 0.5); wrapper = w)) == ["x" => true, "y" => true]
        st = sfw(SL.named("x" => 0.5, "y" => 0.3, "z" => 0.2); spread = SL.named("z" => 0.1), wrapper = (y = w2, x = w))
        @test has(st) == ["x" => true, "y" => true, "z" => false]
        @test st["y"]["wrapper"] === w2
        @test has(sfw(SL.named("x" => 0.5, "y" => 0.5); wrapper = Dict("y" => w))) == ["x" => false, "y" => true]
        @test has(sfw(SL.named("x" => 0.5, "y" => 0.5); wrapper = nothing)) == ["x" => false, "y" => false]
        d = wdata(300)
        r1 = quiet(() -> simulation(d, sfw(SL.named("Z" => 0.7, "C" => 0.3); asset_class = SL.named("Z" => "certificate"), wrapper = (Z = w,))))
        r2 = quiet(() -> simulation(d, create_strategy("Z" => asset_config("certificate"; share = 0.7, wrapper = w),
                                                      "C" => asset_config("etf"; share = 0.3))))
        @test r1.worth == r2.worth
        st = SL.portfolio_template("60_40"; map = SL.named("stocks" => "aktien"), wrapper = (aktien = w, bonds = w2))
        @test has(st) == ["aktien" => true, "bonds" => true]
        @test errmsg(() -> SL.portfolio_template("60_40"; map = SL.named("stocks" => "aktien"), wrapper = (stocks = w,))) ==
              "wrapper: 'stocks' ist kein Asset der Strategie (Assets: aktien, bonds)."
        @test errmsg(() -> sfw(SL.named("x" => 0.5, "y" => 0.5); wrapper = (x = w, y = "w"))) ==
              "wrapper: Eintrag 'y' muss ein Objekt aus wrapper_config() sein, nicht character."
        @test occursin("braucht jedes Element einen Namen", errmsg(() -> sfw(SL.named("x" => 0.5, "y" => 0.5); wrapper = [w])))
        @test endswith(errmsg(() -> sfw(SL.named("x" => 0.5, "y" => 0.5); wrapper = 1)), "nicht numeric.")
        @test startswith(errmsg(() -> sfw(SL.named("x" => 0.5, "y" => 0.5); trading = SL.named("y" => "signal"), signal_buy = "b",
                                          signal_sell = "s", wrapper = (y = w,))), "wrapper: Asset 'y' hat trading = \"signal\"")
        @test startswith(errmsg(() -> sfw(SL.named("x" => 0.5, "y" => 0.5); trading = SL.named("y" => "signal"), wrapper = (y = w,))),
                         "asset_config: bei trading = \"signal\" müssen signal_buy")
    end

    @testset "Druck" begin
        w = wrapper_config(inner(); costs = funds_costs(0.95, 10), order_fee = (percent = 0.1,), volume = 1e6)
        out = split(sprint(show, MIME"text/plain"(), w), "\n")
        @test out[1] == "Fonds-Wrapper (wrapper_config)"
        @test any(l -> occursin(r"Fondsvolumen: +1000000.00 EUR", l), out)
        @test any(l -> occursin(r"^  Wrapper: +A 60 %, B 40 %", l), split(sprint(show, MIME"text/plain"(), asset_config(; wrapper = w)), "\n"))
        @test split(sprint(show, MIME"text/plain"(), funds_costs()), "\n")[1] == "Fondskosten (funds_costs)"
        out = split(sprint(show, MIME"text/plain"(), wrapper_nav(wdata(30), w)), "\n")
        @test out[1] == "Anteilswert (wrapper_nav)"
        @test any(l -> occursin(r"Zeitraum: +2019-11-01 bis 2019-11-30 \(30 Datentage\)", l), out)
    end
end
