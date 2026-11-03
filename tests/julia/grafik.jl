# grafik_tests.jl (T18): SVG-Grafiken der Julia-Fassung (Dashboard, Grafik-API, Grafiken der Analyse- und
# Erweiterungsmodule mit SimLevPlot.data). R zeichnet mit Basisgrafik, die Referenzfälle tests/faelle
# vergleichen keine Grafiken; die Objekte stammen aber aus den Referenzfällen, damit Python und Julia dieselben
# Eingaben zeichnen (Gegenstück: python/tests/test_dashboard.py, test_output.py, test_plot_*.py).
# Inhalt wörtlich aus engine_tests.jl ("Dashboards") und api_tests.jl ("Grafik-API", "Grafiken der
# Erweiterungsmodule", "Grafiken der Analysemodule") bis 1.4.0.
# Erwartet: `using SimLev`, `using Test, Dates, Logging`.

const SL = SimLev
const _SL = SimLev
quiet(f) = with_logger(NullLogger()) do
    redirect_stderr(devnull) do
        f()
    end
end
errmsg(f) = try
    quiet(f); ""
catch e
    e isa ErrorException ? e.msg : sprint(showerror, e)
end
days(a, b) = collect(Date(a):Day(1):Date(b))
_api_warns(f) = (l = Test.TestLogger(); r = with_logger(f, l); (r, [string(x.message) for x in l.logs if x.level == Logging.Warn]))
_api_err(f) = try f(); "" catch e; e isa ErrorException ? e.msg : sprint(showerror, e) end

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

@testset "Grafik-API" begin
    n = 300
    d = (date = collect(Date(2022, 1, 3):Day(1):Date(2022, 1, 3) + Day(n - 1)),
         A = collect(range(100, 130; length = n)), B = collect(range(100, 110; length = n)))
    r = simulation(d, create_strategy(A = asset_config("etf", "bnh", 0.6, 0, 30), B = asset_config("etf", "bnh", 0.4, 0, 0)); io = devnull)
    dir = mktempdir()
    cd(dir) do
        x, ws = _api_warns(() -> r_plot(r; style = "compact", colour = "red"))
        @test x isa SimLevPlot
        @test ws == ["plot.SimLevResult: unbekanntes Argument 'colour' wird ignoriert (Tippfehler?)."]
        @test isempty(readdir(dir))                       # kein stilles Rplots.svg
        @test r_plot(r; file = "a.svg") isa SimLevPlot
        @test isfile("a.svg")
        @test occursin("nur als SVG", _api_err(() -> r_plot(r; file = "a.png")))
        @test !isfile("a.png")
        @test plot_dashboard(r; file = "b.svg") isa SimLevPlot && isfile("b.svg")
        _, ws = _api_warns(() -> plot_dashboard(r; widht = 3))
        @test ws == ["plot_dashboard: unbekanntes Argument 'widht' wird ignoriert (Tippfehler?)."]
        @test occursin("die Endung '.pdf'", _api_err(() -> export_dashboard(r, "c.pdf")))
        @test !isfile("c.pdf")
        redirect_stderr(devnull) do
            export_dashboard(r; filename = "c.svg")
        end
        @test isfile("c.svg")
        wd = withdrawal_simulation(reshape([1.0 + 0.05 * sin(i) for i in 1:60], 20, 3), withdrawal_rule("constant"); inflation = 2)
        y, ws = _api_warns(() -> r_plot(wd; probz = 1))
        @test y isa SimLevPlot && ws == ["plot.SimLevWithdrawal: unbekanntes Argument 'probz' wird ignoriert (Tippfehler?)."]
        @test r_plot(wd; file = "w.svg") isa SimLevPlot && isfile("w.svg")
        @test y.kind == "SimLevWithdrawal" && y.source === wd && collect(keys(y.data)) == ["wealth", "spending"]
        @test all(names(df) == ["year", "q05", "q25", "q50", "q75", "q95"] for (_, df) in y.data)
        @test y.data["spending"]["year"] == collect(1:size(_SL.Withdrawal._mat(wd["spending"]), 1))
        _, ws = _api_warns(() -> r_plot(r, "compact"; style = "compact"))
        @test ws == ["plot.SimLevResult: 1 zusätzliche(s) Positionsargument(e) wird/werden ignoriert; Optionen bitte als Schlüsselwort angeben."]
        @test occursin("plot.SimLevResult: Grafiken werden nur als SVG gespeichert; 'a.png' hat die Endung '.png'.",
                       _api_err(() -> r_plot(r; file = "a.png")))
        @test occursin("plot_dashboard: file muss ein Dateiname (Zeichenkette) sein", _api_err(() -> plot_dashboard(r; file = 3)))
        @test sort(readdir(dir)) == ["a.svg", "b.svg", "c.svg", "w.svg"]
        # Rahmen: Zeichenfunktion liefert (svg, data), String oder SimLevPlot
        f1(x; a = 1, width = 100) = ("<svg>$a $width</svg>", RList("wealth" => RFrame("year" => [1, 2], "q50" => [x, x])))
        f2(x) = "<svg/>"
        f3(x) = SimLevPlot("<svg>o</svg>")
        f4(x) = 42
        m1 = _SL._plot_method(f1, "Dummy")
        p1, ws = _api_warns(() -> m1(3.0; a = 5, b = 1, file = "d.svg"))
        @test ws == ["plot.Dummy: unbekanntes Argument 'b' wird ignoriert (Tippfehler?)."]
        @test p1.svg == "<svg>5 100</svg>" && p1.kind == "Dummy" && p1.source == 3.0 && read("d.svg", String) == p1.svg
        @test collect(keys(p1.data)) == ["wealth"] && p1.data["wealth"] isa RFrame
        @test sprint(show, p1) == "SimLevPlot(Dummy, SVG, 16 Bytes, Panels: wealth)"
        m1b = _SL._plot_method((x; kw...) -> ("<svg/>", ["a" => (v = [1.0],)]), "Pairs")
        @test m1b(1).data["a"] isa RFrame
        p2 = _SL._plot_method(f2, "S")(:src)
        @test p2.svg == "<svg/>" && isempty(p2.data) && p2.kind == "S" && p2.source === :src
        @test sprint(show, p2) == "SimLevPlot(S, SVG, 6 Bytes)"
        p3 = _SL._plot_method(f3, "O")(1)
        @test p3.svg == "<svg>o</svg>" && p3.kind == "O" && p3.source == 1
        @test occursin("plot.B: die Grafikmethode lieferte kein SVG (sondern Int64).", _api_err(() -> _SL._plot_method(f4, "B")(1)))
        rm("d.svg")
    end
    # alle registrierten plot-Methoden laufen über die gemeinsame Hülle
    for (cls, f) in _SL._PLOTS
        ok = occursin("_plot_method", string(nameof(typeof(f))))
        ok || println("API: plot-Methode für $cls ohne _plot_method")
        @test ok
    end
end

# Grafiken der Erweiterungsmodule: SimLevPlot mit data (Schlüssel/Spalten wie Python, Werte aus dem Objekt).
# Objekte aus den Referenzfällen (Julia-Code der Fälle), damit Python und Julia dieselben Eingaben zeichnen.
function _plot_case_obj(case, var = "result")
    c = Base.invokelatest(fall, case)
    m = Module(:PlotCase)
    Core.eval(m, :(using SimLev, Dates))
    Core.eval(m, :(const SL = SimLev))
    inp = get(c, "inputs", nothing)
    if inp !== nothing
        for (k, v) in pairs(inp)
            Core.eval(m, :($(Symbol(k)) = $(QuoteNode(Base.invokelatest(decode, v)))))
        end
    end
    with_logger(NullLogger()) do
        redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                Base.include_string(m, c["jl"], "jl:" * case)
            end
        end
    end
    return Base.invokelatest(getglobal, m, Symbol(var))
end
_bits(v) = reinterpret.(Int64, Float64.(collect(v)))

@testset "Grafiken der Erweiterungsmodule (SVG, data)" begin
    Q = ["year", "q05", "q25", "q50", "q75", "q95"]
    cases = [
        ("SimLevOptimization", "optimize/po4_min_variance", (;), ["weights" => ["asset", "weight", "risk_share"]],
         ["Gewichte und Risikoanteile (min_variance)", "Risikoanteil"]),
        ("SimLevFrontier", "optimize/ef_default", (;), ["frontier" => ["volatility", "expected_return"],
         "assets" => ["asset", "volatility", "expected_return"], "max_sharpe" => ["volatility", "expected_return"]],
         ["Effizienzgrenze", "Volatilität (% p. a.)"]),
        ("SimLevPBO", "overfitting/pbo_sharpe", (;), ["logits" => ["lambda"], "degradation" => ["is_best", "oos_best"]],
         ["Logits (PBO ", "Leistungsabfall", "sharpe In-Sample (bester Punkt)"]),
        ("SimLevWalkForward", "overfitting/wf_basic", (;), ["growth" => ["date", "walk_forward", "hindsight", "average"]],
         ["Walk-Forward Out-of-Sample", "Rückschau-Bester"]),
        ("SimLevParamSearch", "param_search/ps_grid", (;), ["heatmap" => ["x", "y", "value"]], ["sharpe (blau = hoch)"]),
        ("SimLevParamSearch", "param_search/ps_grid", (params = ["n"],), ["profile" => ["x", "value"]], ["sharpe nach n"]),
        ("SimLevParamSearch", "param_search/ps_random:x", (;), ["scatter" => ["x", "y", "value"]], ["sharpe (Farbe; blau = hoch)"]),
        ("SimLevGoalPlan", "planning/go_ex", (;), ["policy" => ["period", "wealth", "choice", "candidate"]],
         ["Optimale Wahl je Zeit und Vermögen"]),
        ("SimLevHMM", "regimes/hmm_week", (;), ["filtered" => ["date", "probability"]],
         ["Gefilterte Wahrscheinlichkeit des unruhigsten Zustands (Z2)"]),
        ("SimLevSensitivity", "sensitivity/lvs_basic", (;), ["leverage" => ["leverage", "value"]], ["cagr nach Hebel"]),
        ("SimLevSensitivity", "sensitivity/rs_bands", (;), ["variants" => ["label", "value"]], ["Rebalancing-Varianten: cagr"]),
        ("SimLevWeights", "tactical/bl_basic", (;), ["weights" => ["date", "A", "C", "B", "CASH"]], ["Zielgewichte", "Gewicht"]),
        ("SimLevWithdrawal", "withdrawal/ws_constant", (;), ["wealth" => Q, "spending" => Q], ["Reales Vermögen", "Realer Konsum je Jahr"]),
        ("SimLevWithdrawal", "withdrawal/ws_gamma1", (;), ["spending" => Q], ["Realer Konsum je Jahr"]),
    ]
    for (cls, case, kw, cols, texts) in cases
        parts = split(case, ":")
        x = _plot_case_obj(parts[1], length(parts) > 1 ? parts[2] : "result")
        p, ws = _api_warns(() -> r_plot(x; kw...))
        @test isempty(ws)
        @test p isa SimLevPlot && p.kind == cls && p.source === x
        @test startswith(p.svg, "<svg") && endswith(p.svg, "</svg>\n")
        @test [k => names(df) for (k, df) in p.data] == cols
        @test all(t -> occursin(t, p.svg), texts)
    end
    # Werte unskaliert wie im Objekt
    o = _plot_case_obj("optimize/po4_min_variance")
    d = r_plot(o).data["weights"]
    @test _bits(d["weight"]) == _bits(o["risk"]["weight"]) && _bits(d["risk_share"]) == _bits(o["risk"]["risk_share"])
    @test occursin("width=\"800\" height=\"500\"", r_plot(o; width = 800, height = 500).svg)
    h = _plot_case_obj("regimes/hmm_week")
    f = r_plot(h).data["filtered"]
    @test _bits(f["probability"]) == _bits(_SL.Regimes._fmat(h["filtered"])[:, Int(h["k"])]) && eltype(f["date"]) == Date
    ws_ = _plot_case_obj("withdrawal/ws_constant")
    p2 = r_plot(ws_; probs = [0.1, 0.5, 0.9])
    @test names(p2.data["wealth"]) == ["year", "q10", "q50", "q90"] && eltype(p2.data["wealth"]["year"]) == Int
    @test _bits(p2.data["wealth"]["q50"]) == _bits(r_plot(ws_).data["wealth"]["q50"])
    lv = _plot_case_obj("sensitivity/lvs_basic")
    @test _bits(r_plot(lv; metric = "sharpe").data["leverage"]["value"]) == _bits(lv["sharpe"])
    @test _bits(r_plot(lv).data["leverage"]["value"]) == _bits(lv["cagr"])        # Anteil, nicht ×100
    g = _plot_case_obj("planning/go_ex")
    pd_ = r_plot(g).data["policy"]
    @test eltype(pd_["choice"]) == Int && eltype(pd_["period"]) == Int
    # wie R plot(x, data = NULL): data wird angenommen und nicht verwendet (keine Warnung)
    _, ws = _api_warns(() -> r_plot(h; data = nothing))
    @test isempty(ws)
    @test occursin("plot.SimLevPBO: Grafiken werden nur als SVG gespeichert; 'p.png' hat die Endung '.png'.",
                   _api_err(() -> r_plot(_plot_case_obj("overfitting/pbo_sharpe"); file = "p.png")))
end

# Grafiken der Analysemodule (analysis_tests, backcast, bootstrap, deep_analysis, dependence): wie Python.
@testset "Grafiken der Analysemodule (SVG, data)" begin
    DA4 = ["growth" => ["series", "date", "growth"], "drawdown" => ["series", "date", "drawdown"],
           "rolling" => ["series", "date", "cagr"], "annual" => ["year", "al", "raw"]]
    cases = [
        ("SimLevSignalAnalysis", "analysis_tests/sa_basic", (;),
         ["bins" => ["bin", "mean", "lower", "upper"], "scatter" => ["signal", "forward", "fitted"]],
         ["Je Signalbereich", "Mittlere Vorwärtsrendite (%)", "Streudiagramm", ">mom</text>"]),
        ("SimLevSignalAnalysis", "analysis_tests/sa_binary", (;),
         ["bins" => ["bin", "mean", "lower", "upper"], "scatter" => ["signal", "forward"]], ["Je Signalbereich"]),
        ("SimLevHeatmap", "analysis_tests/hm_sim", (;), ["heatmap" => ["start_year", "years", "value"]],
         ["Annualisierte reale Rendite", "Haltedauer (Jahre)", "+25 %"]),
        ("SimLevBackcastFit", "backcast/bf_basic", (;), ["deviation" => ["date", "deviation"]],
         ["Pfadabweichung im Fit-Fenster", "1 - Sim/Produkt (%)"]),
        ("SimLevBackcastFit", "backcast/bf_grid", (;), ["deviation" => ["date", "deviation"], "grid" => ["value", "loss"]],
         ["Gittersuche", "drag (% p. a.)", "height=\"720\""]),
        ("SimLevBackcast", "backcast/bc_fit", (;), ["backcast" => ["date", "value", "model", "source"]],
         ["Backcast und Produkt", "Wert (log. Skala)", "Modell durchgehend"]),
        ("SimLevBackcast", "backcast/bc_fit", (log = false,), ["backcast" => ["date", "value", "model", "source"]], [">Wert</text>"]),
        ("SimLevBootstrapStudy", "bootstrap/study_basic", (;), ["density" => ["strategy", "x", "density"]],
         ["Verteilung cagr (stationary, 3 Pfade)", "Dichte"]),
        ("SimLevAnalysis", "deep_analysis/da_df_aligned", (;), DA4,
         ["Wertentwicklung (TWR, Start = 1)", "Drawdowns", "Rollierend 1 J.: cagr", "Jahresrenditen"]),
        ("SimLevAnalysis", "deep_analysis/da_df_aligned", (type = "monthly", series = 2),
         ["monthly" => ["year", "month", "return"]], ["Monatsrenditen: raw", "Mär"]),
        ("SimLevAnalysis", "deep_analysis/da_short_series", (type = "rolling",),
         ["rolling" => ["series", "date", "cagr"]], ["Rollierend: Zeitraum zu kurz"]),
        ("SimLevDependence", "dependence/da_breaks", (;),
         ["rolling" => ["date", "rolling", "dcc"], "tail" => ["q", "lower", "upper", "independence"],
          "conditional" => ["regime", "pearson", "pearson_lo", "pearson_hi", "lambda_lower"], "scatter" => ["u", "v"]],
         ["stocks ~ bonds: rollierend (20) und DCC", "stocks ~ bonds: Tail-Abhängigkeit", "Pseudo-Beobachtungen"]),
        ("SimLevDependence", "dependence/da_basic", (type = "conditional",),
         ["conditional" => ["regime", "pearson", "lambda_lower"]], String[]),
        ("SimLevDependence", "dependence/da_warn", (type = "rolling",), ["rolling" => ["date", "rolling"]], String[]),
        ("SimLevTailRegression", "dependence/treg_multi", (;),
         ["inflation" => ["quantile", "estimate", "lower", "upper"], "zins" => ["quantile", "estimate", "lower", "upper"]],
         ["Effekt von inflation", "Quantilsregression"]),
        ("SimLevCoVaR", "dependence/covar_basic", (;), ["delta_covar" => ["asset", "date", "delta_covar"]],
         ["Delta-CoVaR für", "Delta-CoVaR (%)"]),
    ]
    for (cls, case, kw, cols, texts) in cases
        x = _plot_case_obj(case)
        p, ws = _api_warns(() -> r_plot(x; kw...))
        @test isempty(ws)
        @test p isa SimLevPlot && p.kind == cls && p.source === x
        @test startswith(p.svg, "<svg") && endswith(p.svg, "</svg>\n")
        @test [k => names(df) for (k, df) in p.data] == cols
        @test all(t -> occursin(t, p.svg), texts)
    end
    # Werte unskaliert wie im Objekt bzw. wie berechnet
    sa = _plot_case_obj("analysis_tests/sa_basic")
    d = r_plot(sa).data
    m = Float64.(sa["bins"]["mean"]); se = Float64.(sa["bins"]["sd"]) ./ sqrt.(Float64.(sa["bins"]["n"]))
    @test _bits(d["bins"]["mean"]) == _bits(m) && _bits(d["bins"]["lower"]) == _bits(m .- 2 .* se)
    @test _bits(d["scatter"]["forward"]) == _bits(sa["data"]["forward"])
    hm = _plot_case_obj("analysis_tests/hm_sim")
    h = r_plot(hm).data["heatmap"]
    M = hm["matrix"].data
    @test _bits(h["value"]) == _bits([M[i, j] for i in axes(M, 1) for j in axes(M, 2) if isfinite(M[i, j])])
    @test eltype(h["start_year"]) == Int && eltype(h["years"]) == Int
    bf = _plot_case_obj("backcast/bf_grid")
    @test _bits(r_plot(bf).data["deviation"]["deviation"]) == _bits(bf["diagnostics"]["deviation"]["deviation"])
    @test startswith(r_plot(bf; width = 800, height = 300).svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"600\"")
    bl = _plot_case_obj("backcast/bc_lead")
    ok = isfinite.(bl["value"])
    @test _bits(r_plot(bl).data["backcast"]["value"]) == _bits(bl["value"][ok]) && !all(ok)
    st = _plot_case_obj("bootstrap/study_basic")
    @test occursin("width=\"700\"", r_plot(st; metric = "max_drawdown", width = 700).svg)
    @test occursin("bw.nrd0: mindestens 2 Werte nötig", _api_err(() -> r_plot(_plot_case_obj("bootstrap/study_print_paired"))))   # T18: Meldung der C-Bibliothek wie R (.sl_kde)
    da = _plot_case_obj("deep_analysis/da_df_aligned")
    g = r_plot(da).data
    v = da["series"]["al"]["value"]
    @test _bits(g["growth"]["growth"][g["growth"]["series"] .== "al"]) == _bits(v ./ v[1])
    @test _bits(g["drawdown"]["drawdown"][g["drawdown"]["series"] .== "al"]) == _bits(v ./ accumulate(max, v) .- 1)
    @test _bits(g["annual"]["raw"]) == _bits(da["annual"].data[:, 2]) && eltype(g["annual"]["year"]) == Int
    @test _api_err(() -> r_plot(da; type = "monthly", series = 3)) == "series: Name oder Nummer einer Reihe (al, raw)."
    @test _api_err(() -> r_plot(da; metric = "x")) == "metric: 'cagr', 'volatility', 'sharpe', 'max_drawdown', 'beta' oder 'excess_cagr'."
    dp = _plot_case_obj("dependence/da_breaks")
    dd = r_plot(dp).data
    @test _bits(dd["rolling"]["rolling"]) == _bits(dp["rolling"]["stocks ~ bonds"]) && eltype(dd["rolling"]["date"]) == Date
    cv = _plot_case_obj("dependence/covar_basic")
    @test _bits(r_plot(cv).data["delta_covar"]["delta_covar"]) == _bits(cv["series"]["delta_covar"])
    _, ws = _api_warns(() -> r_plot(da; type = "growth", figsize = (3, 4)))
    @test ws == ["plot.SimLevAnalysis: unbekanntes Argument 'figsize' wird ignoriert (Tippfehler?)."]
    @test occursin("plot.SimLevBackcast: Grafiken werden nur als SVG gespeichert; 'b.png' hat die Endung '.png'.",
                   _api_err(() -> r_plot(_plot_case_obj("backcast/bc_fit"); file = "b.png")))
    @test !isfile("b.png")
end
