# Messbasis SimLev, Julia (Etappe 3, tools/bench). Aufgaben siehe README.md.
#
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 julia --project=julia tools/bench/bench.jl [ausgabe.csv] [aufgaben]
# aufgaben: kommagetrennt (z. B. T1,T8), Voreinstellung alle außer P1. P1 (= P1c1, P1c2) misst
# bootstrap mit cores = 1 und 2 (Threads; Julia mit `-t 2` starten) nur auf Anforderung.
# Je Aufgabe 1 Aufwärmlauf (erster_lauf_s; enthält in Julia die Kompilierung),
# dann 3 gemessene Läufe (Median, Min, Max). Ein Kern: cores = 1, wo die
# Funktion es kennt; Threads setzt run.sh. Die Daten entstehen mit dem
# Zufall von SimLev (simlev_seed, SimLev.SLib; seit Etappe 9.6a) und sind dieselben
# Zahlen wie in bench.R (Prüfsumme in der Ausgabe).

const OUT = length(ARGS) >= 1 ? ARGS[1] : joinpath("tools", "bench", "out", "julia.csv")
const ONLY = length(ARGS) >= 2 ? reduce(vcat, [a == "P1" ? ["P1c1", "P1c2"] : [String(a)] for a in split(ARGS[2], ",")]) : nothing
const RUNS = 3

const T_LOAD = @elapsed @eval using SimLev
using Dates, Printf, Logging

median(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

const R = SimLev.SLib   # seit Etappe 9.6a: Zufall von SimLev (vorher RRng)
const RB = SimLev.RBase

path(level, n, m, s) = level .* RB.r_cumprod(1 .+ R.rnorm(n, m, s))

# ── Daten wie bench.R ──
SimLev.simlev_seed(1); n = 10958
A = path(100, n, 3e-4, 0.01); B = path(50, n, 1e-4, 0.003)
d30 = (date = collect(Date(1995, 1, 1):Day(1):(Date(1995, 1, 1) + Day(n - 1))), A = A, B = B)
SimLev.simlev_seed(7); n = 7305
ak = path(100, n, 3e-4, 0.011); bo = path(100, n, 1e-4, 0.003); go = path(100, n, 2e-4, 0.009); em = path(100, n, 3e-4, 0.014)
d = (date = collect(Date(2000, 1, 1):Day(1):(Date(2000, 1, 1) + Day(n - 1))), aktien = ak, bonds = bo, gold = go, em = em)
W = reshape(1 .+ R.rnorm(30 * 2000, 0.05, 0.15), 30, 2000)

function sim_msgjr(n, om, al, ga, be, P, seed)
    SimLev.simlev_seed(seed); K = length(om)
    hk = om ./ (1 .- al .- ga ./ 2 .- be); s = 1; y = zeros(n)
    for t in 1:n
        if t > 1
            s = Int(first(R.sample(K, 1; prob = P[s, :]))); e = y[t-1]
            hk = om .+ (al .+ ga .* Float64(e < 0)) .* (e * e) .+ be .* hk
        end
        y[t] = sqrt(hk[s]) * first(R.rnorm(1))
    end
    y
end
y8 = sim_msgjr(2000, [2e-6, 2e-5], [0.02, 0.05], [0.04, 0.10], [0.92, 0.85], [0.99 0.01; 0.03 0.97], 7)

fp(x) = @sprintf("%.17g", RB.r_sum(vec(x)))
println("Daten: S30 ", fp(d30.A), ", T ", fp(d.em), ", W ", fp(W), ", T8 ", fp(y8))

st30 = create_strategy(A = asset_config("etf", "bnh"; share = 0.7), B = asset_config("etf", "bnh"; share = 0.3))
cfg = bootstrap_config((akt = "aktien",); input = "prices")
st = create_strategy(akt = asset_config("etf", "bnh"))
A4 = ["aktien", "bonds", "gold", "em"]

const TASKS = [
    "S30" => () -> simulation(d30, st30; start_value = 1e4, dca = dca_plan(; value = 200, span = 1), rebalance = rebalance_plan(; unit = "quarter"), tax = tax_profile(; base_rate = 2)),
    "T1" => () -> bootstrap(d, cfg, "stationary"; n = 200, seed = 1, progress = false, path_length = 2520, cores = 1),
    "T2" => () -> bootstrap(d, cfg, "garch"; n = 50, seed = 1, progress = false, path_length = 2520, cores = 1),
    "T3" => () -> bootstrap_study(d, cfg, "stationary"; n = 50, path_length = 2520, seed = 1, progress = false,
                                  strategies = (a = st,), cores = 1),
    "T4" => () -> withdrawal_simulation(W, withdrawal_rule("constant"; rate = 4); start_value = 1e6),
    "T5" => () -> dependence_analysis(d, A4; copulas = false),
    "T6" => () -> portfolio_optimize(d; assets = A4, method = "min_cvar"),
    "T7" => () -> portfolio_optimize(d; assets = A4, method = "hrp"),
    "T8" => () -> SimLev.MsGarch._ms_garch_fit(y8, 2, "gjrGARCH"),
    "P1c1" => () -> bootstrap(d, cfg, "stationary"; n = 400, seed = 1, progress = false, path_length = 2520, cores = 1),
    "P1c2" => () -> bootstrap(d, cfg, "stationary"; n = 400, seed = 1, progress = false, path_length = 2520, cores = 2),
]
any(t -> startswith(t, "P"), something(ONLY, String[])) && Threads.nthreads() < 2 &&
    @warn "P1: Julia läuft mit einem Thread; cores = 2 rechnet dann nacheinander (julia -t 2)"


function el(f)
    with_logger(NullLogger()) do
        redirect_stdio(stdout = devnull, stderr = devnull) do
            t = time_ns(); f(); (time_ns() - t) / 1e9
        end
    end
end

rows = Any[("Laden", "Julia", T_LOAD, T_LOAD, T_LOAD, T_LOAD)]
for (k, f) in TASKS
    (ONLY === nothing ? !startswith(k, "P") : k in ONLY) || continue
    first_s = el(f)
    ts = [el(f) for _ in 1:RUNS]
    push!(rows, (k, "Julia", median(ts), minimum(ts), maximum(ts), first_s))
    @printf("%-4s median %.3f s (min %.3f, max %.3f; erster Lauf %.3f)\n", k, median(ts), minimum(ts), maximum(ts), first_s)
    flush(stdout)
end
mkpath(dirname(OUT))
open(OUT, "w") do io
    println(io, "aufgabe,sprache,median_s,min_s,max_s,erster_lauf_s")
    for r in rows
        @printf(io, "%s,%s,%.4f,%.4f,%.4f,%.4f\n", r...)
    end
end
println("-> ", OUT)
