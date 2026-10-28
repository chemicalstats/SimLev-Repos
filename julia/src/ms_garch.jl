# MsGarch – Port von r/R/ms_garch.R (Vorlage python/simlev/ms_garch.py)
#
# Eigene ML-Schätzung des MS-GARCH-Modells nach Haas, Mittnik und Paolella
# (2004): K Regime, je Regime ein GARCH(1,1)- ("sGARCH") oder GJR-GARCH(1,1)-
# Varianzpfad ("gjrGARCH"); die Varianzpfade aller Regime laufen parallel;
# Normalverteilung mit Mittelwert 0; Regimewechsel als Markov-Kette.
# Likelihood über den Hamilton-Filter (BootstrapCore.ms_garch_filter, Port von
# r/src/ms_garch.c), Maximierung mit optim (BFGS) auf eigener Parametrisierung
# auf R^p, deterministische Startwerte (kein Zufall): volles HMM-EM
# (Regimes._hmm_em) und Rangeinteilung der Volatilität, je mit kleinem Raster;
# optim von beiden Familien, die höhere Log-Likelihood zählt. Genutzt von
# Bootstrap._prepare_ms_info für "ms_garch", "ms_ar_garch_m" und "tvtp_ms_garch".
#
# Wie in R sind Summen weniger Werte fortlaufende double-Additionen (nicht
# r_sum, das wie R's sum in long double summiert). Nur interne Funktionen.
module MsGarch

import ..SimLev

const RList = SimLev.RList

_ex(x::Float64) = SimLev.RLibm.exp(x)
_lg(x::Float64) = SimLev.RLibm.log(x)

"`paste(format(x), collapse = \", \")`; `nothing`/`missing` stehen für NA."
function _show(x)
    (x === nothing || x === missing) && return "NA"
    x isa SimLev.RVector && (x = x.values)
    x isa Tuple && (x = collect(x))
    if x isa AbstractVector && any(v -> v === missing || v === nothing, x)
        return join([v === missing || v === nothing ? "NA" : string(v) for v in x], ", ")
    end
    r = SimLev.RFmt.format(x)
    r isa AbstractString && return String(r)
    return join([string(s) for s in r], ", ")
end

"Varianzmodell und Regimezahl der MS-GARCH-Schätzung prüfen (`.ms_garch_check`)."
function _ms_garch_check(K, model)
    mv = model isa AbstractVector || model isa Tuple ? collect(model) : [model]
    ok_m = length(mv) == 1 && mv[1] isa AbstractString && mv[1] in ("sGARCH", "gjrGARCH")
    ok_m || error("MS-GARCH: Varianzmodell je Regime (params ms_garch_model, ms_ar_garch_model bzw. tvtp_garch_model) " *
                  "muss \"sGARCH\" oder \"gjrGARCH\" sein (erhalten: $(_show(model))).")
    kv = K isa AbstractVector || K isa Tuple ? collect(K) : [K]
    ok_k = length(kv) == 1 && kv[1] isa Real && !(kv[1] isa Bool)
    if ok_k
        k0 = Float64(kv[1])
        ok_k = isfinite(k0) && k0 == Float64(SimLev.RFmt.r_round(k0)) && k0 >= 2
    end
    ok_k || error("MS-GARCH: Anzahl Regime (params ms_n_regimes, ms_ar_n_regimes bzw. tvtp_n_regimes) muss eine " *
                  "ganze Zahl >= 2 sein (erhalten: $(_show(K))).")
    return true
end

"""
Stationäre Verteilung einer Übergangsmatrix (`.ms_garch_stat`): Potenziteration
wie für `pi_` in `.prepare_ms_info` (Start gleichverteilt, höchstens 1000
Schritte, Abbruch bei maximaler Änderung < 1e-12). `pi_ %*% P` in der
Reihenfolge von R's `matprod` (Referenz-BLAS `dgemv`, bei nicht endlichen
Werten `RLinalg.matprod`).
"""
function _ms_garch_stat(P)
    P = Matrix{Float64}(P isa SimLev.NamedMat ? P.data : P)
    K = size(P, 1)
    pi_ = fill(1 / K, K)
    fin = all(isfinite, P)
    for _ in 1:1000
        p2 = Vector{Float64}(undef, K)
        if fin && all(isfinite, pi_)
            for j in 1:K
                s = 0.0
                for i in 1:K
                    s = s + P[i, j] * pi_[i]
                end
                p2[j] = s
            end
        else
            p2 = Float64.(vec(collect(SimLev.RLinalg.matprod(reshape(pi_, 1, K), P))))
        end
        mx = -Inf
        for i in 1:K
            dv = abs(p2[i] - pi_[i])
            isnan(dv) && error("missing value where TRUE/FALSE needed")
            dv > mx && (mx = dv)
        end
        mx < 1e-12 && break
        pi_ = p2
    end
    return pi_
end

"""
Parametervektor auf R^p in Modellparameter umrechnen (`.ms_garch_unpack`).
Reihenfolge: je Regime 1 bis K (θ_ω, a, [g], b), danach P zeilenweise ohne
Diagonale. ω = exp(θ_ω); sGARCH: e = exp(c(a, b)), α = e[1]/(1 + sum(e)),
β = e[2]/(1 + sum(e)); gjrGARCH: e = exp(c(a, g, b)), α = e[1]/d,
γ = 2 e[2]/d, β = e[3]/d mit d = 1 + sum(e). Zeile i von P: exp(θ_i.) mit
θ_ii = 0, geteilt durch die Zeilensumme.
"""
function _ms_garch_unpack(theta, K::Int, gjr::Bool)
    th = Float64.(vec(collect(theta)))
    np_ = gjr ? 4 : 3
    om = zeros(K); al = zeros(K); be = zeros(K); ga = zeros(K)
    for k in 1:K
        j = (k - 1) * np_
        om[k] = _ex(th[j+1])
        if gjr
            e1 = _ex(th[j+2]); e2 = _ex(th[j+3]); e3 = _ex(th[j+4])
            d = 1 + ((e1 + e2) + e3)
            al[k] = e1 / d; ga[k] = 2 * e2 / d; be[k] = e3 / d
        else
            e1 = _ex(th[j+2]); e2 = _ex(th[j+3])
            d = 1 + (e1 + e2)
            al[k] = e1 / d; be[k] = e2 / d
        end
    end
    P = zeros(K, K); pos = K * np_
    for i in 1:K
        for j in 1:K
            if j == i
                P[i, j] = 1.0
            else
                pos += 1
                P[i, j] = _ex(th[pos])
            end
        end
        s = 0.0
        for j in 1:K
            s = s + P[i, j]
        end
        for j in 1:K
            P[i, j] = P[i, j] / s
        end
    end
    return (omega = om, alpha = al, beta = be, gamma = ga, P = P)
end

"""
Modellparameter in den Parametervektor auf R^p umrechnen (`.ms_garch_pack`,
Umkehrung von `_ms_garch_unpack`; Restanteil r = 1 - α - γ/2 - β = 1/d).
"""
function _ms_garch_pack(om, al, be, ga, P, gjr::Bool)
    K = length(om); th = Float64[]
    for k in 1:K
        r = 1 - al[k] - ga[k] / 2 - be[k]
        push!(th, _lg(Float64(om[k])), _lg(al[k] / r))
        gjr && push!(th, _lg((ga[k] / 2) / r))
        push!(th, _lg(be[k] / r))
    end
    for i in 1:K, j in 1:K
        j != i && push!(th, _lg(P[i, j] / P[i, i]))
    end
    return th
end

"`seq(0, 1, length.out = n)` (n ≥ 2)."
function _seq01(n::Int)
    if n > 2
        n1 = n - 1.0
        return vcat(0.0, Float64[0.0 + i * (1.0 / n1) for i in 1:n-2], 1.0)
    end
    return [0.0, 1.0][1:n]
end

"""
    _ms_garch_fit(y, K, model)

MS-GARCH-Modell per Maximum Likelihood schätzen (`.ms_garch_fit`, eigene
Fassung). `y`: Tagesrenditen als Anteil (Mittelwert 0 angenommen); `K`: Anzahl
Regime (ganze Zahl ≥ 2); `model`: "sGARCH" oder "gjrGARCH". Liefert
`RList(omega, alpha, beta, gamma, P, regimes, s2, loglik, convergence)`:
Parameter je Regime (aufsteigend nach unbedingter Varianz ω/(1 - α - γ/2 - β)
sortiert; γ = 0 bei "sGARCH"), Übergangsmatrix P (Zeile = von), Viterbi-Pfad
(1 bis K), vorhergesagte Mischungsvarianz s2[t] = Σ_k P(s_t = k | F_{t-1}) h[t, k],
Log-Likelihood und Konvergenzcode von optim.
"""
function _ms_garch_fit(y, K, model)
    _ms_garch_check(K, model)
    K = Int(Float64(K isa AbstractVector || K isa Tuple ? first(K) : K))
    model = String(model isa AbstractVector || model isa Tuple ? first(model) : model)
    gjr = model == "gjrGARCH"
    y = Float64.(vec(collect(y))); n = length(y)
    h1 = SimLev.r_var(y)
    C = SimLev.BootstrapCore; R = SimLev.Regimes; st = SimLev.RStats
    allfin(m) = all(isfinite, m.omega) && all(isfinite, m.alpha) && all(isfinite, m.beta) &&
                all(isfinite, m.gamma) && all(isfinite, m.P)
    # Zielfunktion: negative Log-Likelihood, 1e10 statt -Inf
    function nll(theta)
        m = _ms_garch_unpack(theta, K, gjr)
        allfin(m) || return 1e10
        ll = C.ms_garch_filter(y, m.omega, m.alpha, m.beta, m.gamma, m.P, _ms_garch_stat(m.P), h1)["loglik"]
        return isfinite(ll) ? -ll : 1e10
    end
    # Zeilen einer Start-Übergangsmatrix mit Nullen oder nicht endlichen Werten:
    # 0.9 auf der Diagonale, Rest gleich verteilt
    function fix_P(P0)
        P0 = Matrix{Float64}(P0)
        for i in 1:K
            if !all(isfinite, P0[i, :]) || any(==(0), P0[i, :])
                P0[i, :] .= 0.1 / (K - 1); P0[i, i] = 0.9
            end
        end
        P0
    end
    # Zweite Start-Übergangsmatrix je Familie: 0.99 auf der Diagonale, Rest gleich verteilt
    P99 = fill(0.01 / (K - 1), K, K)
    for i in 1:K
        P99[i, i] = 0.99
    end
    # Festes Raster (α, [γ], β), ω über Varianz-Targeting
    grid = gjr ? [(0.03, 0.06, 0.90), (0.05, 0.10, 0.82), (0.02, 0.04, 0.94)] :
                 [(0.05, 0.0, 0.90), (0.10, 0.0, 0.85), (0.03, 0.0, 0.95)]
    # Bester Startpunkt einer Familie (Varianzen s2k aufsteigend, Start-Übergangsmatrix P0):
    # Raster mit P0, danach Raster mit P99; höchste Log-Likelihood, bei Gleichstand der erste Punkt
    function best_start(s2k, P0)
        par0 = nothing; best = Inf
        for Pst in (P0, P99), g in grid
            al = fill(g[1], K); ga = fill(g[2], K); be = fill(g[3], K)
            om = s2k .* (1 - g[1] - g[2] / 2 - g[3])
            p = _ms_garch_pack(om, al, be, ga, Pst, gjr)
            v = nll(p)
            if par0 === nothing || v < best
                par0 = p; best = v
            end
        end
        par0
    end
    starts = Vector{Vector{Float64}}()
    # Familie 1 (HMM-Start): volles Baum-Welch-EM des Gauss'schen HMM auf y wie in
    # regime_hmm (Startwert aus der Rangeinteilung der rollierenden Volatilität,
    # 21 Tage), Zustände aufsteigend nach Varianz; bei Abbruch nur Familie 2
    X = reshape(copy(y), n, 1)
    ridge = fill(1e-10 + 1e-6 * SimLev.r_mean([SimLev.r_var(X[:, 1])]), 1, 1)
    hm = try
        R._hmm_em(X, K, R._hmm_init_rank(X, K, 21, ridge), 300, 1e-7, ridge)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
    if hm !== nothing
        s2h = Float64[s[1, 1] for s in hm.S]
        A = Matrix{Float64}(hm.A)
        if all(isfinite, s2h) && all(>(0), s2h) && all(isfinite, A)
            o = st.order(s2h)
            push!(starts, best_start(s2h[o], fix_P(A[o, o])))
        end
    end
    # Familie 2 (Rang-Start): Regime aus Quantilen der rollierenden Volatilität (wie
    # .prepare_regime_info; .rolling_vol erwartet Brutto-Renditen), Varianz je Regime aufsteigend
    vol = C.rolling_vol(y .+ 1, 21)
    th = Float64.(vec(collect(st.quantile(vol, _seq01(K + 1); names = false, type = 7))))
    th[end] = th[end] + 1e-10
    reg0 = C.assign_regimes(vol, th)
    P0 = fix_P(C.estimate_trans_mat(reg0, K))
    s2k = Float64[]
    for k in 1:K
        i = findall(==(k), reg0)
        push!(s2k, length(i) < 30 ? h1 : SimLev.r_var(y[i]))
    end
    s2k = sort(filter(!isnan, s2k))
    push!(starts, best_start(s2k, P0))
    # Optimierung (BFGS mit numerischem Gradienten, ohne Hesse-Matrix) von jedem
    # Startpunkt; genommen wird die höchste Log-Likelihood, bei Gleichstand der
    # erste Lauf (HMM-Start vor Rang-Start)
    o = nothing
    for par0 in starts
        oi = st.optim(par0, nll; method = "BFGS", control = Dict("maxit" => 500, "reltol" => 1e-10))
        if o === nothing || Float64(oi["value"]) < Float64(o["value"])
            o = oi
        end
    end
    oval = Float64(o["value"]); opar = Float64.(vec(collect(o["par"]))); conv = Int(o["convergence"])
    (!isfinite(oval) || oval >= 1e10 || !all(isfinite, opar)) &&
        error("Log-Likelihood nicht endlich (optim-Code $conv).")
    # Identifikation: Regime aufsteigend nach unbedingter Varianz
    m = _ms_garch_unpack(opar, K, gjr)
    unc = Float64[m.omega[k] / (1 - m.alpha[k] - m.gamma[k] / 2 - m.beta[k]) for k in 1:K]
    ord = st.order(unc)
    om = m.omega[ord]; al = m.alpha[ord]; be = m.beta[ord]; ga = m.gamma[ord]
    P = m.P[ord, ord]
    # Letzter Filterlauf mit den sortierten Parametern
    xi0 = _ms_garch_stat(P)
    f = C.ms_garch_filter(y, om, al, be, ga, P, xi0, h1)
    isfinite(f["loglik"]) || error("Log-Likelihood nicht endlich (letzter Filterlauf).")
    pr = f["pred"]; h = f["h"]
    s2 = Float64[pr[t, 1] * h[t, 1] for t in 1:n]
    for k in 2:K, t in 1:n
        s2[t] = s2[t] + pr[t, k] * h[t, k]
    end
    regimes = R._hmm_viterbi(f["lB"], SimLev.RLibm.log.(P), SimLev.RLibm.log.(xi0))
    return RList("omega" => om, "alpha" => al, "beta" => be, "gamma" => ga, "P" => P,
                 "regimes" => Int.(regimes), "s2" => s2, "loglik" => Float64(f["loglik"]), "convergence" => conv)
end

end # module
