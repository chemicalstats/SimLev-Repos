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
    :add_asset => (),
    :align_macro => (:name, :lag, :lag_unit, :transform, :periods,),
    :align_series => (:calendar, :range, :fill, :max_gap, :start, :end_,),
    :asset_config => (:asset_class, :action_type, :asset_share, :asset_spread, :asset_bonus, :deliverable, :asset_start, :tax_regime, :signal_buy, :signal_sell,),
    :backcast => (:fit, :data, :params, :splice, :fill, :rebase,),
    :backcast_fit => (:ter, :leverage, :rate, :fx, :model, :fit, :fixed, :objective, :loss, :horizon, :hybrid_weight, :lag, :rate_lag, :start, :end_, :method, :grid, :bounds, :ter_basis, :rate_basis, :accrual, :index_fill, :validate,),
    :blend_weights => (:shares,),
    :block_length => (:transform,),
    :bond_index_from_yields => (:maturity, :coupon_frequency, :method, :start,),
    :bootstrap => (:method, :n, :params, :ess, :ess_grid, :progress, :path_length, :seed, :cores, :max_tries,),
    :bootstrap_config => (:letfs, :regime_index, :aux, :aux_type, :cross, :input,),
    :bootstrap_data => (:i, :dates, :start_date,),
    :bootstrap_probability => (:thresholds,),
    :bootstrap_study => (:method, :n, :params, :ess, :ess_grid, :path_length, :dates, :start_date, :burn_in, :sim_args, :metrics, :benchmark, :cores, :chunk_size, :seed, :chunk_dir, :max_tries, :keep_paths, :keep_returns, :keep_aux, :progress,),
    :check_series => (:columns, :jump, :stale, :revert,),
    :compute_rebal_trigger => (:threshold, :lev_col, :vol_col, :triggers, :out_col,),
    :conditional_volatility => (:base, :upper, :lower, :target, :window, :min_exposure, :max_exposure, :min_history, :scaling, :high_exposure, :low_exposure, :every, :ppy,),
    :convert_currency => (:method, :suffix,),
    :copula_scenarios => (:n, :family, :stress, :frequency, :seed,),
    :covar_analysis => (:state, :q, :frequency,),
    :cpcv_portfolio => (:assets, :methods, :n_groups, :test_groups, :purge, :embargo, :frequency,),
    :create_strategy => (:assets,),
    :crisis_replay => (:crises, :rebalance,),
    :currency_hedged_index => (:cost, :basis, :start,),
    :dcc_fit => (),
    :deep_analysis => (:benchmark, :risk_free, :rolling_years, :var_levels, :top_drawdowns, :inflation,),
    :deflate => (:base_date, :suffix,),
    :deflated_sharpe => (:id, :n_trials, :effective, :frequency, :dates, :risk_free,),
    :dependence_analysis => (:conditions, :frequency, :quantiles, :breaks, :n_regimes, :window, :dcc, :copulas, :B, :block, :tail_q, :seed,),
    :efficient_frontier => (:assets, :n, :lower, :upper, :cov, :risk_free, :frequency,),
    :entropy_pooling => (:states, :frequency, :prior,),
    :export_dashboard => (:filename, :width, :height,),
    :fit_copula => (:families,),
    :glidepath => (:start, :end_, :every,),
    :goal_optimize => (:contributions, :n_grid, :n_sim, :seed,),
    :horizon_model => (:type, :years, :prob, :min, :max, :mean, :sd, :mode, :seed,),
    :leverage_sensitivity => (:leverages, :rate, :expense, :spread, :strategy, :sim_args, :metrics, :cores,),
    :leveraged_series => (:leverage, :rate, :expense, :spread, :start,),
    :lumpsum_vs_dca => (:amount, :months, :horizon, :step, :sim_args, :cores,),
    :min_track_record => (:target, :prob, :frequency, :ppy,),
    :momentum_score => (:lookbacks, :type,),
    :money_market_index => (:spread, :basis, :start,),
    :param_bootstrap => (:ids, :top, :by, :map, :include,),
    :param_range => (:n, :step, :integer, :log,),
    :param_search => (:builder, :strategy, :method, :n, :constraint, :sim_args, :burn_in, :metrics, :objective, :maximize, :cores, :seed, :keep_returns,),
    :param_space => (),
    :pbo => (:S, :metric, :frequency, :dates, :risk_free,),
    :perfect_withdrawal_rate => (:legacy,),
    :plateau => (:metric, :radius, :k,),
    :pooled_bootstrap => (:weights, :inflation, :frequency, :n, :years, :L, :country_weights, :target, :seed,),
    :portfolio_optimize => (:assets, :method, :lower, :upper, :cov, :mu, :risk_free, :risk_aversion, :budget, :alpha, :frequency, :resample, :block, :seed,),
    :portfolio_returns => (:frequency,),
    :portfolio_template => (:name, :map,),
    :probabilistic_sharpe => (:benchmark, :ppy,),
    :quantile_reg => (:X, :tau, :intercept, :tol, :maxit,),
    :read_tax_tariff => (:file,),
    :reality_check => (:benchmark, :B, :block, :frequency, :dates, :seed,),
    :rebalancing_sensitivity => (:frequencies, :offsets, :bands, :band_type, :include_none, :sim_args, :metrics, :cores,),
    :regime_hmm => (:k, :frequency, :n_start, :max_iter, :tol, :seed,),
    :regime_states => (:type, :output, :state_prob, :lag,),
    :regime_subset => (:min_run,),
    :remove_asset => (),
    :result_index => (:base,),
    :return_heatmap => (:inflation, :max_years,),
    :risk_contributions => (:measure, :alpha, :frequency, :cov,),
    :rolling_optimization => (:method, :window, :every, :frequency,),
    :scenario_risk => (:alpha,),
    :sensitivity_grid => (:sim_args, :metrics, :cores, :keep_results,),
    :set_expected_return => (:type, :ppy,),
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
    :simulation => (:start_value, :spread, :details, :liquidate, :dca_mode, :dca_value, :dca_span, :dca_days, :dca_unit, :dca_anchor, :dca_start, :dca_skip, :balance_mode, :balance_span, :balance_days, :balance_unit, :balance_anchor, :balance_start, :balance_skip, :balance_dca, :balance_thresh, :balance_thresh_type, :tax_mode, :tax_rate, :marginal_tax_rate, :use_guenstigerpruefung, :private_sale_threshold, :sparer_pauschbetrag, :use_sparer_pauschbetrag, :include_soli_on_income_tax, :soli_rate_income_tax, :base_rate, :base_rate_flex, :base_rate_data, :funds_fee, :bonus_fee, :fractions, :risk_free, :split_mode, :split_thresh, :event_col, :event_mode, :event_weight, :church_tax, :order_fee, :dca_fee, :harvest_mode, :harvest_day, :harvest_loss_pot, :taxable_income, :tax_tariff,),
    :splice_series => (:dates,),
    :strategy_from_weights => (),
    :study_metrics => (),
    :tactical_rotation => (:top, :safe, :absolute, :canary, :breadth, :lookbacks, :type, :every, :weighting,),
    :tactical_rules => (),
    :tactical_simulation => (:rebalance, :tolerance, :tolerance_type, :lag, :asset_args,),
    :tail_dependence => (:q,),
    :tail_regression => (:quantiles, :frequency, :B, :block, :seed,),
    :target_volatility => (:target, :window, :max_exposure, :every, :ppy,),
    :total_return_index => (:dividends, :yield, :withholding, :dates, :start,),
    :update_asset => (),
    :validate_bootstrap => (:min_rows, :verbose,),
    :validate_dependence => (:agg, :q, :max_paths,),
    :validate_strategy => (:data,),
    :view_mean => (:op,),
    :view_prob => (:op,),
    :view_vol => (:op,),
    :walk_forward => (:train, :test, :step, :anchored, :metric, :select, :risk_free,),
    :withdrawal_cohorts => (:price, :inflation, :years, :frequency, :step, :wrap, :cape, :base_rate, :inflation_type,),
    :withdrawal_max_rate => (:rule, :success, :lower, :upper, :tol,),
    :withdrawal_paths => (:column, :strategy, :inflation, :inflation_type, :frequency, :dates, :start_date, :cape,),
    :withdrawal_rule => (:type, :rate, :ceiling, :floor, :cut, :raise, :cpr_years, :inflation_cap, :skip_inflation, :smoothing, :exp_return, :stock_share, :age, :max_age, :fv, :cape_a, :cape_b, :ratchet_threshold, :ratchet_gap, :extra, :floor95, :min_real, :max_real, :max_rate,),
    :withdrawal_simulation => (:rule, :start_value, :inflation, :frequency, :strategy, :years, :timing, :income, :tax_mode, :tax_rate, :asset_bonus, :sparer_pauschbetrag, :base_rate, :vorabpauschale, :sale_cost, :cost_basis, :loss_carryforward, :gamma, :keep_paths, :horizon,),
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
    @test asset_config(asset_class = "etf", action_type = "bnh", asset_share = 0.5).asset_share ==
          asset_config("etf", "bnh", 0.5).asset_share
end

@testset "Schlüsselwortformen (Befunde)" begin
    n = 400
    dates = collect(Date(2007, 1, 1):Day(1):Date(2007, 1, 1) + Day(n - 1))
    set_seed(3)
    ra = _SL.RRng.rnorm(n, 3e-4, 0.01); rb = 0.5 .* ra .+ _SL.RRng.rnorm(n, 1e-4, 0.006)
    A = 100 .* _SL.RBase.r_cumprod(1 .+ ra); B = 100 .* _SL.RBase.r_cumprod(1 .+ rb)
    d = RFrame("date" => dates, "A" => A, "B" => B)
    same(a, b) = sprint(show, MIME"text/plain"(), a) == sprint(show, MIME"text/plain"(), b)

    @test same(fit_copula(ra, rb, ["gaussian", "t"]), fit_copula(ra, rb; families = ["gaussian", "t"]))
    @test same(tail_dependence(ra, rb, [0.05, 0.1]), tail_dependence(ra, rb; q = [0.05, 0.1]))
    X = reshape(ra, :, 1)
    @test quantile_reg(rb, X, 0.25) == quantile_reg(rb; X = X, tau = 0.25)
    @test quantile_reg(rb, X; tau = 0.75) == quantile_reg(rb, X, 0.75)
    cr = RFrame("crisis" => ["Test"], "start" => [Date(2007, 3, 1)], "end" => [Date(2007, 6, 30)])
    w = named("A" => 0.6, "B" => 0.4)
    @test same(crisis_replay(d, w, cr), crisis_replay(d, w; crises = cr))
    b = bootstrap(d, bootstrap_config((A = "A", B = "B"); input = "prices"), "stationary"; n = 2, path_length = 60, seed = 1, progress = false)
    @test same(bootstrap_data(b, 2), bootstrap_data(b; i = 2))
    st = create_strategy(A = asset_config("etf", "bnh"))
    @test validate_strategy(st, d) == validate_strategy(st; data = d)
    @test occursin("'A'", _api_err(() -> validate_strategy(st; data = RFrame("date" => dates, "B" => B))))
    t1 = read_tax_tariff(); t2 = read_tax_tariff(file = t1["file"])
    @test t1["zones"]["a"] == t2["zones"]["a"]
    @test withdrawal_rule("guyton_klinger") == withdrawal_rule(type = "guyton_klinger")
    @test withdrawal_rule(type_ = "vpw")["type"] == "vpw"
    @test horizon_model("fixed"; years = 30)["type"] == horizon_model(type = "fixed", years = 30)["type"]
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
        @test x isa SimLevDashboard
        @test ws == ["plot.SimLevResult: unbekanntes Argument 'colour' wird ignoriert (Tippfehler?)."]
        @test isempty(readdir(dir))                       # kein stilles Rplots.svg
        @test r_plot(r; file = "a.svg") isa SimLevDashboard
        @test isfile("a.svg")
        @test occursin("nur als SVG", _api_err(() -> r_plot(r; file = "a.png")))
        @test !isfile("a.png")
        @test plot_dashboard(r; file = "b.svg") isa SimLevDashboard && isfile("b.svg")
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
        @test y isa SimLevDashboard && ws == ["plot.SimLevWithdrawal: unbekanntes Argument 'probz' wird ignoriert (Tippfehler?)."]
        @test r_plot(wd; file = "w.svg") isa SimLevDashboard && isfile("w.svg")
        @test sort(readdir(dir)) == ["a.svg", "b.svg", "c.svg", "w.svg"]
    end
    # alle registrierten plot-Methoden laufen über die gemeinsame Hülle
    for (cls, f) in _SL._PLOTS
        ok = occursin("_plot_method", string(nameof(typeof(f))))
        ok || println("API: plot-Methode für $cls ohne _plot_method")
        @test ok
    end
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
    hm = return_heatmap(RFrame("date" => dts, "value" => A))
    @test same(return_heatmap(["date" => dts, "value" => A]), hm)
    @test same(return_heatmap((date = dts, value = A)), hm)
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
