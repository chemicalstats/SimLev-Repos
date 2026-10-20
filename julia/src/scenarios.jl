# Scenarios – Port von r/R/scenarios.R (Vorlage python/simlev/scenarios.py)
#
#   entropy_pooling()   gewichtet Szenarien so um, dass sie eigene Annahmen
#                       ("Views") erfüllen, bei minimaler relativer Entropie
#                       (Meucci 2008, Fully Flexible Probabilities)
#   view_mean(), view_prob(), view_vol()   Bausteine für Annahmen
#   copula_scenarios()  Szenarien aus t- bzw. Gauss-Copula mit empirischen
#                       Rändern, optional unter Stress
#   scenario_risk()     Portfolio-Kennzahlen auf (gewichteten) Szenarien
#   crisis_replay()     ein Portfolio durch historische Krisenfenster
#
# `view_prob(expr, …)`: `expr` ist ein Ausdruck als Text in R-Syntax über den
# Spalten der Szenarien (z. B. "aktien < -2 & inflation > 2"), ausgewertet wie
# `Dependence._eval_condition` mit dem gemeinsamen Auswerter `SimLev.RExpr`
# (R-Syntax, Vorrang und NA-Logik wie R; freie Variablen aus `env`).
module Scenarios

import ..SimLev
using Dates

export view_mean, view_prob, view_vol, entropy_pooling, copula_scenarios, scenario_risk, crisis_replay

const _NA = SimLev.NA
const RFrame = SimLev.RFrame
const RList = SimLev.RList
const RVector = SimLev.RVector
const NamedMat = SimLev.NamedMat

_D() = SimLev.Dependence
_fmat(X) = SimLev.Dependence._fmat(X)
_fvec(x) = SimLev.Dependence._fvec(x)

_is_num_scalar(v) = v isa Real && !(v isa Bool)

"Zielwert einer Annahme prüfen (eine endliche Zahl, ggf. mit Bereich)."
function _view_value(value, what, lo = -Inf, hi = Inf)
    a = value === nothing ? Any[] : value isa AbstractVector || value isa Tuple ? collect(value) : Any[value]
    ok = length(a) == 1 && _is_num_scalar(a[1]) && isfinite(Float64(a[1])) && lo <= a[1] <= hi
    if !ok
        rng = (isfinite(lo) && isfinite(hi)) ? _D()._sprintf(" zwischen %g und %g", lo, hi) :
              isfinite(lo) ? _D()._sprintf(" >= %g", lo) : ""
        got = isempty(a) ? "" : _D()._fmt1(value)
        error("$what: value muss eine endliche Zahl$rng sein (erhalten: $got).")
    end
    value isa AbstractVector ? value[1] : value
end

_ops = ("=", "<=", ">=")

"Annahme an den Erwartungswert einer Spalte (Einheit der Spalte)."
view_mean(var, value, op_pos = _ops; op = op_pos) =
    (v = _view_value(value, "view_mean"); RList("type" => "mean", "var" => var, "value" => v, "op" => _D()._match_arg(op, _ops)))

"Annahme an die Wahrscheinlichkeit eines Ereignisses (Ausdruck als Text über den Spalten)."
view_prob(expr, value, op_pos = _ops; op = op_pos) =
    (v = _view_value(value, "view_prob", 0, 1); RList("type" => "prob", "expr" => expr, "value" => v, "op" => _D()._match_arg(op, _ops)))

"Annahme an die Standardabweichung einer Spalte (Einheit der Spalte, >= 0)."
view_vol(var, value, op_pos = _ops; op = op_pos) =
    (v = _view_value(value, "view_vol", 0); RList("type" => "vol", "var" => var, "value" => v, "op" => _D()._match_arg(op, _ops)))

"Szenario-Tabelle aus Daten (Renditen in Prozent je Periode, Zustände verzögert) oder `as.data.frame(x)`."
function _scen_frame(x, assets, states, frequency)
    D = _D()
    if D._is_frame(x) && haskey(D._as_frame(x), "date")
        rd = D._dep_returns(x, assets, states, frequency)
        for a in D._as_names(assets)
            rd[a] = 100 .* SimLev.RLibm.expm1.(_fvec(rd[a]))
        end
        ok = D._complete_rows((rd[c] for c in names(rd))...)
        return SimLev.rows(rd, findall(ok))
    end
    D._is_frame(x) && return D._as_frame(x)
    if x isa NamedMat && x.colnames !== nothing
        M = _fmat(x)
        return RFrame((x.colnames[j] => M[:, j] for j in 1:size(M, 2))...)
    end
    M = _fmat(x)
    RFrame(("V$j" => M[:, j] for j in 1:size(M, 2))...)
end

"`stats::cov2cor`."
_cov2cor(V) = _fmat(SimLev.RStats.cov2cor(_fmat(V)))

_vget(v, k) = SimLev.Dependence._getopt(v, k)

"""
    entropy_pooling(x, assets, views; states = nothing, frequency = "week", prior = nothing, env = Main)

Entropy Pooling: Szenarien (`x`: Kursdaten mit `date` oder fertige
Szenario-Tabelle) auf Annahmen aus `view_mean`, `view_prob`, `view_vol`
umgewichten. Klasse `SimLevScenarios`.
"""
function entropy_pooling(x, assets, views; states = nothing, frequency = ("week", "day", "month"), prior = nothing, env = Main)
    x = SimLev.as_rframe(x)
    D = _D()
    frequency = D._match_arg(frequency, ("week", "day", "month"))
    assets = D._as_names(assets)
    states_l = D._as_names(states)
    S = _scen_frame(x, assets, states, frequency)
    Tn = SimLev.nrow(S)
    if prior !== nothing
        pa = prior isa RVector ? prior.values : prior isa AbstractVector ? prior : [prior]
        isnum = all(v -> v isa Real && !(v isa Bool), pa)
        bad = !isnum || length(pa) != Tn
        if !bad
            pf = _fvec(pa)
            bad = !all(isfinite, pf) || any(<(0), pf) || SimLev.r_sum(pf) <= 0
        end
        if bad
            neg = isnum && any(v -> !isnan(Float64(v)) && v < 0, pa) ? ", negative Werte" : ""
            error("entropy_pooling: prior muss $Tn endliche Werte >= 0 mit positiver Summe haben (einer je Szenario; " *
                  "erhalten: Länge $(length(pa))$neg).")
        end
        p = _fvec(pa)
    else
        p = fill(1 / Tn, Tn)
    end
    p = p ./ SimLev.r_sum(p)
    vars = [v for v in unique(vcat(assets, states_l)) if haskey(S, v)]
    cols = Dict(v => _fvec(S[v]) for v in vars)
    m0 = Dict(v => SimLev.r_sum(p .* cols[v]) for v in vars)
    views = views === nothing ? Any[] : collect(views)
    mean_view = Dict{String,Float64}()
    for v in views
        (_vget(v, "type") == "mean" && _vget(v, "op") == "=") && (mean_view[String(_vget(v, "var"))] = Float64(_vget(v, "value")))
    end
    Fs = Vector{Float64}[]; bs = Float64[]; ineqs = Bool[]
    for v in views
        t = _vget(v, "type")
        f = if t == "mean"
            haskey(S, String(_vget(v, "var"))) ? _fvec(S[String(_vget(v, "var"))]) : nothing
        elseif t == "prob"
            ex = _vget(v, "expr")
            r = D._eval_condition(ex, S; env = env)
            ex isa AbstractString ? SimLev.RExpr.as_numeric(r) : Float64[D._num1(e isa Bool ? Float64(e) : e) for e in r]
        elseif t == "vol"
            vn = String(_vget(v, "var"))
            if haskey(S, vn)
                mu = get(mean_view, vn, get(m0, vn, _NA))
                dvec = _fvec(S[vn]) .- mu
                dvec .* dvec
            else
                Float64[]
            end
        else
            error("Unbekannter View-Typ.")
        end
        if f === nothing || length(f) != Tn
            nm = _vget(v, "var") !== nothing ? _vget(v, "var") : _vget(v, "expr")
            error("View '$nm' passt nicht zu den Szenarien.")
        end
        val0 = _vget(v, "value")
        t == "vol" && !(_is_num_scalar(val0) && val0 >= 0) && error("view_vol: Standardabweichung muss >= 0 sein.")
        val = t == "vol" ? Float64(val0) * Float64(val0) : Float64(val0)
        sg = Dict("=" => 0, "<=" => 1, ">=" => -1)[_vget(v, "op")]
        push!(Fs, sg == -1 ? -f : f); push!(bs, sg == -1 ? -val : val); push!(ineqs, sg != 0)
    end
    q = p
    if !isempty(Fs)
        A = permutedims(reduce(hcat, Fs))          # Annahmen × Szenarien
        b = bs; ineq = ineqs
        function dual(l)
            e = .-vec(_fmat(D._flex(SimLev.RLinalg.crossprod, (A, reshape(_fvec(l), :, 1)))))
            mx = D._rmax(e)
            w = p .* SimLev.RLibm.exp.(e .- mx)
            Z = SimLev.r_sum(w)
            SimLev.RLibm.log(Z) + mx + SimLev.r_sum(_fvec(l) .* b), w ./ Z
        end
        fn(l) = dual(l)[1]
        gr(l) = b .- D._matvec(A, dual(l)[2])
        lower = [ineq[i] ? 0.0 : -Inf for i in eachindex(b)]
        o = SimLev.RStats.optim(zeros(length(b)), fn, gr; method = "L-BFGS-B", lower = lower,
                                control = Dict{String,Any}("maxit" => 5000, "factr" => 1e3, "pgtol" => 1e-12))
        q = dual(_fvec(D._el(o, "par")))[2]
        viol = D._matvec(A, q) .- b
        for i in eachindex(viol)
            ineq[i] && (viol[i] = isnan(viol[i]) ? viol[i] : max(viol[i], 0.0))
        end
        mv = D._rmax(abs.(viol))
        mv > 1e-4 * D._rmax(1.0, abs.(b)) && @warn "Annahmen nicht vollständig erfüllbar (Abweichung $(D._sprintf("%.2e", mv)))."
    end
    wsd(v, w) = (m = SimLev.r_sum(w .* v); dv = v .- m; sqrt(SimLev.r_sum(w .* (dv .* dv))))
    summ = RFrame("var" => vars, "mean_prior" => Float64[m0[v] for v in vars],
                  "mean_post" => Float64[SimLev.r_sum(q .* cols[v]) for v in vars],
                  "sd_prior" => Float64[wsd(cols[v], p) for v in vars], "sd_post" => Float64[wsd(cols[v], q) for v in vars])
    Xa = reduce(hcat, [_fvec(S[a]) for a in assets])
    Xa = reshape(Xa, Tn, length(assets))
    mu = D._colsums(Xa .* q)
    sq = sqrt.(q)
    Xc = Matrix{Float64}(undef, Tn, length(assets))
    for j in 1:length(assets), i in 1:Tn
        Xc[i, j] = (Xa[i, j] - mu[j]) * sq[i]
    end
    C = _fmat(D._flex(SimLev.RLinalg.crossprod, (Xc,)))
    qp = q[q .> 0]
    out = RList(; class = ["SimLevScenarios"])
    out["scenarios"] = S
    out["prob"] = q
    out["prior"] = p
    out["assets"] = assets
    out["states"] = states
    out["views"] = views
    out["effective_n"] = SimLev.RLibm.exp(-SimLev.r_sum(qp .* SimLev.RLibm.log.(qp)))
    out["summary"] = summ
    out["correlation"] = NamedMat(_cov2cor(C); rownames = assets, colnames = assets)
    out["frequency"] = frequency
    out["kind"] = "entropy_pooling"
    out
end

"`approx(xg, yg, u, rule = 2)\$y` als Funktion."
_approx_fn(xg, yg) = u -> _fvec(D_el(_D()._flex(SimLev.RStats.approx, (xg, yg), NamedTuple(), (xout = _fvec(u), rule = 2)), "y"))
D_el(o, k) = _D()._el(o, k)

_rnorm_mat(m, k) = reshape(_fvec(SimLev.RRng.rnorm(Int(m * k))), Int(m), Int(k))
_chol(A) = _fmat(SimLev.RLinalg.chol(_fmat(A)))
_solve(A) = _fmat(SimLev.RLinalg.solve(_fmat(A)))
_rchisq(n, df) = _fvec(SimLev.RRng.rchisq(Int(n), Float64(df)))

"Benannte Liste (Stress-Bänder): Paare Name => Wert in Reihenfolge; `nothing`, wenn unbenannt."
function _named_list(x)
    x isa NamedTuple && return [String(k) => v for (k, v) in pairs(x)]
    x isa AbstractDict && return [String(k) => v for (k, v) in x]
    x isa AbstractVector{<:Pair} && return [String(p.first) => p.second for p in x]
    nothing
end

"""
    copula_scenarios(x, assets; n = 10000, family = "t", stress = nothing, frequency = "week", seed = nothing)

Szenarien aus einer t- bzw. Gauss-Copula mit empirischen Rändern. `stress`:
benannte Liste (NamedTuple, RList, Vektor von Paaren) von Quantilbändern je
Anlage, z. B. `(aktien = [0, 0.05],)`. Klasse `SimLevScenarios`.
"""
function copula_scenarios(x, assets; n = 10000, family = ("t", "gaussian"), stress = nothing,
                          frequency = ("week", "day", "month"), seed = nothing)
    x = SimLev.as_rframe(x)
    D = _D()
    family = D._match_arg(family, ("t", "gaussian"))
    frequency = D._match_arg(frequency, ("week", "day", "month"))
    assets = D._as_names(assets)
    S = _scen_frame(x, assets, nothing, frequency)
    X = reshape(reduce(hcat, [_fvec(S[a]) for a in assets]), SimLev.nrow(S), length(assets))
    Tn, k = size(X)
    U = reduce(hcat, [D._pobs(X[:, j]) for j in 1:k])
    U = reshape(U, Tn, k)
    tau = _fmat(D._kendall(NamedMat(X; colnames = assets)))
    R = SimLev.RLibm.sin.(pi .* tau ./ 2)
    named = true
    ev = D._flex(SimLev.RLinalg.eigen, (R,), NamedTuple(), (symmetric = true,))
    vals = _fvec(D._el(ev, "values"))
    if D._rmin(vals) < 1e-6
        V = _fmat(D._el(ev, "vectors"))
        Dg = zeros(k, k)
        for i in 1:k
            Dg[i, i] = (1e-6 > vals[i] || isnan(1e-6)) ? 1e-6 : vals[i]
        end
        R = D._matprod(D._matprod(V, Dg), permutedims(V))
        R = _cov2cor(R)
        named = false
    end
    Ri = _solve(R)
    ldR = Float64(D._el(D._flex(SimLev.RLinalg.determinant, (R,)), "modulus"))
    lgam = D._lgamma
    function ll_t(nu)
        Z = reshape(SimLev.RNmath.qt.(U, nu), Tn, k)
        qv = D._rowsums(D._matprod(Z, Ri) .* Z)
        c0 = lgam((nu + k) / 2) + (k - 1) * lgam(nu / 2) - k * lgam((nu + 1) / 2) - 0.5 * ldR
        terms = (c0 .- (nu + k) / 2 .* SimLev.RLibm.log1p.(qv ./ nu)) .+ (nu + 1) / 2 .* D._rowsums(SimLev.RLibm.log1p.(Z .* Z ./ nu))
        SimLev.r_sum(terms)
    end
    nu = family == "t" ? D._optimize(v -> -ll_t(v), 2.1, 100.0)[1] : Inf
    grid = (collect(1:Tn) .- 0.5) ./ Tn
    qmarg = [_approx_fn(grid, SimLev.RStats.r_sort(X[:, j])) for j in 1:k]
    st_list = nothing
    if stress !== nothing
        st_list = _named_list(stress)
        if st_list === nothing || isempty(st_list) || any(p -> p.first == "", st_list) ||
           length(unique(first.(st_list))) < length(st_list)
            error("stress: benannte Liste von Quantilbändern je Anlage erwartet, z. B. list(aktien = c(0, 0.05)).")
        end
        unk = [p.first for p in st_list if !(p.first in assets)]
        isempty(unk) || error("stress: unbekannte Anlage(n) $(join(["'$u'" for u in unique(unk)], ", ")); vorhanden: $(join(assets, ", ")).")
        for (a, b) in st_list
            ba = b isa AbstractVector || b isa Tuple ? collect(b) : Any[b]
            good = length(ba) == 2 && all(_is_num_scalar, ba) && all(v -> isfinite(Float64(v)), ba) &&
                   ba[1] >= 0 && ba[2] <= 1 && ba[1] < ba[2]
            good || error("stress: Band für '$a' muss c(von, bis) mit 0 <= von < bis <= 1 sein (Anteile, keine Prozent; " *
                          "erhalten: $(D._fmt1(b))).")
        end
    end
    n = Int(n)
    fin = isfinite(nu)
    sim = D._with_rng_restore(seed) do
        st = st_list === nothing ? Int[] : [findfirst(==(p.first), assets) for p in st_list]
        Z = zeros(n, k)
        if length(st) == 1
            band = _fvec(st_list[1].second)
            u = _fvec(SimLev.RRng.runif(n, band[1], band[2]))
            Z[:, st[1]] = fin ? SimLev.RNmath.qt.(u, nu) : SimLev.RNmath.qnorm.(u)
        elseif length(st) > 1
            ks = length(st)
            Ls = _chol(R[st, st])
            lo = [Float64(_fvec(p.second)[1]) for p in st_list]; hi = [Float64(_fvec(p.second)[2]) for p in st_list]
            parts = Matrix{Float64}[]
            nz = 0; drawn = 0.0; m = 100000
            while true
                E = D._matprod(_rnorm_mat(m, ks), Ls)
                if fin
                    sc = sqrt.(_rchisq(m, nu) ./ nu)
                    E = E ./ sc
                end
                Ub = fin ? SimLev.RNmath.pt.(E, nu) : SimLev.RNmath.pnorm.(E)
                hit = [count(j -> Ub[i, j] >= lo[j] && Ub[i, j] <= hi[j], 1:ks) == ks for i in 1:size(E, 1)]
                push!(parts, E[hit, :])
                nz += count(hit); drawn += m
                nz >= n && break
                drawn >= 5e7 && error("stress: Bänder gemeinsam zu unwahrscheinlich (Trefferquote $(D._sprintf("%.1e", nz / drawn)) " *
                                      "bei $(D._sprintf("%.0e", drawn)) Ziehungen); Bänder erweitern oder weniger Anlagen stressen.")
                m = Int(min(1e6, max(1e5, ceil(1.2 * (n - nz) / max(nz / drawn, 1e-7)))))
            end
            Zs = reduce(vcat, parts)
            Z[:, st] = Zs[1:n, :]
        end
        if !isempty(st)
            rest = [j for j in 1:k if !(j in st)]
            if !isempty(rest)
                Rss = R[st, st]; Rrs = R[rest, st]; Rss_i = _solve(Rss)
                RR = D._matprod(Rrs, Rss_i)
                M = D._matprod(Z[:, st], permutedims(RR))
                Sc = R[rest, rest] .- D._matprod(RR, permutedims(Rrs))
                Id = zeros(length(rest), length(rest))
                for i in eachindex(rest)
                    Id[i, i] = 1e-12
                end
                L = _chol(Sc .+ Id)
                E = D._matprod(_rnorm_mat(n, length(rest)), L)
                if fin
                    Zst = Z[:, st]
                    dq = D._rowsums(D._matprod(Zst, Rss_i) .* Zst)
                    ns = length(st)
                    chi = _rchisq(n, nu + ns)
                    scale = sqrt.((nu .+ dq) ./ (nu + ns) ./ (chi ./ (nu + ns)))
                    Z[:, rest] = M .+ E .* scale
                else
                    Z[:, rest] = M .+ E
                end
            end
        else
            Z = D._matprod(_rnorm_mat(n, k), _chol(R))
            fin && (Z = Z ./ sqrt.(_rchisq(n, nu) ./ nu))
        end
        Z
    end
    V = fin ? SimLev.RNmath.pt.(sim, nu) : SimLev.RNmath.pnorm.(sim)
    Y = k == 0 ? zeros(n, 0) : reshape(reduce(hcat, [qmarg[j](V[:, j]) for j in 1:k]), n, k)
    out_df = RFrame((assets[j] => Y[:, j] for j in 1:k)...)
    stress_out = stress === nothing ? nothing : RList((p.first => p.second for p in st_list)...)
    out = RList(; class = ["SimLevScenarios"])
    out["scenarios"] = out_df
    out["prob"] = fill(1 / n, n)
    out["prior"] = fill(1 / n, n)
    out["assets"] = assets
    out["states"] = nothing
    out["effective_n"] = n
    out["copula"] = RList("family" => family, "correlation" => named ? NamedMat(R; rownames = assets, colnames = assets) : R,
                          "df" => nu)
    out["stress"] = stress_out
    out["summary"] = RFrame("var" => assets, "mean_prior" => D._colmeans(X), "mean_post" => D._colmeans(Y),
                            "sd_prior" => Float64[SimLev.r_sd(X[:, j]) for j in 1:k],
                            "sd_post" => Float64[SimLev.r_sd(Y[:, j]) for j in 1:k])
    out["correlation"] = NamedMat(D._cormat(Y); rownames = assets, colnames = assets)
    out["frequency"] = frequency
    out["kind"] = "copula"
    out
end

function _print_scenarios(io::IO, x)
    D = _D()
    fr = Dict("week" => "Woche", "day" => "Tag", "month" => "Monat")[x["frequency"]]
    print(io, D._sprintf("SimLev-Szenarien (%s): %d Szenarien, effektiv %.0f, Renditen in %% je %s", x["kind"],
                         SimLev.nrow(x["scenarios"]), Float64(x["effective_n"]), fr) * "\n")
    cop = get(x, "copula", nothing)
    if cop !== nothing
        st = get(x, "stress", nothing)
        extra = ""
        if st !== nothing && length(st) > 0
            extra = ", Stress: " * join([D._sprintf("%s in [%g, %g]", k, _fvec(b)[1], _fvec(b)[2]) for (k, b) in st], "; ")
        end
        print(io, D._sprintf("Copula: %s, Freiheitsgrade %.1f%s", cop["family"], Float64(cop["df"]), extra) * "\n")
    end
    s = x["summary"]
    y = RFrame("Variable" => collect(s["var"]), "Mittel vorher" => D._sprintf_vec("%.3f", _fvec(s["mean_prior"])),
               "Mittel nachher" => D._sprintf_vec("%.3f", _fvec(s["mean_post"])),
               "Sd vorher" => D._sprintf_vec("%.3f", _fvec(s["sd_prior"])), "Sd nachher" => D._sprintf_vec("%.3f", _fvec(s["sd_post"])))
    D._ln(io, D._print_df(y))
    print(io, "\nKorrelation nachher\n")
    C = x["correlation"]
    rn = C isa NamedMat ? C.rownames : nothing; cn = C isa NamedMat ? C.colnames : nothing
    D._ln(io, D._print_matrix(D._r_round(_fmat(C), 3), rn, cn))
    nothing
end

"Gewichte als (Namen, Werte); Namen `nothing`, wenn unbenannt."
function _named_weights(w)
    w isa RVector && return w.names, collect(w.values)
    w isa NamedTuple && return [String(k) for k in keys(w)], collect(values(w))
    w isa AbstractDict && return [String(k) for k in keys(w)], collect(values(w))
    w isa AbstractVector{<:Pair} && return [String(p.first) for p in w], [p.second for p in w]
    nothing, (w isa AbstractVector ? collect(w) : [w])
end
_isnum_arr(a) = all(v -> v isa Real && !(v isa Bool), a)

"""
    scenario_risk(x, weights; alpha = 0.05)

Portfolio-Kennzahlen auf Szenarien (gewichtet mit `x["prob"]`): benannter Vektor
`mean`, `volatility`, `var`, `cvar`, `q05`, `q50`, `q95`, `prob_loss`.
`weights`: benannter Vektor (RVector, NamedTuple, Dict, Paare).
"""
function scenario_risk(x, weights; alpha = 0.05)
    x = SimLev.as_rframe(x)
    D = _D()
    SimLev.inherits(x, "SimLevScenarios") || error("x muss ein SimLevScenarios sein.")
    av = alpha isa AbstractVector ? alpha : [alpha]
    (length(av) == 1 && _is_num_scalar(av[1]) && isfinite(Float64(av[1])) && 0 < av[1] < 1) ||
        error("scenario_risk: alpha muss ein Anteil echt zwischen 0 und 1 sein (erhalten: $(D._fmt1(alpha))).")
    alpha = Float64(av[1])
    nms, vals = _named_weights(weights)
    (!_isnum_arr(vals) || nms === nothing || any(==(""), nms)) &&
        error("scenario_risk: weights muss ein benannter numerischer Vektor sein (Namen = Anlagespalten der Szenarien).")
    unk = unique([k for k in nms if !haskey(x["scenarios"], k)])
    isempty(unk) || error("scenario_risk: unbekannte Anlage(n) $(join(["'$u'" for u in unk], ", ")).")
    w = _fvec(vals)
    X = reshape(reduce(hcat, [_fvec(x["scenarios"][k]) for k in nms]), SimLev.nrow(x["scenarios"]), length(nms))
    q = _fvec(x["prob"])
    r = D._matvec(X, w)
    o = D._order(r)
    cw = SimLev.r_cumsum(q[o])
    ro = r[o]
    qf(a) = (h = findfirst(>=(a), cw); h === nothing ? _NA : ro[h])
    var_a = -qf(alpha)
    prev = vcat([0.0], cw[1:end-1])
    take = [min(q[o][i], max(0.0, alpha - prev[i])) for i in eachindex(o)]
    cvar = -SimLev.r_sum(take .* ro) / SimLev.r_sum(take)
    m = SimLev.r_sum(q .* r)
    dv = r .- m
    RVector([m, sqrt(SimLev.r_sum(q .* (dv .* dv))), var_a, cvar, qf(0.05), qf(0.5), qf(0.95), SimLev.r_sum(q[r .< 0])];
            names = ["mean", "volatility", "var", "cvar", "q05", "q50", "q95", "prob_loss"])
end

const _DEFAULT_CRISES = RFrame(
    "crisis" => ["Ölkrise 1973/74", "Schwarzer Montag 1987", "Dotcom 2000-02", "Finanzkrise 2007-09",
                 "Eurokrise 2011", "Covid 2020", "Inflation/Zinsen 2022"],
    "start" => Date.(["1973-01-11", "1987-08-25", "2000-03-24", "2007-10-09", "2011-04-29", "2020-02-19", "2022-01-03"]),
    "end" => Date.(["1974-10-03", "1987-12-04", "2002-10-09", "2009-03-09", "2011-10-03", "2020-03-23", "2022-10-12"]))

"`cumprod` (long double)."
function _cumprod(x)
    out = similar(x, Float64)
    s = SimLev.F80(1.0)
    for i in eachindex(x)
        s = s * SimLev._ldq(Float64(x[i]))
        out[i] = Float64(s)
    end
    out
end
"`cummax` (NA/NaN pflanzt sich fort)."
function _cummax(x)
    out = similar(x, Float64)
    mx = -Inf
    for i in eachindex(x)
        mx = (isnan(x[i]) || isnan(mx)) ? mx + x[i] : (mx > x[i] ? mx : x[i])
        out[i] = mx
    end
    out
end

"""
    crisis_replay(data, weights; crises = nothing, rebalance = false)

Portfolio (`weights`, auf Summe 1 normiert) durch historische Krisen führen;
`crises`: RFrame mit `crisis`, `start`, `end` (`nothing` = eingebaute Liste).
"""
function crisis_replay(data, weights, crises_pos = nothing; crises = crises_pos, rebalance::Bool = false)
    data = SimLev.as_rframe(data)
    crises = SimLev.as_rframe(crises)
    D = _D()
    crises === nothing && (crises = _DEFAULT_CRISES)
    (D._is_frame(data) && haskey(D._as_frame(data), "date")) || error("crisis_replay: data.frame mit Spalte 'date' erwartet.")
    (D._is_frame(crises) && all(c -> haskey(D._as_frame(crises), c), ("crisis", "start", "end"))) ||
        error("crisis_replay: crises muss ein data.frame mit den Spalten crisis, start, end sein.")
    data = D._as_frame(data); crises = D._as_frame(crises)
    nms, vals = _named_weights(weights)
    (!_isnum_arr(vals) || nms === nothing || any(==(""), nms) || !all(v -> isfinite(Float64(v)), vals)) &&
        error("crisis_replay: weights muss ein benannter numerischer Vektor ohne NA sein (Namen = Kursspalten).")
    unk = unique([k for k in nms if !(k in setdiff(names(data), ["date"]))])
    isempty(unk) || error("crisis_replay: Kursspalte(n) $(join(["'$u'" for u in unk], ", ")) fehlen in data.")
    wv = _fvec(vals)
    sw = SimLev.r_sum(wv)
    sw <= 0 && error("crisis_replay: Summe der Gewichte muss positiv sein (erhalten $(D._sprintf("%g", sw))); sie wird auf 1 normiert.")
    data = D._dep_sort_dates(data)
    d = collect(data["date"])
    dd = D._days(d)
    w = wv ./ sw
    cs = D._days(collect(D._to_date(crises["start"], "crisis_replay: crises\$start")))
    ce = D._days(collect(D._to_date(crises["end"], "crisis_replay: crises\$end")))
    P = reduce(hcat, [D._fill_na(D._dep_check_prices(D._num(data[a]), a, d), "locf"; keep_leading = true) for a in nms])
    P = reshape(P, length(d), length(nms))
    nd = length(dd)
    rowsv = Dict{String,Any}[]
    for i in 1:SimLev.nrow(crises)
        s = findfirst(>=(cs[i]), dd)
        e = findlast(<=(ce[i]), dd)
        (s === nothing || e === nothing || e <= s || any(isnan, P[s, :])) && continue
        rel = P[s:e, :] ./ permutedims(P[s, :])
        port = if rebalance
            g = D._matvec(rel[2:end, :] ./ rel[1:end-1, :], w)
            _cumprod(vcat([1.0], g))
        else
            D._matvec(rel, w)
        end
        ddn = D._rmin(port ./ _cummax(port) .- 1)
        after = _NA
        if e < nd
            relx = P[e:end, :] ./ permutedims(P[s, :])
            px = D._matvec(relx, w)
            kk = findfirst(>=(1), px)
            kk !== nothing && (after = dd[e+kk-1] - dd[e])
        end
        row = Dict{String,Any}("crisis" => crises["crisis"][i], "start" => d[s], "end" => d[e],
                               "portfolio" => 100 * (port[end] - 1), "max_drawdown" => 100 * ddn, "days_to_recover" => after)
        last = 100 .* (rel[end, :] .- 1)
        for (j, a) in enumerate(nms)
            row[a] = last[j]
        end
        push!(rowsv, row)
    end
    isempty(rowsv) && error("Keine Krise liegt im Datenzeitraum.")
    cols = vcat(["crisis", "start", "end", "portfolio", "max_drawdown", "days_to_recover"], unique(nms))
    RFrame((c => (c == "crisis" ? [r[c] for r in rowsv] : c in ("start", "end") ? Date[r[c] for r in rowsv] :
                  Float64[r[c] for r in rowsv]) for c in cols)...)
end

function __init__()
    SimLev.register_print!("SimLevScenarios", _print_scenarios)
end

end # module
