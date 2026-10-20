# Kleine Arbeitslast beim Vorkompilieren: Maschinencode für die Engine und die
# wichtigsten Erweiterungsfunktionen – für die hier benutzten Argumenttypen –
# landet im Paket-Cache. Das verkürzt den ersten Aufruf von simulation(),
# bootstrap(), withdrawal_simulation(), portfolio_optimize(), deep_analysis(),
# param_search() usw. deutlich, macht ihn aber nicht so schnell wie spätere
# Aufrufe: Laden des Caches, Laufzeit-Dispatch und Methoden für andere
# Argumenttypen (oder Pfade, die die Arbeitslast nicht berührt) kosten beim
# ersten Aufruf weiterhin Übersetzungszeit.
#
# Die Arbeitslast verändert den Laufzeitzustand nicht: Der Zufallszustand
# (`RRng`) wird am Ende auf den Ausgangszustand zurückgesetzt (wie in
# `RRng.__init__`), Zwischenspeicher und Bibliotheks-Handles (LAPACK, ICU)
# werden geleert, damit keine Zeiger aus der Vorkompilierung in den Cache
# geraten. Jeder Baustein läuft in `try`; die gesamte Arbeitslast steht
# zusätzlich in `try … catch`: Ein Fehler (z. B. fehlende System-LAPACK/ICU,
# andere libm) darf das Laden des Pakets nie verhindern.
# `_precompile_ext(; strict = true)` meldet Fehler (für Tests). Abschalten:
# SIMLEV_SKIP_PRECOMPILE=1 (alles), SIMLEV_SKIP_PRECOMPILE_EXT=1 (Erweiterungen).

"Arbeitslast für die Erweiterungsmodule (Bootstrap, Withdrawal, Optimize, …)."
function _precompile_ext(; strict::Bool = false)
    errs = String[]
    step(f, what) = try
        f()
    catch e
        strict && push!(errs, what * ": " * sprint(showerror, e))
        nothing
    end
    io = IOBuffer()
    sh(x) = (show(io, MIME"text/plain"(), x); x)
    seed_old = RRng.has_random_seed() ? RRng.get_random_seed() : nothing
    try
        n = 900
        dates = collect(Date(2015, 1, 1):Day(1):Date(2015, 1, 1) + Day(n - 1))
        RRng.set_seed(1)
        ra = RRng.rnorm(n, 3e-4, 0.01); rb = RRng.rnorm(n, 1e-4, 0.004); rc = RRng.rnorm(n, 2e-4, 0.007)
        A = 100 .* r_cumprod(1 .+ ra); B = 100 .* r_cumprod(1 .+ rb); C = 100 .* r_cumprod(1 .+ rc)
        d = RFrame("date" => dates, "A" => A, "B" => B, "C" => C, "infl" => [2.0 + sin(i / 90) for i in 1:n],
                   "zins" => [1.0 + (i > 400) for i in 1:n])
        st = create_strategy("A" => asset_config("etf", "bnh", 0.6), "B" => asset_config("etf", "bnh", 0.4))
        st1 = create_strategy("A" => asset_config("etf", "bnh"))
        # Bootstrap
        step("bootstrap") do
            cfg = Bootstrap.bootstrap_config((akt = "A",); aux = (zins = "zins",), input = "prices")
            sh(cfg)
            b = Bootstrap.bootstrap(d, cfg, "stationary"; n = 2, path_length = 200, seed = 1, progress = false)
            sh(b)
            Bootstrap.block_length(ra)
            stv = Bootstrap.bootstrap_study(d, Bootstrap.bootstrap_config((A = "A",); input = "prices"), "stationary";
                                            n = 2, path_length = 200, seed = 2, progress = false,
                                            strategies = (a = st1,))
            sh(stv); sh(r_summary(stv))
            sh(Bootstrap.bootstrap_probability(stv, "cagr > 0 & max_drawdown < 0.5"))
        end
        # Withdrawal
        step("withdrawal") do
            R = reshape([1.0 + 0.05 * sin(i) for i in 1:60], 20, 3)
            for rule in ("constant", "guyton_klinger", "vpw")
                w = Withdrawal.withdrawal_simulation(R, Withdrawal.withdrawal_rule(rule); inflation = 2)
                sh(w); sh(r_summary(w))
            end
        end
        # Optimize
        step("optimize") do
            Rm = NamedMat(hcat(ra, rb, rc); colnames = ["A", "B", "C"])
            for m in ("min_variance", "max_sharpe", "risk_parity", "hrp", "min_cvar")
                sh(Optimize.portfolio_optimize(Rm; method = m))
            end
        end
        # Deep analysis
        step("deep_analysis") do
            x1 = RFrame("date" => dates, "value" => A)
            sh(DeepAnalysis.deep_analysis(RList("X" => x1, "Y" => RFrame("date" => dates, "value" => B));
                                          benchmark = "X", rolling_years = 1))
        end
        # Parametersuche, Overfitting
        step("param_search") do
            sts = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell"))
            b(p) = RList("strategy" => sts, "signal" => df -> Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
            ps = ParamSearch.param_search(d, b, ParamSearch.param_space(n = [10.0, 40.0], band = [0.0, 2.0]); burn_in = 50)
            sh(ps)
            sh(Overfitting.deflated_sharpe(ps))
            sh(Overfitting.pbo(ps; S = 4))
        end
        # Abhängigkeiten, Szenarien, Regime
        step("dependence") do
            sh(Dependence.dependence_analysis(d, ["A", "B", "C"]; conditions = ["infl"], B = 9, seed = 1, dcc = false))
            sh(Dependence.regime_subset(d, "infl > 2 & !zins > 1"))
        end
        step("scenarios") do
            sh(Scenarios.entropy_pooling(d, ["A", "B"], [Scenarios.view_mean("A", -0.3), Scenarios.view_prob("A < -1 & B > 0", 0.2)]))
        end
        # Sensitivität, Taktik, Planung
        step("sensitivity") do
            sh(Sensitivity.leverage_sensitivity(d, "A"; leverages = [1, 2], rate = 2))
        end
        step("tactical") do
            w = Tactical.tactical_rules(d, [RList("when" => "A > B", "weights" => named("A" => 1))], named("C" => 1))
            sh(w)
            res = Tactical.tactical_simulation(d, w)
            sh(res)
            sh(Tactical.tactical_rotation(d, ["A", "B"]; top = 1, safe = "C"))
        end
        step("planning") do
            sh(Planning.goal_optimize(hcat(ra, rb, rc)[1:30, :] .+ 1, 100, 110, 1; n_grid = 4, n_sim = 20, seed = 6))
        end
        step("data_prep") do
            DataPrep.align_series(us = RFrame("date" => dates[1:50], "value" => A[1:50]),
                                  eu = RFrame("date" => dates[10:60], "value" => B[10:60]))
        end
    finally
        # Zufallszustand und Zwischenspeicher wie vorher
        if seed_old === nothing
            RRng.__init__()
        else
            RRng.set_random_seed(seed_old)
        end
        empty!(RExpr._CACHE)
    end
    return errs
end

"Arbeitslast für die Engine (simulation(), Ausgabe, Trigger)."
function _precompile_engine()
    n = 800
    dates = collect(Date(2019, 1, 1):Day(1):Date(2019, 1, 1) + Day(n - 1))
    px(a, b) = [100 * (1 + a * i / n + 0.05 * sin(b * i)) for i in 1:n]
    sb = [i % 37 < 5 for i in 1:n]; ss = [i % 37 > 25 for i in 1:n]
    data = (date = dates, A = px(0.5, 0.05), B = px(0.1, 0.11), C = px(3.0, 0.07),
            b = sb, s = ss, ev = [i % 50 == 0 for i in 1:n], br = fill(2.55, n), w1 = fill(0.6, n))
    s2 = create_strategy(A = asset_config("etf", "bnh", 0.6, 0.1, 30), B = asset_config("etf", "bnh", 0.4, 0.1, 0))
    s3 = create_strategy(A = asset_config("certificate", "signal", 0.4, 0.2, 0; signal_buy = "b", signal_sell = "s"),
                         B = asset_config("etc", "bnh", 0.3, 0.1, 0; deliverable = true),
                         C = asset_config("etf", "bnh", 0.3, 0.1, 30; asset_start = dates[100]))
    io = devnull
    for det in (false, true)
        r = simulation(data, s2; tax_mode = "person", balance_mode = true, dca_mode = true, dca_value = 100,
                       dca_span = 1, liquidate = true, base_rate = 2.55, details = det, io = io)
        format_result(r)
        format_summary(summary(r))
        sprint(show, MIME"text/plain"(), r)
        simulation(data, s3; tax_mode = "person", marginal_tax_rate = 42, balance_mode = true,
                   balance_unit = "quarter", balance_thresh = 2, split_mode = true, split_thresh = [50, 200],
                   fractions = false, event_col = "ev", event_weight = (A = "w1",), risk_free = 2,
                   use_guenstigerpruefung = true, details = det, io = io)
        simulation(data, s2; tax_mode = "funds", liquidate = true, base_rate_flex = true, base_rate_data = "br",
                   dca_mode = true, dca_value = 50.0, dca_span = 1, dca_days = [1, 15], dca_unit = "month",
                   balance_mode = true, balance_days = 31, balance_anchor = "end", risk_free = "br", details = det, io = io)
    end
    simulation(data, s2; tax_mode = "person", order_fee = (fixed = 1, percent = 0.25), dca_fee = 0, church_tax = 9,
               harvest_mode = true, taxable_income = 50000, use_guenstigerpruefung = true, base_rate = 2,
               dca_mode = true, dca_value = 100, dca_span = 1, liquidate = true, io = io)
    gaps = (date = dates[1:2:end], A = px(0.5, 0.05)[1:2:end])
    simulation(gaps, create_strategy(A = asset_config("etf", "bnh", 1.0, 0.1, 30)); io = io)
    compute_rebal_trigger((date = dates, target_leverage = px(0.1, 0.2) ./ 50), "abs_leverage")
    return nothing
end

"Zustand nach der Arbeitslast zurücksetzen (Zufall, Zwischenspeicher, Bibliotheks-Handles)."
function _precompile_reset()
    for f in (() -> empty!(RExpr._CACHE),
              () -> (RLinalg._SYSLAPACK[] = false; RLinalg._LAPACK_WARNED[] = false),
              () -> RStats.collate_reset())
        try
            f()
        catch
        end
    end
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1 && get(ENV, "SIMLEV_SKIP_PRECOMPILE", "0") != "1"
    try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do; redirect_stderr(devnull) do
            try
                _precompile_engine()
            catch
            end
            get(ENV, "SIMLEV_SKIP_PRECOMPILE_EXT", "0") == "1" || _precompile_ext()
        end; end
    catch
        # Fehler in der Arbeitslast (auch beim Umleiten von stderr) verhindern das Laden nie
    end
    _precompile_reset()
end
