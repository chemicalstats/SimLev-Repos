# AnalysisTests – r/R/analysis_tests.R (Vorlage python/simlev/analysis_tests.py)
#
#   signal_analysis()    Vorwärtsrenditen je Signalbereich (Regressogramm)
#   sharpe_test()        Unterschied zweier Sharpe Ratios (Ledoit & Wolf 2008)
#   reality_check()      White (2000) Reality Check und Hansen (2005) SPA
#   min_track_record()   Mindestlänge einer Historie (Bailey & López de Prado 2012)
#   return_heatmap()     annualisierte (reale) Renditen je Startjahr und Haltedauer
module AnalysisTests

import ..SimLev
using Dates

export signal_analysis, sharpe_test, reality_check, min_track_record, return_heatmap

const DA = SimLev.DeepAnalysis
const _NA = SimLev.NA

"`is.numeric(x) && is.null(dim(x))`."
_is_num_vector(x) = DA._isnum_el(x) ||
                    (x isa AbstractVector && nonmissingtype(eltype(x)) <: Real && !(nonmissingtype(eltype(x)) <: Bool))

"Periodenrenditen aus Ergebnis, data.frame oder Vektor (`.ret_from`): `RList(r, date)`."
function _ret_from(x, frequency, inflation = nothing)
    x = SimLev.as_rframe(x)
    _is_num_vector(x) && return SimLev.RList("r" => DA._f64(x isa AbstractVector ? x : [x]), "date" => nothing)
    s = DA._da_series(x, "x")
    inflation === nothing || (s = DA._da_deflate(s, inflation))
    if frequency == "day"
        keep = vcat(true, .!s.filled[2:end])
        d = s.date[keep]; v = s.value[keep]
    else
        key = frequency == "week" ? DA._key_isoweek(s.date) : DA._key_month(s.date)
        e = DA._last_of_key(key)
        d = s.date[e]; v = s.value[e]
    end
    SimLev.RList("r" => DA._ratio_m1(v), "date" => DA._dates(d[2:end]))
end

# ═══════════════════════════════════════════════════════════════════════════
# signal_analysis
# ═══════════════════════════════════════════════════════════════════════════

"`as.integer(x)` (Abschneiden; nothing/NA → nothing je Element)."
function _as_int(x)
    x === nothing && return nothing
    a = x isa Union{AbstractVector,Tuple} ? collect(x) : Any[x]
    Union{Nothing,Int}[(e isa Real && !(e isa Float64 && isnan(e))) ? Int(trunc(Float64(e))) : nothing for e in a]
end

"Grenzen wie `cutb()` in `signal_analysis`."
function _cut_breaks(v, k, br)
    if br === nothing
        u = sort(unique(v))
        if length(u) <= k
            br = vcat(-Inf, u[2:end], Inf)
        else
            p = DA._vecf(SimLev.RStats.seq_len_out(0.0, 1.0, Int(ceil(k + 1))))
            br = unique(DA._quantile(v, p))
        end
    end
    br = collect(Float64, br)
    br[1] = -Inf; br[end] = Inf
    br
end

"`cut(v, br, include.lowest = TRUE, right = FALSE)` → (Codes 1-basiert, 0 = NA; Level)."
function _cut(v, br)
    res = SimLev.RStats.cut(collect(Float64, v), collect(Float64, br); include_lowest = true, right = false)
    _factor_codes(res)
end
"Codes und Level eines Faktors aus `RStats.cut`."
function _factor_codes(res)
    if res isa Tuple && length(res) == 2
        return Int[c === missing || c === nothing ? 0 : Int(c) for c in res[1]], String.(res[2])
    elseif res isa SimLev.RVector
        lv = String.(get(res.attrs, "levels", String[]))
        return Int[c === missing || (c isa Float64 && isnan(c)) ? 0 : Int(c) for c in res.values], lv
    elseif res isa AbstractDict
        lv = String.(DA._rget(res, "levels"))
        return Int[c === missing ? 0 : Int(c) for c in DA._rget(res, "codes")], lv
    elseif hasproperty(res, :codes) && hasproperty(res, :levels)
        return Int[c === missing || c === nothing ? 0 : Int(c) for c in res.codes], String.(res.levels)
    end
    error("RStats.cut: unbekanntes Ergebnis $(typeof(res))")
end
"`cut(x, k, labels = FALSE)` → Codes 1..k."
_cut_n(x, k) = DA._vecf(SimLev.RStats.cut(collect(Float64, x), Int(k); labels = false))

function _st(z)
    n = length(z); m = SimLev.r_mean(z); sd = SimLev.r_sd(z)
    Float64[n, m, _median(z), DA._mean_lgl(z .> 0), sd, m / (sd / sqrt(n))]
end
const _ST_NAMES = ["n", "mean", "median", "win_rate", "sd", "t"]
_median(z) = DA._vecf(SimLev.RStats.median(collect(Float64, z)))[1]

"`stats::t.test(x, y)` (Welch) → (statistic, p.value)."
function _welch(x, y)
    tt = SimLev.RStats.t_test(collect(Float64, x), collect(Float64, y))
    DA._vecf(DA._rget(tt, "statistic"))[1], DA._vecf(DA._rget(tt, "p.value"))[1]
end

"`lm(forward ~ stats::poly(signal, degree), data = df)` → (Modell, R²)."
function _poly_lm(df, degree)
    m = SimLev.RStats.lm("forward ~ stats::poly(signal, degree)"; data = df, degree = Int(degree))
    r2 = DA._vecf(DA._rget(SimLev.RStats.summary_lm(m), "r.squared"))[1]
    m, r2
end

"""
    signal_analysis(data, signal, target; horizon = 21, step = nothing, bins = 5, breaks = nothing,
                    signal2 = nothing, bins2 = 3, splits = 1, degree = 2)

Vorwärtsrenditen je Signalbereich (R: `signal_analysis()`); Ergebnis: `RList`
der Klasse `SimLevSignalAnalysis`.
"""
function signal_analysis(data, signal, target; horizon = 21, step = nothing, bins = 5, breaks = nothing,
                         signal2 = nothing, bins2 = 3, splits = 1, degree = 2)
    data = SimLev.as_rframe(data)
    (DA._is_frame(data) && "date" in names(DA._as_frame(data))) ||
        DA._stop("signal_analysis: data muss ein data.frame mit Spalte 'date' sein.")
    data = DA._as_frame(data)
    n = SimLev.nrow(data)
    d = DA._to_date_days(data["date"], "signal_analysis: data\$date")
    nms = names(data)
    function getcol(v, what)
        if v isa AbstractString || (v isa AbstractVector && !isempty(v) && first(v) isa AbstractString)
            vl = v isa AbstractString ? [String(v)] : String.(v)
            (length(vl) != 1 || !(vl[1] in nms)) &&
                DA._stop(DA._sp("signal_analysis: %s: Spalte '%s' fehlt in data (vorhanden: %s).", what, vl[1], join(nms, ", ")))
            return DA._as_numeric_col(data[vl[1]])
        end
        a = v isa AbstractVector ? v : [v]
        length(a) != n && DA._stop(DA._sp("signal_analysis: %s hat Länge %d, data hat %d Zeilen.", what, length(a), n))
        DA._as_numeric_col(a)
    end
    sig = getcol(signal, "signal")
    target isa AbstractString || DA._stop("signal_analysis: target muss ein Spaltenname sein.")
    px = getcol(target, "target")
    s2all = signal2 !== nothing ? getcol(signal2, "signal2") : nothing
    ok = findall(!isnan, d); nn = findall(isnan, d)
    o = vcat(ok[sortperm(d[ok]; alg = MergeSort)], nn)
    o = o[.!isnan.(d[o])]
    dup = DA._duplicated_last(d[o])
    any(dup) && DA._message(DA._sp("Hinweis: signal_analysis: %d doppelte Daten; der letzte Wert je Datum wird verwendet.", count(dup)))
    o = o[.!dup]
    d = d[o]; sig = sig[o]; px = px[o]
    s2all === nothing || (s2all = s2all[o])
    n = length(o)
    px = DA._f64(SimLev.Backcast._fill_na(px, "locf"; keep_leading = true))
    hz = _as_int(horizon); stp = _as_int(step === nothing ? horizon : step)
    if length(hz) != 1 || hz[1] === nothing || hz[1] < 1 || hz[1] >= n
        DA._stop(DA._sp("signal_analysis: horizon muss zwischen 1 und %d (Zeilen - 1) liegen (ist: %s).", n - 1,
                        join((h === nothing ? "NA" : string(h) for h in hz), ", ")))
    end
    (length(stp) != 1 || stp[1] === nothing || stp[1] < 1) && DA._stop("signal_analysis: step muss eine ganze Zahl >= 1 sein.")
    horizon = hz[1]; step = stp[1]
    if breaks !== nothing
        ba = breaks isa Union{AbstractVector,Tuple} ? collect(breaks) : Any[breaks]
        okb = all(DA._isnum_el, ba) && length(ba) >= 3
        if okb
            bf = DA._f64(ba)
            okb = !any(isnan, bf) && all(i -> bf[i] > bf[i-1], 2:length(bf))
        end
        okb || DA._stop("signal_analysis: breaks braucht mindestens 3 streng aufsteigende Grenzen (erste und letzte werden zu -Inf und Inf), z. B. c(-Inf, 0, Inf).")
        breaks = bf
    end
    if breaks === nothing
        bl = bins isa AbstractVector ? DA._f64(bins) : [Float64(bins)]
        (length(bl) != 1 || isnan(bl[1]) || bl[1] < 2) && DA._stop("signal_analysis: bins muss eine ganze Zahl >= 2 sein.")
    end
    t0 = collect(1:step:(n - horizon))
    fwd = px[t0 .+ horizon] ./ px[t0] .- 1
    s2 = s2all !== nothing ? s2all[t0] : nothing
    cc = [!isnan(sig[t]) && !isnan(fwd[i]) && (s2 === nothing || !isnan(s2[i])) for (i, t) in enumerate(t0)]
    rn = string.(findall(cc))
    dd = d[t0][cc]; sv = sig[t0][cc]; fw = fwd[cc]; s2v = s2 === nothing ? nothing : s2[cc]
    length(sv) < 20 && DA._stop(DA._sp("signal_analysis: zu wenige Stichtage (%d, mindestens 20) mit Signal und Vorwärtsrendite.", length(sv)))
    length(unique(sv)) < 2 && DA._stop(DA._sp("signal_analysis: Signal ist an allen Stichtagen gleich (%g); keine Bereiche möglich.", sv[1]))
    ppy = (n - 1) / ((d[n] - d[1]) / 365.25)
    ann(m) = SimLev.r_pow(1 + m, ppy / horizon) - 1
    codes, lv = _cut(sv, _cut_breaks(sv, breaks === nothing ? Float64(DA._first(bins)) : 0.0, breaks))
    rows_ = Vector{Any}[]
    for (j, lab) in enumerate(lv)
        sel = codes .== j
        any(sel) || continue
        z = fw[sel]
        push!(rows_, Any[lab, DA._rmin(sv[sel]), DA._rmax(sv[sel]), _st(z)..., ann(SimLev.r_mean(z))])
    end
    bcols = ["bin", "from", "to", _ST_NAMES..., "annualized"]
    tab = SimLev.RFrame("bin" => String[r[1] for r in rows_],
                        (c => Float64[r[i+1] for r in rows_] for (i, c) in enumerate(bcols[2:end]))...)
    lo = fw[codes .== 1]; hi = fw[codes .== length(lv)]
    tstat, pval = (length(lo) > 2 && length(hi) > 2) ? _welch(hi, lo) : (_NA, _NA)
    spread = SimLev.RVector([SimLev.r_mean(hi) - SimLev.r_mean(lo), tstat, pval]; names = ["difference", "t", "p"])
    fit = nothing
    if degree > 0 && length(unique(sv)) > degree + 1
        dfl = SimLev.RFrame("signal" => sv, "forward" => fw; rownames = rn)
        model, r2 = _poly_lm(dfl, Int(degree))
        fit = SimLev.RList("model" => model, "r_squared" => r2)
    end
    spl = nothing
    if splits > 1
        seg = _cut_n(collect(1.0:length(sv)), splits)
        M = fill(_NA, length(lv), Int(splits)); cn = String[]
        for k in 1:Int(splits)
            for j in eachindex(lv)
                z = fw[(seg .== k) .& (codes .== j)]
                M[j, k] = isempty(z) ? _NA : SimLev.r_mean(z)
            end
            dk = dd[seg .== k]
            push!(cn, join(string.(DA._key_year([DA._rmin(dk), DA._rmax(dk)])), "-"))
        end
        spl = SimLev.NamedMat(M; rownames = lv, colnames = cn)
    end
    t2 = nothing; bin2 = nothing
    if s2v !== nothing
        codes2, lv2 = _cut(s2v, _cut_breaks(s2v, Float64(bins2), nothing))
        Mm = fill(_NA, length(lv), length(lv2)); Mn = zeros(Int, length(lv), length(lv2))
        for i in eachindex(lv), j in eachindex(lv2)
            z = fw[(codes .== i) .& (codes2 .== j)]
            Mn[i, j] = length(z)
            isempty(z) || (Mm[i, j] = SimLev.r_mean(z))
        end
        t2 = SimLev.RList("mean" => SimLev.NamedMat(Mm; rownames = lv, colnames = lv2),
                          "n" => SimLev.NamedMat(Mn; rownames = lv, colnames = lv2))
        bin2 = SimLev.RFmt.RFactor(codes2, lv2)
    end
    out = SimLev.RFrame("date" => DA._dates(dd), "signal" => sv, "forward" => fw; rownames = rn)
    s2v === nothing || (out["signal2"] = s2v)
    out["bin"] = SimLev.RFmt.RFactor(codes, lv)
    bin2 === nothing || (out["bin2"] = bin2)
    SimLev.RList("bins" => tab, "overall" => SimLev.RVector(_st(fw); names = _ST_NAMES), "spread" => spread,
                 "splits" => spl, "table2d" => t2, "fit" => fit, "data" => out, "horizon" => horizon, "step" => step,
                 "target" => String(target), "signal_name" => signal isa AbstractString ? String(signal) : "signal";
                 class = ["SimLevSignalAnalysis"])
end

_pct(f, v) = String[DA._sp(f, 100 * Float64(e)) for e in v]

"`print.SimLevSignalAnalysis`."
function _print_signal(io::IO, x)
    print(io, DA._sp("Signal-Analyse: %s -> Rendite von '%s' über %d Zeilen (%d Stichtage, Abstand %d)\n\n",
                     x["signal_name"], x["target"], Int(x["horizon"]), SimLev.nrow(x["data"]), Int(x["step"])))
    b = x["bins"]
    tab = SimLev.RFrame("Bereich" => String.(b["bin"]), "n" => DA._f64(b["n"]),
                        "Mittel" => _pct("%.2f %%", b["mean"]), "Median" => _pct("%.2f %%", b["median"]),
                        "Treffer" => _pct("%.0f %%", b["win_rate"]), "t" => String[DA._sp("%.2f", Float64(v)) for v in b["t"]],
                        "p. a." => _pct("%.1f %%", b["annualized"]))
    DA._print_df(io, tab; row_names = false)
    o = x["overall"]
    print(io, DA._sp("\nAlle Stichtage: Mittel %.2f %%, Trefferquote %.0f %%\n", 100 * o["mean"], 100 * o["win_rate"]))
    sp = x["spread"]
    print(io, DA._sp("Oberster minus unterster Bereich: %+.2f %% (Welch-t %.2f, p = %.3f)\n", 100 * sp["difference"], sp["t"], sp["p"]))
    get(x, "fit", nothing) === nothing || print(io, DA._sp("Polynom-Glättung: R^2 = %.3f\n", x["fit"]["r_squared"]))
    if get(x, "splits", nothing) !== nothing
        print(io, "\nMittelwerte je Zeitabschnitt (Stabilität)\n")
        DA._print_matrix(io, DA._rround(SimLev.NamedMat(100 .* x["splits"].data; rownames = x["splits"].rownames,
                                                        colnames = x["splits"].colnames), 2))
    end
    if get(x, "table2d", nothing) !== nothing
        M = x["table2d"]["mean"]
        print(io, "\nMittelwerte je Bereich beider Signale\n")
        DA._print_matrix(io, DA._rround(SimLev.NamedMat(100 .* M.data; rownames = M.rownames, colnames = M.colnames), 2))
    end
    nothing
end

"`plot.SimLevSignalAnalysis` (SVG): Balken je Bereich (± 2 Standardfehler) und Streudiagramm."
function _plot_signal(x; file = nothing)
    b = x["bins"]; nb = SimLev.nrow(b)
    m = 100 .* DA._f64(b["mean"]); se = 100 .* DA._f64(b["sd"]) ./ sqrt.(DA._f64(b["n"]))
    lo = m .- 2 .* se; hi = m .+ 2 .* se
    fin = filter(isfinite, vcat(lo, hi, 0.0))
    s = DA._Svg(1000, 460)
    p = DA._panel(s, 0, 0, 500, 460, (0.5, nb + 0.5), (minimum(fin), maximum(fin)); title = "Je Signalbereich",
                  xlab = "Signalbereich (niedrig -> hoch)", ylab = "Mittlere Vorwärtsrendite (%)", xticks = collect(1:nb))
    for i in 1:nb
        DA._rect(s, p, i - 0.35, 0.0, i + 0.35, m[i]; fill = "#2C6E9B")
        DA._lines(s, p, [i, i], [lo[i], hi[i]]; col = "#000", lwd = 1)
    end
    DA._hline(s, p, 100 * x["overall"]["mean"]; col = "#B5562B", dash = "5,4")
    dd = x["data"]; sv = DA._f64(dd["signal"]); fv = 100 .* DA._f64(dd["forward"])
    q = DA._panel(s, 500, 0, 500, 460, (DA._rmin(sv), DA._rmax(sv)), (DA._rmin(fv), DA._rmax(fv)); title = "Streudiagramm",
                  xlab = x["signal_name"], ylab = "Vorwärtsrendite (%)")
    DA._points(s, q, sv, fv)
    if get(x, "fit", nothing) !== nothing
        fitted = DA._vecf(DA._rget(x["fit"]["model"], "fitted.values"))
        o = sortperm(sv; alg = MergeSort)
        DA._lines(s, q, sv[o], 100 .* fitted[o]; col = "#B5562B", lwd = 2)
    end
    DA._hline(s, q, 0.0)
    SimLev.SimLevDashboard(DA._svg_done(s, file))
end

# ═══════════════════════════════════════════════════════════════════════════
# sharpe_test
# ═══════════════════════════════════════════════════════════════════════════

_mat(r) = Matrix{Float64}(r isa SimLev.NamedMat ? r.data : r)
_crossprod(A) = _mat(SimLev.RLinalg.crossprod(Matrix{Float64}(A)))
_crossprod(A, B) = _mat(SimLev.RLinalg.crossprod(Matrix{Float64}(A), Matrix{Float64}(B)))
_matprod(A, B) = _mat(SimLev.RLinalg.matprod(Matrix{Float64}(A), Matrix{Float64}(B)))

"Newey-West-Kovarianz mit Bartlett-Kern (`.hac_cov`)."
function _hac_cov(Y, lag = nothing)
    Y = Matrix{Float64}(Y isa SimLev.NamedMat ? Y.data : Y)
    Tn = size(Y, 1)
    lag === nothing && (lag = floor(4 * SimLev.r_pow(Tn / 100, 2 / 9)))
    cm = DA._col_means(Y)
    Yc = Y .- cm'
    S = _crossprod(Yc) ./ Tn
    for l in 1:Int(lag)
        G = _crossprod(Yc[l+1:Tn, :], Yc[1:Tn-l, :]) ./ Tn
        S = S .+ (1 - l / (lag + 1)) .* (G .+ permutedims(G))
    end
    S
end

_with_rng(f, seed) = SimLev.Bootstrap._with_rng_restore(f; seed = seed)
_boot_idx(n, m, L) = Int.(DA._vecf(SimLev.BootstrapCore.boot_idx_stationary(n, m, L)))
_ppy_default(frequency) = Dict("day" => 252.0, "week" => 52.0, "month" => 12.0)[frequency]
_sr(r) = SimLev.r_mean(r) / SimLev.r_sd(r)

const _SHARPE_NAMES = ["sharpe_x", "sharpe_y", "difference", "se", "z", "p_value", "ci_low", "ci_high", "n"]

"""
    sharpe_test(x, y; frequency = ["week", "day", "month"], method = ["hac", "bootstrap"],
                B = 2000, block = nothing, seed = nothing, ppy = nothing)

Test auf gleiche Sharpe Ratios (Ledoit & Wolf 2008; R: `sharpe_test()`).
Ergebnis: benannter Vektor (`RVector`).
"""
function sharpe_test(x, y; frequency = ["week", "day", "month"], method = ["hac", "bootstrap"], B = 2000,
                     block = nothing, seed = nothing, ppy = nothing)
    x = SimLev.as_rframe(x)
    y = SimLev.as_rframe(y)
    frequency = DA._match_arg(frequency, ["week", "day", "month"])
    method = DA._match_arg(method, ["hac", "bootstrap"])
    a = _ret_from(x, frequency); b = _ret_from(y, frequency)
    (a["date"] === nothing) != (b["date"] === nothing) &&
        DA._stop("sharpe_test: x und y müssen dieselbe Art sein: beide Renditevektoren oder beide Kursreihen/Ergebnisse (data.frame bzw. SimLevResult).")
    if a["date"] !== nothing
        da = DA._days(a["date"]); db = DA._days(b["date"])
        sb = Set(db)
        common = unique([v for v in da if v in sb])
        ra = a["r"][DA._match(common, da)]; rb = b["r"][DA._match(common, db)]
        ppy === nothing && (ppy = (length(common) - 1) / ((maximum(common) - minimum(common)) / 365.25))
    else
        length(a["r"]) != length(b["r"]) &&
            DA._stop(DA._sp("sharpe_test: Renditevektoren x und y müssen gleich lang und zeitgleich sein (Längen %d und %d).",
                            length(a["r"]), length(b["r"])))
        ra = a["r"]; rb = b["r"]
        ppy === nothing && (ppy = _ppy_default(frequency))
    end
    ok = isfinite.(ra) .& isfinite.(rb)
    ra = ra[ok]; rb = rb[ok]; Tn = length(ra)
    Tn < 10 && DA._stop(DA._sp("sharpe_test: zu wenige gemeinsame Renditepaare (%d, mindestens 10).", Tn))
    for (k, v) in (("x", ra), ("y", rb))
        SimLev.r_sd(v) == 0 && DA._stop(DA._sp("sharpe_test: Renditen von %s haben die Varianz 0; die Sharpe Ratio ist nicht definiert.", k))
    end
    ppy = Float64(ppy)
    d0 = _sr(ra) - _sr(rb)
    if length(ra) == length(rb) && all(ra .== rb)          # identical(): -0 == 0
        return SimLev.RVector([_sr(ra) * sqrt(ppy), _sr(rb) * sqrt(ppy), 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, Float64(Tn)]; names = _SHARPE_NAMES)
    end
    if method == "hac"
        mu = [SimLev.r_mean(ra), SimLev.r_mean(rb)]
        g = [SimLev.r_mean(ra .* ra), SimLev.r_mean(rb .* rb)]
        v1 = SimLev.r_pow(g[1] - mu[1] * mu[1], 1.5); v2 = SimLev.r_pow(g[2] - mu[2] * mu[2], 1.5)
        grad = [g[1] / v1, -g[2] / v2, -0.5 * mu[1] / v1, 0.5 * mu[2] / v2]
        Psi = _hac_cov(hcat(ra, rb, ra .* ra, rb .* rb))
        q = _matprod(_matprod(reshape(grad, 1, 4), Psi), reshape(grad, 4, 1))
        se = sqrt(q[1] / Tn)
        z = d0 / se
        p = 2 * DA._vecf(SimLev.RNmath.pnorm(-abs(z)))[1]
        qq = DA._vecf(SimLev.RNmath.qnorm(0.975))[1]
        ci = [d0 + (-1 * qq) * se, d0 + (1 * qq) * se]
    else
        block === nothing && (block = max(2.0, SimLev.RFmt.r_round(SimLev.r_pow(Tn, 1 / 3), 0)))
        function run()
            out = Vector{Float64}(undef, Int(B))
            for i in 1:Int(B)
                k = _boot_idx(Tn, Tn, block)
                out[i] = _sr(ra[k]) - _sr(rb[k])
            end
            out
        end
        dbs = _with_rng(run, seed)
        se = SimLev.r_sd(dbs)
        z = d0 / se
        p = DA._mean_lgl(abs.(dbs .- d0) .>= abs(d0))
        ci = DA._quantile(dbs, [0.025, 0.975])
    end
    k = sqrt(ppy)
    SimLev.RVector([_sr(ra) * k, _sr(rb) * k, d0 * k, se * k, z, p, ci[1] * k, ci[2] * k, Float64(Tn)]; names = _SHARPE_NAMES)
end

# ═══════════════════════════════════════════════════════════════════════════
# reality_check
# ═══════════════════════════════════════════════════════════════════════════

"""
    reality_check(x; benchmark = nothing, B = 999, block = nothing,
                  frequency = ["week", "day", "month"], dates = nothing, seed = nothing)

White Reality Check und Hansen-SPA-Test (R: `reality_check()`); Ergebnis:
`RList` der Klasse `SimLevRealityCheck`.
"""
function reality_check(x; benchmark = nothing, B = 999, block = nothing, frequency = ["week", "day", "month"],
                       dates = nothing, seed = nothing)
    x = SimLev.as_rframe(x)
    frequency = DA._match_arg(frequency, ["week", "day", "month"])
    rr = SimLev.Overfitting._of_returns(x, frequency, dates)
    Rf = DA._rget(rr, "R")
    R = _mat(Rf)
    cn = Rf isa SimLev.NamedMat && Rf.colnames !== nothing ? copy(Rf.colnames) :
         Rf isa SimLev.RFrame ? names(Rf) : ["p$j" for j in 1:size(R, 2)]
    if benchmark === nothing
        b = zeros(size(R, 1))
    else
        barr = benchmark isa SimLev.RVector ? benchmark.values : benchmark isa Union{AbstractVector,Tuple} ? collect(benchmark) : Any[benchmark]
        if length(barr) == 1
            e = barr[1]
            j = e isa AbstractString ? (e in cn ? findfirst(==(e), cn) : nothing) :
                (e isa Real && !(e isa Float64 && isnan(e))) ? Int(trunc(Float64(e))) : nothing
            (j === nothing || j < 1 || j > size(R, 2)) && DA._stop("benchmark: unbekannte Spalte.")
            b = R[:, j]
            keepc = [i for i in 1:size(R, 2) if i != j]
            R = R[:, keepc]; cn = cn[keepc]
        else
            b = DA._f64(barr)
        end
    end
    length(b) != size(R, 1) && DA._stop("benchmark passt nicht zur Länge der Renditen.")
    D = R .- b
    Tn, K = size(D)
    fbar = DA._col_means(D)
    block === nothing && (block = max(2.0, SimLev.RFmt.r_round(SimLev.r_pow(Tn, 1 / 3), 0)))
    function run()
        out = Matrix{Float64}(undef, Int(B), K)
        for i in 1:Int(B)
            out[i, :] = DA._col_means(D[_boot_idx(Tn, Tn, block), :])
        end
        out
    end
    Fb = _with_rng(run, seed)
    sq = sqrt(Tn)
    om = Float64[max(SimLev.r_sd(Fb[:, j]), 1e-12) * sq for j in 1:K]
    V = DA._rmax(sq .* fbar)
    Vb = Float64[DA._rmax(sq .* (Fb[i, :] .- fbar)) for i in 1:size(Fb, 1)]
    p_rc = DA._mean_lgl(Vb .>= V)
    Tspa = max(DA._rmax(sq .* fbar ./ om), 0.0)
    thr = -sqrt.(om .* om ./ Tn .* 2 .* SimLev.RLibm.log(SimLev.RLibm.log(Float64(Tn))))
    function spa_p(gv)
        Ts = Float64[max(DA._rmax((sq .* (Fb[i, :] .- gv)) ./ om), 0.0) for i in 1:size(Fb, 1)]
        DA._mean_lgl(Ts .>= Tspa)
    end
    jbest = DA._which_max(fbar)
    SimLev.RList("p_rc" => p_rc, "p_spa" => spa_p(fbar .* (fbar .>= thr)), "p_spa_lower" => spa_p(max.(fbar, 0.0)),
                 "p_spa_upper" => spa_p(fbar), "best" => cn[jbest], "mean_excess" => SimLev.RVector(fbar; names = cn),
                 "n" => Tn, "k" => K, "B" => B; class = ["SimLevRealityCheck"])
end

"`print.SimLevRealityCheck`."
function _print_rc(io::IO, x)
    print(io, DA._sp("Reality Check und SPA: %d Strategien, %d Perioden, B = %d\n", Int(x["k"]), Int(x["n"]), Int(x["B"])))
    print(io, DA._sp("  Beste Strategie: %s (mittlere Überrendite %.4f je Periode)\n", string(x["best"]), DA._rmax(DA._f64(x["mean_excess"]))))
    print(io, DA._sp("  p-Wert Reality Check (White):   %.3f\n  p-Wert SPA (Hansen, konsistent): %.3f  [untere %.3f, obere %.3f]\n",
                     x["p_rc"], x["p_spa"], x["p_spa_lower"], x["p_spa_upper"]))
    print(io, "  Lesart: kleiner p-Wert = die beste Strategie schlägt die Benchmark auch nach Berücksichtigung der Auswahl.\n")
    nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# min_track_record
# ═══════════════════════════════════════════════════════════════════════════

"""
    min_track_record(x; target = 0, prob = 0.95, frequency = ["week", "day", "month"], ppy = nothing)

Mindestlänge einer Historie (Minimum Track Record Length; R: `min_track_record()`).
"""
function min_track_record(x; target = 0, prob = 0.95, frequency = ["week", "day", "month"], ppy = nothing)
    x = SimLev.as_rframe(x)
    frequency = DA._match_arg(frequency, ["week", "day", "month"])
    a = _ret_from(x, frequency)
    r = filter(isfinite, a["r"])
    if ppy === nothing
        if a["date"] !== nothing
            dd = DA._days(a["date"])
            ppy = (length(r) - 1) / ((maximum(dd) - minimum(dd)) / 365.25)
        else
            ppy = _ppy_default(frequency)
        end
    end
    ppy = Float64(ppy)
    m = SimLev.r_mean(r); sdv = SimLev.r_sd(r)
    sr = m / sdv; sr0 = target / sqrt(ppy)
    z = (r .- m) ./ sdv
    g3 = SimLev.r_mean(Float64[SimLev.r_pow(v, 3.0) for v in z])
    g4 = SimLev.r_mean(Float64[SimLev.r_pow(v, 4.0) for v in z])
    need = if sr <= sr0
        Inf
    else
        qq = DA._vecf(SimLev.RNmath.qnorm(prob))[1] / (sr - sr0)
        1 + (1 - g3 * sr + (g4 - 1) / 4 * (sr * sr)) * (qq * qq)
    end
    nr = length(r)
    SimLev.RVector([sr * sqrt(ppy), Float64(nr), need, need / ppy, nr / ppy, Float64(nr >= need)];
                   names = ["sharpe", "periods", "needed_periods", "needed_years", "available_years", "sufficient"])
end

# ═══════════════════════════════════════════════════════════════════════════
# return_heatmap
# ═══════════════════════════════════════════════════════════════════════════

"""
    return_heatmap(x; inflation = nothing, max_years = 30)

Annualisierte (reale) Renditen je Startjahr und Haltedauer (R: `return_heatmap()`);
Ergebnis: `RList` der Klasse `SimLevHeatmap` (`matrix`, `summary`, `real`).
"""
function return_heatmap(x; inflation = nothing, max_years = 30)
    x = SimLev.as_rframe(x)
    s = DA._da_series(x, "x")
    inflation === nothing || (s = DA._da_deflate(s, inflation))
    d = s.date
    yr = DA._key_year(d); m = length(yr)
    e = DA._last_of_key(yr)
    keep = vcat(true, .!s.filled[2:end])
    dk = d[keep]
    tol = min(7.0, DA._rmax(Float64[dk[i] - dk[i-1] for i in 2:length(dk)]))
    dec31 = DA._day1(Date(yr[m], 12, 31))
    dec31 - d[m] >= tol && (e = e[1:end-1])
    v = s.value
    base = vcat(v[1], v[e]); years = vcat(yr[1] - 1, yr[e])
    d1 = DA._date1(d[1])
    if !(Dates.month(d1) == 1 && Dates.day(d1) == 1)
        base = v[e]; years = yr[e]
    end
    ny = length(base) - 1
    ny < 1 && DA._stop("return_heatmap: Die Reihe umfasst kein vollständiges Kalenderjahr.")
    H = Int(min(max_years, ny))
    M = fill(_NA, ny, H)
    for i in 1:ny, h in 1:min(H, ny - i + 1)
        M[i, h] = SimLev.r_pow(base[i+h] / base[i], 1 / h) - 1
    end
    Mn = SimLev.NamedMat(M; rownames = string.(years[2:end]), colnames = string.(1:H))
    mins = Float64[]; meds = Float64[]; maxs = Float64[]; neg = Float64[]; cnt = Float64[]
    for j in 1:H
        c = filter(!isnan, M[:, j])
        push!(mins, DA._rmin(c)); push!(meds, _median(c)); push!(maxs, DA._rmax(c))
        push!(neg, DA._mean_lgl(c .< 0)); push!(cnt, Float64(length(c)))
    end
    summ = SimLev.RFrame("years" => collect(1:H), "min" => mins, "median" => meds, "max" => maxs,
                         "share_negative" => neg, "n" => cnt; rownames = string.(1:H))
    SimLev.RList("matrix" => Mn, "summary" => summ, "real" => inflation !== nothing; class = ["SimLevHeatmap"])
end

"`print.SimLevHeatmap`."
function _print_heatmap(io::IO, x)
    print(io, "Renditen je Startjahr und Haltedauer (", x["real"] ? "real" : "nominal", ", annualisiert)\n\n")
    s = x["summary"]
    sel = findall(y -> y in (1, 3, 5, 10, 15, 20, 25, 30), s["years"])
    tab = SimLev.RFrame("Jahre" => collect(Int, s["years"][sel]), "Minimum" => _pct("%.1f %%", s["min"][sel]),
                        "Median" => _pct("%.1f %%", s["median"][sel]), "Maximum" => _pct("%.1f %%", s["max"][sel]),
                        "negativ" => _pct("%.0f %%", s["share_negative"][sel]), "Zeitraeume" => DA._f64(s["n"][sel]))
    DA._print_df(io, tab; row_names = false)
    nothing
end

"`plot.SimLevHeatmap` (SVG): Heatmap Startjahr x Haltedauer (Farbskala bei ± 25 % begrenzt)."
function _plot_heatmap(x; file = nothing)
    Mm = x["matrix"]; M = 100 .* Mm.data
    fin = filter(isfinite, M); lim = min(isempty(fin) ? 1.0 : maximum(abs.(fin)), 25.0)
    pal = DA._ramp(["#B5562B", "#F2E9DC", "#2C6E9B"], 51)
    yrs = parse.(Int, Mm.rownames); H = size(M, 2)
    s = DA._Svg(900, 520)
    p = DA._panel(s, 0, 0, 820, 520, (yrs[1] - 0.5, yrs[end] + 0.5), (0.5, H + 0.5);
                  title = "Annualisierte $(x["real"] ? "reale" : "nominale") Rendite", xlab = "Startjahr",
                  ylab = "Haltedauer (Jahre)", xticks = Float64.(yrs[1:max(1, cld(length(yrs), 12)):end]),
                  xlabels = string.(yrs[1:max(1, cld(length(yrs), 12)):end]))
    for i in eachindex(yrs), h in 1:H
        v = M[i, h]; isfinite(v) || continue
        v = clamp(v, -lim, lim)
        c = pal[clamp(round(Int, (v + lim) / (2 * lim) * 50) + 1, 1, 51)]
        DA._rect(s, p, yrs[i] - 0.5, h - 0.5, yrs[i] + 0.5, h + 0.5; fill = c)
    end
    for (k, t) in enumerate((-lim, 0.0, lim))
        DA._legend(s, p, [DA._sp("%+.0f %%", t)], [pal[[1, 26, 51][k]]]; x = 830.0, y = 60.0 + 20 * (k - 1), box = true)
    end
    SimLev.SimLevDashboard(DA._svg_done(s, file))
end

function __init__()
    SimLev.register_print!("SimLevSignalAnalysis", _print_signal)
    SimLev.register_plot!("SimLevSignalAnalysis", SimLev._plot_method(_plot_signal, "SimLevSignalAnalysis"))
    SimLev.register_print!("SimLevRealityCheck", _print_rc)
    SimLev.register_print!("SimLevHeatmap", _print_heatmap)
    SimLev.register_plot!("SimLevHeatmap", SimLev._plot_method(_plot_heatmap, "SimLevHeatmap"))
end

end # module
