# Engine-Tests (simulation(), Steuerrecht 0.5.0, Ausgabe, Konfiguration, Trigger, Dashboards,
# Golden Master). Vorlagen: r/tests/testthat (test-engine-notes.R, test-blue-engine*.R,
# test-review9-engine.R, test-tariff.R, test-strategy.R) und python/tests/test_*engine*.py.
# Erwartet: `using SimLev`, `using Test, Dates, Random, Logging` und golden_tools.jl sind geladen.

const SL = SimLev
quiet(f) = with_logger(NullLogger()) do
    redirect_stderr(devnull) do
        f()
    end
end
"Warnungen (Texte) während f() sammeln; Rückgabe (Wert, Warnungen)."
function with_warnings(f)
    struct_logger = TestLogger(min_level = Logging.Warn)
    val = with_logger(struct_logger) do
        redirect_stderr(devnull) do
            f()
        end
    end
    return val, String[string(l.message) for l in struct_logger.logs if l.level == Logging.Warn]
end
errmsg(f) = try
    quiet(f); ""
catch e
    e isa ErrorException ? e.msg : sprint(showerror, e)
end
days(a, b) = collect(Date(a):Day(1):Date(b))
appr(a, b) = isapprox(a, b; rtol = 1.5e-8, atol = 1e-9)

# Unabhängige Handrechnung § 32a Abs. 1 EStG (VZ 2026)
function T_est(x)
    x = floor(max(0, x))
    t = x <= 12348 ? 0.0 : x <= 17799 ? (y = (x - 12348) / 1e4; (914.51 * y + 1400) * y) :
        x <= 69878 ? (z = (x - 17799) / 1e4; (173.10 * z + 2397) * z + 1034.87) :
        x <= 277825 ? 0.42 * x - 11135.63 : 0.45 * x - 19470.38
    floor(t)
end
# Lieferbares ETC G (§ 23): 50 Stück zu 100, am 1.7.2020 zu p2 alles nach H umgeschichtet
function p23(; p2 = 150.0, stop = "2021-03-31", tax = tax_profile(), kw...)
    d = days("2020-01-01", stop)
    df = (date = d, G = [x < Date(2020, 6, 1) ? 100.0 : p2 for x in d], H = fill(50.0, length(d)),
          ev = [x == Date(2020, 7, 1) for x in d], wG = zeros(length(d)), wH = ones(length(d)))
    st = create_strategy(G = asset_config("etc", "bnh"; share = 0.5, spread = 0, deliverable = true),
                         H = asset_config("certificate", "bnh"; share = 0.5, spread = 0))
    quiet(() -> simulation(df, st; start_value = 1e4, tax = tax,
                           rebalance = rebalance_plan(; event_col = "ev", event_mode = "replace", skip = true,
                                                      event_weight = ["G" => "wG", "H" => "wH"]), kw...))
end
# Zertifikat Z (§ 20): 200 Stück zu 50, am 1.7.2020 zu pz nach M umgeschichtet
function gp(; stop = "2021-03-31", pz = 70.0, tax = tax_profile(), kw...)
    d = days("2020-01-01", stop)
    df = (date = d, Z = [x < Date(2020, 6, 1) ? 50.0 : pz for x in d], M = fill(100.0, length(d)),
          ev = [x == Date(2020, 7, 1) for x in d], wZ = zeros(length(d)), wM = ones(length(d)))
    st = create_strategy(Z = asset_config("certificate", "bnh"; share = 0.5, spread = 0),
                         M = asset_config("certificate", "bnh"; share = 0.5, spread = 0))
    quiet(() -> simulation(df, st; start_value = 2e4, tax = tax,
                           rebalance = rebalance_plan(; event_col = "ev", event_mode = "replace", skip = true,
                                                      event_weight = ["Z" => "wZ", "M" => "wM"]), kw...))
end
gbm(rng, n, s0, mu, sig) = s0 .* cumprod(1 .+ mu .+ sig .* randn(rng, n))
st1(; kw...) = create_strategy(A = asset_config("etf"; share = 1, spread = 0, kw...))

@testset "R-Numerik und Formatierung" begin
    # Software-Nachbildung (andere Plattformen) und Hardware-long-double rechnen gleich
    rng = MersenneTwister(5); nbad = 0
    for _ in 1:3000
        x, y = (rand(rng) - 0.5) * 10.0^rand(rng, -30:30), (rand(rng) - 0.5) * 10.0^rand(rng, -30:30)
        for op in (+, -, *, /)
            nbad += Float64(op(SL.F80Soft(x), SL.F80Soft(y))) !== Float64(op(SL.F80(x), SL.F80(y)))
        end
        nbad += Float64(sqrt(SL.F80Soft(abs(x)))) !== Float64(sqrt(SL.F80(abs(x))))
    end
    @test nbad == 0
    @test isna_strict(SL.r_sum([1.0, NA]))
    @test isna_strict(SL.r_var([1.0]))
    @test isnan(SL.r_mean(Float64[]))
    @test SL.r_sprintf("%+.2f%%", NA) == "NA%"
    @test SL.r_sprintf("%+.2f%%", NaN) == "NaN%"
    @test SL.r_sprintf("%+.2f", Inf) == "+Inf"
    @test SL.r_sprintf("%10.2f", NA) == "        NA"
    @test SL.r_sprintf("%d Tage", 3.0) == "3 Tage"
    @test SL.r_sprintf("%s", 1e5) == "1e+05"
    @test SL.r_sprintf("%.*f", 2, 3.14159) == "3.14"
    @test SL.r_as_character(123456.7) == "123456.7"
    @test SL.r_as_character(0.1 + 0.2) == "0.3"
    @test SL.r_as_character(1e-20) == "1e-20"
    @test SL.r_format1(1234567.891) == "1234568"
    @test SL.r_format1(0.000012345) == "1.2345e-05"
    @test SL.r_format([1.0, 10.0, 100.5]) == ["  1.0", " 10.0", "100.5"]
    @test SL.r_format1(20350.0; big_mark = " ", scientific = false) == "20 350"
    @test SL.r_format1(99999.5; digits = 5) == "1e+05"
    @test SL.r_deparse([1.0, 2.5]) == "c(1, 2.5)"
    @test SL.r_deparse("a") == "\"a\""
    @test SL.r_round(2.675, 2) == 2.67
    @test SL.r_as_numeric("914.51") == 914.51 && isna_strict(SL.r_as_numeric("x"))
    @test SL.r_cummax([1.0, 3.0, NA, 5.0])[3:4] |> v -> all(isna_strict, v)
end

@testset "asset_config und Strategien" begin
    cfg = asset_config("etf"; share = 0.7, partial_exemption = 30)
    @test cfg isa AssetConfig && r_class(cfg) == ["asset_config", "list"]
    @test cfg.asset_class == "etf" && cfg["share"] == 0.7 && cfg.tax_regime == "investment_fund"
    @test collect(keys(cfg)) == ["asset_class", "trading", "share", "spread", "partial_exemption",
                                 "deliverable", "start", "tax_regime", "signal_buy", "signal_sell"]
    @test asset_config("etc"; deliverable = true).tax_regime == "private_sale"
    @test asset_config("etf", "bnh", 0.5, 0.1, 30).partial_exemption == 30
    c, w = with_warnings(() -> asset_config("etn_deliverable"))
    @test c.asset_class == "etn" && c.deliverable == true && occursin("veraltet", w[1])
    @test occursin("share muss ein Anteil größer 0", errmsg(() -> asset_config(; share = 50)))
    @test errmsg(() -> asset_config("xx")) == "'arg' should be one of “etf”, “etn”, “etc”, “certificate”, “etn_standard”, “etn_deliverable”"
    @test asset_config(; start = "2020-02-01").start == Date(2020, 2, 1)
    s = create_strategy(A = asset_config("etf"; share = 0.6), B = asset_config("etf"; share = 0.4))
    @test s isa Strategy && collect(keys(s)) == ["A", "B"]
    @test sprint(show, MIME"text/plain"(), s) == "Anlagestrategie (2 Assets)\n================================\n\nA:\n  Klasse: etf | Anteil: 60% | Steuer: investment_fund\nB:\n  Klasse: etf | Anteil: 40% | Steuer: investment_fund\n"
    @test occursin("mehrfach", errmsg(() -> create_strategy("A" => asset_config(), "A" => asset_config())))
    @test strategy_validate(s, (date = [Date(2020)], A = [1.0], B = [1.0]))
    s2 = strategy_update_asset(s, "A"; asset_class = "etc", deliverable = true)
    @test s2.A.tax_regime == "private_sale"
    @test length(strategy_remove_asset(s, "A")) == 1
end

@testset "Engine: Grundfunktionen und Ergebnisobjekt" begin
    rng = MersenneTwister(1); n = 400
    d = (date = days("2020-01-01", "2021-02-03"), A = gbm(rng, n, 100, 3e-4, 0.01))
    r = simulation(d, st1())
    @test r isa SimLevResult && r_class(r) == ["SimLevResult"]
    @test collect(keys(r)) == ["dates", "filled", "worth", "twr_index", "invested", "external_flows", "cagr", "ttwror",
                               "drawdowns", "statistics", "buys", "sells", "report", "tax_report", "undefined_metrics", "open_lots"]
    @test r.worth === r["worth"] && r.statistics isa RList && r.buys isa RVector && r.undefined_metrics isa RFrame
    @test r.open_lots === nothing && r.external_flows == false && r.invested[end] == 10000
    r2 = copy(r); r2["tactical"] = 1; r2.extra2 = "x"
    @test r2.tactical == 1 && haskey(r2, "extra2") && keys(r2)[end] == "extra2" && !haskey(r, "tactical")
    @test sprint(show, MIME"text/plain"(), r2) == sprint(show, MIME"text/plain"(), r)
    rp = simulation(d, st1(); tax = tax_profile(; harvest = harvest_rule()), costs = sim_costs(5))
    @test rp.open_lots isa RList && rp.open_lots["A"]["lots"] isa RFrame && rp.fees_paid > 0
    @test rp.tax_report["next_year"]["year"] == 2022 && rp.harvest_days isa Vector{Date}
    @test occursin("Steuern", sprint(show, MIME"text/plain"(), rp)) || rp.tax_report["total_taxes_paid"] == 0
    # Einzeltag: NA mit Ursache
    r1, w = with_warnings(() -> simulation((date = [Date(2024, 1, 2)], A = [100.0]), st1()))
    @test isna_strict(r1.cagr) && isna_strict(r1.ttwror) && any(occursin("Zeitraum 1 Tag (Laufzeit 0 Jahre)", x) for x in w)
    @test "cagr" in r1.undefined_metrics["metric"]
    txt = sprint(show, MIME"text/plain"(), r1)
    @test occursin("CAGR:             nicht definiert (Zeitraum 1 Tag, Laufzeit 0 Jahre (Einzeltag))", txt)
    sm = summary(r1)
    @test sm isa SL.SimLevSummary && occursin("Zeitraum:         1 Tag (", sprint(show, MIME"text/plain"(), sm))
    @test r_summary(r) isa SL.SimLevSummary
    # Fehler und Warnungen wortgleich
    @test occursin("summieren sich auf 0.9000", errmsg(() -> simulation(d, create_strategy(A = asset_config(; share = 0.9)))))
    @test occursin("Kursspalte 'B' fehlt in 'data'", errmsg(() -> simulation(d, create_strategy(B = asset_config()))))
    dup = (date = [Date(2020, 1, 1); days("2020-01-01", "2020-01-05")], A = collect(101.0:106.0))
    @test occursin("mehrfach vor (1 doppelte Zeilen)", errmsg(() -> simulation(dup, st1())))
    # Fondsmodus mit tax_profile() (Kirchensteuer) wie bis 6.2 mit tax_mode = "funds"
    dg = (date = days("2020-01-01", "2020-12-31"), A = collect(range(100.0, 160.0; length = 366)))
    r9 = simulation(dg, st1(); funds = funds_costs(), tax = tax_profile(; church_tax = 9), liquidate = true)
    f9 = SL._simulation_flat(dg, st1(); tax_mode = "funds", church_tax = 9, liquidate = true)
    @test r9["worth"] == f9["worth"] && r9["tax_report"]["total_taxes_paid"] == f9["tax_report"]["total_taxes_paid"]
    r0 = simulation(dg, st1(); funds = funds_costs(), liquidate = true)
    @test r9["tax_report"]["total_taxes_paid"] > r0["tax_report"]["total_taxes_paid"]
    @test errmsg(() -> simulation(d, st1(); dca = (value = 100, span = 1))) ==
          "simulation: dca muss NULL oder ein Objekt aus dca_plan() sein, nicht list."
    @test errmsg(() -> simulation(d, st1(); tax = funds_costs())) ==
          "simulation: tax muss NULL oder ein Objekt aus tax_profile() sein, nicht SimLevFundsCosts."
    @test errmsg(() -> tax_profile(25; church_tax = 9)) ==
          "tax_profile: rate und church_tax schließen sich aus; rate gilt nur ohne Kirchensteuer (mit church_tax gilt der Satz nach § 32d Abs. 1 EStG)."
    _, w = with_warnings(() -> rebalance_plan(; event_mode = "replace"))
    @test w == ["rebalance_plan: event_mode wirkt nur zusammen mit event_col und wird ignoriert."]
    _, w = with_warnings(() -> simulation(d, st1(); tax = tax_profile(; church_tax = 9)))   # keine given-Warnung
    @test isempty(w)
    io = IOBuffer(); simulation(d, st1(); tax = tax_profile(), details = true, io = io, liquidate = true)
    @test occursin("Kauf", String(take!(io)))
    d30 = (date = days("2000-01-01", "2029-12-31"), A = gbm(MersenneTwister(2), 10958, 100, 3e-4, 0.01))
    run30() = simulation(d30, st1(); dca = dca_plan(100, 1), rebalance = rebalance_plan(), tax = tax_profile(; base_rate = 2))
    run30()
    @test (@elapsed run30()) < 2          # 30 Jahre täglich (R: mehrere Sekunden)
end

@testset "Engine: Gebühren, Kirchensteuer, Freibetrag" begin
    rng = MersenneTwister(2); n = 3 * 365
    d = (date = days("2020-01-01", "2022-12-30"), A = gbm(rng, n, 100, 5e-4, 0.015), B = gbm(rng, n, 100, 0, 0.003))
    st = create_strategy(A = asset_config("etf"; share = 0.5, spread = 0), B = asset_config("etf"; share = 0.5, spread = 0))
    r3 = simulation(d, st; dca = dca_plan(100, 1; days = 2), costs = sim_costs(10, 0))
    @test r3.fees_paid == 20            # nur die beiden Erstkäufe am Starttag
    @test occursin("unbekannte oder unbenannte Felder (fix)", errmsg(() -> sim_costs(; order_fee = (fix = 5,))))
    _, w = with_warnings(() -> tax_profile(; church_tax = 0.09))
    @test any(occursin("tax_profile: church_tax = 0.09 wird als 0.09 % gelesen (Prozent-Konvention)", x) for x in w)
    @test errmsg(() -> harvest_rule("12-31")) ==
          "harvest_rule: day im Format 'MM-TT' und vor dem 31.12. angeben (z. B. '12-15')."
    # Kirchensteuer: Abgeltungsteuer 25 % / (1 + 0,25 k) × (1 + 5,5 % + k)
    lin = (date = days("2022-01-03", "2022-07-21"), A = collect(range(100, 150; length = 200)))
    s0 = create_strategy(A = asset_config("certificate"; spread = 0))
    rk = simulation(lin, s0; tax = tax_profile(; church_tax = 9, sparer_pauschbetrag = 0), liquidate = true)
    @test appr(rk.tax_report["total_taxes_paid"], 5000 * 0.25 / (1 + 0.25 * 0.09) * (1 + 0.055 + 0.09))
end

@testset "Engine: Einkommensteuertarif (taxable_income)" begin
    r = p23(tax = tax_profile(; church_tax = 9, income = income_tariff(74000)))
    ty = r.tax_report["tariff_years"]
    @test ty["year"] == [2020, 2021]
    @test appr(ty["church_tax_paid_deductible"][2], 94.5) && appr(ty["deduction_effect"][2], -43.6)
    @test appr(ty["settlement"][1], 1221.13) && appr(ty["settlement"][2], -43.6)
    @test appr(r.tax_report["total_taxes_paid"], 1221.13 - 43.6)
    @test appr(r.worth[end], 12500 - 1221.13 + 43.6)
    @test appr(p23(tax = tax_profile(; income = income_tariff(50000))).tax_report["total_taxes_paid"], T_est(52500) - T_est(50000))
    @test appr(p23(tax = tax_profile(; income = income_tariff(72469))).tax_report["total_taxes_paid"], 1050.11)
    @test p23(p2 = 119.98, tax = tax_profile(; income = income_tariff(50000))).tax_report["total_taxes_paid"] == 0
    ti(x) = tax_profile(; income = income_tariff(x))
    d1 = p23(tax = ti(74000)).tax_report["total_taxes_paid"]
    @test p23(tax = ti(["2020" => 74000, "2021" => 1])).tax_report["total_taxes_paid"] == d1
    @test p23(tax = ti(RVector([74000.0, 1.0]; names = ["2020", "2021"]))).tax_report["total_taxes_paid"] == d1
    @test p23(tax = ti(RFrame("year" => [2020, 2021], "taxable_income" => [74000.0, 74000.0]))).tax_report["total_taxes_paid"] == d1
    @test occursin("taxable_income fehlt für Simulationsjahr 2021", errmsg(() -> p23(tax = ti(["2020" => 74000]))))
    @test startswith(errmsg(() -> ti([1, 2])), "income_tariff: taxable_income mit 2 Werten muss nach Kalenderjahren benannt sein")
    @test occursin("Name 'x' ist kein Kalenderjahr", errmsg(() -> ti(["2020" => 1, "x" => 2])))
    @test occursin("ungültigen Wert", errmsg(() -> ti(NA)))
    @test occursin("taxable_income muss eine Zahl", errmsg(() -> ti("50000")))
    @test errmsg(() -> income_tariff()) ==
          "income_tariff: taxable_income (zu versteuerndes Einkommen in EUR je Kalenderjahr ohne die Erträge der Simulation) fehlt."
    # Günstigerprüfung: Erstattung am Abrechnungstag im Endwert
    gpt(; gp_ = false) = tax_profile(; income = income_tariff(10000), guenstigerpruefung = gp_)
    g = gp(tax = gpt(gp_ = true))
    ty = g.tax_report["tariff_years"]
    @test ty["capital_income"][1] == 3000 && appr(ty["abgeltung_burden"][1], 791.25) && ty["tariff_burden"][1] == 95
    @test ty["guenstiger"][1] && appr(ty["refund"][1], 696.25) && appr(g.tax_report["total_taxes_paid"], 95)
    @test appr(g.worth[end], 24000 - 95)
    g0 = gp(tax = gpt())
    @test appr(g0.tax_report["total_taxes_paid"], 791.25) && isna_strict(g0.tax_report["tariff_years"]["tariff_burden"][1])
    @test appr(gp(stop = "2020-12-30", tax = gpt(gp_ = true)).worth[end], 24000 - 95)
    tt = SL.tax_tariff()
    @test r_class(tt) == ["SimLevTaxTariff"] && tt["soli"]["satz"] == 5.5
    @test SL._tariff_income_tax(tt, 76500.0) == T_est(76500)
    @test occursin("Einkommensteuertarif (SimLev)\n  Geltung: ab VZ 2026", sprint(show, MIME"text/plain"(), tt))
    @test occursin("nicht gefunden", errmsg(() -> SL.tax_tariff("/nicht/da.csv")))
end

@testset "Engine: Vorabpauschale, Fondsmodus, Splits" begin
    d = (date = days("2020-01-01", "2022-12-30"), A = fill(100.0, 1095))
    r = simulation(d, st1(); funds = funds_costs(10, 0))
    v = 10000.0; v -= 366 * (0.1 / 366) * v; v -= 365 * (0.1 / 365) * v; v -= 364 * (0.1 / 365) * v
    @test appr(r.worth[end], v)
    lin = (date = days("2022-01-03", "2022-07-21"), A = collect(range(100, 150; length = 200)))
    rv = simulation(lin, create_strategy(A = asset_config("etf"; spread = 0, partial_exemption = 30));
                    tax = tax_profile(25; sparer_pauschbetrag = 0), liquidate = true)
    @test appr(rv.tax_report["total_taxes_paid"], 5000 * 0.7 * 0.25)
    rng = MersenneTwister(3); n = 3 * 365
    ds = (date = days("2020-01-01", "2022-12-30"), A = gbm(rng, n, 100, 2e-3, 0.01))
    i = findfirst(>(250), ds.A)
    a = simulation(ds, st1(); fractions = false)
    b = simulation(ds, st1(); fractions = false, splits = split_rule([20, 250]))
    @test isapprox(b.worth[i], a.worth[i]; rtol = 1e-12)
end

@testset "Trigger" begin
    df = (date = days("2020-01-01", "2020-01-10"), target_leverage = [2.00, 2.05, 2.30, 2.28, 1.95, 1.90, 2.40, 2.42, 2.10, 2.00],
          sigma_ewma = [0.10, 0.11, 0.16, 0.15, 0.10, 0.10, 0.20, 0.22, 0.14, 0.12])
    df = rebalance_trigger(df, "abs_leverage"; threshold = 10, out_col = "a")
    df = rebalance_trigger(df, "vol_band"; threshold = 20, out_col = "v")
    df = rebalance_trigger(df, "combined"; triggers = [(type = "abs_leverage", threshold = 10), (type = "vol_band", threshold = 20)],
                               out_col = "c")
    T, F = true, false
    @test df.a == [F, F, T, F, T, F, T, F, T, T]
    @test df.v == [F, F, T, F, T, F, T, F, T, F]
    @test df.c == [F, F, T, F, T, F, T, F, T, T]
    @test rebalance_trigger((date = df.date[1:4], target_leverage = [NA, NA, 2.0, 2.3]), "abs_leverage").rebal_trigger == [F, F, F, T]
    @test errmsg(() -> rebalance_trigger(df, "nope")) == "Unbekannter type='nope'."
    rf = rebalance_trigger(RFrame("x" => [1.0, 2.0], "target_leverage" => [1.0, 2.0]), "abs_leverage")
    @test rf isa RFrame && rf["rebal_trigger"] == [F, T]
end

@testset "Dashboards" begin
    n = 400
    d = (date = days("2022-01-03", "2023-02-06"), A = collect(range(100, 130; length = n)), B = collect(range(100, 110; length = n)))
    r = simulation(d, create_strategy(A = asset_config("etf", "bnh", 0.6, 0, 30), B = asset_config("etf", "bnh", 0.4, 0, 0)))
    dsh = plot_dashboard(r)
    @test dsh isa SimLevPlot && occursin("Monatsrenditen (%)", dsh.svg) && occursin("Kennzahlen", dsh.svg)
    @test occursin("Strategievergleich", plot_dashboard(r; compare = r).svg)
    @test !occursin("Rollierende", plot_dashboard(r; style = "compact").svg)
    @test occursin("unbekannte(s) Panel(s) \"xy\"", errmsg(() -> plot_dashboard(r; style = "custom", panels = ["xy"])))
    @test occursin("unbekannte Farbe(n) 'foo'", errmsg(() -> plot_dashboard(r; colors = (foo = "red",))))
    @test r_plot(r; style = "compact") isa SimLevPlot
    # data: Schlüssel, Spalten und Werte wie die Datenfunktionen (Python liefert dieselben)
    cols = Dict("performance" => ["date", "strategy"], "drawdown" => ["date", "drawdown"], "distribution" => ["return"],
                "rolling" => ["date", "return_pct"], "monthly" => ["year", "month", "return_pct"],
                "stats" => ["section", "label", "value"], "correlation" => ["date", "correlation"],
                "comparison" => ["label", "value", "compare", "diff"])
    @test collect(keys(dsh.data)) == ["performance", "drawdown", "distribution", "rolling", "monthly", "stats"]
    @test dsh.kind == "SimLevResult" && dsh.source === r
    @test sprint(show, dsh) == "SimLevPlot(SimLevResult, SVG, $(sizeof(dsh.svg)) Bytes, Panels: performance, drawdown, distribution, rolling, monthly, stats)"
    @test sprint(show, MIME"image/svg+xml"(), dsh) == dsh.svg && startswith(dsh.svg, "<svg")
    pc = plot_dashboard(r; compare = r)
    @test collect(keys(pc.data)) == ["performance", "drawdown", "distribution", "rolling", "monthly", "stats", "correlation", "comparison"]
    for (k, df) in pc.data
        @test df isa RFrame && names(df) == (k == "performance" ? [cols[k]; "compare"] : cols[k])
    end
    bits(v) = reinterpret(UInt64, collect(Float64, v))
    D = pc.data
    @test D["performance"]["date"] == r.dates && bits(D["performance"]["strategy"]) == bits(r.worth)
    @test bits(D["drawdown"]["drawdown"]) == bits(r.drawdowns)
    @test bits(D["distribution"]["return"]) == bits(SL._dashboard_returns(r).returns)
    rr = SL._rolling_returns(r)
    @test bits(D["rolling"]["return_pct"]) == bits(rr.values) && D["rolling"]["date"] == r.dates[rr.idx]
    yrs, mat = SL._monthly_matrix(r)
    cells = [(i, j) for i in 1:length(yrs), j in 1:12 if !isnan(mat[i, j])]
    sort!(cells)
    @test D["monthly"]["year"] == [parse(Int, yrs[i]) for (i, _) in cells] && D["monthly"]["month"] == [j for (_, j) in cells]
    @test bits(D["monthly"]["return_pct"]) == bits([mat[i, j] for (i, j) in cells])
    secs = SL._stats_sections(r, r)
    @test D["stats"]["section"] == [s for (s, ls) in secs for _ in ls]
    @test [a * ": " * b for (a, b) in zip(D["stats"]["label"], D["stats"]["value"])] == [v for (_, ls) in secs for v in ls]
    cr = SL._correlation(r, r)
    @test D["correlation"]["date"] == cr.dates && bits(D["correlation"]["correlation"]) == bits(cr.rho)
    rows = SL._comparison_rows(r, r)
    @test D["comparison"]["label"] == [z.metric for z in rows] && D["comparison"]["diff"] == [z.diff for z in rows]
    @test D["comparison"]["value"] == [z.v1 for z in rows] && D["comparison"]["compare"] == [z.v2 for z in rows]
    rs = simulation((date = d.date[1:3], A = d.A[1:3], B = d.B[1:3]), create_strategy(A = asset_config("etf", "bnh", 1, 0, 0)); io = devnull)
    ps = plot_dashboard(rs)
    @test occursin("Zu wenige Daten", ps.svg) && names(ps.data["distribution"]) == ["return"] && nrow(ps.data["distribution"]) == 0
    pn = with_logger(NullLogger()) do
        plot_dashboard(r; style = "custom", panels = "comparison")
    end
    @test isempty(pn.data) && occursin("Keine zeichenbaren Panels:", pn.svg)
    secs = SL._stats_sections(r)
    @test secs[1].first == "Rendite" && startswith(secs[1].second[1], "CAGR: +")
    g = tempname() * ".svg"
    quiet(() -> export_dashboard(r, g))
    @test filesize(g) > 1000
end

@testset "Bitgleichheit zu R (Golden Master, strikt)" begin
    root = SimLev.REnv.golden_dir(joinpath(@__DIR__, "..", "..", "golden"))
    @test isdir(joinpath(root, "cases"))
    for dir in ("cases", "extra")
        path = joinpath(root, dir)
        isdir(path) || continue
        for f in sort(readdir(path))
            endswith(f, ".json.gz") || continue
            errs = run_case(joinpath(path, f); strict_na = Sys.islinux())
            isempty(errs) || @info "Abweichung in $f" errs
            @test isempty(errs)
        end
    end
end
