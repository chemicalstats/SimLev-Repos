# Kleine Arbeitslast beim Vorkompilieren: Maschinencode für die Engine und die
# häufigen Wege der Erweiterungen – für die hier benutzten Argumenttypen –
# landet im Paket-Cache. Das verkürzt den ersten Aufruf von simulation(),
# bootstrap() (stationär, GARCH über die ML-Schätzung der C-Bibliothek slc), bootstrap_study(),
# der MS-GARCH-Schätzung, withdrawal_simulation(), portfolio_optimize(),
# result_analysis() und des Fonds-Wrappers (wrapper_nav(), Wrapper-Asset) deutlich, macht ihn aber nicht so schnell wie spätere
# Aufrufe: Laden des Caches, Laufzeit-Dispatch und Methoden für andere
# Argumenttypen (oder Pfade, die die Arbeitslast nicht berührt) kosten beim
# ersten Aufruf weiterhin Übersetzungszeit.
#
# Auswahl (Etappe 4.8): Jeder Baustein kostet bei jeder Änderung am Paket
# Vorkompilierzeit. Seltene Wege (param_search/Überanpassung,
# dependence_analysis, Szenarien, Sensitivitäten, Taktik, Planung,
# series_align) übersetzt erst ihr erster Aufruf; dafür sind GARCH (bootstrap
# "garch", bis 9.6b über die rugarch-Nachbildung) und MS-GARCH (_ms_garch_fit)
# aufgenommen, deren erster Lauf sonst 10 bzw. 6 s dauerte.
#
# Die Arbeitslast verändert den Laufzeitzustand nicht: Die Daten kommen aus
# einem eigenen SimLev-Strom (`SLib.main_stream(1)`, der globale Zustand bleibt
# unberührt; seit Etappe 9.6b statt der R-Nachbildung `RRng`, die mit 9.6c entfallen ist), Zwischenspeicher
# und Bibliotheks-Handles (ICU) werden geleert, damit keine Zeiger aus der
# Vorkompilierung in den Cache geraten. Jeder Baustein läuft in `try`; die gesamte Arbeitslast steht
# zusätzlich in `try … catch`: Ein Fehler (z. B. fehlende ICU,
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
    try
        n = 900
        dates = collect(Date(2015, 1, 1):Day(1):Date(2015, 1, 1) + Day(n - 1))
        rs = SLib.main_stream(1)
        ra = SLib.rnorm(n, 3e-4, 0.01; stream = rs); rb = SLib.rnorm(n, 1e-4, 0.004; stream = rs)
        rc = SLib.rnorm(n, 2e-4, 0.007; stream = rs)
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
            Bootstrap.bootstrap_block_length(ra)
            stv = Bootstrap.bootstrap_study(d, Bootstrap.bootstrap_config((A = "A",); input = "prices"), "stationary";
                                            n = 2, path_length = 200, seed = 2, progress = false,
                                            strategies = (a = st1,))
            sh(stv); sh(r_summary(stv))
            sh(Bootstrap.bootstrap_probability(stv, "cagr > 0 & max_drawdown < 0.5"))
        end
        # GARCH (ML-Schätzung in slc, bootstrap "garch") und MS-GARCH-Schätzung
        step("garch") do
            cfg = Bootstrap.bootstrap_config((akt = "A",); input = "prices")
            sh(Bootstrap.bootstrap(d, cfg, "garch"; n = 2, path_length = 200, seed = 1, progress = false))
        end
        step("ms_garch") do
            MsGarch._ms_garch_fit(rb[1:300], 2, "gjrGARCH")
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
            sh(DeepAnalysis.result_analysis(RList("X" => x1, "Y" => RFrame("date" => dates, "value" => B));
                                          benchmark = "X", rolling_years = 1))
        end
    finally
        # Zwischenspeicher wie vorher (der globale Zufallszustand bleibt unberührt)
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
                         C = asset_config("etf", "bnh", 0.3, 0.1, 30; start = dates[100]))
    io = devnull
    for det in (false, true)
        r = simulation(data, s2; tax = tax_profile(; base_rate = 2.55), rebalance = rebalance_plan(),
                       dca = dca_plan(100, 1), liquidate = true, details = det, io = io)
        format_result(r)
        format_summary(summary(r))
        sprint(show, MIME"text/plain"(), r)
        simulation(data, s3; tax = tax_profile(; income = income_rate(42), guenstigerpruefung = true),
                   rebalance = rebalance_plan(; unit = "quarter", thresh = 2, event_col = "ev", event_weight = (A = "w1",)),
                   splits = split_rule([50, 200]), fractions = false, risk_free = 2, details = det, io = io)
        simulation(data, s2; liquidate = true,
                   dca = dca_plan(50.0, 1; days = [1, 15], unit = "month"),
                   rebalance = rebalance_plan(; days = 31, anchor = "end"), risk_free = "br", details = det, io = io)
        simulation(data, s2; tax = tax_profile(; base_rate = "br"), io = io)
    end
    simulation(data, s2; costs = sim_costs((fixed = 1, percent = 0.25), 0),
               tax = tax_profile(; church_tax = 9, base_rate = 2, guenstigerpruefung = true,
                                 income = income_tariff(50000), harvest = harvest_rule()),
               dca = dca_plan(100, 1), liquidate = true, io = io)
    for b in (sim_costs(), dca_plan(100, 1), rebalance_plan(), split_rule([50, 200]), tax_profile(), income_rate(42),
              income_tariff(50000), harvest_rule(), funds_costs())
        sprint(show, MIME"text/plain"(), b)
    end
    # Fonds-Wrapper (Etappe 6.5c): Anteilswert und Wrapper-Asset in simulation()
    w = wrapper_config(s2; rebalance = rebalance_plan(; unit = "quarter"), costs = funds_costs(0.95, 10))
    sprint(show, MIME"text/plain"(), w)
    sprint(show, MIME"text/plain"(), wrapper_nav(data, w))
    simulation(data, create_strategy(Z = asset_config("certificate"; share = 0.7, wrapper = w),
                                     C = asset_config("etf", "bnh", 0.3)); tax = tax_profile(), io = io)
    gaps = (date = dates[1:2:end], A = px(0.5, 0.05)[1:2:end])
    simulation(gaps, create_strategy(A = asset_config("etf", "bnh", 1.0, 0.1, 30)); io = io)
    rebalance_trigger((date = dates, target_leverage = px(0.1, 0.2) ./ 50), "abs_leverage")
    return nothing
end

"Zustand nach der Arbeitslast zurücksetzen (Zufall, Zwischenspeicher, Bibliotheks-Handles)."
function _precompile_reset()
    for f in (() -> empty!(RExpr._CACHE),
              () -> RStats.collate_reset())
        try
            f()
        catch
        end
    end
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1 && !REnv.skip_precompile()
    try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do; redirect_stderr(devnull) do
            try
                _precompile_engine()
            catch
            end
            REnv.skip_precompile_ext() || _precompile_ext()
        end; end
    catch
        # Fehler in der Arbeitslast (auch beim Umleiten von stderr) verhindern das Laden nie
    end
    _precompile_reset()
end
