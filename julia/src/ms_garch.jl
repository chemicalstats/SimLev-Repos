# MsGarch – Port von r/R/ms_garch.R (Vorlage python/simlev/ms_garch.py)
#
# Eigene ML-Schätzung des MS-GARCH-Modells nach Haas, Mittnik und Paolella
# (2004): K Regime, je Regime ein GARCH(1,1)- ("sGARCH") oder GJR-GARCH(1,1)-
# Varianzpfad ("gjrGARCH"); die Varianzpfade aller Regime laufen parallel;
# Normalverteilung mit Mittelwert 0; Regimewechsel als Markov-Kette.
# Likelihood über den Hamilton-Filter, Maximierung mit BFGS auf eigener
# Parametrisierung auf R^p, deterministische Startwerte (kein Zufall): volles HMM-EM
# und Rangeinteilung der Volatilität, je mit kleinem Raster; seit Etappe 9.6b ganz in
# der C-Bibliothek slc (SLib.ms_garch_fit). Seit 9.6c entfallen der frühere Filter-Port
# (BootstrapCore) und die Umrechnung der Parameter (_ms_garch_unpack/_pack). Genutzt von
# Bootstrap._prepare_ms_info für "ms_garch", "ms_ar_garch_m" und "tvtp_ms_garch".
#
# Wie in R sind Summen weniger Werte fortlaufende double-Additionen (nicht
# r_sum, das wie R's sum in long double summiert). Nur interne Funktionen.
module MsGarch

import ..SimLev

const RList = SimLev.RList


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
Schritte, Abbruch bei maximaler Änderung < 1e-12). `pi_ %m% P` in der
Reihenfolge des slc-Matrixprodukts (je Element ab 0,0 aufsteigend summiert,
Entwurf B.6; bei nicht endlichen Werten `SLib.matmul`).
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
            p2 = Float64.(vec(collect(SimLev.SLib.matmul(reshape(pi_, 1, K), P))))
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
    _ms_garch_fit(y, K, model)

MS-GARCH-Modell per Maximum Likelihood schätzen (`.ms_garch_fit`, eigene
Fassung). `y`: Tagesrenditen als Anteil (Mittelwert 0 angenommen); `K`: Anzahl
Regime (ganze Zahl ≥ 2); `model`: "sGARCH" oder "gjrGARCH". Liefert
`RList(omega, alpha, beta, gamma, P, regimes, s2, loglik, convergence)`:
Parameter je Regime (aufsteigend nach unbedingter Varianz ω/(1 - α - γ/2 - β)
sortiert; γ = 0 bei "sGARCH"), Übergangsmatrix P (Zeile = von), Viterbi-Pfad
(1 bis K), vorhergesagte Mischungsvarianz s2[t] = Σ_k P(s_t = k | F_{t-1}) h[t, k],
Log-Likelihood und Konvergenzcode des besten BFGS-Laufs. Seit Etappe 9.6b wie R ganz in der
C-Bibliothek slc (`SLib.ms_garch_fit`): Starts aus HMM-EM und Rangeinteilung, BFGS von allen
Rasterpunkten beider Familien (sGARCH 12, gjrGARCH seit N1 20), seit N1 mit analytischem
Gradienten; GJR je Regime mit α + γ ≥ 0, also auch γ < 0.
"""
function _ms_garch_fit(y, K, model)
    _ms_garch_check(K, model)
    K = Int(Float64(K isa AbstractVector || K isa Tuple ? first(K) : K))
    model = String(model isa AbstractVector || model isa Tuple ? first(model) : model)
    SimLev.SLib.ms_garch_fit(Float64.(vec(collect(y))), K, model)   # ganz in C (slc, Entwurf B.13; seit Etappe 9.6b)
end

end # module
