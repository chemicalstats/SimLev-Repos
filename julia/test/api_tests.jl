# Tests der öffentlichen Schnittstelle: Schlüsselwortformen aller in R
# optionalen Argumente, einheitliche Grafik-API, data.frame-artige Eingaben,
# NA/NaN in long-double-Kumulationen, Plattform-Bibliotheken.

using Test
using SimLev
using Dates
using Logging

const _SL = SimLev

# In R optionale Argumente der exportierten Funktionen (formals() von SimLev
# 0.5.0; `.` → `_`, `end` → `end_`). Jedes muss in Julia als Schlüsselwort gehen.
const _R_OPTIONAL = Dict{Symbol,Tuple}(
    :strategy_add_asset => (),
    :series_align_macro => (:name, :lag, :lag_unit, :transform, :periods,),
    :series_align => (:calendar, :range, :fill, :max_gap, :start, :end_,),
    :asset_config => (:asset_class, :trading, :share, :spread, :partial_exemption, :deliverable, :start, :tax_regime, :signal_buy, :signal_sell,),
    :backcast => (:fit, :data, :params, :splice, :fill, :rebase,),
    :backcast_fit => (:ter, :leverage, :rate, :fx, :model, :fit, :fixed, :objective, :loss, :horizon, :hybrid_weight, :lag, :rate_lag, :start, :end_, :method, :grid, :bounds, :ter_basis, :rate_basis, :accrual, :index_fill, :validate,),
    :tactical_blend => (:shares,),
    :bootstrap_block_length => (:transform,),
    :index_bond => (:maturity, :coupon_frequency, :method, :start,),
    :bootstrap => (:method, :n, :params, :ess, :ess_grid, :progress, :path_length, :seed, :cores, :max_tries,),
    :bootstrap_config => (:letfs, :regime_index, :aux, :aux_type, :cross, :input,),
    :bootstrap_data => (:i, :dates, :start,),
    :bootstrap_probability => (:thresholds,),
    :bootstrap_study => (:method, :n, :params, :ess, :ess_grid, :path_length, :dates, :start, :burn_in, :sim_args, :metrics, :benchmark, :cores, :chunk_size, :seed, :chunk_dir, :max_tries, :keep_paths, :keep_returns, :keep_aux, :progress,),
    :series_check => (:columns, :jump, :stale, :revert,),
    :rebalance_trigger => (:threshold, :lev_col, :vol_col, :triggers, :out_col,),
    :tactical_conditional_volatility => (:base, :upper, :lower, :target, :window, :min_exposure, :max_exposure, :min_history, :scaling, :high_exposure, :low_exposure, :every, :ppy,),
    :series_convert_currency => (:method, :suffix,),
    :scenario_copula => (:n, :family, :stress, :frequency, :seed,),
    :tail_covar => (:state, :q, :frequency,),
    :portfolio_cpcv => (:assets, :methods, :n_groups, :test_groups, :purge, :embargo, :frequency,),
    :create_strategy => (:assets,),
    :scenario_crisis => (:crises, :rebalance,),
    :index_currency_hedged => (:cost, :basis, :start,),
    :dependence_dcc => (),
    :result_analysis => (:benchmark, :risk_free, :rolling_years, :var_levels, :top_drawdowns, :inflation,),
    :series_deflate => (:base_date, :suffix,),
    :sharpe_deflated => (:id, :n_trials, :effective, :frequency, :dates, :risk_free,),
    :dependence_analysis => (:conditions, :frequency, :quantiles, :breaks, :n_regimes, :window, :dcc, :copulas, :B, :block, :tail_q, :seed,),
    :portfolio_frontier => (:assets, :n, :lower, :upper, :cov, :risk_free, :frequency,),
    :scenario_entropy_pooling => (:states, :frequency, :prior,),
    :export_dashboard => (:filename, :width, :height,),
    :copula_fit => (:families,),
    :tactical_glidepath => (:start, :end_, :every,),
    :planning_goal => (:contributions, :n_grid, :n_sim, :seed,),
    :withdrawal_horizon => (:type, :years, :prob, :min, :max, :mean, :sd, :mode, :seed,),
    :sensitivity_leverage => (:leverages, :rate, :expense, :spread, :strategy, :sim_args, :metrics, :cores,),
    :series_leverage => (:leverage, :rate, :expense, :spread, :start,),
    :planning_lumpsum_vs_dca => (:amount, :months, :horizon, :step, :sim_args, :cores,),
    :sharpe_min_track_record => (:target, :prob, :frequency, :ppy,),
    :momentum_score => (:lookbacks, :type,),
    :index_money_market => (:spread, :basis, :start,),
    :param_bootstrap => (:ids, :top, :by, :map, :include,),
    :param_range => (:n, :step, :integer, :log,),
    :param_search => (:builder, :strategy, :method, :n, :constraint, :sim_args, :burn_in, :metrics, :objective, :maximize, :cores, :seed, :keep_returns,),
    :param_space => (),
    :overfit_pbo => (:S, :metric, :frequency, :dates, :risk_free,),
    :withdrawal_perfect_rate => (:legacy,),
    :param_plateau => (:metric, :radius, :k,),
    :bootstrap_pooled => (:weights, :inflation, :frequency, :n, :years, :L, :country_weights, :target, :seed,),
    :portfolio_optimize => (:assets, :method, :lower, :upper, :cov, :mu, :risk_free, :risk_aversion, :budget, :alpha, :frequency, :resample, :block, :seed,),
    :portfolio_returns => (:frequency,),
    :portfolio_template => (:name, :map,),
    :sharpe_probabilistic => (:benchmark, :ppy,),
    :quantile_regression => (:X, :tau, :intercept, :tol, :maxit,),
    :tax_tariff => (:file,),
    :overfit_reality_check => (:benchmark, :B, :block, :frequency, :dates, :seed,),
    :sensitivity_rebalancing => (:frequencies, :offsets, :bands, :band_type, :include_none, :sim_args, :metrics, :cores,),
    :regime_hmm => (:k, :frequency, :n_start, :max_iter, :tol, :seed,),
    :regime_states => (:type, :output, :state_prob, :lag,),
    :regime_subset => (:min_run,),
    :strategy_remove_asset => (),
    :result_index => (:base,),
    :result_heatmap => (:inflation, :max_years,),
    :portfolio_risk_contributions => (:measure, :alpha, :frequency, :cov,),
    :portfolio_rolling => (:method, :window, :every, :frequency,),
    :scenario_risk => (:alpha,),
    :sensitivity_grid => (:sim_args, :metrics, :cores, :keep_results,),
    :series_shift_return => (:type, :ppy,),
    :sharpe_haircut => (:n_obs, :n_tests, :frequency, :dates, :risk_free, :ppy,),
    :sharpe_test => (:frequency, :method, :B, :block, :seed, :ppy,),
    :signal_analysis => (:horizon, :step, :bins, :breaks, :signal2, :bins2, :splits, :degree,),
    :signal_combine => (:op,),
    :signal_crossover => (:fast, :slow, :type, :band, :lag,),
    :signal_drawdown => (:sell_dd, :buy_dd, :window, :lag,),
    :signal_ema => (:n, :band, :lag,),
    :signal_momentum => (:n, :threshold, :band, :lag,),
    :signal_sma => (:n, :band, :lag,),
    :signal_state => (:initial,),
    :signal_volatility => (:n, :threshold, :band, :ppy, :lag,),
    :simulation => (:start_value, :costs, :dca, :rebalance, :splits, :tax, :risk_free, :fractions, :liquidate, :details,),
    :sim_costs => (:order_fee, :dca_fee,),
    :dca_plan => (:days, :unit, :anchor, :start, :skip, :fill_deficits,),
    :rebalance_plan => (:span, :days, :unit, :anchor, :start, :skip, :thresh, :thresh_type, :event_col, :event_mode, :event_weight,),
    :split_rule => (),
    :tax_profile => (:rate, :church_tax, :sparer_pauschbetrag, :private_sale_threshold, :base_rate, :guenstigerpruefung, :income, :harvest,),
    :income_rate => (:soli_rate,),
    :income_tariff => (:tariff,),
    :harvest_rule => (:day, :loss_pot,),
    :funds_costs => (:fee, :performance_fee,),
    :series_splice => (:dates,),
    :strategy_from_weights => (),
    :bootstrap_study_metrics => (),
    :tactical_rotation => (:top, :safe, :absolute, :canary, :breadth, :lookbacks, :type, :every, :weighting,),
    :tactical_rules => (),
    :tactical_simulation => (:rebalance, :tolerance, :tolerance_type, :lag, :asset_args,),
    :tail_dependence => (:q,),
    :tail_regression => (:quantiles, :frequency, :B, :block, :seed,),
    :tactical_target_volatility => (:target, :window, :max_exposure, :every, :ppy,),
    :index_total_return => (:dividends, :yield, :withholding, :dates, :start,),
    :strategy_update_asset => (),
    :bootstrap_validate => (:min_rows, :verbose,),
    :dependence_validate => (:agg, :q, :max_paths,),
    :strategy_validate => (:data,),
    :view_mean => (:op,),
    :view_prob => (:op,),
    :view_vol => (:op,),
    :overfit_walk_forward => (:train, :test, :step, :anchored, :metric, :select, :risk_free,),
    :withdrawal_cohorts => (:price, :inflation, :years, :frequency, :step, :wrap, :cape, :base_rate, :inflation_type,),
    :withdrawal_max_rate => (:rule, :success, :lower, :upper, :tol,),
    :withdrawal_paths => (:column, :strategy, :inflation, :inflation_type, :frequency, :dates, :start, :cape,),
    :withdrawal_rule => (:type, :rate, :ceiling, :floor, :cut, :raise, :cpr_years, :inflation_cap, :skip_inflation, :smoothing, :exp_return, :stock_share, :age, :max_age, :fv, :cape_a, :cape_b, :ratchet_threshold, :ratchet_gap, :extra, :floor95, :min_real, :max_real, :max_rate,),
    :withdrawal_simulation => (:rule, :start_value, :inflation, :frequency, :strategy, :years, :timing, :income, :tax, :partial_exemption, :base_rate, :vorabpauschale, :sale_cost, :cost_basis, :loss_carryforward, :gamma, :keep_paths, :horizon,),
)

"Deklarierte Schlüsselwörter aller Methoden; `true`, wenn eine Methode `kw...` sammelt."
function _api_kws(f)
    ks = Set{Symbol}(); splat = false
    for m in methods(f), k in Base.kwarg_decl(m)
        s = String(k)
        endswith(s, "...") ? (splat = true) : push!(ks, k)
    end
    ks, splat
end

_api_warns(f) = (l = Test.TestLogger(); r = with_logger(f, l); (r, [string(x.message) for x in l.logs if x.level == Logging.Warn]))
_api_err(f) = try f(); "" catch e; e isa ErrorException ? e.msg : sprint(showerror, e) end

@testset "API" begin

@testset "Schlüsselwörter wie R (alle Exporte)" begin
    # nur über `kw...` angenommen (Prüfung gegen die Feldliste bzw. Weitergabe)
    via_splat = (:asset_config,)
    for (f, opt) in _R_OPTIONAL
        @test isdefined(_SL, f)
        isdefined(_SL, f) || continue
        ks, splat = _api_kws(getfield(_SL, f))
        miss = [a for a in opt if !(a in ks)]
        if f in via_splat
            @test splat
        else
            isempty(miss) || println("API: $f ohne Schlüsselwort ", miss)
            @test isempty(miss)
        end
    end
    @test asset_config(asset_class = "etf", trading = "bnh", share = 0.5).share ==
          asset_config("etf", "bnh", 0.5).share
end

@testset "Schlüsselwortformen (Befunde)" begin
    n = 400
    dates = collect(Date(2007, 1, 1):Day(1):Date(2007, 1, 1) + Day(n - 1))
    set_seed(3)
    ra = _SL.RRng.rnorm(n, 3e-4, 0.01); rb = 0.5 .* ra .+ _SL.RRng.rnorm(n, 1e-4, 0.006)
    A = 100 .* _SL.RBase.r_cumprod(1 .+ ra); B = 100 .* _SL.RBase.r_cumprod(1 .+ rb)
    d = RFrame("date" => dates, "A" => A, "B" => B)
    same(a, b) = sprint(show, MIME"text/plain"(), a) == sprint(show, MIME"text/plain"(), b)

    @test same(copula_fit(ra, rb, ["gaussian", "t"]), copula_fit(ra, rb; families = ["gaussian", "t"]))
    @test same(tail_dependence(ra, rb, [0.05, 0.1]), tail_dependence(ra, rb; q = [0.05, 0.1]))
    X = reshape(ra, :, 1)
    @test quantile_regression(rb, X, 0.25) == quantile_regression(rb; X = X, tau = 0.25)
    @test quantile_regression(rb, X; tau = 0.75) == quantile_regression(rb, X, 0.75)
    cr = RFrame("crisis" => ["Test"], "start" => [Date(2007, 3, 1)], "end" => [Date(2007, 6, 30)])
    w = named("A" => 0.6, "B" => 0.4)
    @test same(scenario_crisis(d, w, cr), scenario_crisis(d, w; crises = cr))
    b = bootstrap(d, bootstrap_config((A = "A", B = "B"); input = "prices"), "stationary"; n = 2, path_length = 60, seed = 1, progress = false)
    @test same(bootstrap_data(b, 2), bootstrap_data(b; i = 2))
    st = create_strategy(A = asset_config("etf", "bnh"))
    @test strategy_validate(st, d) == strategy_validate(st; data = d)
    @test occursin("'A'", _api_err(() -> strategy_validate(st; data = RFrame("date" => dates, "B" => B))))
    t1 = tax_tariff(); t2 = tax_tariff(file = t1["file"])
    @test t1["zones"]["a"] == t2["zones"]["a"]
    @test withdrawal_rule("guyton_klinger") == withdrawal_rule(type = "guyton_klinger")
    @test withdrawal_rule(type_ = "vpw")["type"] == "vpw"
    @test withdrawal_horizon("fixed"; years = 30)["type"] == withdrawal_horizon(type = "fixed", years = 30)["type"]
    @test _SL.view_mean("A", 1.0, "<=") == _SL.view_mean("A", 1.0; op = "<=")
    @test _SL.view_prob("A > 0", 0.4; op = ">=")["op"] == ">="
    @test _SL.view_vol("A", 2.0; op = "=")["op"] == "="
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
@isdefined(read_case) || include(joinpath(@__DIR__, "golden_tools.jl"))
@isdefined(decode) || include(joinpath(@__DIR__, "reftree.jl"))
function _plot_case_obj(case, var = "result")
    c = Base.invokelatest(read_ref_case, joinpath(@__DIR__, "..", "..", "golden", "modules", case * ".json.gz"))
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
    @test occursin("need at least 2 points", _api_err(() -> r_plot(_plot_case_obj("bootstrap/study_print_paired"))))
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

@testset "data.frame-artige Eingaben (as_rframe)" begin
    dates = collect(Date(2020, 1, 1):Day(1):Date(2020, 1, 10))
    v = collect(1.0:10.0)
    f0 = RFrame("date" => dates, "A" => v)
    for x in ((date = dates, A = v), ["date" => dates, "A" => v], [:date => dates, :A => v],
              Dict("date" => dates, "A" => v), Dict(:A => v, :date => dates))
        f = _SL.as_rframe(x)
        @test f isa RFrame && f["A"] == v && f["date"] == dates && nrow(f) == 10
    end
    @test names(_SL.as_rframe(Dict("b" => v, "a" => v))) == ["a", "b"]     # Dict ungeordnet → sortiert
    @test _SL.as_rframe(f0) === f0
    @test _SL.as_rframe((a = [1, 2], b = 0.5))["b"] == [0.5, 0.5]
    @test _SL.as_rframe((a = [1, 2], b = [1, 2, 3])) isa NamedTuple       # ungleich lang: unverändert
    @test _SL.as_rframe(RList("a" => [1.0])) isa RList
    @test _SL.as_rframe([1.0, 2.0]) == [1.0, 2.0]
    @test _SL.as_rframe((akt = "A",)) isa RFrame                          # Skalare: eine Zeile

    # Erweiterungen nehmen alle Formen gleich an
    same(a, b) = sprint(show, MIME"text/plain"(), a) == sprint(show, MIME"text/plain"(), b)
    n = 800
    dts = collect(Date(2015, 1, 1):Day(1):Date(2015, 1, 1) + Day(n - 1))
    set_seed(5)
    ra = _SL.RRng.rnorm(n, 3e-4, 0.01); rb = _SL.RRng.rnorm(n, 1e-4, 0.005)
    A = 100 .* _SL.RBase.r_cumprod(1 .+ ra); B = 100 .* _SL.RBase.r_cumprod(1 .+ rb)
    po(x) = portfolio_optimize(x; method = "min_variance")
    ref = po(RFrame("A" => ra, "B" => rb))
    for x in ((A = ra, B = rb), ["A" => ra, "B" => rb], Dict("A" => ra, "B" => rb))
        @test same(po(x), ref)
    end
    cfg = bootstrap_config((A = "A", B = "B"); input = "prices")
    st = (s = create_strategy(A = asset_config("etf", "bnh", 0.5), B = asset_config("etf", "bnh", 0.5)),)
    bs(x) = bootstrap_study(x, cfg, "stationary"; n = 2, path_length = 100, seed = 2, progress = false, strategies = st)
    ref = bs(RFrame("date" => dts, "A" => A, "B" => B))
    for x in ((date = dts, A = A, B = B), ["date" => dts, "A" => A, "B" => B], Dict("date" => dts, "A" => A, "B" => B))
        r = bs(x)
        @test same(r["results"], ref["results"]) && r["returns"] == ref["returns"]   # ohne Laufzeit (elapsed)
    end
    hm = result_heatmap(RFrame("date" => dts, "value" => A))
    @test same(result_heatmap(["date" => dts, "value" => A]), hm)
    @test same(result_heatmap((date = dts, value = A)), hm)
end

@testset "NA/NaN in Kumulationen wie R" begin
    N = NA; isNA(x) = isna_strict(x); isNaN(x) = isnan(x) && !isna_strict(x)
    B = _SL.RBase
    c = B.r_cumsum([NaN, N]); @test isNaN(c[1]) && isNA(c[2])
    c = B.r_cumsum([1.0, NaN, 3.0, N]); @test c[1] == 1 && isNaN(c[2]) && isNaN(c[3]) && isNA(c[4])
    c = B.r_cumprod([NaN, 1.0, N]); @test isNaN(c[1]) && isNaN(c[2]) && isNA(c[3])
    c = _SL.r_cumprod([1.0, N, NaN]); @test c[1] == 1 && isNA(c[2]) && isNA(c[3])
    @test isNaN(B.r_sum([NaN, N])) && isNA(B.r_sum([N, NaN]))         # x87: ruhiges NaN schlägt Speicher-NA
    @test isNaN(B.r_prod([NaN, N])) && isNA(B.r_mean([NaN, N]))
    @test isNaN(B.colSums([NaN N; N NaN])[1]) && isNA(B.colSums([NaN N; N NaN])[2])
    # Hardware- und Software-F80 stimmen bei NaN-Ergebnissen überein
    v5 = [2.0, N, NaN, Inf, -Inf]
    for t in Iterators.product(v5, v5, v5)
        x = collect(t)
        for f in (_SL._r_sum, _SL._r_prod)
            h = f(_SL.F80, x, false); s = f(_SL.F80Soft, x, false)
            @test isna_strict(h) == isna_strict(s) && isnan(h) == isnan(s)
        end
    end
end

@testset "Plattform-Bibliotheken" begin
    @test _SL.RLibm.LIBM == _SL._LIBM
    Sys.islinux() && @test _SL._LIBM == "libm.so.6" && _SL._LIBC == "libc.so.6"
    @test _SL._c_sprintf("%.17g", 0.1) == "0.10000000000000001"
    @test _SL._c_sprintf("%*.*e", Int32(12), Int32(3), 3.14159) == "   3.142e+00"
    @test length(_SL._c_sprintf("%.*f", Int32(400), 1 / 3)) == 402        # Puffer wächst
    @test _SL._c_sprintf("%s!", "x"^300) == "x"^300 * "!"
    @test _SL._pick_lib("libgibtsnicht.so.9", _SL._LIBM) == _SL._LIBM
    @test _SL._precompile_reset() === nothing
    @test _SL.RLinalg._SYSLAPACK[] === false || _SL.RLinalg._SYSLAPACK[] === nothing || _SL.RLinalg._SYSLAPACK[] isa Ptr
end

end
