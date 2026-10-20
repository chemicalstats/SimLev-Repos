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
function p23(; p2 = 150.0, stop = "2021-03-31", kw...)
    d = days("2020-01-01", stop)
    df = (date = d, G = [x < Date(2020, 6, 1) ? 100.0 : p2 for x in d], H = fill(50.0, length(d)),
          ev = [x == Date(2020, 7, 1) for x in d], wG = zeros(length(d)), wH = ones(length(d)))
    st = create_strategy(G = asset_config("etc", "bnh"; asset_share = 0.5, asset_spread = 0, deliverable = true),
                         H = asset_config("certificate", "bnh"; asset_share = 0.5, asset_spread = 0))
    quiet(() -> simulation(df, st; start_value = 1e4, tax_mode = "person", event_col = "ev", event_mode = "replace",
                           event_weight = ["G" => "wG", "H" => "wH"], kw...))
end
# Zertifikat Z (§ 20): 200 Stück zu 50, am 1.7.2020 zu pz nach M umgeschichtet
function gp(; stop = "2021-03-31", pz = 70.0, kw...)
    d = days("2020-01-01", stop)
    df = (date = d, Z = [x < Date(2020, 6, 1) ? 50.0 : pz for x in d], M = fill(100.0, length(d)),
          ev = [x == Date(2020, 7, 1) for x in d], wZ = zeros(length(d)), wM = ones(length(d)))
    st = create_strategy(Z = asset_config("certificate", "bnh"; asset_share = 0.5, asset_spread = 0),
                         M = asset_config("certificate", "bnh"; asset_share = 0.5, asset_spread = 0))
    quiet(() -> simulation(df, st; start_value = 2e4, tax_mode = "person", event_col = "ev", event_mode = "replace",
                           event_weight = ["Z" => "wZ", "M" => "wM"], kw...))
end
gbm(rng, n, s0, mu, sig) = s0 .* cumprod(1 .+ mu .+ sig .* randn(rng, n))
st1(; kw...) = create_strategy(A = asset_config("etf"; asset_share = 1, asset_spread = 0, kw...))

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
    cfg = asset_config("etf"; asset_share = 0.7, asset_bonus = 30)
    @test cfg isa AssetConfig && r_class(cfg) == ["asset_config", "list"]
    @test cfg.asset_class == "etf" && cfg["asset_share"] == 0.7 && cfg.tax_regime == "investment_fund"
    @test collect(keys(cfg)) == ["asset_class", "action_type", "asset_share", "asset_spread", "asset_bonus",
                                 "deliverable", "asset_start", "tax_regime", "signal_buy", "signal_sell"]
    @test asset_config("etc"; deliverable = true).tax_regime == "private_sale"
    @test asset_config("etf", "bnh", 0.5, 0.1, 30).asset_bonus == 30
    c, w = with_warnings(() -> asset_config("etn_deliverable"))
    @test c.asset_class == "etn" && c.deliverable == true && occursin("veraltet", w[1])
    @test occursin("asset_share muss ein Anteil größer 0", errmsg(() -> asset_config(; asset_share = 50)))
    @test errmsg(() -> asset_config("xx")) == "'arg' should be one of “etf”, “etn”, “etc”, “certificate”, “etn_standard”, “etn_deliverable”"
    @test asset_config(; asset_start = "2020-02-01").asset_start == Date(2020, 2, 1)
    s = create_strategy(A = asset_config("etf"; asset_share = 0.6), B = asset_config("etf"; asset_share = 0.4))
    @test s isa Strategy && collect(keys(s)) == ["A", "B"]
    @test sprint(show, MIME"text/plain"(), s) == "Anlagestrategie (2 Assets)\n================================\n\nA:\n  Klasse: etf | Anteil: 60% | Steuer: investment_fund\nB:\n  Klasse: etf | Anteil: 40% | Steuer: investment_fund\n"
    @test occursin("mehrfach", errmsg(() -> create_strategy("A" => asset_config(), "A" => asset_config())))
    @test validate_strategy(s, (date = [Date(2020)], A = [1.0], B = [1.0]))
    s2 = update_asset(s, "A"; asset_class = "etc", deliverable = true)
    @test s2.A.tax_regime == "private_sale"
    @test length(remove_asset(s, "A")) == 1
    m = quiet(() -> migrate_strategy(["X" => (asset_class = "etn_standard", action_type = "bnh", asset_share = 1)]))
    @test m.X.asset_class == "etn" && m.X.deliverable == false
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
    rp = simulation(d, st1(); tax_mode = "person", order_fee = 5, harvest_mode = true)
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
    @test occursin("summieren sich auf 0.9000", errmsg(() -> simulation(d, create_strategy(A = asset_config(; asset_share = 0.9)))))
    @test occursin("Kursspalte 'B' fehlt in 'data'", errmsg(() -> simulation(d, create_strategy(B = asset_config()))))
    dup = (date = [Date(2020, 1, 1); days("2020-01-01", "2020-01-05")], A = collect(101.0:106.0))
    @test occursin("mehrfach vor (1 doppelte Zeilen)", errmsg(() -> simulation(dup, st1())))
    _, w = with_warnings(() -> simulation(d, st1(); funds_fee = 1))
    @test w == ["simulation: funds_fee wirkt nur bei tax_mode = \"funds\" (hier tax_mode = \"none\") und wird ignoriert."]
    _, w = with_warnings(() -> simulation(d, st1(); funds_fee = 1, church_tax = 9))   # given bleibt erhalten
    @test w == ["simulation: funds_fee wirkt nur bei tax_mode = \"funds\" (hier tax_mode = \"none\") und wird ignoriert."]
    io = IOBuffer(); simulation(d, st1(); tax_mode = "person", details = true, io = io, liquidate = true)
    @test occursin("Kauf", String(take!(io)))
    d30 = (date = days("2000-01-01", "2029-12-31"), A = gbm(MersenneTwister(2), 10958, 100, 3e-4, 0.01))
    run30() = simulation(d30, st1(); dca_mode = true, dca_value = 100, dca_span = 1, balance_mode = true, tax_mode = "person", base_rate = 2)
    run30()
    @test (@elapsed run30()) < 2          # 30 Jahre täglich (R: mehrere Sekunden)
end

@testset "Engine: Gebühren, Kirchensteuer, Freibetrag" begin
    rng = MersenneTwister(2); n = 3 * 365
    d = (date = days("2020-01-01", "2022-12-30"), A = gbm(rng, n, 100, 5e-4, 0.015), B = gbm(rng, n, 100, 0, 0.003))
    st = create_strategy(A = asset_config("etf"; asset_share = 0.5, asset_spread = 0), B = asset_config("etf"; asset_share = 0.5, asset_spread = 0))
    r3 = simulation(d, st; dca_mode = true, dca_value = 100, dca_span = 1, dca_days = 2, order_fee = 10, dca_fee = 0)
    @test r3.fees_paid == 20            # nur die beiden Erstkäufe am Starttag
    @test occursin("unbekannte oder unbenannte Felder (fix)", errmsg(() -> simulation(d, st; order_fee = (fix = 5,))))
    _, w = with_warnings(() -> simulation(d, st; church_tax = 0.09))
    @test any(occursin("Prozent-Konvention", x) for x in w)
    _, w = with_warnings(() -> simulation(d, st; harvest_mode = true))
    @test any(occursin("harvest_mode wirkt nur", x) for x in w)
    @test errmsg(() -> simulation(d, st; tax_mode = "person", harvest_mode = true, harvest_day = "12-31")) ==
          "harvest_day im Format 'MM-TT' und vor dem 31.12. angeben (z. B. '12-15')."
    # Kirchensteuer: Abgeltungsteuer 25 % / (1 + 0,25 k) × (1 + 5,5 % + k)
    lin = (date = days("2022-01-03", "2022-07-21"), A = collect(range(100, 150; length = 200)))
    s0 = create_strategy(A = asset_config("certificate"; asset_spread = 0))
    rk = simulation(lin, s0; tax_mode = "person", church_tax = 9, use_sparer_pauschbetrag = false, liquidate = true)
    @test appr(rk.tax_report["total_taxes_paid"], 5000 * 0.25 / (1 + 0.25 * 0.09) * (1 + 0.055 + 0.09))
end

@testset "Engine: Einkommensteuertarif (taxable_income)" begin
    r = p23(taxable_income = 74000, church_tax = 9)
    ty = r.tax_report["tariff_years"]
    @test ty["year"] == [2020, 2021]
    @test appr(ty["church_tax_paid_deductible"][2], 94.5) && appr(ty["deduction_effect"][2], -43.6)
    @test appr(ty["settlement"][1], 1221.13) && appr(ty["settlement"][2], -43.6)
    @test appr(r.tax_report["total_taxes_paid"], 1221.13 - 43.6)
    @test appr(r.worth[end], 12500 - 1221.13 + 43.6)
    @test appr(p23(taxable_income = 50000).tax_report["total_taxes_paid"], T_est(52500) - T_est(50000))
    @test appr(p23(taxable_income = 72469).tax_report["total_taxes_paid"], 1050.11)
    @test p23(p2 = 119.98, taxable_income = 50000).tax_report["total_taxes_paid"] == 0
    d1 = p23(taxable_income = 74000).tax_report["total_taxes_paid"]
    @test p23(taxable_income = ["2020" => 74000, "2021" => 1]).tax_report["total_taxes_paid"] == d1
    @test p23(taxable_income = RVector([74000.0, 1.0]; names = ["2020", "2021"])).tax_report["total_taxes_paid"] == d1
    @test p23(taxable_income = RFrame("year" => [2020, 2021], "taxable_income" => [74000.0, 74000.0])).tax_report["total_taxes_paid"] == d1
    @test occursin("taxable_income fehlt für Simulationsjahr 2021", errmsg(() -> p23(taxable_income = ["2020" => 74000])))
    @test occursin("muss nach Kalenderjahren benannt sein", errmsg(() -> p23(taxable_income = [1, 2])))
    @test occursin("Name 'x' ist kein Kalenderjahr", errmsg(() -> p23(taxable_income = ["2020" => 1, "x" => 2])))
    @test occursin("ungültigen Wert", errmsg(() -> p23(taxable_income = NA)))
    @test occursin("taxable_income muss eine Zahl", errmsg(() -> p23(taxable_income = "50000")))
    # Günstigerprüfung: Erstattung am Abrechnungstag im Endwert
    g = gp(taxable_income = 10000, use_guenstigerpruefung = true)
    ty = g.tax_report["tariff_years"]
    @test ty["capital_income"][1] == 3000 && appr(ty["abgeltung_burden"][1], 791.25) && ty["tariff_burden"][1] == 95
    @test ty["guenstiger"][1] && appr(ty["refund"][1], 696.25) && appr(g.tax_report["total_taxes_paid"], 95)
    @test appr(g.worth[end], 24000 - 95)
    g0 = gp(taxable_income = 10000)
    @test appr(g0.tax_report["total_taxes_paid"], 791.25) && isna_strict(g0.tax_report["tariff_years"]["tariff_burden"][1])
    @test appr(gp(stop = "2020-12-30", taxable_income = 10000, use_guenstigerpruefung = true).worth[end], 24000 - 95)
    tt = SL.read_tax_tariff()
    @test r_class(tt) == ["SimLevTaxTariff"] && tt["soli"]["satz"] == 5.5
    @test SL._tariff_income_tax(tt, 76500.0) == T_est(76500)
    @test occursin("Einkommensteuertarif (SimLev)\n  Geltung: ab VZ 2026", sprint(show, MIME"text/plain"(), tt))
    @test occursin("nicht gefunden", errmsg(() -> SL.read_tax_tariff("/nicht/da.csv")))
end

@testset "Engine: Vorabpauschale, Fondsmodus, Splits" begin
    d = (date = days("2020-01-01", "2022-12-30"), A = fill(100.0, 1095))
    r = simulation(d, st1(); tax_mode = "funds", funds_fee = 10, bonus_fee = 0)
    v = 10000.0; v -= 366 * (0.1 / 366) * v; v -= 365 * (0.1 / 365) * v; v -= 364 * (0.1 / 365) * v
    @test appr(r.worth[end], v)
    lin = (date = days("2022-01-03", "2022-07-21"), A = collect(range(100, 150; length = 200)))
    rv = simulation(lin, create_strategy(A = asset_config("etf"; asset_spread = 0, asset_bonus = 30)); tax_mode = "person",
                    tax_rate = 25, use_sparer_pauschbetrag = false, liquidate = true)
    @test appr(rv.tax_report["total_taxes_paid"], 5000 * 0.7 * 0.25)
    rng = MersenneTwister(3); n = 3 * 365
    ds = (date = days("2020-01-01", "2022-12-30"), A = gbm(rng, n, 100, 2e-3, 0.01))
    i = findfirst(>(250), ds.A)
    a = simulation(ds, st1(); fractions = false)
    b = simulation(ds, st1(); fractions = false, split_mode = true, split_thresh = [20, 250])
    @test isapprox(b.worth[i], a.worth[i]; rtol = 1e-12)
end

@testset "Trigger" begin
    df = (date = days("2020-01-01", "2020-01-10"), target_leverage = [2.00, 2.05, 2.30, 2.28, 1.95, 1.90, 2.40, 2.42, 2.10, 2.00],
          sigma_ewma = [0.10, 0.11, 0.16, 0.15, 0.10, 0.10, 0.20, 0.22, 0.14, 0.12])
    df = compute_rebal_trigger(df, "abs_leverage"; threshold = 10, out_col = "a")
    df = compute_rebal_trigger(df, "vol_band"; threshold = 20, out_col = "v")
    df = compute_rebal_trigger(df, "combined"; triggers = [(type = "abs_leverage", threshold = 10), (type = "vol_band", threshold = 20)],
                               out_col = "c")
    T, F = true, false
    @test df.a == [F, F, T, F, T, F, T, F, T, T]
    @test df.v == [F, F, T, F, T, F, T, F, T, F]
    @test df.c == [F, F, T, F, T, F, T, F, T, T]
    @test compute_rebal_trigger((date = df.date[1:4], target_leverage = [NA, NA, 2.0, 2.3]), "abs_leverage").rebal_trigger == [F, F, F, T]
    @test errmsg(() -> compute_rebal_trigger(df, "nope")) == "Unbekannter type='nope'."
    rf = compute_rebal_trigger(RFrame("x" => [1.0, 2.0], "target_leverage" => [1.0, 2.0]), "abs_leverage")
    @test rf isa RFrame && rf["rebal_trigger"] == [F, T]
end

@testset "Dashboards" begin
    n = 400
    d = (date = days("2022-01-03", "2023-02-06"), A = collect(range(100, 130; length = n)), B = collect(range(100, 110; length = n)))
    r = simulation(d, create_strategy(A = asset_config("etf", "bnh", 0.6, 0, 30), B = asset_config("etf", "bnh", 0.4, 0, 0)))
    f = tempname() * ".html"
    @test plot_interactive(r; file = f, open = false) == f
    txt = read(f, String)
    @test startswith(txt, "<!DOCTYPE html>") && occursin("makePanel(\"performance\",\"Wertentwicklung des Depots\"", txt)
    plot_interactive(r; file = f, panels = "drawdown", max_points = 100, open = false)
    @test !occursin("id=\"performance\"", read(f, String))
    dsh = plot_dashboard(r)
    @test dsh isa SimLevDashboard && occursin("Monatsrenditen (%)", dsh.svg) && occursin("Kennzahlen", dsh.svg)
    @test occursin("Strategievergleich", plot_dashboard(r; compare = r).svg)
    @test !occursin("Rollierende", plot_dashboard(r; style = "compact").svg)
    @test occursin("unbekannte(s) Panel(s) \"xy\"", errmsg(() -> plot_dashboard(r; style = "custom", panels = ["xy"])))
    @test occursin("unbekannte Farbe(n) 'foo'", errmsg(() -> plot_dashboard(r; colors = (foo = "red",))))
    @test r_plot(r; style = "compact") isa SimLevDashboard
    secs = SL._stats_sections(r)
    @test secs[1].first == "Rendite" && startswith(secs[1].second[1], "CAGR: +")
    g = tempname() * ".svg"
    quiet(() -> export_dashboard(r, g))
    @test filesize(g) > 1000
    @test occursin("plotly", errmsg(() -> export_html_dashboard(r)))
end

@testset "Bitgleichheit zu R (Golden Master, strikt)" begin
    root = get(ENV, "SIMLEV_GOLDEN_DIR", joinpath(@__DIR__, "..", "..", "golden"))
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
