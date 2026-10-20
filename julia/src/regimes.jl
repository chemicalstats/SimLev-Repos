# Regimes – Port von r/R/regimes.R (Vorlage python/simlev/regimes.py)
#
#   regime_hmm()     schätzt K Marktphasen aus den Periodenrenditen einer oder
#                    mehrerer Reihen (Gauss'sches Hidden-Markov-Modell, Baum-Welch,
#                    mehrere Startwerte); gefilterte und geglättete
#                    Wahrscheinlichkeiten sowie der Viterbi-Pfad
#   regime_states()  legt die Regime auf einen Tageskalender (Standard: gefiltert,
#                    verzögert, ohne Zukunftsinformation)
module Regimes

import ..SimLev
using Dates

export regime_hmm, regime_states

const _NA = SimLev.NA
const RFrame = SimLev.RFrame
const RList = SimLev.RList
const RVector = SimLev.RVector
const NamedMat = SimLev.NamedMat

_D() = SimLev.Dependence
_fmat(X) = SimLev.Dependence._fmat(X)
_fvec(x) = SimLev.Dependence._fvec(x)

"Log-Dichte der multivariaten Normalverteilung je Zeile (`.ldmvn`)."
function _ldmvn(X, mu, S)
    X = _fmat(X); mu = _fvec(mu)
    L = _fmat(SimLev.RLinalg.chol(_fmat(S)))
    n, d = size(X)
    Xc = Matrix{Float64}(undef, n, d)
    for j in 1:d, i in 1:n
        Xc[i, j] = X[i, j] - mu[j]
    end
    Z = permutedims(_fmat(_D()._flex(SimLev.RLinalg.backsolve, (L, permutedims(Xc)), NamedTuple(), (transpose = true,))))
    rs = _D()._rowsums(Z .* Z)
    sl = SimLev.r_sum([SimLev.RLibm.log(L[i, i]) for i in 1:size(L, 1)])
    c = 0.5 * d * SimLev.RLibm.log(2 * pi)
    (-0.5 .* rs .- sl) .- c
end

"R `which.max` (erstes Maximum, NA ignoriert); `nothing`, wenn leer."
function _which_max(v)
    v = _fvec(v)
    best = nothing
    for i in eachindex(v)
        isnan(v[i]) && continue
        (best === nothing || v[i] > v[best]) && (best = i)
    end
    best
end

"`max.col(m, ties.method = \"first\")` je Zeile (NA bei NaN in der Zeile)."
function _max_col_first(M)
    M = _fmat(M)
    out = Vector{Union{Missing,Int}}(undef, size(M, 1))
    for r in 1:size(M, 1)
        if any(isnan, view(M, r, :))
            out[r] = missing
            continue
        end
        m = 1; a = M[r, 1]
        for c in 2:size(M, 2)
            b = M[r, c]
            a < b && (a = b; m = c)
        end
        out[r] = m
    end
    out
end

"Viterbi-Pfad aus Log-Emissionen, Log-Übergangsmatrix und Log-Startverteilung (`.hmm_viterbi`)."
function _hmm_viterbi(lB, lA, lp0)
    lB = _fmat(lB); lA = _fmat(lA); lp0 = _fvec(lp0)
    Tn, k = size(lB)
    dl = lp0 .+ lB[1, :]
    bp = zeros(Int, Tn, k)
    for t in 2:Tn
        cand = dl .+ lA                      # cand[i, j] = dl[i] + lA[i, j]
        im = _max_col_first(permutedims(cand))
        if any(ismissing, im)
            wm = [_which_max(cand[:, j]) for j in 1:k]
            any(w -> w === nothing, wm) && error("replacement has length zero")
            imv = Int[w for w in wm]
            mx = Float64[_D()._rmax(cand[:, j]) for j in 1:k]
        else
            imv = Int[i for i in im]
            mx = Float64[cand[imv[j], j] for j in 1:k]
        end
        bp[t, :] = imv
        dl = mx .+ lB[t, :]
    end
    path = zeros(Int, Tn)
    w = _which_max(dl)
    w === nothing && error("replacement has length zero")
    path[Tn] = w
    for t in Tn:-1:2
        path[t-1] = bp[t, path[t]]
    end
    path
end

"`stats::cov2cor` (über RStats, mit R's Warnung)."
_cov2cor(V) = _fmat(SimLev.RStats.cov2cor(_fmat(V)))

"R `pmax(a, b)` elementweise (NaN in `b` gewinnt, NaN in `a` bleibt)."
_pmax2(a, b) = [(b[i] > a[i] || isnan(b[i])) ? b[i] : a[i] for i in eachindex(a)]

function _isint_scalar(k)
    k isa AbstractVector && (length(k) == 1 ? (k = k[1]) : return false)
    (k isa Real && !(k isa Bool)) || return false
    kf = Float64(k)
    isfinite(kf) && kf == Float64(SimLev.RFmt.r_round(kf)) && kf >= 2
end

"""
    regime_hmm(data, columns; k = 2, frequency = "week", n_start = 5, max_iter = 300,
               tol = 1e-7, seed = 1)

Gauss'sches Hidden-Markov-Modell für Marktregime (Klasse `SimLevHMM`); die
Zustände sind nach Volatilität aufsteigend sortiert.
"""
function regime_hmm(data, columns; k = 2, frequency = ("week", "day", "month"), n_start = 5, max_iter = 300,
                    tol = 1e-7, seed = 1)
    data = SimLev.as_rframe(data)
    D = _D()
    frequency = D._match_arg(frequency, ("week", "day", "month"))
    _isint_scalar(k) || error("regime_hmm: k muss eine ganze Zahl >= 2 sein (erhalten: $(D._fmt1(k))); ein Zustand wäre " *
                              "eine einzige Normalverteilung ohne Regime.")
    k = Int(Float64(k isa AbstractVector ? k[1] : k))
    columns = D._as_names(columns)
    rd = D._dep_returns(data, columns, nothing, frequency)
    X = reduce(hcat, [_fvec(rd[c]) for c in columns])
    Tn, d = size(X)
    Tn < 50 * k && error("regime_hmm: zu wenige Perioden für die Zustandszahl ($Tn Perioden, mindestens $(50 * k) für k = $k).")
    flat = [columns[j] for j in 1:d if SimLev.r_sd(X[:, j]) == 0]
    isempty(flat) || error("regime_hmm: Spalte(n) $(join(["'$f'" for f in flat], ", ")) ohne Schwankung (alle Periodenrenditen " *
                           "gleich, z. B. konstante Kurse); kein Modell schätzbar.")
    dd = D._days(rd["date"])
    ppy = (Tn - 1) / ((dd[Tn] - dd[1]) / 365.25)
    rv = 1e-10 + 1e-6 * SimLev.r_mean([SimLev.r_var(X[:, j]) for j in 1:d])
    ridge = zeros(d, d)
    for i in 1:d
        ridge[i, i] = rv
    end
    lg = SimLev.RLibm.log; ex = SimLev.RLibm.exp

    function fit_once(init)
        mu = copy(init.mu); S = [copy(s) for s in init.S]; A = copy(init.A)
        p0 = fill(1 / k, k)
        ll_old = -Inf
        function estep()
            lB = reduce(hcat, [_ldmvn(X, mu[j, :], S[j]) for j in 1:k])
            lB = reshape(lB, Tn, k)
            m = lB[:, 1]
            for j in 2:k
                m = _pmax2(m, lB[:, j])
            end
            E = Matrix{Float64}(undef, Tn, k)
            for j in 1:k, i in 1:Tn
                E[i, j] = ex(lB[i, j] - m[i])
            end
            fb = SimLev.DependenceCore.hmm_forward_backward(E, A, p0)
            ll = SimLev.r_sum(lg.(fb["scale"])) + SimLev.r_sum(m)
            lB, fb, ll
        end
        it = 0
        for it_ in 1:Int(max_iter)
            it = it_
            lB, fb, ll = estep()
            ga = fb["smoothed"]; xi = fb["xi"]
            p0 = ga[1, :]
            rsx = D._rowsums(xi)
            A = Matrix{Float64}(undef, k, k)
            for j in 1:k, i in 1:k
                A[i, j] = xi[i, j] / rsx[i]
            end
            for j in 1:k
                w = ga[:, j]
                sw = SimLev.r_sum(w)
                mu[j, :] = D._colsums(X .* w) ./ sw
                Xc = Matrix{Float64}(undef, Tn, d)
                sq = sqrt.(w)
                for c in 1:d, i in 1:Tn
                    Xc[i, c] = (X[i, c] - mu[j, c]) * sq[i]
                end
                S[j] = _fmat(D._flex(SimLev.RLinalg.crossprod, (Xc,))) ./ sw .+ ridge
            end
            abs(ll - ll_old) < tol * (1 + abs(ll)) && break
            ll_old = ll
        end
        lB, fb, ll = estep()
        (mu = mu, S = S, A = A, p0 = p0, ll = ll, filtered = fb["filtered"], smoothed = fb["smoothed"], lB = lB, iter = it)
    end

    inits = D._with_rng_restore(seed) do
        res = Any[]
        for s in 1:Int(n_start)
            vol = sqrt.(D._roll_mean(D._rowsums(X .* X), max(4.0, D._r_round(ppy / 12))))
            if any(isnan, vol)
                md = D._median(vol; na_rm = true)
                vol = [isnan(v) ? md : v for v in vol]
            end
            cl = s == 1 ? D._cut_n(D._rank_avg(vol), k) :
                          Int.(D._fvec(D._flex(SimLev.RRng.sample_int, (k, Tn), NamedTuple(), (replace = true,))))
            mu = Matrix{Float64}(undef, k, d)
            for j in 1:k
                mu[j, :] = D._colmeans(X[cl .== j, :])
            end
            S = [_fmat(SimLev.RStats.cov(X[cl .== j, :])) .+ ridge for j in 1:k]
            off = 0.1 / max(1, k - 1)
            A = fill(off, k, k)
            for i in 1:k
                A[i, i] += 0.9 - off
            end
            push!(res, (mu = mu, S = S, A = A))
        end
        res
    end
    fits = Any[]
    for i in inits
        f = try
            fit_once(i)
        catch e
            e isa InterruptException && rethrow()
            nothing
        end
        f === nothing || push!(fits, f)
    end
    isempty(fits) && error("regime_hmm: Schätzung fehlgeschlagen.")
    f = fits[_which_max([fi.ll for fi in fits])]
    vol = [sqrt(SimLev.r_mean([s[i, i] for i in 1:d])) for s in f.S]
    o = D._order(vol)
    A = f.A[o, o]; mu = f.mu[o, :]; S = f.S[o]
    lB = f.lB[:, o]
    path = _hmm_viterbi(lB, lg.(A), lg.(f.p0[o]))
    npar = k - 1 + k * (k - 1) + k * d + k * d * (d + 1) / 2
    zn = ["Z$j" for j in 1:k]
    vols = Matrix{Float64}(undef, k, d)
    for j in 1:k, c in 1:d
        vols[j, c] = sqrt(S[j][c, c] * ppy) * 100
    end
    out = RList(; class = ["SimLevHMM"])
    out["transition"] = NamedMat(A; rownames = zn, colnames = zn)
    out["means"] = NamedMat(mu .* ppy .* 100; rownames = zn, colnames = columns)
    out["volatility"] = NamedMat(vols; rownames = zn, colnames = columns)
    out["correlation"] = Any[NamedMat(_cov2cor(s); rownames = columns, colnames = columns) for s in S]
    out["filtered"] = f.filtered[:, o]
    out["smoothed"] = f.smoothed[:, o]
    out["viterbi"] = path
    out["dates"] = collect(rd["date"])
    out["columns"] = columns
    out["k"] = k
    out["loglik"] = f.ll
    out["bic"] = -2 * f.ll + npar * lg(Float64(Tn))
    out["initial"] = RVector(f.p0[o]; names = zn)
    out["duration"] = RVector([1 / (1 - A[i, i]) for i in 1:k]; names = zn)
    out["frequency"] = frequency
    out["ppy"] = ppy
    out["share"] = D._colmeans(f.smoothed[:, o])
    out
end

function _print_hmm(io::IO, x)
    D = _D()
    k = Int(x["k"])
    print(io, D._sprintf("Hidden-Markov-Modell: %d Zustände auf %s (%s), %d Perioden, logL %.1f, BIC %.1f", k,
                         join(x["columns"], ", "), x["frequency"], length(x["dates"]), x["loglik"], x["bic"]) * "\n\n")
    mu = _fmat(x["means"]); vo = _fmat(x["volatility"]); share = _fvec(x["share"]); dur = _fvec(x["duration"])
    for j in 1:k
        print(io, D._sprintf("  Z%d: Anteil %.0f %%, erwartete Dauer %.1f Perioden, Rendite %s %% p. a., Vola %s %%", j,
                             100 * share[j], dur[j], join(D._sprintf_vec("%.1f", mu[j, :]), "/"),
                             join(D._sprintf_vec("%.1f", vo[j, :]), "/")) * "\n")
    end
    print(io, "\nÜbergangsmatrix\n")
    T = x["transition"]
    D._ln(io, D._print_matrix(D._r_round(_fmat(T), 3), T.rownames, T.colnames))
    F = _fmat(x["filtered"])
    last = F[size(F, 1), :]
    print(io, D._sprintf("\nAktueller Zustand (gefiltert): Z%d mit %.0f %%", _which_max(last), 100 * D._rmax(last)) * "\n")
    nothing
end

function _plot_hmm(x; file = nothing, width = 900, height = 380)
    D = _D()
    k = Int(x["k"])
    top = _fmat(x["filtered"])[:, k]
    D._svg_grid(["p"], _ -> ((c, box) -> D._svg_lines!(c, box, [(D._days(x["dates"]), top, "#B5562B", "P(Z$k | bis t)")];
                                                       ylim = (0.0, 1.0), hline = [(0.5, "grey")], dates = true,
                                                       ylabel = "P(Z$k | bis t)",
                                                       title = "Gefilterte Wahrscheinlichkeit des unruhigsten Zustands (Z$k)"));
                file = file, width = width, height = height)
end

"""
    regime_states(x, dates; type = "filtered", output = "state", state_prob = x["k"], lag = 1)

Regime aus `regime_hmm()` auf Zieldaten legen (`dates`: Datumsvektor oder
Datenrahmen mit Spalte `date`); je Datum der letzte Zustand, dessen Periodenende
plus `lag` Tage nicht nach dem Datum liegt (sonst NA).
"""
function regime_states(x, dates; type = ("filtered", "smoothed", "viterbi"), output = ("state", "probability"),
                       state_prob = nothing, lag = 1)
    dates = SimLev.as_rframe(dates)
    D = _D()
    type = D._match_arg(type, ("filtered", "smoothed", "viterbi"))
    output = D._match_arg(output, ("state", "probability"))
    state_prob === nothing && (state_prob = x["k"])
    type != "filtered" && @warn "Geglättete bzw. Viterbi-Zustände nutzen Zukunftsdaten - nur zur Beschreibung verwenden."
    src = D._is_frame(dates) ? D._as_frame(dates)["date"] : dates
    d = D._to_date(src isa AbstractVector ? src : [src], "regime_states: dates")
    P = type == "filtered" ? x["filtered"] : type == "smoothed" ? x["smoothed"] : nothing
    prob = output == "probability"
    if prob
        P === nothing && error("Wahrscheinlichkeit nicht für Viterbi.")
        v = _fmat(P)[:, Int(state_prob)]
    elseif P === nothing
        v = Vector{Union{Missing,Int}}(collect(x["viterbi"]))
    else
        v = _max_col_first(P)
    end
    dv = D._days(collect(d))
    ref = D._days(x["dates"]) .+ lag
    out = prob ? fill(_NA, length(dv)) : Vector{Union{Missing,Int}}(missing, length(dv))
    for i in eachindex(dv)
        isnan(dv[i]) && continue
        kk = searchsortedlast(ref, dv[i])
        kk > 0 && (out[i] = v[kk])
    end
    out
end

function __init__()
    SimLev.register_print!("SimLevHMM", _print_hmm)
    SimLev.register_plot!("SimLevHMM", SimLev._plot_method(_plot_hmm, "SimLevHMM"))
end

end # module
