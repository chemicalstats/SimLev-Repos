# AnalysisTests – Gegenstück zu r/R/analysis_tests.R und python/simlev/analysis_tests.py
#
#   signal_analysis()    Vorwärtsrenditen je Signalbereich (Regressogramm)
#   sharpe_test()        Unterschied zweier Sharpe Ratios (Ledoit & Wolf 2008)
#   overfit_reality_check()      White (2000) Reality Check und Hansen (2005) SPA
#   sharpe_min_track_record()   Mindestlänge einer Historie (Bailey & López de Prado 2012)
#   result_heatmap()     annualisierte (reale) Renditen je Startjahr und Haltedauer
module AnalysisTests

import ..SimLev
using ..SimLev: _AnaSvg, _ana_hline, _ana_legend, _ana_lines, _ana_panel, _ana_points, _ana_ramp, _ana_rect,
                _ana_svg_done
using Dates

export signal_analysis, sharpe_test, overfit_reality_check, sharpe_min_track_record, result_heatmap

const DA = SimLev.DeepAnalysis
const _NA = SimLev.NA

"`is.numeric(x) && is.null(dim(x))`."
# seit 1.6.5 (CR2-X27-1): auch Vector{Any} aus Zahlen (ohne Wahrheitswerte) bzw. missing, wie Python
_is_num_vector(x) = DA._isnum_el(x) ||
                    (x isa AbstractVector && nonmissingtype(eltype(x)) <: Real && !(nonmissingtype(eltype(x)) <: Bool)) ||
                    (x isa AbstractVector && !isempty(x) && !(x isa SimLev.RFrame) &&
                     all(e -> e === missing || (e isa Real && !(e isa Bool)), x))

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
    SimLev.RList("r" => DA._ratio_m1(v), "date" => DA._dates(d[2:end]), "lvl" => v, "ldate" => DA._dates(d))
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

# Langfristige Kovarianz mit Bartlett-Gewichten (R .sa_lrv, seit 1.6.5, CR2-5)
function _sa_lrv(a, b, L)
    n = length(a); s = SimLev.r_sum(a .* b)
    for l in 1:L
        l < n || continue
        s = s + (1 - l / (L + 1)) * (SimLev.r_sum(a[l+1:n] .* b[1:n-l]) + SimLev.r_sum(b[l+1:n] .* a[1:n-l]))
    end
    s
end

function _st(z)
    n = length(z); m = SimLev.r_mean(z); sd = SimLev.r_sd(z)
    Float64[n, m, _median(z), DA._mean_lgl(z .> 0), sd, m / (sd / sqrt(n))]
end
const _ST_NAMES = ["n", "mean", "median", "win_rate", "sd", "t"]
_median(z) = DA._vecf(SimLev.RStats.median(collect(Float64, z)))[1]

"""Welch-Test wie `.sl_welch_test` (R) → (statistic, p.value); p über `SLib.pt`.
Bei se = 0 (beide Stichproben konstant) NA."""
function _welch(x, y)
    x = collect(Float64, x); y = collect(Float64, y)
    nx, ny = length(x), length(y)
    ax = SimLev.r_var(x) / nx; ay = SimLev.r_var(y) / ny
    se2 = ax + ay
    (isfinite(se2) && se2 > 0) || return (_NA, _NA)
    tt = (SimLev.r_mean(x) - SimLev.r_mean(y)) / sqrt(se2)
    nu = (se2 * se2) / ((ax * ax) / (nx - 1) + (ay * ay) / (ny - 1))
    tt, 2 * SimLev.SLib.pt(-abs(tt), nu)
end

"""Polynom-Kleinstquadrate wie `.sl_poly_fit` (R): Basis 1, z, ..., z^d mit
z = (x - mean(x)) / sd(x), Lösung über `SLib.lsfit`; r² = 1 - RSS/TSS → (Modell, R²)."""
function _poly_lm(df, degree)
    x = DA._f64(df["signal"]); y = DA._f64(df["forward"]); degree = Int(degree)
    cx = SimLev.r_mean(x); sx = SimLev.r_sd(x)
    z = (x .- cx) ./ sx
    X = ones(Float64, length(z), degree + 1)
    for j in 1:degree
        X[:, j + 1] = X[:, j] .* z
    end
    nms = vcat(["(Intercept)"], degree >= 1 ? ["z"] : String[], ["z^$k" for k in 2:degree])
    f = SimLev.SLib.lsfit(X, y)
    res = f["residuals"]; d = y .- SimLev.r_mean(y)
    r2 = 1 - SimLev.r_sum(res .* res) / SimLev.r_sum(d .* d)
    model = SimLev.RList("coefficients" => SimLev.RVector(f["coefficients"]; names = nms),
                         "fitted" => f["fitted.values"], "degree" => degree,
                         "basis" => SimLev.RVector([cx, sx]; names = ["center", "scale"]))
    model, r2
end

"""
    signal_analysis(data, signal, target; horizon = 21, step = nothing, bins = 5, breaks = nothing,
                    signal2 = nothing, bins2 = 3, splits = 1, degree = 2)

Signal-Analyse: Vorwärtsrenditen je Signalbereich.

Beantwortet die Frage "Wenn das Signal auf diesem Niveau steht, was passiert danach typischerweise?" -
unabhängig von einer konkreten Handelsregel. Für jeden Stichtag (Zeile 1, dann alle `step` Zeilen) wird die
Rendite der Zielreihe über die folgenden `horizon` Zeilen gemessen (P_t+h / P_t - 1, als Anteil) und nach dem
Signalwert am Stichtag in Bereiche eingeteilt (Regressogramm). Splits prüfen, ob der Zusammenhang über die
Zeit stabil ist. Das ist eine Beschreibung vergangener Muster, kein Nachweis einer handelbaren Überrendite.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Klasse Date oder umwandelbar) und der Kursspalte `target`;
  optional Signalspalten. Die Zeilen werden nach Datum sortiert (Signalvektoren mit), bei doppeltem Datum gilt
  die letzte Zeile (mit Hinweis).
- `signal`: Spaltenname in `data` oder numerischer Vektor der Länge `nrow(data)`. Der Wert in Zeile t muss nur
  mit Daten bis einschließlich Zeile t berechnet sein (sonst Zukunftsinformation).
  Seit 1.6.4 keine Faktoren (Spalte oder Vektor).
- `target`: Name der Kursspalte (Niveaus, keine Renditen). Fehlende Kurse werden mit dem letzten bekannten
  Wert fortgeschrieben.
- `horizon`: Vorwärtshorizont in Zeilen der Daten (ganze Zahl von 1 bis `nrow(data) - 1`, Standard 21), z. B.
  21 Handelstage oder 30 Kalendertage.
- `step`: Abstand der Stichtage in Zeilen. `nothing` (Standard) = `horizon`, die Vorwärtsrenditen überlappen
  dann nicht.
- `bins`: Anzahl Bereiche nach Quantilen des Signals (ganze Zahl >= 2, Standard 5). Gleiche Quantilsgrenzen
  werden zusammengefasst (dann weniger Bereiche). Hat das Signal höchstens `bins` verschiedene Werte (z. B.
  0/1), erhält jeder Wert einen eigenen Bereich. Wird ignoriert, wenn `breaks` angegeben ist.
- `breaks`: Numerischer Vektor (mindestens 3) streng aufsteigender Bereichsgrenzen in der Einheit des Signals;
  `nothing` (Standard) = Quantile (`bins`). Die erste und letzte Grenze werden durch `-Inf` und `Inf` ersetzt;
  Bereiche sind links geschlossen, `[a, b)`.
- `signal2`, `bins2`: Optional zweites Signal (Spaltenname oder Vektor wie `signal`) und die Anzahl seiner
  Quantilsbereiche (Standard 3) für eine 2D-Tabelle. `nothing` (Standard) = keine 2D-Tabelle.
- `splits`: Anzahl gleich großer Gruppen aufeinanderfolgender Stichtage für die Stabilitätsprüfung (ganze
  Zahl, Standard 1 = keine Aufteilung).
  Seit 1.6.4 eine ganze Zahl ≥ 1.
- `degree`: Grad der Polynom-Regression `forward ~ poly(signal, degree)` (ganze Zahl, Standard 2; 0 = keine).
  Wird nur geschätzt, wenn es mehr als `degree + 1` verschiedene Signalwerte gibt.
  Seit 1.6.4 eine ganze Zahl ≥ 0.

# Rückgabe
Objekt der Klasse `SimLevSignalAnalysis`, eine Liste mit

- `bins`: Tabelle (RFrame) je (nicht leerem) Bereich: `bin` (Intervall als Text), `from`, `to` (kleinster und
  größter Signalwert im Bereich), `n`, `mean`, `median` (Vorwärtsrendite als Anteil), `win_rate` (Anteil
  positiver Renditen), `sd`, `t` (`mean / (sd / sqrt(n))`) und `annualized` ((1 + mean)^ppy / horizon - 1,
  Anteil p. a.; `ppy` = Zeilen je Jahr, geschätzt als `(nrow(data) - 1)` / Zeitspanne in Jahren zu 365.25
  Tagen).
- `overall`: benannter Vektor `n`, `mean`, `median`, `win_rate`, `sd`, `t` über alle Stichtage.
- `spread`: benannter Vektor `difference` (Mittel oberster minus unterster Bereich, Anteil), `t` und `p`
  (Welch-t-Test mit Freiheitsgraden nach Welch-Satterthwaite; `NA`, wenn einer der beiden Bereiche höchstens 2
  Werte hat oder beide konstant sind).
- `splits`: Matrix Bereiche x Zeitabschnitte mit der mittleren Vorwärtsrendite (Anteil), Spaltennamen
  "Jahr-Jahr"; `nothing` bei `splits = 1`.
- `table2d`: Liste mit `mean` (Matrix Bereich `signal` x Bereich `signal2`, mittlere Vorwärtsrendite als
  Anteil) und `n` (Häufigkeiten); `nothing` ohne `signal2`.
- `fit`: Liste mit `model` und `r_squared` (R^2 = 1 - RSS/TSS); `nothing` ohne Polynom-Glättung. `model` ist
  eine Liste mit `coefficients` (Basis 1, z, z^2, ... mit z = (signal - Mittel) / Standardabweichung),
  `fitted` (angepasste Werte), `degree` und `basis` (`center`, `scale`); bis 0.10.0 war es ein `lm`-Objekt mit
  orthogonalen Polynomen (angepasste Werte und R^2 sind gleich).
- `data`: Tabelle (RFrame) der Stichtage mit `date`, `signal`, `forward` (Anteil), ggf. `signal2`, `bin`, ggf.
  `bin2`.
- `horizon`, `step`, `target`, `signal_name`: Einstellungen.

`print()` zeigt die Bereichstabelle in Prozent, `plot()` Balken je Bereich (mit +/- 2 Standardfehlern) und ein
Streudiagramm Signal gegen Vorwärtsrendite.

# Details
Eingabe ist ein Tabelle (RFrame) mit Datum, Kursspalte und Signal (Spalte oder Vektor). Stichtage mit
fehlendem Signal (bzw. fehlendem zweiten Signal) oder fehlender Vorwärtsrendite entfallen; es müssen
mindestens 20 Stichtage bleiben.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1095
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
p = d["aktien"]
d["mom"] = [i > 60 ? p[i] / p[i-60] - 1 : NaN for i in 1:n]   # 60-Tage-Rendite
sa = signal_analysis(d, "mom", "aktien"; horizon = 21, bins = 4, splits = 2)
println(sa["bins"])
```
"""
function signal_analysis(data, signal, target; horizon = 21, step = nothing, bins = 5, breaks = nothing,
                         signal2 = nothing, bins2 = 3, splits = 1, degree = 2)
    # seit 1.6.4 nur RFrame wie R data.frame (Entscheidung 6; vorher NamedTuple/Dict umgewandelt)
    (data isa SimLev.RFrame && "date" in names(data)) ||
        DA._stop("signal_analysis: data muss ein data.frame mit Spalte 'date' sein.")
    data["date"] isa SimLev.RFmt.RFactor && SimLev.chk_stop("spalte_faktor", "signal_analysis", "date")   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
    data = DA._as_frame(data)
    n = SimLev.nrow(data)
    d = DA._to_date_days(data["date"], "signal_analysis: data\$date")
    nms = names(data)
    function getcol(v, what, type = "logisch_oder_numerisch")
        if v isa AbstractString || (v isa AbstractVector && !isempty(v) && first(v) isa AbstractString)
            vl = v isa AbstractString ? [String(v)] : String.(v)
            (length(vl) != 1 || !(vl[1] in nms)) &&
                DA._stop(DA._sp("signal_analysis: %s: Spalte '%s' fehlt in data (vorhanden: %s).", what, vl[1], join(nms, ", ")))
            SimLev.chk_col_type(data, vl[1], "signal_analysis", type)   # seit 1.6.4 (vorher Text MethodError)
            return DA._as_numeric_col(data[vl[1]])
        end
        # seit 1.6.4: Vektoren nur numerisch oder logisch (keine Tabelle, Matrix oder Liste)
        numel(e) = e === missing || e isa Real
        ((v isa AbstractVector && all(numel, v)) || v isa Real) ||
            SimLev.chk_stop("e2.spalte_oder_vektor", "signal_analysis", what)
        a = v isa AbstractVector ? v : [v]
        length(a) != n && DA._stop(DA._sp("signal_analysis: %s hat Länge %d, data hat %d Zeilen.", what, length(a), n))
        DA._as_numeric_col(a)
    end
    sig = getcol(signal, "signal")
    target = SimLev.chk_scalar(target)
    target isa AbstractString || DA._stop("signal_analysis: target muss ein Spaltenname sein.")
    px = getcol(target, "target", "numerisch")
    s2all = signal2 !== nothing ? getcol(signal2, "signal2") : nothing
    ok = findall(!isnan, d); nn = findall(isnan, d)
    o = vcat(ok[sortperm(d[ok]; alg = MergeSort)], nn)
    o = o[.!isnan.(d[o])]
    dup = SimLev.DataPrep._duplicated(d[o]; from_last = true)   # duplicated(d, fromLast = TRUE) (seit 1.6.4 eine Fassung)
    any(dup) && DA._message(DA._sp("Hinweis: signal_analysis: %d doppelte Daten; der letzte Wert je Datum wird verwendet.", count(dup)))
    o = o[.!dup]
    d = d[o]; sig = sig[o]; px = px[o]
    s2all === nothing || (s2all = s2all[o])
    n = length(o)
    px = DA._f64(SimLev.Backcast._fill_na(px, "locf"; keep_leading = true))
    # seit 1.6.4: ganze Zahlen (vorher z. B. 2.5 InexactError), Meldung ohne Eingabewert
    horizon, step, bins = SimLev.chk_scalar(horizon), SimLev.chk_scalar(step), SimLev.chk_scalar(bins)
    int1(v) = v isa Real && !(v isa Bool) && isfinite(Float64(v)) && Float64(v) == trunc(Float64(v))
    int1(horizon) || SimLev.chk_stop("ganz", "signal_analysis", "horizon", "1")
    step === nothing || (int1(step) && step >= 1) || DA._stop("signal_analysis: step muss eine ganze Zahl >= 1 sein.")
    (int1(bins) && bins >= 2) || DA._stop("signal_analysis: bins muss eine ganze Zahl >= 2 sein.")
    bins2 = SimLev.chk_int1(bins2, "signal_analysis", "bins2"; lo = 2)
    splits = SimLev.chk_int1(splits, "signal_analysis", "splits")
    degree = SimLev.chk_int1(degree, "signal_analysis", "degree"; lo = 0)
    hz = _as_int(horizon); stp = _as_int(step === nothing ? horizon : step)
    if length(hz) != 1 || hz[1] === nothing || hz[1] < 1 || hz[1] >= n
        DA._stop(DA._sp("signal_analysis: horizon muss zwischen 1 und %d (Zeilen - 1) liegen.", n - 1))
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
    # seit 1.6.5 (CR2-X37-1): -0.0 und 0.0 sind ein Wert (wie R und Python); nur für unique und Bereichsgrenzen
    svu = sv .+ 0.0
    length(unique(svu)) < 2 && DA._stop("signal_analysis: Signal ist an allen Stichtagen gleich; keine Bereiche möglich.")
    ppy = (n - 1) / ((d[n] - d[1]) / 365.25)
    ann(m) = SimLev._pow1m(m, ppy / horizon)
    codes, lv = _cut(sv, _cut_breaks(svu, breaks === nothing ? Float64(DA._first(bins)) : 0.0, breaks))
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
    ov = _st(fw)
    # seit 1.6.5 (CR2-5, K3): bei step < horizon Newey-West-Standardfehler (Bartlett, Lag ceiling(horizon / step) - 1)
    if step < horizon
        L = Int(cld(horizon, step)) - 1
        zb(j) = (z = zeros(length(fw)); sel = codes .== j; z[sel] = fw[sel] .- SimLev.r_mean(fw[sel]); z)
        tv = copy(tab["t"]); r = 0
        for j in eachindex(lv)
            any(codes .== j) || continue
            r += 1; z = zb(j)
            tv[r] = tab["mean"][r] / sqrt(_sa_lrv(z, z, L) / tab["n"][r]^2)
        end
        tab["t"] = tv
        z0 = fw .- ov[2]
        ov[6] = ov[2] / sqrt(_sa_lrv(z0, z0, L) / Float64(length(fw))^2)
        if length(lo) > 2 && length(hi) > 2
            zh = zb(length(lv)); zl = zb(1)
            v = _sa_lrv(zh, zh, L) / Float64(length(hi))^2 + _sa_lrv(zl, zl, L) / Float64(length(lo))^2 -
                2 * _sa_lrv(zh, zl, L) / (Float64(length(hi)) * length(lo))
            tt = spread["difference"] / sqrt(v)
            spread = SimLev.RVector([spread["difference"], tt, 2 * SimLev.SLib.pnorm([-abs(tt)])[1]];
                                    names = ["difference", "t", "p"])
        end
    end
    fit = nothing
    if degree > 0 && length(unique(svu)) > degree + 1
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
        codes2, lv2 = _cut(s2v, _cut_breaks(s2v .+ 0.0, Float64(bins2), nothing))
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
    SimLev.RList("bins" => tab, "overall" => SimLev.RVector(ov; names = _ST_NAMES), "spread" => spread,
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

"""
`plot.SimLevSignalAnalysis` (SVG): Balken je Bereich (± 2 Standardfehler) und Streudiagramm.

Liefert `(svg, data)`; `data`: `bins` (`bin`, `mean`, `lower`, `upper`: Mittel und Mittel ± 2
Standardfehler als Anteil) und `scatter` (`signal`, `forward` und mit Polynom-Glättung `fitted`).
"""
function _plot_signal(x)
    b = x["bins"]; nb = SimLev.nrow(b)
    m = 100 .* DA._f64(b["mean"]); se = 100 .* DA._f64(b["sd"]) ./ sqrt.(DA._f64(b["n"]))
    lo = m .- 2 .* se; hi = m .+ 2 .* se
    fin = filter(isfinite, vcat(lo, hi, 0.0))
    s = _AnaSvg(1000, 460)
    p = _ana_panel(s, 0, 0, 500, 460, (0.5, nb + 0.5), (minimum(fin), maximum(fin)); title = "Je Signalbereich",
                   xlab = "Signalbereich (niedrig -> hoch)", ylab = "Mittlere Vorwärtsrendite (%)", xticks = collect(1:nb))
    for i in 1:nb
        _ana_rect(s, p, i - 0.35, 0.0, i + 0.35, m[i]; fill = "#2C6E9B")
        _ana_lines(s, p, [i, i], [lo[i], hi[i]]; col = "#000", lwd = 1)
    end
    _ana_hline(s, p, 100 * x["overall"]["mean"]; col = "#B5562B", dash = "5,4")
    dd = x["data"]; sv = DA._f64(dd["signal"]); fv = 100 .* DA._f64(dd["forward"])
    q = _ana_panel(s, 500, 0, 500, 460, (DA._rmin(sv), DA._rmax(sv)), (DA._rmin(fv), DA._rmax(fv)); title = "Streudiagramm",
                   xlab = x["signal_name"], ylab = "Vorwärtsrendite (%)")
    _ana_points(s, q, sv, fv)
    sc = SimLev.RFrame("signal" => copy(sv), "forward" => DA._f64(dd["forward"]))
    if get(x, "fit", nothing) !== nothing
        fitted = DA._vecf(DA._rget(x["fit"]["model"], "fitted"))
        o = sortperm(sv; alg = MergeSort)
        _ana_lines(s, q, sv[o], 100 .* fitted[o]; col = "#B5562B", lwd = 2)
        sc["fitted"] = copy(fitted)
    end
    _ana_hline(s, q, 0.0)
    m0 = DA._f64(b["mean"]); se1 = DA._f64(b["sd"]) ./ sqrt.(DA._f64(b["n"]))
    data = SimLev.RList("bins" => SimLev.RFrame("bin" => String[string(v) for v in b["bin"]], "mean" => m0,
                                                "lower" => m0 .- 2 .* se1, "upper" => m0 .+ 2 .* se1),
                        "scatter" => sc)
    return (_ana_svg_done(s), data)
end

# ═══════════════════════════════════════════════════════════════════════════
# sharpe_test
# ═══════════════════════════════════════════════════════════════════════════

_mat(r) = Matrix{Float64}(r isa SimLev.NamedMat ? r.data : r)
# Matrixprodukte der C-Bibliothek slc, wie .sl_crossprod und %m% in R
_crossprod(A) = _mat(SimLev.SLib.crossprod(Matrix{Float64}(A)))
_crossprod(A, B) = _mat(SimLev.SLib.crossprod(Matrix{Float64}(A), Matrix{Float64}(B)))
_matprod(A, B) = _mat(SimLev.SLib.matmul(Matrix{Float64}(A), Matrix{Float64}(B)))

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

"Hauptstrom."
_main_stream(seed, fn) = SimLev.SLib.main_stream(seed, fn)

"""Tabellen nur als RFrame (Entscheidung 6, seit 1.6.4): NamedTuple, Dict und Paare sind in R Listen; Meldung wie R
`.da_series` für eine Liste."""
_no_list(x, name) = (x isa Union{NamedTuple,AbstractVector{<:Pair}} ||
                     (x isa AbstractDict && !(x isa SimLev.SimLevResult) &&
                      !(x isa SimLev.RList && SimLev.inherits(x, "SimLevResult")))) &&
    DA._stop(DA._sp("'%s' muss ein SimLevResult oder ein data.frame(date, value) sein.", name))

"benchmark: Zahl, Zahlenvektor oder ein einzelner Name (R: numerisch oder Text der Länge 1, kein Faktor)."
function _bench_ok(b)
    b isa AbstractString && return true
    v = b isa SimLev.RVector ? b.values : b isa Union{AbstractVector,Tuple} ? collect(Any, b) : Any[b]
    b isa AbstractMatrix && return false
    isempty(v) && return false
    length(v) == 1 && v[1] isa AbstractString && return true
    return all(e -> e isa Real && !(e isa Bool), v)
end
_boot_idx(n, m, L, stream) = Vector{Int}(SimLev.SLib.boot_idx_stationary(n, m, L; stream = stream))
_ppy_default(frequency) = Dict("day" => 252.0, "week" => 52.0, "month" => 12.0)[frequency]
_sr(r) = SimLev.r_mean(r) / SimLev.r_sd(r)

const _SHARPE_NAMES = ["sharpe_x", "sharpe_y", "difference", "se", "z", "p_value", "ci_low", "ci_high", "n"]

"""
    sharpe_test(x, y; frequency = ["week", "day", "month"], method = ["hac", "bootstrap"],
                B = 2000, block = nothing, ppy = nothing, seed = nothing, studentize = true, kernel = nothing,
                prewhiten = nothing)

Test auf gleiche Sharpe Ratios (Ledoit & Wolf 2008).

Prüft, ob sich die Sharpe Ratios zweier Strategien unterscheiden, robust gegen Autokorrelation,
Heteroskedastie und dicke Ränder (Ledoit & Wolf 2008): mit der Delta-Methode und Newey-West-Kovarianz
(`"hac"`) oder einem Block-Bootstrap der Renditepaare (`"bootstrap"`, seit 1.6.5 studentisiert und zirkulär). Der klassische
Jobson-Korkie-Test unterstellt Normalverteilung und unabhängige Renditen und ist für Finanzdaten zu
optimistisch.

# Argumente
- `x`, `y`: Zwei Renditequellen derselben Art (nicht mischen, sonst Fehler):

  - numerische Vektoren einfacher Periodenrenditen als Anteil (0.01 = 1 %), gleich lang und zeitgleich; Paare
    mit einem nicht endlichen Wert werden entfernt;
  - `SimLevResult` aus `simulation()` (verwendet wird der um Ein- und Auszahlungen bereinigte Wertindex aus
    `result_index()`; bei `"day"` ohne aufgefüllte Tage) oder `data.frame` mit Spalte `date` und einer
    Wertspalte (`value`, sonst die erste numerische Spalte; Niveaus, keine Renditen). Daraus werden Renditen
    von Periodenende zu Periodenende der `frequency` gebildet und nur gemeinsame Perioden-Enddaten verwendet.
- `frequency`: Periodenlänge: `"week"` (Standard, ISO-Wochen), `"day"` oder `"month"`. Bei Vektor-Eingabe
  bestimmt sie nur den Standardwert von `ppy`.
- `method`: "hac" (Standard): Delta-Methode mit HAC-Kovarianz (Standard Newey-West, Bartlett-Kern, Lag ⌊4
  (T/100)^(2/9)⌋; siehe kernel, prewhiten); "bootstrap": seit 1.6.5 studentisierter zirkulärer Block-Bootstrap der
  Renditepaare nach Ledoit & Wolf (2008, Abschnitt 3.2.2, siehe studentize und Details); mit studentize = `false`
  stationärer Block-Bootstrap wie bis 1.6.4 (Standardfehler = Standardabweichung der Bootstrap-Differenzen, p-Wert =
  Anteil der Wiederholungen mit |d^* - d| ≥ |d|, Intervall = 2.5- und 97.5-%-Quantil der Bootstrap-Differenzen).
- `B`: Anzahl Bootstrap-Wiederholungen (ganze Zahl, Standard 2000); nur bei `method = "bootstrap"`.
  Seit 1.6.4 höchstens 10^8.
- `block`: Blocklänge in Perioden: mit studentize = `true` die feste Länge b der Blöcke des zirkulären
  Block-Bootstraps (ganze Zahl), sonst die mittlere Blocklänge des stationären Bootstraps (geometrisch verteilte
  Blocklängen, Blöcke laufen zyklisch über das Ende); `nothing` (Standard) = max(2, round(T^(1/3))) mit T = Anzahl
  Renditepaare. Nur bei method = "bootstrap".
  Seit 1.6.4 eine Zahl ≥ 1. Mit studentize = `true` seit 1.6.5 höchstens T/4: die Block-Kovarianz Ψ* braucht
  mindestens 4 Blöcke (l = floor(T/b) ≥ 4, sonst Fehler; bei weniger Blöcken ist sie singulär und p-Wert und
  Intervall sind unbrauchbar). Die Güte des Tests sinkt schon vorher mit wachsender Blocklänge; T/4 ist nur die
  Mindestbedingung.
- `ppy`: Perioden je Jahr für die Annualisierung. `nothing` (Standard) = bei Vektoren 252 (`"day"`), 52
  (`"week"`) bzw. 12 (`"month"`); bei Ergebnissen und Tabelle (RFrame) aus den gemeinsamen Daten geschätzt:
  (Anzahl Perioden - 1) / (Zeitspanne in Tagen / 365.25).
  Seit 1.6.4 eine Zahl > 0.
- `seed`: Startwert für den Bootstrap (Standard `nothing`). Mit Startwert (ganze Zahl, |seed| < 2^53) ist das
  Ergebnis reproduzierbar und der Zufallszustand von SimLev bleibt unverändert; mit `nothing` wird genau
  einmal ein Startwert aus dem Zufallszustand von SimLev gezogen (siehe `simlev_seed()`), wiederholte Aufrufe
  liefern dann verschiedene Ergebnisse. `set.seed()` wirkt nicht.
- `studentize`: Logisch (seit 1.6.5, Standard `true`): bei method = "bootstrap" der studentisierte zirkuläre
  Block-Bootstrap nach Ledoit & Wolf (2008); `false` = der nicht studentisierte stationäre Block-Bootstrap bis 1.6.4
  (bitgleich).
- `kernel`: Kern der HAC-Kovarianz (seit 1.6.5): "bartlett" (Lag ⌊4 (T/100)^(2/9)⌋) oder "qs" (Quadratic Spectral mit
  automatischer Bandbreite S_T = 1.3221 (α(2) T)^(1/5) nach Andrews 1991 aus AR(1)-Näherungen je Moment). `nothing`
  (Standard) = "bartlett" bei method = "hac" (bitgleich zu 1.6.4 außer 142), "qs" beim studentisierten Bootstrap
  (Standardfehler der Ausgangsstichprobe wie bei Ledoit & Wolf 2008).
- `prewhiten`: Logisch (seit 1.6.5): Prewhitening mit einem VAR(1) nach Andrews & Monahan (1992). `nothing` (Standard)
  = `false` bei method = "hac", `true` beim studentisierten Bootstrap. Außer bei Bartlett ohne Prewhitening
  (Newey-West wie bisher) rechnet SimLev den Schätzer von Ledoit & Wolf (2008, Abschnitt 3.1) mit dem Faktor T/(T -
  4).

# Rückgabe
Benannter numerischer Vektor: `sharpe_x`, `sharpe_y` (Sharpe Ratios p. a.), `difference` (`sharpe_x -
sharpe_y`, p. a.), `se` (Standardfehler der Differenz, p. a.), `z` (`difference / se`), `p_value` (zweiseitig,
Anteil), `ci_low`, `ci_high` (95-%-Intervall der Differenz, p. a.) und `n` (Anzahl verwendeter Renditepaare).

# Details
Fertige Simulationen lassen sich direkt vergleichen: `x` und `y` dürfen Ergebnisse von `simulation()` sein.
Die Sharpe Ratio ist hier Mittelwert / Standardabweichung der Periodenrenditen, ohne Abzug eines risikolosen
Zinses, annualisiert mit √(ppy).

Mindestens 10 gemeinsame Renditepaare sind nötig, und keine der beiden Reihen darf die Varianz 0 haben (sonst
Fehler). Identische Reihen ergeben `difference = 0`, `se = 0`, `z = 0` und `p_value = 1`.

Studentisierter Bootstrap (Standard bei method = "bootstrap" seit 1.6.5, Ledoit & Wolf 2008, Abschnitt 3.2.2 und
Bemerkung 3.2): Δ = μ_x/σ_x - μ_y/σ_y; Standardfehler s(Δ) = √(∇f' Ψ ∇f / T) (Gl. 5) mit der HAC-Kovarianz der Momente
(r_x, r_y, r_x^2, r_y^2); Teststatistik d = |Δ| / s(Δ). Je Wiederholung m werden Blöcke der festen Länge b mit
gleichverteiltem Start zyklisch gezogen; der Standardfehler der Stichprobe ist s(Δ^*_m) aus Ψ^* = l^-1 Σ_j ζ_j ζ_j',
ζ_j = b^(-1/2) Σ_{t=1..b} y^*_{(j-1)b+t}, l = ⌊T/b⌋ (Gl. 8), d^*_m = |Δ^*_m - Δ| / s(Δ^*_m). p-Wert (#{d^*_m ≥ d} +
1)/(B + 1) (Gl. 9), Intervall Δ ± z^*_0.95 s(Δ) mit dem 95-%-Quantil der d^*_m (Gl. 7); se ist s(Δ), z = difference /
se. Die Blocklänge wählt SimLev nicht datenabhängig (die Kalibrierung von Ledoit & Wolf, Algorithmus 3.1, ist nicht
umgesetzt).

# Literatur
Ledoit, O. & Wolf, M. (2008), Robust performance hypothesis testing with the Sharpe ratio, Journal of
Empirical Finance 15(5), 850-859.
Andrews, D. W. K. (1991), Heteroskedasticity and autocorrelation consistent covariance matrix estimation, Econometrica
59(3), 817-858. Andrews, D. W. K. & Monahan, J. C. (1992), An improved heteroskedasticity and autocorrelation
consistent covariance matrix estimator, Econometrica 60(4), 953-966.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1095
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["a"] = 100 .* cumprod(1 .+ 4e-4 .+ 0.01 .* randn(rng, n))
d["b"] = 100 .* cumprod(1 .+ 2e-4 .+ 0.01 .* randn(rng, n))
println(sharpe_test(RFrame("date" => d["date"], "a" => d["a"]), RFrame("date" => d["date"], "b" => d["b"])))
```
"""
# Langfristkovarianz für sharpe_test (R `.st_hac`, seit 1.6.5, Entscheidung 177): Bartlett ohne Prewhitening wie bisher
# (Newey-West), sonst Schätzer nach Ledoit & Wolf (2008, Abschnitt 3.1) im Kern (research_vec op 8)
function _st_hac(Y, kernel, prewhiten)
    kernel == "bartlett" && !prewhiten && return _hac_cov(Y)
    Y = Matrix{Float64}(Y)
    T, k = size(Y)
    o = SimLev.SignalsCore.research_vec(8, vec(Y), Float64[T, k, kernel == "qs" ? 2 : 1, prewhiten ? 1 : 0], k * k + 2)
    o[k*k+1] == 1 && SimLev.chk_stop("b2b.st_prewhiten", "sharpe_test")
    o[k*k+1] == 2 && SimLev.chk_stop("b2b.st_bandbreite", "sharpe_test")
    return reshape(o[1:k*k], k, k)
end

function sharpe_test(x, y; frequency = ["week", "day", "month"], method = ["hac", "bootstrap"], B = 2000,
                     block = nothing, ppy = nothing, seed = nothing, studentize = true, kernel = nothing,
                     prewhiten = nothing)
    SimLev.DataPrep._e5_match_arg(frequency, ("week", "day", "month"), "sharpe_test", "frequency")   # seit 1.6.4 (K43 T2-N4) Prüfung vor match.arg (Meldung auswahl)
    SimLev.DataPrep._e5_match_arg(method, ("hac", "bootstrap"), "sharpe_test", "method")
    frequency = DA._match_arg(frequency, ["week", "day", "month"])
    method = DA._match_arg(method, ["hac", "bootstrap"])
    # seit 1.6.4: B, block, ppy und seed vor der Rechnung; Tabellen nur als RFrame (Entscheidung 6)
    B = SimLev.chk_int1(B, "sharpe_test", "B")
    SimLev.chk_max(B, SimLev.SL_MAX_N, "sharpe_test", "B")   # seit 1.6.4 (Entscheidung 16, wie n)
    block = SimLev.chk_num1(block, "sharpe_test", "block"; lo = 1, null_ok = true)
    ppy = SimLev.chk_num1(ppy, "sharpe_test", "ppy"; lo = 0, lo_open = true, null_ok = true)
    seed = SimLev.chk_scalar(seed)
    seed === nothing || SimLev.SLib.check_seed(seed, "sharpe_test")
    # seit 1.6.5 (Entscheidung 177): studentisierter zirkulärer Block-Bootstrap (Standard), Kern und Prewhitening
    studentize = SimLev.chk_bool1(studentize, "sharpe_test", "studentize")
    kernel = SimLev.chk_scalar(kernel)
    kernel === nothing || SimLev.DataPrep._e5_match_arg(kernel, ("bartlett", "qs"), "sharpe_test", "kernel")
    prewhiten = SimLev.chk_scalar(prewhiten)
    prewhiten === nothing || (prewhiten = SimLev.chk_bool1(prewhiten, "sharpe_test", "prewhiten"))
    stud = method == "bootstrap" && studentize
    kernel = kernel === nothing ? (stud ? "qs" : "bartlett") : String(kernel)
    prewhiten = prewhiten === nothing ? stud : prewhiten
    stud && block !== nothing && block != trunc(block) && SimLev.chk_stop("b2b.st_block_ganz", "sharpe_test")
    _no_list(x, "x"); _no_list(y, "y")
    a = _ret_from(x, frequency); b = _ret_from(y, frequency)
    (a["date"] === nothing) != (b["date"] === nothing) &&
        DA._stop("sharpe_test: x und y müssen dieselbe Art sein: beide Renditevektoren oder beide Kursreihen/Ergebnisse (data.frame bzw. SimLevResult).")
    if a["date"] !== nothing
        # seit 1.6.5 (CR2-H-2): erst die gemeinsamen Perioden-Enddaten, dann die Renditen zwischen ihnen
        la = DA._days(a["ldate"]); lb = DA._days(b["ldate"])
        sb = Set(lb)
        cl = unique([v for v in la if v in sb])
        sc = Set(cl)
        nskip = length(setdiff(Set(la), sc)) + length(setdiff(Set(lb), sc))
        nskip > 0 && DA._message(SimLev.chk_msg("b2.st_luecke", "sharpe_test", nskip))
        va = Float64.(a["lvl"])[DA._match(cl, la)]; vb = Float64.(b["lvl"])[DA._match(cl, lb)]
        m = length(cl)
        ra = m > 1 ? va[2:end] ./ va[1:end-1] .- 1 : Float64[]
        rb = m > 1 ? vb[2:end] ./ vb[1:end-1] .- 1 : Float64[]
        common = cl[2:end]
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
    if method == "hac" || stud
        mu = [SimLev.r_mean(ra), SimLev.r_mean(rb)]
        g = [SimLev.r_mean(ra .* ra), SimLev.r_mean(rb .* rb)]
        # seit 1.6.5 (Entscheidung 142): Schwankung über die Abweichungen vom Mittel
        v1 = SimLev.r_pow(SimLev.r_mean((ra .- mu[1]) .^ 2), 1.5); v2 = SimLev.r_pow(SimLev.r_mean((rb .- mu[2]) .^ 2), 1.5)
        grad = [g[1] / v1, -g[2] / v2, -0.5 * mu[1] / v1, 0.5 * mu[2] / v2]
        Psi = _st_hac(hcat(ra, rb, ra .* ra, rb .* rb), kernel, prewhiten)
        q = _matprod(_matprod(reshape(grad, 1, 4), Psi), reshape(grad, 4, 1))
        se = sqrt(q[1] / Tn)
        z = d0 / se
        p = 2 * SimLev.SLib.pnorm(-abs(z))
        qq = SimLev.SLib.qnorm(0.975)
        ci = [d0 + (-1 * qq) * se, d0 + (1 * qq) * se]
    end
    if stud
        # seit 1.6.5 (Entscheidung 177): studentisierter zirkulärer Block-Bootstrap nach Ledoit & Wolf (2008,
        # Abschnitt 3.2.2, Bemerkung 3.2; Gl. 7-9), R: gleicher Weg
        block === nothing && (block = max(2.0, SimLev.RFmt.r_round(SimLev.r_pow(Tn, 1 / 3), 0)))
        block > Tn && SimLev.chk_stop("b2.st_block", "sharpe_test", Tn)
        # seit 1.6.5 (PR2-1): mindestens 4 Blöcke (l = floor(T / b) >= 4), sonst ist die 4x4-Block-Kovarianz singulär
        4 * block > Tn && SimLev.chk_stop("pf2.st_bloecke", "sharpe_test", Tn ÷ 4, Tn)
        S = _main_stream(seed, "sharpe_test")
        par = Float64[Tn, block]
        dk = SimLev.SignalsCore.research_vec(9, vcat(ra, rb), par, 2)[1]
        ds = Vector{Float64}(undef, Int(B))
        nz = 0
        for i in 1:Int(B)
            kk = Vector{Int}(SimLev.SLib.boot_idx_block(Tn, Tn, Int(block), true; stream = S))
            o = SimLev.SignalsCore.research_vec(9, vcat(ra[kk], rb[kk]), par, 2)
            if isnan(o[1]) || !(o[2] > 0)
                nz += 1; ds[i] = NaN; continue
            end
            ds[i] = abs(o[1] - dk) / o[2]
        end
        nz > 0 && SimLev.chk_stop("b2.st_var0", "sharpe_test", nz, Int(B))
        p = (count(>=(abs(dk) / se), ds) + 1) / (Int(B) + 1)
        q95 = DA._quantile(ds, [0.95])[1]
        ci = [d0 + (-1 * q95) * se, d0 + (1 * q95) * se]
    elseif method == "bootstrap"
        block === nothing && (block = max(2.0, SimLev.RFmt.r_round(SimLev.r_pow(Tn, 1 / 3), 0)))
        block > Tn && SimLev.chk_stop("b2.st_block", "sharpe_test", Tn)   # seit 1.6.5 (CR2-H-1)
        S = _main_stream(seed, "sharpe_test")
        dbs = Vector{Float64}(undef, Int(B))
        nz = 0
        for i in 1:Int(B)
            k = _boot_idx(Tn, Tn, block, S)
            if SimLev.r_sd(ra[k]) == 0 || SimLev.r_sd(rb[k]) == 0
                nz += 1; dbs[i] = NaN; continue
            end
            dbs[i] = _sr(ra[k]) - _sr(rb[k])
        end
        nz > 0 && SimLev.chk_stop("b2.st_var0", "sharpe_test", nz, Int(B))
        se = SimLev.r_sd(dbs)
        z = d0 / se
        p = DA._mean_lgl(abs.(dbs .- d0) .>= abs(d0))
        ci = DA._quantile(dbs, [0.025, 0.975])
    end
    k = sqrt(ppy)
    SimLev.RVector([_sr(ra) * k, _sr(rb) * k, d0 * k, se * k, z, p, ci[1] * k, ci[2] * k, Float64(Tn)]; names = _SHARPE_NAMES)
end

# ═══════════════════════════════════════════════════════════════════════════
# overfit_reality_check
# ═══════════════════════════════════════════════════════════════════════════

"""
    overfit_reality_check(x; benchmark = nothing, B = 999, block = nothing,
                  frequency = ["week", "day", "month"], dates = nothing, seed = nothing)

White Reality Check und Hansen-SPA-Test.

Prüft, ob die beste von K Strategien (z. B. alle Punkte einer Parametersuche) eine Benchmark mehr als zufällig
schlägt, unter Berücksichtigung, dass die beste aus vielen gewählt wurde. Der SPA-Test (Hansen 2005) ist
weniger empfindlich gegen schlechte, irrelevante Strategien als der Reality Check (White 2000). Beide mit
stationärem Block-Bootstrap der Ueberrenditen d_t,k = r_t,k - b_t.

# Argumente
- `x`: Renditequelle:

  - `SimLevParamSearch` aus `param_search()` mit gespeicherten Renditen (`keep_returns = "day"`); verwendet
    werden `x["returns"]` (tägliche Renditen je Punkt, Spalten `p<id>`) und `x["dates"]`;
  - numerische Matrix oder Tabelle (RFrame) nur aus numerischen Spalten (ohne Datumsspalte): Zeilen =
    Perioden, Spalten = Strategien, einfache Renditen als Anteil (0.01 = 1 %); ohne Spaltennamen heißen die
    Spalten `p1`, `p2`, ...

  Spalten ohne endlichen Wert werden verworfen, danach alle Zeilen mit einem fehlenden Wert. Bei `print()`:
  Objekt der Klasse `SimLevRealityCheck`.
- `benchmark`: Vergleich: `nothing` (Standard) = Rendite 0; eine einzelne Zahl oder Zeichenkette =
  Spaltennummer bzw. -name in `x` (nach dem Verwerfen leerer Spalten), diese Spalte wird aus den Kandidaten
  entfernt; ein numerischer Vektor (Länge > 1) = Benchmark-Renditen als Anteil mit genau einem Wert je Periode
  nach Aggregation und Entfernen unvollständiger Zeilen.
  Seit 1.6.4 eine Spaltennummer als ganze Zahl, kein Faktor.
- `B`: Anzahl Bootstrap-Wiederholungen (ganze Zahl, Standard 999).
  Seit 1.6.4 höchstens 10^8.
- `block`: Mittlere Blocklänge des stationären Bootstraps in Perioden (geometrisch verteilte Blocklängen,
  zyklisch); `nothing` (Standard) = `max(2, round(T^(1/3)))` mit T = Anzahl Perioden.
  Seit 1.6.4 eine Zahl ≥ 1.
- `frequency`: Periodenlänge: `"week"` (Standard), `"day"` oder `"month"`. Mit Datum (bei `SimLevParamSearch`
  immer, bei Matrizen über `dates`) werden die Renditen geometrisch zu ISO-Wochen bzw. Kalendermonaten
  verkettet; ohne Datum wird nicht aggregiert, die Zeilen gelten dann als Perioden.
- `dates`: Datum je Zeile von `x` (Date oder umwandelbar), nur bei Matrix-Eingabe für die Aggregation;
  `nothing` (Standard) = keine Aggregation. Bei `SimLevParamSearch` wird `x["dates"]` verwendet.
- `seed`: Startwert (Standard `nothing`). Mit Startwert (ganze Zahl, |seed| < 2^53) ist das Ergebnis
  reproduzierbar und der Zufallszustand von SimLev bleibt unverändert; mit `nothing` wird genau einmal ein
  Startwert aus dem Zufallszustand von SimLev gezogen (siehe `simlev_seed()`), wiederholte Aufrufe liefern
  dann verschiedene Ergebnisse. `set.seed()` wirkt nicht.

# Rückgabe
Objekt der Klasse `SimLevRealityCheck`, eine Liste mit `p_rc` (p-Wert Reality Check), `p_spa` (p-Wert SPA,
konsistente Variante), `p_spa_lower`, `p_spa_upper` (untere und obere SPA-Variante), `best` (Name der Spalte
mit der höchsten mittleren Überrendite), `mean_excess` (benannter Vektor: mittlere Überrendite je Periode
gegenüber `benchmark`, Anteil, nicht annualisiert), `n` (Anzahl Perioden), `k` (Anzahl Kandidaten) und `B`.
Kleiner p-Wert = die beste Strategie schlägt die Benchmark auch nach Berücksichtigung der Auswahl.

# Details
Eingabe ist eine Parametersuche oder eine Renditematrix mit einer Spalte je Strategie. Mehrere fertige
Simulationen (Liste von `SimLevResult`) werden vorher zu einer Matrix zusammengefasst, z. B. mit
`sapply(liste, function(r) { v <- result_index(r)\$value; v[-1] / v[-length(v)] - 1 })` (gleicher Kalender
aller Läufe vorausgesetzt; Datum dazu `result_index(liste[[1]])\$date[-1]`), siehe Beispiel.

# Literatur
White, H. (2000), A reality check for data snooping, Econometrica 68(5); Hansen, P. R. (2005), A test for
superior predictive ability, Journal of Business & Economic Statistics 23(4).

# Beispiel
```julia
using SimLev, Random
R = 0.01 .* randn(MersenneTwister(4), 800, 10); R[:, 2] .+= 0.003   # eine Strategie mit echter Überrendite
println(overfit_reality_check(R; B = 200, frequency = "day", seed = 1))
```
"""
function overfit_reality_check(x; benchmark = nothing, B = 999, block = nothing, frequency = ["week", "day", "month"],
                       dates = nothing, seed = nothing)
    SimLev.DataPrep._e5_match_arg(frequency, ("week", "day", "month"), "overfit_reality_check", "frequency")   # seit 1.6.4 (K43 T2-N4) Prüfung vor match.arg (Meldung auswahl)
    frequency = DA._match_arg(frequency, ["week", "day", "month"])
    # seit 1.6.4: benchmark nur Zahl(en) oder ein Name, Spaltennummer ganz; B, block, seed vorab; x nicht als
    # NamedTuple/Dict (R: Liste)
    benchmark === nothing || _bench_ok(benchmark) || SimLev.chk_stop("e2.benchmark", "overfit_reality_check")
    B = SimLev.chk_int1(B, "overfit_reality_check", "B")
    SimLev.chk_max(B, SimLev.SL_MAX_N, "overfit_reality_check", "B")   # seit 1.6.4 (Entscheidung 16, wie n)
    block = SimLev.chk_num1(block, "overfit_reality_check", "block"; lo = 1, null_ok = true)
    seed = SimLev.chk_scalar(seed)
    seed === nothing || SimLev.SLib.check_seed(seed, "overfit_reality_check")
    (x isa Union{NamedTuple,AbstractVector{<:Pair}} ||
     (x isa AbstractDict && !(x isa SimLev.RList && SimLev.inherits(x, "SimLevParamSearch")))) &&
        SimLev.chk_stop("ut2.of_x", "overfit_reality_check")
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
            # seit 1.6.5 (CR2-D-5, K7): Nummer = Spalte der Eingabe (bei einer Suche die id); leere Spalte: Fehler
            j = if e isa AbstractString
                e in cn ? findfirst(==(e), cn) : nothing
            else
                j0 = (e isa Real && !(e isa Bool) && isfinite(Float64(e)) && Float64(e) == trunc(Float64(e))) ? Float64(e) : nothing
                cols = Float64[Float64(c) for c in (DA._rget(rr, "cols") isa SimLev.RVector ? DA._rget(rr, "cols").values : DA._rget(rr, "cols"))]
                jj = j0 === nothing ? nothing : findfirst(==(j0), cols)
                jj === nothing && j0 !== nothing && 1 <= j0 <= maximum(cols) &&
                    SimLev.chk_stop("b2.bench_leer", "overfit_reality_check")
                jj
            end
            j === nothing && SimLev.chk_stop("b2.bench_spalte", "overfit_reality_check")
            b = R[:, j]
            keepc = [i for i in 1:size(R, 2) if i != j]
            R = R[:, keepc]; cn = cn[keepc]
        else
            b = DA._f64(barr)
        end
    end
    length(b) != size(R, 1) && SimLev.chk_stop("rs.benchmark_laenge", "overfit_reality_check")
    # seit 1.6.5 (CR2-X9-1): Inf in der Vergleichsreihe Fehler, Perioden mit NA/NaN entfallen für alle
    any(isinf, b) && SimLev.chk_stop("b2.bench_inf", "overfit_reality_check")
    if any(isnan, b)
        okb = .!isnan.(b); R = R[okb, :]; b = b[okb]
    end
    size(R, 1) < 3 && SimLev.chk_stop("b2.rc_perioden", "overfit_reality_check")   # seit 1.6.5 (CR2-D-6)
    D = R .- b
    Tn, K = size(D)
    fbar = DA._col_means(D)
    block === nothing && (block = max(2.0, SimLev.RFmt.r_round(SimLev.r_pow(Tn, 1 / 3), 0)))
    S = _main_stream(seed, "overfit_reality_check")
    Fb = Matrix{Float64}(undef, Int(B), K)
    if D isa Matrix{Float64} && Tn > 0
        # seit 1.6.3 colMeans(D[idx, ]) ohne Kopie (Kern sl_r_colsums_idx, gleiche Summanden in gleicher Folge wie
        # sl_r_colsums auf der Kopie; m = Tn > 0, also ohne den NaN-Fall leerer Spalten von DA._col_means)
        cm = Vector{Float64}(undef, K)
        for i in 1:Int(B)
            idx = Vector{Int64}(_boot_idx(Tn, Tn, block, S))
            st = ccall((:sl_r_colsums_idx, SimLev.LIBSLC), Cint,
                       (Int64, Int64, Ptr{Float64}, Int64, Int64, Int64, Ptr{Int64}, Int64, Cint, Cint, Ptr{Float64}),
                       Tn, K, D, 1, Tn, length(idx), idx, 1, Cint(0), Cint(1), cm)
            st == 0 || (Fb[i, :] = DA._col_means(D[idx, :]); continue)
            Fb[i, :] = cm
        end
    else
        for i in 1:Int(B)
            Fb[i, :] = DA._col_means(D[_boot_idx(Tn, Tn, block, S), :])
        end
    end
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
    jbest = something(SimLev._which_max(fbar), 0)
    SimLev.RList("p_rc" => p_rc, "p_spa" => spa_p(fbar .* (fbar .>= thr)), "p_spa_lower" => spa_p(max.(fbar, 0.0)),
                 "p_spa_upper" => spa_p(fbar), "best" => cn[jbest], "mean_excess" => SimLev.RVector(fbar; names = cn),
                 "n" => Tn, "k" => K, "B" => B; class = ["SimLevRealityCheck"])
end

"`print.SimLevRealityCheck`."
function _print_rc(io::IO, x)
    print(io, DA._sp("Reality Check und SPA: %d %s, %d Perioden, B = %d\n", Int(x["k"]),
                     Int(x["k"]) == 1 ? "Strategie" : "Strategien", Int(x["n"]), Int(x["B"])))
    print(io, DA._sp("  Beste Strategie: %s (mittlere Überrendite %.4f je Periode)\n", string(x["best"]), DA._rmax(DA._f64(x["mean_excess"]))))
    print(io, DA._sp("  p-Wert Reality Check (White):   %.3f\n  p-Wert SPA (Hansen, konsistent): %.3f  [untere %.3f, obere %.3f]\n",
                     x["p_rc"], x["p_spa"], x["p_spa_lower"], x["p_spa_upper"]))
    print(io, "  Lesart: kleiner p-Wert = die beste Strategie schlägt die Benchmark auch nach Berücksichtigung der Auswahl.\n")
    nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# sharpe_min_track_record
# ═══════════════════════════════════════════════════════════════════════════

"""
    sharpe_min_track_record(x; target = 0, prob = 0.95, frequency = ["week", "day", "month"], ppy = nothing)

Mindestlänge einer Historie (Minimum Track Record Length, Bailey & López de Prado 2012).

Wie viele Perioden braucht es, um mit Wahrscheinlichkeit `prob` sagen zu können, dass die wahre Sharpe Ratio
über `target` liegt? MinTRL = 1 + (1 - γ_3 SR + (γ_4 - 1)/(4)SR^2) ((z_prob)/(SR - SR^*))^2 Dabei sind SR und
SR^* Sharpe Ratios je Periode (Mittelwert / Standardabweichung, ohne Abzug eines risikolosen Zinses), γ_3 die
Schiefe und γ_4 die Wölbung (nicht Exzess) der Renditen. Eingabe ist ein Renditevektor oder eine fertige
Simulation bzw. Kursreihe.

# Argumente
- `x`: Renditequelle: numerischer Vektor einfacher Periodenrenditen als Anteil (0.01 = 1 %; nicht endliche
  Werte werden entfernt), `SimLevResult` aus `simulation()` (bereinigter Wertindex aus `result_index()`) oder
  `data.frame` mit `date` und einer Wertspalte (`value`, sonst erste numerische Spalte; Niveaus). Die beiden
  letzten werden in Renditen der `frequency` umgerechnet.
  Seit 1.6.4 mindestens zwei endliche Renditen, die nicht alle gleich sind (sonst Fehler, in allen Sprachen wie
  bisher in R).
- `target`: Vergleichs-Sharpe-Ratio SR^* p. a. (Standard 0); intern durch √(ppy) geteilt.
- `prob`: Geforderte Sicherheit als Anteil (Standard 0.95 = 95 %).
  Seit 1.6.4 eine Zahl > 0 und < 1.
- `frequency`: Periodenlänge `"week"` (Standard, ISO-Wochen), `"day"` oder `"month"`: bei `SimLevResult` und
  Tabelle (RFrame) die Aggregation (Wert am Periodenende); bei Vektoren nur für den Standardwert von `ppy`.
- `ppy`: Perioden je Jahr. `nothing` (Standard) = bei Vektoren 252 (`"day"`), 52 (`"week"`) bzw. 12
  (`"month"`); sonst geschätzt als (Anzahl Renditen - 1) / (Zeitspanne in Tagen / 365.25).
  Seit 1.6.4 eine Zahl > 0.

# Rückgabe
Benannter numerischer Vektor: `sharpe` (Sharpe Ratio p. a.), `periods` (vorhandene Perioden), `needed_periods`
(MinTRL in Perioden; `Inf`, wenn die Sharpe Ratio nicht über `target` liegt), `needed_years` (`needed_periods
/ ppy`), `available_years` (`periods / ppy`) und `sufficient` (1 = `periods >= needed_periods`, sonst 0).

# Literatur
Bailey, D. H. & Lopez de Prado, M. (2012), The Sharpe ratio efficient frontier, Journal of Risk 15(2).

# Beispiel
```julia
using SimLev, Random
r = 0.002 .+ 0.02 .* randn(MersenneTwister(1), 520)   # 10 Jahre Wochenrenditen
println(sharpe_min_track_record(r; target = 0, ppy = 52))
```
"""
function sharpe_min_track_record(x; target = 0, prob = 0.95, frequency = ["week", "day", "month"], ppy = nothing)
    SimLev.DataPrep._e5_match_arg(frequency, ("week", "day", "month"), "sharpe_min_track_record", "frequency")   # seit 1.6.4 (K43 T2-N4) Prüfung vor match.arg (Meldung auswahl)
    frequency = DA._match_arg(frequency, ["week", "day", "month"])
    # seit 1.6.4: target endlich, prob in (0, 1), ppy > 0; Tabellen nur als RFrame (Entscheidung 6)
    target = SimLev.chk_num1(target, "sharpe_min_track_record", "target")
    prob = SimLev.chk_num1(prob, "sharpe_min_track_record", "prob"; lo = 0, hi = 1, lo_open = true, hi_open = true)
    ppy = SimLev.chk_num1(ppy, "sharpe_min_track_record", "ppy"; lo = 0, lo_open = true, null_ok = true)
    _no_list(x, "x")
    a = _ret_from(x, frequency)
    r = filter(isfinite, a["r"])
    # seit 1.6.4 (Entscheidung 37): entartete Renditen (weniger als zwei, alle gleich) sind ein Fehler wie in R
    (length(r) < 2 || !(SimLev.r_sd(r) > 0)) && SimLev.chk_stop("renditen_entartet", "sharpe_min_track_record")
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
        qq = SimLev.SLib.qnorm(Float64(prob)) / (sr - sr0)
        1 + (1 - g3 * sr + (g4 - 1) / 4 * (sr * sr)) * (qq * qq)
    end
    nr = length(r)
    SimLev.RVector([sr * sqrt(ppy), Float64(nr), need, need / ppy, nr / ppy, Float64(nr >= need)];
                   names = ["sharpe", "periods", "needed_periods", "needed_years", "available_years", "sufficient"])
end

# ═══════════════════════════════════════════════════════════════════════════
# result_heatmap
# ═══════════════════════════════════════════════════════════════════════════

"""
    result_heatmap(x; inflation = nothing, max_years = 30)

Renditen je Startjahr und Haltedauer (annualisiert, wahlweise real).

Annualisierte Renditen für jede Kombination aus Startjahr und Haltedauer (wie die Heatmaps von Portfolio
Charts), wahlweise real. Zeigt auf einen Blick, wie stark das Ergebnis vom Einstiegszeitpunkt abhängt.

# Argumente
- `x`: Eine Reihe: `SimLevResult` aus `simulation()` (verwendet wird der um Ein- und Auszahlungen bereinigte
  Wertindex aus `result_index()`) oder `data.frame` mit Spalte `date` und einer Wertspalte (`value`, sonst die
  erste numerische Spalte; Niveaus, keine Renditen; fehlende Werte werden fortgeschrieben). Eine Liste
  mehrerer Reihen wird nicht angenommen; dafür die Funktion je Element aufrufen, z. B. `lapply(liste,
  result_heatmap)`. Bei `print()`/`plot()`: Objekt der Klasse `SimLevHeatmap`.
- `inflation`: Optional für reale Renditen: `nothing` (Standard) = nominal; eine Zahl = Inflationsrate in
  Prozent p. a. (2 = 2 %), tageweise aufgezinst mit (1 + i/100)^Tage/365.25; oder ein Preisindex als
  `data.frame(date, Wert)` (Niveaus, z. B. VPI; jeder Wert gilt ab seinem Datum) bzw. benannter numerischer
  Vektor mit Datumsnamen. Die Werte werden durch den Index relativ zum Startdatum geteilt.
- `max_years`: Längste Haltedauer in Jahren (ganze Zahl, Standard 30); höchstens die Zahl der verfügbaren
  Jahre.
  Seit 1.6.4 eine ganze Zahl ≥ 1.
  Seit 1.6.4 höchstens 100.

# Rückgabe
Objekt der Klasse `SimLevHeatmap`, eine Liste mit `matrix` (Zeilen = Startjahr, Spalten = Haltedauer 1, 2, ...
Jahre; annualisierte Rendite als Anteil, `NA` wenn der Zeitraum über das Datenende hinausgeht), `summary`
(Tabelle (RFrame) je Haltedauer: `years`, `min`, `median`, `max` (Anteil p. a.), `share_negative` (Anteil
negativer Zeiträume), `n` (Anzahl Zeiträume)) und `real` (logisch, `true` mit `inflation`). `print()` zeigt
die Zusammenfassung für 1, 3, 5, 10, 15, 20, 25 und 30 Jahre in Prozent; `plot()` zeichnet die Heatmap
(Farbskala bei +/- 25 % begrenzt).

# Details
Grundlage sind die Werte am letzten verfügbaren Tag jedes Kalenderjahrs. Beginnt die Reihe am 1. Januar, ist
der erste Wert der Startwert des ersten Jahres; sonst beginnt die Tabelle mit dem ersten vollen Jahr (bei
Handelstagsdaten ohne Wert vom 01.01. also mit dem zweiten). Ein unvollständiges letztes Kalenderjahr entfällt
(früher wurde es wie ein volles Jahr annualisiert); als vollständig gilt es, wenn das Datenende höchstens um
die größte Zeilenlücke der Reihe (höchstens 7 Tage) vor dem 31.12. liegt, bei Handelstagen also z. B. der
30.12. Die Daten werden nach Datum sortiert, doppelte Daten wie in `result_analysis()` behandelt.
Seit 1.6.5 zählt die Haltedauer in Kalenderjahren: fehlt ein Kalenderjahr in den Daten, bleiben die Zellen,
die es als Start- oder Endjahr brauchen, leer (bis 1.6.4 zählten die Zeilen der Jahresend-Tabelle). Bei groben
Daten (mittlerer Zeilenabstand über 7 Tage, z. B. Monatsdaten am Monatsersten) ist das Jahresende der letzte Wert
im Dezember und das erste, unvollständige Jahr entfällt; bei Jahresdaten (eine Zeile je Jahr) entfällt das erste
Jahr. Fallen alle Zeilen auf den 1.1. (Jahresdaten zum Jahresanfang), gilt jeder Wert als Jahresende des Vorjahres:
die Rendite vom 1.1.2010 zum 1.1.2011 steht in der Zeile 2010 (bis 1.6.4 und bei anderen Daten das Jahr des Datums).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 4380
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
d["value"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
hm = result_heatmap(d; inflation = 2, max_years = 10)
println(size(hm["matrix"]))
```
"""
function result_heatmap(x; inflation = nothing, max_years = 30)
    max_years = SimLev.chk_int1(max_years, "result_heatmap", "max_years")   # seit 1.6.4
    SimLev.chk_max(max_years, SimLev.SL_MAX_JAHRE, "result_heatmap", "max_years")   # Entscheidungen 16 und 46
    _no_list(x, "x")   # Tabellen nur als RFrame (Entscheidung 6)
    s = DA._da_series(x, "x")
    inflation === nothing || (s = DA._da_deflate(s, inflation))
    d = s.date
    # seit 1.6.5 (CR2-N-1, Entscheidung 195 F2 Weg b): alle Zeilen am 1.1. → Wert gilt als Jahresende des Vorjahres
    jan1 = length(d) > 1 && all(t -> (q = DA._date1(t); Dates.month(q) == 1 && Dates.day(q) == 1), d)
    dt = jan1 ? d .- 1 : d
    yr = DA._key_year(dt); m = length(yr)
    e = DA._last_of_key(yr)
    keep = vcat(true, .!s.filled[2:end])
    dk = d[keep]
    gaps = Float64[dk[i] - dk[i-1] for i in 2:length(dk)]
    tol = min(7.0, DA._rmax(gaps))
    dec31 = DA._day1(Date(yr[m], 12, 31))
    # seit 1.6.5 (CR2-N-1): Haltedauer nach Kalenderjahren, grobe Daten mit Dezemberwert (R result_heatmap)
    coarse = !isempty(gaps) && _median(gaps) > 7
    annual = length(unique(yr)) == m
    last_ok = dec31 - dt[m] < tol
    v = s.value
    ok = if coarse && !annual
        Bool[Dates.month(DA._date1(d[i])) == 12 for i in e]
    else
        vcat(fill(true, length(e) - 1), last_ok)
    end
    ye = Int[yr[i] for (i, o) in zip(e, ok) if o]; ve = Float64[v[i] for (i, o) in zip(e, ok) if o]
    d1 = DA._date1(d[1])
    if !coarse && Dates.month(d1) == 1 && Dates.day(d1) == 1
        ye = vcat(yr[1] - 1, ye); ve = vcat(v[1], ve)
    end
    ny = isempty(ye) ? 0 : maximum(ye) - minimum(ye)
    ny < 1 && DA._stop("result_heatmap: Die Reihe umfasst kein vollständiges Kalenderjahr.")
    years = collect(minimum(ye):(minimum(ye) + ny))
    base = fill(_NA, ny + 1)
    for (yv, vv) in zip(ye, ve)
        base[yv - years[1] + 1] = vv
    end
    H = Int(min(max_years, ny))
    M = fill(_NA, ny, H)
    for i in 1:ny, h in 1:min(H, ny - i + 1)
        (isnan(base[i]) || isnan(base[i+h])) && continue
        M[i, h] = SimLev._cagr_q(base[i+h] / base[i], h)
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

"""
`plot.SimLevHeatmap` (SVG): Heatmap Startjahr x Haltedauer (Farbskala bei ± 25 % begrenzt).

Liefert `(svg, data)`; `data`: `heatmap` (`start_year`, `years`, `value`: gezeichnete Zellen,
annualisierte Rendite als Anteil wie in `matrix`).
"""
function _plot_heatmap(x)
    Mm = x["matrix"]; M = 100 .* Mm.data
    fin = filter(isfinite, M); lim = min(isempty(fin) ? 1.0 : maximum(abs.(fin)), 25.0)
    pal = _ana_ramp(["#B5562B", "#F2E9DC", "#2C6E9B"], 51)
    yrs = parse.(Int, Mm.rownames); H = size(M, 2)
    s = _AnaSvg(900, 520)
    p = _ana_panel(s, 0, 0, 820, 520, (yrs[1] - 0.5, yrs[end] + 0.5), (0.5, H + 0.5);
                   title = "Annualisierte $(x["real"] ? "reale" : "nominale") Rendite", xlab = "Startjahr",
                   ylab = "Haltedauer (Jahre)", xticks = Float64.(yrs[1:max(1, cld(length(yrs), 12)):end]),
                   xlabels = string.(yrs[1:max(1, cld(length(yrs), 12)):end]))
    sy = Int[]; hy = Int[]; vv = Float64[]
    for i in eachindex(yrs), h in 1:H
        v = M[i, h]; isfinite(v) || continue
        v = clamp(v, -lim, lim)
        # seit 1.6.5 (CR2-N-2): ohne Wertänderung (lim = 0) die mittlere Farbstufe
        c = lim == 0 ? pal[26] : pal[clamp(round(Int, (v + lim) / (2 * lim) * 50) + 1, 1, 51)]
        _ana_rect(s, p, yrs[i] - 0.5, h - 0.5, yrs[i] + 0.5, h + 0.5; fill = c)
        push!(sy, yrs[i]); push!(hy, h); push!(vv, Mm.data[i, h])
    end
    for (k, t) in enumerate((-lim, 0.0, lim))
        _ana_legend(s, p, [DA._sp("%+.0f %%", t)], [pal[[1, 26, 51][k]]]; x = 830.0, y = 60.0 + 20 * (k - 1), box = true)
    end
    return (_ana_svg_done(s),
            SimLev.RList("heatmap" => SimLev.RFrame("start_year" => sy, "years" => hy, "value" => vv)))
end

function __init__()
    SimLev.register_print!("SimLevSignalAnalysis", _print_signal)
    SimLev.register_plot!("SimLevSignalAnalysis", SimLev._plot_method(_plot_signal, "SimLevSignalAnalysis"))
    SimLev.register_print!("SimLevRealityCheck", _print_rc)
    SimLev.register_print!("SimLevHeatmap", _print_heatmap)
    SimLev.register_plot!("SimLevHeatmap", SimLev._plot_method(_plot_heatmap, "SimLevHeatmap"))
end

end # module
