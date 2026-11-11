# Arbeitslast beim Vorkompilieren: Maschinencode für die Engine und die öffentlichen Hauptfunktionen der
# Erweiterungen – für die üblichen Argumenttypen – landet im Paket-Cache. Ziel: Jede Hauptfunktion
# braucht beim ersten Aufruf in einem frischen Prozess höchstens etwa 1 s. Ganz so schnell wie spätere
# Aufrufe wird der erste nicht: Laden des Caches, Laufzeit-Dispatch und Methoden für andere Argumenttypen
# (etwa die Eingangsfunktion für eine NamedTuple mit anderen Spaltennamen oder Pfade, die die Arbeitslast
# nicht berührt) kosten weiterhin Übersetzungszeit.
#
# Daten wie beim Aufrufer: RFrame mit Spalte date (Vector{Date}) und Kursen (Vector{Float64}) (seit 1.6.4, K43
# T1-N7; bis dahin NamedTuple, das die Hauptfunktionen seit Entscheidung 6 ablehnen), dazu RList, NamedMat und
# Matrizen. rechnen Tagesengine, Vorbereitung und Auswertung von
# simulation() im C++-Kern; die Arbeitslast der Engine deckt die Kernhüllen (_sim_engine_run!, die Texte der
# Ereignisse in _sim_engine_signal mit und ohne details, _sim_evaluate, calculate_dates_flags, xirr_rate) und
# die Ausgabe ab, die früheren Wege der Julia-Tagesschleife nicht mehr (details nur noch in zwei Läufen statt
# für jede Variante). Die Erweiterungen decken je Modul die Hauptfunktion mit kleinen Daten ab (bis
# 1.3.0 nur Bootstrap, GARCH, MS-GARCH, Entnahme ohne Steuer, Optimierung auf Renditematrizen und
# result_analysis).
#
# Was die Arbeitslast nur über Laufzeit-Dispatch erreicht, nennt precompile_statements.jl ausdrücklich (sonst
# fehlt es im Cache, siehe dort).
#
# Die Arbeitslast verändert den Laufzeitzustand nicht: Die Daten kommen aus einem eigenen SimLev-Strom
# (`SLib.main_stream(1)`), jede zufällige Funktion bekommt einen festen `seed`, der globale Zustand bleibt
# unberührt (er wird ohnehin beim Laden neu gesetzt, SLib.__init__); Zwischenspeicher und
# Bibliotheks-Handles (ICU) werden geleert, damit keine Zeiger aus der Vorkompilierung in den Cache geraten.
# Jeder Baustein läuft in `try`; die gesamte Arbeitslast steht zusätzlich in `try … catch`: Ein Fehler
# (z. B. fehlende ICU, andere libm) darf das Laden des Pakets nie verhindern. Damit verschluckte Fehler nicht
# unbemerkt bleiben (bis 1.6.3 brachen so 13 von 21 Schritten ab): `_precompile_check()` führt die Arbeitslast im
# laufenden Prozess aus und gibt die gescheiterten Schritte zurück (Werkzeug tests/werkzeuge/precompile_check.jl).
# Abschalten:
# SIMLEV_SKIP_PRECOMPILE=1 (alles), SIMLEV_SKIP_PRECOMPILE_EXT=1 (Erweiterungen).

include("precompile_statements.jl")   # ausdrückliche Übersetzungsanweisungen (aus Traces)

# Fehler der Arbeitslast: `nothing` (verschlucken, beim Vorkompilieren) oder ein Vektor `Bezeichnung => Meldung`
# (`_precompile_check`, seit 1.6.4)
const _PRECOMPILE_ERRORS = Ref{Any}(nothing)
function _precompile_fail(label, e)
    v = _PRECOMPILE_ERRORS[]
    v === nothing || push!(v, string(label) => sprint(showerror, e))
    return nothing
end

"Arbeitslast für die Erweiterungsmodule (je Modul die Hauptfunktionen)."
function _precompile_ext()
    step(f, lbl) = try   # zweites Argument: Bezeichnung (seit 1.6.4 benannt, P14-R11; Fehler für _precompile_check)
        f()
    catch e
        _precompile_fail(lbl, e)
    end
    io = IOBuffer()
    sh(x) = (show(io, MIME"text/plain"(), x); x)
    try
        n = 1100
        dates = collect(Date(2015, 1, 1):Day(1):Date(2015, 1, 1) + Day(n - 1))
        rs = SLib.main_stream(1)
        ra = SLib.rnorm(n, 3e-4, 0.01; stream = rs); rb = SLib.rnorm(n, 1e-4, 0.004; stream = rs)
        rc = SLib.rnorm(n, 2e-4, 0.007; stream = rs); rd = SLib.rnorm(n, 3e-4, 0.013; stream = rs)
        A = 100 .* r_cumprod(1 .+ ra); B = 100 .* r_cumprod(1 .+ rb); C = 100 .* r_cumprod(1 .+ rc)
        D = 100 .* r_cumprod(1 .+ rd)
        d = RFrame("date" => dates, "A" => A, "B" => B, "C" => C, "infl" => [2.0 + sin(i / 90) for i in 1:n],
                   "zins" => [1.0 + (i > 400) for i in 1:n])
        nt = RFrame("date" => dates, "A" => A, "B" => B, "C" => C, "D" => D)   # Kurse wie beim Aufrufer (seit 1.6.4 RFrame)
        A3 = ["A", "B", "C"]
        st = create_strategy("A" => asset_config("etf", "bnh", 0.6), "B" => asset_config("etf", "bnh", 0.4))
        st1 = create_strategy("A" => asset_config("etf", "bnh"))
        stn = create_strategy(A = asset_config("etf", "bnh"; share = 0.6), B = asset_config("etf", "bnh"; share = 0.4))
        # Bootstrap
        step("bootstrap") do
            cfg = Bootstrap.bootstrap_config((akt = "A",); aux = (zins = "zins",), input = "prices")
            sh(cfg)
            b = Bootstrap.bootstrap(d, cfg, "stationary"; n = 2, path_length = 200, seed = 1, progress = false)
            sh(b)
            Bootstrap.bootstrap_block_length(ra)
            cfgn = Bootstrap.bootstrap_config((x = "A",); input = "prices")
            Bootstrap.bootstrap(nt, cfgn, "stationary"; n = 2, path_length = 200, seed = 1, progress = false, cores = 1)
            stv = Bootstrap.bootstrap_study(nt, cfgn, "stationary"; n = 2, path_length = 200, seed = 2, progress = false,
                                            strategies = (a = create_strategy(x = asset_config("etf", "bnh")),), cores = 1)
            sh(stv); sh(r_summary(stv))
            sh(Bootstrap.bootstrap_probability(stv, "cagr > 0 & max_drawdown < 0.5"))
        end
        # GARCH (ML-Schätzung in slc, bootstrap "garch") und MS-GARCH-Schätzung
        step("garch") do
            cfg = Bootstrap.bootstrap_config((akt = "A",); input = "prices")
            sh(Bootstrap.bootstrap(nt, cfg, "garch"; n = 2, path_length = 200, seed = 1, progress = false, cores = 1))
        end
        step("ms_garch") do
            MsGarch._ms_garch_fit(rb[1:300], 2, "gjrGARCH")
        end
        # Withdrawal: Regeln, Steuer mit Satz und mit Tarifweg, historische Kohorten
        step("withdrawal") do
            R = reshape([1.0 + 0.05 * sin(i) for i in 1:60], 20, 3)
            for rule in ("constant", "guyton_klinger", "vpw")
                w = Withdrawal.withdrawal_simulation(R, Withdrawal.withdrawal_rule(rule); inflation = 2)
                sh(w); sh(r_summary(w))
            end
            sh(Withdrawal.withdrawal_simulation(R, Withdrawal.withdrawal_rule("constant"; rate = 4); start_value = 1e6))
            for inc in (income_rate(30), income_tariff(40000))
                sh(Withdrawal.withdrawal_simulation(R, Withdrawal.withdrawal_rule("constant"; rate = 4); start_value = 1e6,
                                                    base_rate = 2.5, cost_basis = 60,
                                                    tax = tax_profile(; church_tax = 9, guenstigerpruefung = true, income = inc)))
            end
            co = Withdrawal.withdrawal_cohorts(RFrame("date" => dates, "value" => A); years = 1)
            sh(Withdrawal.withdrawal_simulation(co, Withdrawal.withdrawal_rule("constant"; rate = 4)))
        end
        # Optimize: Renditematrix, Kurse (NamedTuple), rollierend, Effizienzlinie
        step("optimize") do
            Rm = NamedMat(hcat(ra, rb, rc); colnames = ["A", "B", "C"])
            for m in ("min_variance", "max_sharpe", "risk_parity", "hrp", "min_cvar")
                sh(Optimize.portfolio_optimize(Rm; method = m))
                Optimize.portfolio_optimize(nt; assets = A3, method = m)
            end
            for m in ("min_variance", "hrp")   # RFrame wie beim Aufrufer (seit 1.6.1)
                sh(Optimize.portfolio_optimize(d; assets = A3, method = m))
            end
            sh(Optimize.portfolio_rolling(nt, A3; method = "min_variance", window = 1))
            sh(Optimize.portfolio_frontier(nt; assets = A3, n = 4))
        end
        # Dependence (DCC, Tail, ohne Copulas) und Copula-Anpassung
        step("dependence") do
            sh(Dependence.dependence_analysis(nt, A3; copulas = false))
            sh(Dependence.copula_fit(rb[1:400], rc[1:400]))
            # mit Copulas und Bootstrap, NamedTuple und RFrame (seit 1.6.1)
            sh(Dependence.dependence_analysis(nt, A3; copulas = true, B = 5, seed = 1))
            sh(Dependence.dependence_analysis(d, A3; copulas = true, B = 5, seed = 1))
        end
        step("regimes") do
            sh(Regimes.regime_hmm(nt, ["A", "B"]; k = 2, n_start = 1))
        end
        step("scenarios") do
            sh(Scenarios.scenario_entropy_pooling(nt, A3, [Scenarios.view_mean("A", 0.0)]))
            for x in (nt, d)   # t- und Gauß-Copula (seit 1.6.1)
                sh(Scenarios.scenario_copula(x, A3; n = 200, seed = 1))
                sh(Scenarios.scenario_copula(x, A3; n = 200, seed = 1, family = "gaussian"))
            end
        end
        # Raster, Planung und Sensitivität über simulation()
        step("param_search") do
            nt2 = RFrame("date" => dates, "A" => A, "B" => B)
            sim_args = RList("rebalance" => rebalance_plan(; span = 1, unit = "month"))
            sh(ParamSearch.param_search(nt2; space = ParamSearch.param_space("rebalance.thresh" => [2.0, 5.0]),
                                        strategy = stn, sim_args = sim_args, cores = 1))
            sh(Sensitivity.planning_lumpsum_vs_dca(nt2, stn; amount = 12000, months = 6, horizon = 1, step = 12, cores = 1))
            sh(Sensitivity.sensitivity_grid(nt2, stn, RList("rebalance.thresh" => [2.0, 5.0]);
                                            sim_args = RList("rebalance" => rebalance_plan(; span = 1))))
        end
        step("data_prep") do
            sh(DataPrep.series_align(; a = RFrame("date" => dates[1:2:end], "A" => A[1:2:end]), b = RFrame("date" => dates, "B" => B)))
        end
        step("tactical") do
            sh(Tactical.tactical_simulation(nt, Tactical.tactical_rotation(nt, A3; top = 1, absolute = false)))
            sh(Tactical.tactical_rotation(d, A3; top = 2, absolute = false))   # RFrame (seit 1.6.1)
        end
        step("planning") do
            G = reshape([1.0 + 0.05 * sin(i) for i in 1:60], 20, 3)
            sh(Planning.planning_goal(G, 1e5, 2e5, 5; n_grid = 11, n_sim = 20, seed = 1))
        end
        step("overfitting") do
            sh(Overfitting.overfit_pbo(hcat(ra, rb, rc, rd); S = 4))
        end
        step("analysis_tests") do
            sh(AnalysisTests.signal_analysis(nt, "C", "A"))
        end
        step("backcast") do
            bc = RFrame("date" => dates, "p" => 2 .* A .* (1 .- 1e-5 .* (1:n)), "i" => A)
            sh(Backcast.backcast(Backcast.backcast_fit(bc, "p", "i")))
        end
        # Deep analysis
        step("deep_analysis") do
            x1 = RFrame("date" => dates, "value" => A)
            sh(DeepAnalysis.result_analysis(RList("X" => x1, "Y" => RFrame("date" => dates, "value" => B));
                                          benchmark = "X", rolling_years = 1))
            # einzelnes Ergebnis von simulation() mit Sparplan, Rebalancing und Steuer, RFrame (seit 1.6.1)
            r = simulation(d, st; start_value = 1e5, dca = dca_plan(; value = 500, span = 1),
                           rebalance = rebalance_plan(; unit = "quarter"), tax = tax_profile(; base_rate = 2))
            sh(r); sh(r_summary(r))
            sh(DeepAnalysis.result_analysis(r))
        end
        _precompile_more(d, nt, dates, A3, st, stn, ra, rb, rc, rd, sh, step)
    finally
        RParallel._PRECOMPILE_THREADED[] = false
    end
    return nothing
end

"""Weitere Erstaufrufe (seit 1.6.3; K41 Teil B: 78 von 129 Exporten ohne Arbeitslast, Erstaufrufe 1–5 s mit 75–99 %
Übersetzung): Grafiken, Entnahme über Pfade, Taktik, Prüfungen auf Überanpassung, `cores = 2` über `_threaded`."""
function _precompile_more(d, nt, dates, A3, st, stn, ra, rb, rc, rd, sh, step)
    n = length(dates)
    pl(x) = sh(r_plot(x))
    step("plots") do
        x1 = RFrame("date" => dates, "value" => d["A"])
        ra2 = DeepAnalysis.result_analysis(RList("X" => x1, "Y" => RFrame("date" => dates, "value" => d["B"]));
                                           benchmark = "X", rolling_years = 1)
        pl(ra2)
        sa = AnalysisTests.signal_analysis(nt, "C", "A"; horizon = 21, bins = 5)
        pl(sa)
        ps = ParamSearch.param_search(RFrame("date" => dates, "A" => nt["A"], "B" => nt["B"]);
                                      space = ParamSearch.param_space("rebalance.thresh" => [2.0, 5.0, 10.0]),
                                      strategy = stn, sim_args = RList("rebalance" => rebalance_plan(; span = 1, unit = "month")),
                                      keep_returns = "day", cores = 1)
        ParamSearch.param_plateau(ps); pl(ps)
        wf = Overfitting.overfit_walk_forward(ps; train = 1, test = 1)
        sh(wf); pl(wf)
        rot = Tactical.tactical_rotation(d, A3; top = 2, absolute = false)
        pl(rot)
    end
    step("withdrawal_paths") do
        cfg = Bootstrap.bootstrap_config((a = "A",); aux = (infl = "infl",), input = "prices", aux_type = (infl = "rate",))
        b = Bootstrap.bootstrap(d, cfg, "stationary"; n = 3, path_length = 1000, seed = 1, progress = false)
        wp = Withdrawal.withdrawal_paths(b; column = "a", inflation = "infl")
        w = Withdrawal.withdrawal_simulation(wp, Withdrawal.withdrawal_rule("constant"))
        sh(w); pl(w)
        sv = Bootstrap.bootstrap_study(d, cfg, "stationary"; n = 3, path_length = 1000, seed = 1, progress = false,
                                       strategies = (eq = create_strategy(a = asset_config("etf", "bnh")),),
                                       keep_returns = "month", keep_aux = ["infl"], cores = 1)
        Withdrawal.withdrawal_max_rate(sv, Withdrawal.withdrawal_rule("constant"); success = 0.5, inflation = "infl", tol = 1)
        pl(sv)
    end
    step("tactical") do
        Tactical.tactical_conditional_volatility(d, ["A" => 1], "B")
        Tactical.tactical_rules(d, [(when = "A > B", weights = ["A" => 1]), (when = "C > 100 & A < 120", weights = ["C" => 1])],
                                ["B" => 1])
        Tactical.tactical_target_volatility(d, ["A" => 1], "B")
    end
    step("analyse") do
        Rm = hcat(ra, rb, rc, rd)
        sh(AnalysisTests.overfit_reality_check(Rm[1:500, :]; B = 20, frequency = "week", seed = 1))
        sh(Overfitting.sharpe_deflated(Rm[1:500, :]))
        bc = RFrame("date" => dates, "p" => 2 .* nt["A"] .* (1 .- 1e-5 .* (1:n)), "i" => nt["A"])
        sh(Backcast.backcast_fit(bc, "p", "i"; method = "grid"))
        sh(Optimize.portfolio_risk_contributions(nt, ["A" => 0.5, "B" => 0.3, "C" => 0.2]; cov = "ledoit_wolf"))
        sh(Optimize.portfolio_rolling(nt, A3; window = 1, every = "month", cov = "ledoit_wolf"))
        sh(Scenarios.scenario_entropy_pooling(nt, ["A", "B"], [Scenarios.view_mean("A", 0.0), Scenarios.view_vol("B", 0.009; op = "<=")];
                                              frequency = "day"))
        sh(Bootstrap.bootstrap_probability(Bootstrap.bootstrap_study(nt, Bootstrap.bootstrap_config((x = "A",); input = "prices"),
                                                                      "stationary"; n = 2, path_length = 200, seed = 3,
                                                                      progress = false, cores = 1,
                                                                      strategies = (a = create_strategy(x = asset_config("etf", "bnh")),
                                                                                    b = create_strategy(x = asset_config("etf", "bnh")))),
                                           "cagr > 0"; b = "path %in% (1:2)"))
    end
    step("threads") do   # J4: _threaded (cores = 2) auch bei einem Thread im Vorkompilierprozess
        RParallel._PRECOMPILE_THREADED[] = true
        cfgn = Bootstrap.bootstrap_config((x = "A",); input = "prices")
        Bootstrap.bootstrap(nt, cfgn, "stationary"; n = 2, path_length = 200, seed = 1, progress = false, cores = 2)
        Bootstrap.bootstrap_study(nt, cfgn, "stationary"; n = 2, path_length = 200, seed = 2, progress = false,
                                  strategies = (a = create_strategy(x = asset_config("etf", "bnh")),), cores = 2)
        RParallel._PRECOMPILE_THREADED[] = false
    end
    return nothing
end

"Arbeitslast für die Engine (simulation() über den C++-Kern, Ausgabe, Dashboard, Trigger)."
function _precompile_engine()
    n = 800
    dates = collect(Date(2019, 1, 1):Day(1):Date(2019, 1, 1) + Day(n - 1))
    px(a, b) = [100 * (1 + a * i / n + 0.05 * sin(b * i)) for i in 1:n]
    sb = [i % 37 < 5 for i in 1:n]; ss = [i % 37 > 25 for i in 1:n]
    # seit 1.6.4 RFrame (simulation() nimmt nur Tabellen; bis 1.6.3 NamedTuple)
    data = RFrame("date" => dates, "A" => px(0.5, 0.05), "B" => px(0.1, 0.11), "C" => px(3.0, 0.07),
                  "b" => sb, "s" => ss, "ev" => [i % 50 == 0 for i in 1:n], "br" => fill(2.55, n), "w1" => fill(0.6, n))
    s2 = create_strategy(A = asset_config("etf", "bnh", 0.6, 0.1, 30), B = asset_config("etf", "bnh", 0.4, 0.1, 0))
    s3 = create_strategy(A = asset_config("certificate", "signal", 0.4, 0.2, 0; signal_buy = "b", signal_sell = "s"),
                         B = asset_config("etc", "bnh", 0.3, 0.1, 0; deliverable = true),
                         C = asset_config("etf", "bnh", 0.3, 0.1, 30; start = dates[100]))
    io = devnull
    # Variante mit typischen Bausteinen (Satz, Rebalancing, Sparplan, Liquidation), Ausgabe und Zusammenfassung
    r = simulation(data, s2; tax = tax_profile(; base_rate = 2.55), rebalance = rebalance_plan(),
                   dca = dca_plan(100, 1), liquidate = true, io = io)
    format_result(r)
    format_summary(summary(r))
    sprint(show, MIME"text/plain"(), r)
    sprint(show, MIME"text/plain"(), plot_dashboard(r))
    # Signale, Ereignis-Rebalancing, Splits, Satz mit Günstigerprüfung; einmal mit details (Ereignistexte)
    for det in (false, true)
        simulation(data, s3; tax = tax_profile(; income = income_rate(42), guenstigerpruefung = true),
                   rebalance = rebalance_plan(; unit = "quarter", thresh = 2, event_col = "ev", event_weight = (A = "w1",)),
                   splits = split_rule([50, 200]), fractions = false, risk_free = 2, details = det, io = io)
    end
    simulation(data, s2; liquidate = true,
               dca = dca_plan(50.0, 1; days = [1, 15], unit = "month"),
               rebalance = rebalance_plan(; days = 31, anchor = "end"), risk_free = "br", io = io)
    simulation(data, s2; tax = tax_profile(; base_rate = "br"), io = io)
    # Tarifweg mit Kirchensteuer, Freibetrag und Gebühren, mit und ohne details
    for det in (false, true)
        simulation(data, s2; costs = sim_costs((fixed = 1, percent = 0.25), 0),
                   tax = tax_profile(; church_tax = 9, base_rate = 2, guenstigerpruefung = true,
                                     income = income_tariff(50000), harvest = harvest_rule()),
                   dca = dca_plan(100, 1), liquidate = true, details = det, io = io)
    end
    for b in (sim_costs(), dca_plan(100, 1), rebalance_plan(), split_rule([50, 200]), tax_profile(), income_rate(42),
              income_tariff(50000), harvest_rule(), funds_costs())
        sprint(show, MIME"text/plain"(), b)
    end
    # Kernhüllen außerhalb von simulation(): Termine und Zinsfuß
    calculate_dates_flags(true, 1, "month", nothing, dates)
    xirr_rate([0.0, 0.5, 1.0], [1000.0, -200.0, 300.0], 1500.0, 2.0)
    # Fonds-Wrapper: Anteilswert und Wrapper-Asset in simulation()
    w = wrapper_config(s2; rebalance = rebalance_plan(; unit = "quarter"), costs = funds_costs(0.95, 10))
    sprint(show, MIME"text/plain"(), w)
    sprint(show, MIME"text/plain"(), wrapper_nav(data, w))
    simulation(data, create_strategy(Z = asset_config("certificate"; share = 0.7, wrapper = w),
                                     C = asset_config("etf", "bnh", 0.3)); tax = tax_profile(), io = io)
    gaps = RFrame("date" => dates[1:2:end], "A" => px(0.5, 0.05)[1:2:end])
    simulation(gaps, create_strategy(A = asset_config("etf", "bnh", 1.0, 0.1, 30)); io = io)
    rebalance_trigger(RFrame("date" => dates, "target_leverage" => px(0.1, 0.2) ./ 50), "abs_leverage")   # seit 1.6.4 RFrame
    return nothing
end

"Zustand nach der Arbeitslast zurücksetzen (Zufall, Zwischenspeicher, Bibliotheks-Handles)."
function _precompile_reset()
    for f in (() -> (empty!(RExpr._CACHE); empty!(RExpr._CACHE_ORDER)),
              () -> RStats.collate_reset(),
              () -> (_TT_CACHE[] = nothing),   # Tarif (tax_tariff, seit 1.6.3)
              () -> (RParallel._PRECOMPILE_THREADED[] = false))
        try
            f()
        catch
        end
    end
    return nothing
end

"""Arbeitslast im laufenden Prozess mit sichtbaren Fehlern (seit 1.6.4, K43 T1-N7): Engine und Erweiterungen wie
beim Vorkompilieren, danach `_precompile_reset()`. Rückgabe: Vektor `Bezeichnung => Meldung` der gescheiterten Schritte
(leer: alle liefen). Werkzeug: `julia --project=julia tests/werkzeuge/precompile_check.jl`."""
function _precompile_check()
    errs = Pair{String,String}[]
    _PRECOMPILE_ERRORS[] = errs
    try
        try
            _precompile_engine()
        catch e
            _precompile_fail("engine", e)
        end
        try
            _precompile_ext()
        catch e
            _precompile_fail("ext", e)
        end
    finally
        _PRECOMPILE_ERRORS[] = nothing
        _precompile_reset()
    end
    return errs
end

if ccall(:jl_generating_output, Cint, ()) == 1 && !REnv.skip_precompile()
    try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do; redirect_stderr(devnull) do
            try
                _precompile_engine()
            catch
            end
            REnv.skip_precompile_ext() || _precompile_ext()
            try
                _precompile_statements()
            catch
            end
        end; end
    catch
        # Fehler in der Arbeitslast (auch beim Umleiten von stderr) verhindern das Laden nie
    end
    _precompile_reset()
end
