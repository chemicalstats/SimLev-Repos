# ─────────────────────────────────────────────────────────────────────────────
# Statisches Dashboard (Port von plot_dashboard.R) als abhängigkeitsfreies SVG
#
# Prüfungen, Meldungen, Beschriftungen und alle berechneten Werte (Tagesrenditen
# wie `.dashboard_returns`, Kennzahlentexte, Monatsrenditen, rollierende
# Renditen und Korrelationen, Vergleichstabelle mit Farben) entsprechen SimLev
# 0.5.0. Nur das Zeichnen (Basisgrafik in R) ist als SVG nachgebaut;
# Schriftgrößen und Ränder sind angenähert.
#
# Hier stehen die Datenfunktionen und Panels; `SimLevPlot`, die plot-API und
# die Zeichenhilfen (`_Canvas`, `_text!`, `_frame!`, `r_pretty`, Farben, …)
# kommen aus svg.jl (Abschnitt „Stil Dashboard“).
# ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_COLORS = ["primary" => "#2E86AB", "secondary" => "#A23B72", "positive" => "#06A77D",
                        "negative" => "#D62246", "neutral" => "#6C757D", "background" => "#F8F9FA",
                        "grid" => "#E9ECEF"]
const _ALL_PANELS = ("performance", "drawdown", "distribution", "rolling", "monthly", "stats", "correlation", "comparison")
const _DEFAULT_PANELS = ("performance", "drawdown", "distribution", "rolling", "monthly", "stats")

_xget(x, name::AbstractString) = (x isa AbstractDict || x isa RList) ? get(x, name, nothing) : nothing
_xlen(v) = v === nothing ? 0 : v isa AbstractVector ? length(v) : 1

"""
Tagesrenditen fürs Dashboard wie in `simulation()` (R: `.dashboard_returns`):
einzahlungsbereinigt (aus `twr_index`), aufgefüllte Tage ausgeschlossen,
Beobachtungen je Jahr, Sparplan-Kennung, Einzahlungssumme und zeitgewichteter
Index (ältere Ergebnisse: aus `report\$flows`).
"""
function _dashboard_returns(x)
    w = collect(Float64, _xget(x, "worth"))
    n = length(w)
    report = _xget(x, "report")
    flows = zeros(n)
    if report !== nothing && length(report) > 0
        first_ = true
        for (_, a) in report
            f = collect(Float64, a["flows"])
            if first_
                flows = f; first_ = false
            else
                flows = flows .+ f
            end
        end
    end
    length(flows) != n && (flows = zeros(n))
    twr_x = _xget(x, "twr_index")
    has_twr = _xlen(twr_x) == n
    all_r = n < 2 ? Float64[] :
            has_twr ? Float64[twr_x[i+1] / twr_x[i] - 1 for i in 1:n-1] :
            Float64[(w[i+1] - w[i] - flows[i+1]) / w[i] for i in 1:n-1]
    all_r = Float64[isfinite(v) ? v : 0.0 for v in all_r]
    fx = _xget(x, "filled")
    filled = _xlen(fx) == n ? Vector{Bool}(fx) : falses(n)
    r = n >= 1 ? all_r[.!filled[2:end]] : all_r
    dates = _xget(x, "dates")
    years = (dates !== nothing && n >= 2) ? Dates.value(dates[n] - dates[1]) / 365.25 : 0.0
    ef = _xget(x, "external_flows")
    ext = ef !== nothing ? _is_true(ef) : (n >= 2 && any(v -> !isnan(v) && v != 0, flows[2:end]))
    inv = _xget(x, "invested")
    invested = _xlen(inv) == n ? collect(Float64, inv) : n > 0 ? w[1] .+ r_cumsum([0.0; flows[2:end]]) : Float64[]
    twr = has_twr ? collect(Float64, twr_x) : n > 0 ? r_cumprod([1.0; 1 .+ all_r]) : Float64[]
    ppy = (years > 0 && !isempty(r)) ? length(r) / years : 365.25
    return (all_returns = all_r, returns = r, ppy = ppy, external_flows = ext, invested = invested, twr_index = twr)
end

"`.dash_custom_layout`: 1–2 Panels in einer Zeile, sonst 2 Spalten mit bis zu 4 Zeilen."
function _dash_custom_layout(n::Int)
    nr = (1, 1, 2, 2, 3, 3, 4, 4)[n]
    nc = cld(n, nr)
    v = [collect(1:n); zeros(Int, nr * nc - n)]
    return permutedims(reshape(v, nc, nr))
end

function _check_colors(colors)
    colors === nothing && return Dict{String,Any}(DEFAULT_COLORS)
    defnames = [p.first for p in DEFAULT_COLORS]
    items = colors isa RVector ? (colors.names === nothing ? nothing : [n => v for (n, v) in zip(colors.names, colors.values)]) :
            _is_mapping(colors) ? _kvpairs(colors) : nothing
    if items === nothing || any(p -> isempty(p.first), items)
        error("plot.SimLevResult: colors muss eine benannte Liste (oder ein benannter Zeichenvektor) sein, z. B. list(primary = \"#003366\"); möglich: $(join(defnames, ", ")).")
    end
    unk = unique([p.first for p in items if !(p.first in defnames)])
    isempty(unk) || error("plot.SimLevResult: unbekannte Farbe(n) $(join(("'$u'" for u in unk), ", ")) in colors; möglich: $(join(defnames, ", ")).")
    function ok(v)
        if v isa Union{AbstractVector,Tuple}
            length(v) == 1 || return false
            v = first(v)
        end
        (v === nothing || v === missing || v isa Bool) && return false
        v isa AbstractFloat && isnan(v) && return false
        v isa Union{AbstractString,Real} || return false
        try
            _col2rgba(v); return true
        catch
            return false
        end
    end
    bad = [p for p in items if !ok(p.second)]
    if !isempty(bad)
        dep(v) = v === nothing || v === missing ? "NA" : (v isa AbstractFloat && isnan(v)) ? "NA_real_" : r_deparse(v)
        error("plot.SimLevResult: ungültige Farbe(n) in colors: $(join(("$(p.first) = $(dep(p.second))" for p in bad), ", ")); erwartet je Element ein R-Farbname (z. B. \"navy\", siehe grDevices::colors()) oder ein Hex-Code \"#RRGGBB\" bzw. \"#RRGGBBAA\".")
    end
    out = Dict{String,Any}(DEFAULT_COLORS)
    for (k, v) in items
        out[k] = v isa Union{AbstractVector,Tuple} ? first(v) : v
    end
    return out
end

# ── Berechnete Daten (wie in R) ─────────────────────────────────────────────

"`format_amount`: Beträge in Tsd. bzw. Mio. (Achsenwerte exakt, Endwert mit 3 Stellen)."
function _format_amount(x; signif3::Bool = false)
    out = String[]
    for z in (x isa AbstractVector ? x : [x])
        z = Float64(z)
        u = abs(z) >= 1e6 ? 1e6 : abs(z) >= 1e3 ? 1e3 : 1.0
        v = z / u
        local d::Int
        if signif3
            d = Int(r_max2(0.0, 2 - floor(_libm_log10(r_max2(abs(v), 1.0)))))
        else
            d = 3
            for k in 0:2
                if abs(v - r_round(v, k)) < 1e-8 * max(1, abs(v))
                    d = k; break
                end
            end
        end
        push!(out, r_sprintf("%.*f", d, v) * (u == 1e6 ? " Mio." : u == 1e3 ? " Tsd." : ""))
    end
    return out
end

"`stats::cor(x, y)` für zwei vollständige Vektoren (cov_complete2 in R's cov.c)."
function _r_cor(x::Vector{Float64}, y::Vector{Float64})
    n = length(x)
    function mean_(v)
        s = _LD0
        for a in v; s = s + F80(a); end
        t = s / F80(n)
        if isfinite(Float64(t))
            s = _LD0
            for a in v; s = s + (F80(a) - t); end
            t = t + s / F80(n)
        end
        return Float64(t)
    end
    xm, ym = mean_(x), mean_(y)
    n1 = n - 1
    s = _LD0
    for (a, b) in zip(x, y)
        s = s + F80(a - xm) * F80(b - ym)
    end
    ans = Float64(s / F80(n1))
    function sdev(v, m)
        s = _LD0
        for a in v
            d = F80(a - m); s = s + d * d
        end
        return Float64(sqrt(s / F80(n1)))
    end
    sx, sy = sdev(x, xm), sdev(y, ym)
    (sx == 0 || sy == 0) && return NA
    ans /= (sx * sy)
    return r_min2(r_max2(ans, -1.0), 1.0)
end

function _tot_ret(r)
    f = _dashboard_returns(r)
    f.external_flows && return f.twr_index[end] - 1
    w = r["worth"]
    return w[end] / w[1] - 1
end
_ann_vol(r) = (sd = r["statistics"]["sd"]; _isna_any(sd) ? NA : sd * sqrt(_dashboard_returns(r).ppy))

"Texte des Kennzahlen-Panels (Abschnitt → Zeilen) wie in R."
function _stats_sections(x, compare = nothing)
    dash = _dashboard_returns(x)
    ext = dash.external_flows
    st = x["statistics"]
    worth = x["worth"]
    n_days = length(worth)
    dd = x["drawdowns"]
    inv = _xget(x, "invested")
    start = if _xlen(inv) == n_days
        s0 = 0.0
        for (_, a) in x["report"]
            f = a["flows"]
            s0 += length(f) == n_days ? f[1] : 0.0
        end
        r_sprintf("Startkapital: %.2f EUR", inv[1] - s0)
    else
        r_sprintf("Depotwert Starttag: %.2f EUR", worth[1])
    end
    depot = [start, r_sprintf("Endwert: %.2f EUR", worth[end])]
    ext && push!(depot, r_sprintf("Eingezahlt: %.2f EUR", dash.invested[end]))
    push!(depot, "Dauer: $n_days Tage")
    secs = Pair{String,Vector{String}}[
        "Rendite" => [r_sprintf(ext ? "CAGR (geldgew.): %+.2f%%" : "CAGR: %+.2f%%", x["cagr"] * 100),
                      r_sprintf("TTWROR: %+.2f%%", x["ttwror"] * 100),
                      r_sprintf(ext ? "Gesamtrendite (TWR): %+.2f%%" : "Gesamtrendite: %+.2f%%", _tot_ret(x) * 100)],
        "Risiko" => [r_sprintf(ext ? "Max. Drawdown (TWR): %.2f%%" : "Max. Drawdown: %.2f%%", maximum(dd) * 100),
                     r_sprintf("Volatilität je Tag: %.2f%%", st["sd"] * 100),
                     r_sprintf("Volatilität p. a.: %.2f%%", _ann_vol(x) * 100)],
        "Renditeprofil" => [r_sprintf("Sharpe Ratio: %.2f", st["sharpe"]), r_sprintf("Schiefe: %.2f", st["skewness"]),
                            r_sprintf("Wölbung: %.2f", st["kurtosis"])],
        "Depot" => depot]
    if compare !== nothing
        push!(secs, "Vergleich" => [r_sprintf("Diff. CAGR: %+.2f%%", (x["cagr"] - compare["cagr"]) * 100),
                                    r_sprintf("Diff. Gesamtrendite: %+.2f%%", (_tot_ret(x) - _tot_ret(compare)) * 100),
                                    r_sprintf("Diff. Volatilität: %+.2f%%", (_ann_vol(x) - _ann_vol(compare)) * 100)])
    end
    return secs
end

"Zeilen des Panels „Strategievergleich“: Kennzahl, Werte, Differenz und deren Farbe."
function _comparison_rows(x, compare, col = Dict{String,Any}(DEFAULT_COLORS))
    ext_any = _dashboard_returns(x).external_flows || _dashboard_returns(compare).external_flows
    metrics = [ext_any ? "CAGR (MWR)" : "CAGR", ext_any ? "Max. DD (TWR)" : "Max. DD", "Volatilität", "Sharpe"]
    lower_better = (false, true, true, false)
    vals(r) = [r["cagr"] * 100, maximum(r["drawdowns"]) * 100, _ann_vol(r) * 100, r["statistics"]["sharpe"]]
    a, b = vals(x), vals(compare)
    rows = []
    for (i, m) in enumerate(metrics)
        d = a[i] - b[i]
        better = lower_better[i] ? d < 0 : d > 0
        dc = (!isfinite(d) || r_round(d, 2) == 0) ? col["neutral"] : (better ? col["positive"] : col["negative"])
        push!(rows, (metric = m, v1 = r_sprintf("%.2f", a[i]), v2 = r_sprintf("%.2f", b[i]), diff = r_sprintf("%+.2f", d), diff_col = dc))
    end
    return rows
end

"Rollierende Renditen (bis 30 Tage, kalendergenau annualisiert); `values = nothing` bei zu wenigen Daten."
function _rolling_returns(x)
    worth = x["worth"]
    n_days = length(worth)
    dates = Int[to_days(d) for d in _xget(x, "dates")]
    window = max(2, min(30, n_days ÷ 10))
    n_days <= window && return (window = window, values = nothing, idx = Int[])
    growth = r_cumprod(1 .+ [0.0; _dashboard_returns(x).all_returns])
    vals = Float64[]
    for i in window:n_days
        days = Float64(dates[i] - dates[i-window+1])
        push!(vals, (r_pow(growth[i] / growth[i-window+1], 365.25 / days) - 1) * 100)
    end
    return (window = window, values = vals, idx = collect(window:n_days))
end

"Monatsrenditen in Prozent (Jahre × 12), verkettete einzahlungsbereinigte Tagesrenditen."
function _monthly_matrix(x)
    dts = _xget(x, "dates")
    ym = [Dates.format(d, dateformat"yyyy-mm") for d in dts]
    month_ret = [0.0; _dashboard_returns(x).all_returns]
    groups = Dict{String,Vector{Float64}}()
    for (k, v) in zip(ym, month_ret)
        push!(get!(groups, k, Float64[]), v)
    end
    ks = sort(collect(keys(groups)))
    years = unique([k[1:4] for k in ks])
    mat = fill(NA, length(years), 12)
    for k in ks
        mat[findfirst(==(k[1:4]), years), parse(Int, k[6:7])] = (r_prod(1 .+ groups[k]) - 1) * 100
    end
    return years, mat
end

"Rollierende Korrelation der bereinigten Tagesrenditen; `nothing` bei zu wenigen Daten."
function _correlation(x, compare)
    n_days = length(x["worth"])
    rc_x = _dashboard_returns(x).all_returns
    rc_c = _dashboard_returns(compare).all_returns
    fill_of(r) = (f = _xget(r, "filled"); _xlen(f) == n_days ? Vector{Bool}(f)[2:end] : falses(max(0, n_days - 1)))
    ok = .!(fill_of(x) .| fill_of(compare))
    rx, ry = rc_x[ok], rc_c[ok]
    m = length(rx)
    k = min(252, m ÷ 4)
    (m >= 40 && k >= 10) || return nothing
    win(v) = (cs = [0.0; r_cumsum(v)]; cs[k+1:m+1] .- cs[1:m-k+1])
    sx, sy, sxx, syy, sxy = win(rx), win(ry), win(rx .* rx), win(ry .* ry), win(rx .* ry)
    vx = k .* sxx .- sx .* sx
    vy = k .* syy .- sy .* sy
    rho = [(vx[i] > 0 && vy[i] > 0) ? (k * sxy[i] - sx[i] * sy[i]) / sqrt(max(vx[i], 0) * max(vy[i], 0)) : NA for i in eachindex(vx)]
    rho = [isnan(v) ? v : min(max(v, -1.0), 1.0) for v in rho]
    dts = _xget(x, "dates")
    rho_dates = dts[2:end][ok][k:m]
    rho_all = (r_sd(rx) > 0 && r_sd(ry) > 0) ? _r_cor(rx, ry) : NA
    return (k = k, rho = rho, dates = rho_dates, rho_all = rho_all)
end

# ── Panels ──────────────────────────────────────────────────────────────────

function _panel_performance(c, cell, x, compare, dash)
    col = c.col
    worth = x["worth"]; ext = dash.external_flows
    xs = Float64[to_days(d) for d in x["dates"]]
    allv = Float64[worth; compare === nothing ? Float64[] : compare["worth"]; ext ? dash.invested : Float64[]]
    allv = filter(isfinite, allv)
    y_rng = (minimum(allv), maximum(allv))
    lo, hi = _r_range(y_rng...)
    p = _Panel(cell..., xs[1], xs[end], lo, hi)
    ticks = [t for t in r_pretty(y_rng...) if lo <= t <= hi]
    _frame!(c, p; title = "Wertentwicklung des Depots", ylabel = "Depotwert (EUR)", yticks = ticks,
            ylabels = _format_amount(ticks), xticks = _date_ticks(xs[1], xs[end]))
    dx, dy = _decimate(xs, worth)
    _area!(c, p, dx, dy, minimum(worth), _alpha(col["primary"], 0x30))
    _polyline!(c, p, dx, dy; color = _col(col["primary"]), width = 2.5)
    ext && _polyline!(c, p, _decimate(xs, dash.invested)...; color = _col(col["neutral"]), width = 1.5, dash = "2,3", step = true)
    legend = Tuple{String,String,String}[]
    if compare !== nothing
        _polyline!(c, p, _decimate(xs, compare["worth"])...; color = _col(col["secondary"]), width = 2.5, dash = "8,5")
        legend = [("Strategie 1", _col(col["primary"]), ""), ("Strategie 2", _col(col["secondary"]), "8,5")]
        ext && push!(legend, ("Einzahlungen", _col(col["neutral"]), "2,3"))
    elseif ext
        legend = [("Depotwert", _col(col["primary"]), ""), ("Einzahlungen", _col(col["neutral"]), "2,3")]
    end
    if !isempty(legend)
        _rect!(c, p.x0 + 6, p.y0 + 6, 130, 8 + 16 * length(legend); fill = "white", stroke = _col(col["grid"]))
        for (i, (lab, lc, ld)) in enumerate(legend)
            yy = p.y0 + 14 + 16 * (i - 1)
            _line!(c, p.x0 + 12, yy, p.x0 + 36, yy; color = lc, width = 2, dash = ld)
            _text!(c, p.x0 + 42, yy, lab; size = 10)
        end
    end
    _text!(c, p.x0 + p.w + 4, _py(p, worth[end]), _format_amount(worth[end]; signif3 = true)[1]; size = 9,
           color = _col(col["primary"]), weight = "bold", bg = _alpha(col["background"], 0xD9))
    cols = Pair{String,Any}["date" => collect(Date, x["dates"]), "strategy" => collect(Float64, worth)]
    compare === nothing || push!(cols, "compare" => collect(Float64, compare["worth"]))
    ext && push!(cols, "invested" => collect(Float64, dash.invested))
    return RFrame(cols...)
end

function _panel_drawdown(c, cell, x, dash)
    col = c.col
    xs = Float64[to_days(d) for d in x["dates"]]
    dd = x["drawdowns"] .* 100
    lo, hi = _r_range(minimum(-dd) * 1.1, 0.0)
    p = _Panel(cell..., xs[1], xs[end], lo, hi)
    yt, yl = _yaxis(lo, hi)
    _frame!(c, p; title = dash.external_flows ? "Drawdown-Analyse (zeitgewichtet)" : "Drawdown-Analyse",
            ylabel = "Drawdown (%)", yticks = yt, ylabels = yl, xticks = _date_ticks(xs[1], xs[end]))
    dx, dy = _decimate(xs, -dd)
    _area!(c, p, dx, dy, 0.0, _alpha(col["negative"], 0x40))
    _polyline!(c, p, dx, dy; color = _col(col["negative"]), width = 2)
    max_dd = maximum(dd)
    _line!(c, p.x0, _py(p, -max_dd), p.x0 + p.w, _py(p, -max_dd); color = _col(col["negative"]), width = 1.5, dash = "6,4")
    _text!(c, p.x0 + 4, _py(p, -max_dd) - 9, r_sprintf("Max.: %.1f%%", max_dd); color = _col(col["negative"]), weight = "bold",
           bg = _alpha(col["background"], 0xD9))
    return RFrame("date" => collect(Date, x["dates"]), "drawdown" => collect(Float64, x["drawdowns"]))
end

function _panel_distribution(c, cell, x, dash)
    col = c.col
    if length(dash.returns) < 3
        p = _Panel(cell..., 0, 1, 0, 1)
        _empty_panel!(c, p, "Verteilung der Tagesrenditen")
        return RFrame("return" => Float64[])
    end
    rets = dash.returns .* 100
    lo, hi = minimum(rets), maximum(rets)
    br = r_pretty(lo, hi, 50; min_n = 1)
    length(br) < 2 && (br = [lo, hi == lo ? lo + 1 : hi])
    counts = zeros(Int, length(br) - 1)
    for v in rets
        j = searchsortedfirst(br, v) - 1      # rechts geschlossene Klassen (wie hist())
        j = clamp(j, 1, length(counts))
        counts[j] += 1
    end
    ymax = maximum(counts) * 1.04
    p = _Panel(cell..., br[1], br[end], 0.0, ymax)
    yt, yl = _yaxis(0.0, maximum(counts))
    xt = r_pretty(br[1], br[end])
    _frame!(c, p; title = "Verteilung der Tagesrenditen", xlabel = "Tagesrendite (%)", ylabel = "Häufigkeit",
            yticks = yt, ylabels = yl, xticks = [(t, r_format1(t)) for t in xt if br[1] <= t <= br[end]], grid = false)
    f = _alpha(col["primary"], 0x80)
    for j in eachindex(counts)
        counts[j] == 0 && continue
        x0 = _px(p, br[j]); x1 = _px(p, br[j+1])
        _svg!(c, "<rect x=\"$(_c(x0))\" y=\"$(_c(_py(p, counts[j])))\" width=\"$(_c(x1 - x0))\" height=\"$(_c(_py(p, 0) - _py(p, counts[j])))\" " *
                 "fill=\"$(_svgcol(f))\" fill-opacity=\"$(_svgop(f))\" stroke=\"$(_col(col["primary"]))\" stroke-width=\"0.6\"/>")
    end
    mu, sd = r_mean(rets), r_sd(rets)
    if sd > 0
        xsq = [lo + (hi - lo) * i / 99 for i in 0:99]
        yn = [_libm_exp(-0.5 * ((v - mu) / sd)^2) / (sd * sqrt(2pi)) * length(rets) * (hi - lo) / 50 for v in xsq]
        _polyline!(c, p, xsq, yn; color = _col(col["secondary"]), width = 2, dash = "6,4")
    end
    _line!(c, _px(p, mu), p.y0, _px(p, mu), p.y0 + p.h; color = _col(col["positive"]), width = 2, dash = "6,4")
    st = x["statistics"]
    lines_ = [r_sprintf("Mittel: %.2f%%", mu), r_sprintf("Std.-Abw.: %.2f%%", sd), r_sprintf("Schiefe: %.2f", st["skewness"]),
              r_sprintf("Wölbung: %.2f", st["kurtosis"])]
    for (i, t) in enumerate(lines_)
        _text!(c, p.x0 + p.w - 6, p.y0 + 12 + 14 * (i - 1), t; size = 10, color = _col(col["primary"]), anchor = "end",
               bg = _alpha(col["background"], 0xD9))
    end
    return RFrame("return" => collect(Float64, dash.returns))
end

function _panel_rolling(c, cell, x, dash)
    col = c.col
    rr = _rolling_returns(x)
    if rr.values === nothing
        _empty_panel!(c, _Panel(cell..., 0, 1, 0, 1), "Rollierende Renditen (annualisiert)")
        return RFrame("date" => Date[], "return_pct" => Float64[])
    end
    xs = Float64[to_days(d) for d in x["dates"]]
    rd = xs[rr.idx]; vals = rr.values
    ext = dash.external_flows
    cagr_pct = (ext ? x["ttwror"] : x["cagr"]) * 100
    fv = filter(isfinite, [vals; isfinite(cagr_pct) ? cagr_pct : Float64[]; 0.0])
    lo, hi = _r_range(minimum(fv), maximum(fv))
    p = _Panel(cell..., xs[1], xs[end], lo, hi)
    yt, yl = _yaxis(lo, hi)
    _frame!(c, p; title = "Rollierende $(rr.window)-Tage-Renditen (annualisiert)", ylabel = "Rendite p. a. (%)",
            yticks = yt, ylabels = yl, xticks = _date_ticks(xs[1], xs[end]))
    _line!(c, p.x0, _py(p, 0), p.x0 + p.w, _py(p, 0); color = _col(col["neutral"]), dash = "6,4")
    pos = [v >= 0 ? v : NaN for v in vals]; neg = [v < 0 ? v : NaN for v in vals]
    _polyline!(c, p, _decimate(rd, pos)...; color = _col(col["positive"]), width = 1.5)
    _polyline!(c, p, _decimate(rd, neg)...; color = _col(col["negative"]), width = 1.5)
    if isfinite(cagr_pct)
        _line!(c, p.x0, _py(p, cagr_pct), p.x0 + p.w, _py(p, cagr_pct); color = _col(col["primary"]), width = 1.5, dash = "6,4")
        _text!(c, p.x0 + 4, _py(p, cagr_pct) - 9, r_sprintf(ext ? "TTWROR: %.1f%%" : "CAGR: %.1f%%", cagr_pct); size = 10,
               color = _col(col["primary"]), weight = "bold", bg = _alpha(col["background"], 0xD9))
    end
    return RFrame("date" => collect(Date, x["dates"][rr.idx]), "return_pct" => collect(Float64, vals))
end

function _panel_monthly(c, cell, x)
    col = c.col
    years, mat = _monthly_matrix(x)
    ny = length(years)
    p = _Panel(cell..., 0.5, 12.5, 0.5, ny + 0.5)
    _title!(c, p, "Monatsrenditen (%)")
    neg = _col2rgba(col["negative"]); pos = _col2rgba(col["positive"])
    function heat(v)
        t = (clamp(v, -10, 10) + 10) / 20
        k = clamp(floor(Int, t * 20), 0, 19) / 19       # 20 Farbstufen
        a, b, u = k < 0.5 ? (neg, (1.0, 1.0, 1.0), k * 2) : ((1.0, 1.0, 1.0), pos, (k - 0.5) * 2)
        return _svgcol((a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u, a[3] + (b[3] - a[3]) * u, 1.0))
    end
    cw = p.w / 12; ch = p.h / max(ny, 1)
    ry = Int[]; rm = Int[]; rv = Float64[]
    for i in 1:ny, j in 1:12
        v = mat[i, j]
        isnan(v) && continue
        push!(ry, parse(Int, years[i])); push!(rm, j); push!(rv, v)
        x0 = p.x0 + (j - 1) * cw; y0 = p.y0 + p.h - i * ch
        _rect!(c, x0, y0, cw, ch; fill = heat(v))
        ch >= 9 && _text!(c, x0 + cw / 2, y0 + ch / 2, r_sprintf("%.1f", v); size = min(9, ch * 0.7), anchor = "middle",
                          color = abs(v) > 5 ? "white" : "black")
    end
    _rect!(c, p.x0, p.y0, p.w, p.h; stroke = "#CED4DA", sw = 0.8)
    for j in 1:12
        _text!(c, p.x0 + (j - 0.5) * cw, p.y0 + p.h + 8, _MONATE_KURZ[j]; size = 9, color = "#495057", anchor = "end", rot = -90)
    end
    step = max(1, cld(ny, 12))
    for i in 1:step:ny
        _text!(c, p.x0 - 6, p.y0 + p.h - (i - 0.5) * ch, years[i]; size = 9, color = "#495057", anchor = "end")
    end
    _text!(c, p.x0 + p.w / 2, p.y0 + p.h + 40, "Monat"; size = 11, color = "#495057", anchor = "middle")
    _text!(c, p.x0 - 44, p.y0 + p.h / 2, "Jahr"; size = 11, color = "#495057", anchor = "middle", rot = -90)
    return RFrame("year" => ry, "month" => rm, "return_pct" => rv)
end

function _panel_stats(c, cell, x, compare)
    col = c.col
    p = _Panel(cell..., 0, 1, 0, 1)
    _title!(c, p, "Kennzahlen")
    secs = _stats_sections(x, compare)
    nl(g) = sum(1 + 0.85 * length(last(s)) + 0.5 for s in g)
    two = nl(secs) > 16
    groups = two ? [secs[1:cld(length(secs), 2)], secs[cld(length(secs), 2)+1:end]] : [secs]
    lh = min(0.88 / maximum(nl(g) for g in groups), 0.07) * p.h
    for (k, g) in enumerate(groups)
        x0 = p.x0 + (0.05 + (k - 1) * 0.46) * p.w; yy = p.y0 + 0.05 * p.h
        for (s, ls) in g
            _text!(c, x0, yy + 0.5 * lh, s; size = 12, color = _col(col["primary"]), weight = "bold")
            yy += lh
            for v in ls
                _text!(c, x0 + 0.03 * p.w, yy + 0.425 * lh, v; size = 10.5, color = _col(col["neutral"]))
                yy += 0.85 * lh
            end
            yy += 0.5 * lh
        end
    end
    _rect!(c, p.x0 + 0.02 * p.w, p.y0 + 0.02 * p.h, 0.96 * p.w, 0.96 * p.h; stroke = _col(col["grid"]), sw = 2)
    sec = String[]; lab = String[]; val = String[]
    for (s, ls) in secs, v in ls
        k = findfirst(": ", v)
        push!(sec, s)
        push!(lab, k === nothing ? v : v[1:prevind(v, first(k))])
        push!(val, k === nothing ? "" : v[nextind(v, last(k)):end])
    end
    return RFrame("section" => sec, "label" => lab, "value" => val)
end

function _panel_correlation(c, cell, x, compare)
    col = c.col
    r = _correlation(x, compare)
    if r === nothing
        _empty_panel!(c, _Panel(cell..., 0, 1, 0, 1), "Rollierende Korrelation")
        return RFrame("date" => Date[], "correlation" => Float64[])
    end
    xs = Float64[to_days(d) for d in x["dates"]]
    lo, hi = _r_range(-1.0, 1.0)
    p = _Panel(cell..., xs[1], xs[end], lo, hi)
    yt, yl = _yaxis(-1.0, 1.0)
    _frame!(c, p; title = "Rollierende Korrelation ($(r.k) Tage)", ylabel = "Korrelation", yticks = yt, ylabels = yl,
            xticks = _date_ticks(xs[1], xs[end]))
    _line!(c, p.x0, _py(p, 0), p.x0 + p.w, _py(p, 0); color = _col(col["neutral"]), dash = "6,4")
    _polyline!(c, p, _decimate(Float64[to_days(d) for d in r.dates], r.rho)...; color = _col(col["primary"]), width = 1.5)
    ra = r.rho_all
    if isfinite(ra)
        _line!(c, p.x0, _py(p, ra), p.x0 + p.w, _py(p, ra); color = _col(col["secondary"]), width = 1.5, dash = "6,4")
        _text!(c, p.x0 + 4, _py(p, ra) + (ra > 0.8 ? 9 : -9), r_sprintf("Gesamt: %.2f", ra); size = 10,
               color = _col(col["secondary"]), weight = "bold", bg = _alpha(col["background"], 0xD9))
    end
    return RFrame("date" => collect(Date, r.dates), "correlation" => collect(Float64, r.rho))
end

function _panel_comparison(c, cell, x, compare)
    col = c.col
    p = _Panel(cell..., 0, 1, 0, 1)
    _title!(c, p, "Strategievergleich")
    rows = _comparison_rows(x, compare, col)
    X(f) = p.x0 + f * p.w; Y(f) = p.y0 + (1 - f) * p.h
    _text!(c, X(0.35), Y(0.88), "Strategie 1"; color = _col(col["primary"]), weight = "bold", anchor = "end")
    _text!(c, X(0.65), Y(0.88), "Strategie 2"; color = _col(col["secondary"]), weight = "bold", anchor = "end")
    _text!(c, X(0.95), Y(0.88), "Differenz"; color = _col(col["neutral"]), weight = "bold", anchor = "end")
    for (i, r) in enumerate(rows)
        yy = 0.70 - (0.70 - 0.16) * (i - 1) / max(length(rows) - 1, 1)
        _text!(c, X(0.05), Y(yy), r.metric; weight = "bold")
        _text!(c, X(0.35), Y(yy), r.v1; color = _col(col["primary"]), anchor = "end")
        _text!(c, X(0.65), Y(yy), r.v2; color = _col(col["secondary"]), anchor = "end")
        _text!(c, X(0.95), Y(yy), r.diff; color = _col(r.diff_col), weight = "bold", anchor = "end")
    end
    _rect!(c, X(0.02), Y(0.98), 0.96 * p.w, 0.96 * p.h; stroke = _col(col["grid"]), sw = 2)
    return RFrame("label" => String[r.metric for r in rows], "value" => String[r.v1 for r in rows],
                  "compare" => String[r.v2 for r in rows], "diff" => String[r.diff for r in rows])
end

"""
    plot_dashboard(x; style = ("full", "compact", "custom"), panels = nothing, compare = nothing,
                   colors = nothing, width = 1400, height = nothing, file = nothing)

Mehrteiliges Dashboard wie R's `plot.SimLevResult` als SVG ([`SimLevPlot`](@ref)).
`style`: `"full"` (alle Panels), `"compact"` (4 Kern-Panels) oder `"custom"`
(Panels aus `panels`, eindeutige Abkürzungen erlaubt). `compare`: zweites
Ergebnis über dieselben Tage. `colors`: benannte Liste eigener Farben
(R-Farbname oder Hex-Code). `file`: zusätzlich als SVG-Datei speichern (nur
Endung `.svg`); ohne `file` wird nichts geschrieben. Unbekannte Schlüsselwörter
ergeben eine Warnung. Auch über `r_plot(x; ...)`.

`data` des Ergebnisses enthält je gezeichnetem Panel (Zeichenreihenfolge) ein `RFrame`:
`performance` (`date`, `strategy`, ggf. `compare`, `invested`), `drawdown` (`date`,
`drawdown`), `distribution` (`return`), `rolling` (`date`, `return_pct`), `monthly`
(`year`, `month`, `return_pct`), `stats` (`section`, `label`, `value`), `correlation`
(`date`, `correlation`), `comparison` (`label`, `value`, `compare`, `diff`).
"""
function plot_dashboard(x; style = ("full", "compact", "custom"), panels = nothing, compare = nothing,
                        colors = nothing, width::Real = 1400, height = nothing, file = nothing, kwargs...)
    _warn_unknown_kw("plot_dashboard", collect(keys(kwargs)))
    file === nothing || _check_svg_file(file, "plot_dashboard")
    style = match_arg(style, ("full", "compact", "custom"), "style")
    panels_given = panels !== nothing
    pv = panels === nothing ? collect(_DEFAULT_PANELS) : panels isa AbstractString ? [panels] : panels
    if !(pv isa Union{AbstractVector,Tuple}) || isempty(pv) || !all(p -> p isa AbstractString, pv)
        shown = pv === nothing ? "" : join(r_format(pv isa Union{AbstractVector,Tuple} ? collect(Any, pv) : pv), ", ")
        error("plot.SimLevResult: panels muss ein Zeichenvektor sein (erhalten: $shown); möglich: $(join(("\"$p\"" for p in _ALL_PANELS), ", ")).")
    end
    pm = [_pmatch(String(p), _ALL_PANELS) for p in pv]
    if any(isnothing, pm)
        error("plot.SimLevResult: unbekannte(s) Panel(s) $(join(("\"$p\"" for (p, i) in zip(pv, pm) if i === nothing), ", ")) in panels; möglich: $(join(("\"$p\"" for p in _ALL_PANELS), ", ")).")
    end
    panels = unique([_ALL_PANELS[i] for i in pm])
    panels_given && style != "custom" && @warn "plot.SimLevResult: panels wirkt nur mit style = \"custom\" und wird bei style = \"$style\" ignoriert."
    col = _check_colors(colors)
    if compare !== nothing && (!inherits(compare, "SimLevResult") || length(compare["worth"]) != length(x["worth"]))
        why = !inherits(compare, "SimLevResult") ? "erhalten: Objekt der Klasse '$(_r_class1(compare))'" :
              "$(length(compare["worth"])) statt $(length(x["worth"])) Tage"
        error("plot.SimLevResult: compare muss ein SimLevResult über dieselben Tage wie x sein ($why); NULL = kein Vergleich.")
    end
    skipped = String[]
    if style == "custom" && compare === nothing && any(p -> p in ("correlation", "comparison"), panels)
        skipped = [p for p in panels if p in ("correlation", "comparison")]
        @warn "plot.SimLevResult: Panel(s) $(join(("\"$p\"" for p in skipped), ", ")) nicht gezeichnet: $(length(skipped) > 1 ? "benötigen" : "benötigt") ein Vergleichsergebnis (compare)."
        panels = [p for p in panels if !(p in skipped)]
    end
    local selected, layout
    if style == "full"
        selected = compare !== nothing ? ["performance", "drawdown", "distribution", "rolling", "monthly", "correlation", "stats", "comparison"] :
                   collect(_DEFAULT_PANELS)
        layout = permutedims(reshape(collect(1:length(selected)), 2, :))
    elseif style == "compact"
        selected = ["performance", "drawdown", "distribution", "stats"]
        layout = [1 2; 3 4]
    else
        selected = panels
        layout = isempty(panels) ? fill(1, 1, 1) : _dash_custom_layout(length(panels))
    end
    nr, nc = size(layout)
    W = Float64(width)
    H = height === nothing ? (nr >= 3 ? W * 10 / 14 : W * 8 / 12) : Float64(height)
    io = IOBuffer()
    c = _Canvas(io, col)
    bg = _col2rgba(col["background"])
    print(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$(round(Int, W))\" height=\"$(round(Int, H))\" ",
          "viewBox=\"0 0 $(round(Int, W)) $(round(Int, H))\" font-family=\"Helvetica, Arial, sans-serif\">\n")
    _rect!(c, 0, 0, W, H; fill = _svgcol(bg))
    cw = W / nc; chh = H / nr
    function cell_of(slot)
        idx = findall(==(slot), layout)
        r0 = minimum(i[1] for i in idx); r1 = maximum(i[1] for i in idx)
        c0 = minimum(i[2] for i in idx); c1 = maximum(i[2] for i in idx)
        return ((c0 - 1) * cw + 80, (r0 - 1) * chh + 40, (c1 - c0 + 1) * cw - 130, (r1 - r0 + 1) * chh - 95)
    end
    data = RList()
    if isempty(selected)
        _text!(c, W / 2, H / 2 - 8, "Keine zeichenbaren Panels:"; size = 13, color = _col(col["neutral"]), anchor = "middle")
        _text!(c, W / 2, H / 2 + 10, "$(join(skipped, ", ")) ohne Vergleichsergebnis (compare)"; size = 13,
               color = _col(col["neutral"]), anchor = "middle")
    else
        dash = _dashboard_returns(x)
        order = [p for p in ("performance", "drawdown", "distribution", "rolling", "monthly", "stats", "correlation", "comparison") if p in selected]
        for (slot, pn) in enumerate(order)
            cell = cell_of(slot)
            pn == "performance" && (data[pn] = _panel_performance(c, cell, x, compare, dash))
            pn == "drawdown" && (data[pn] = _panel_drawdown(c, cell, x, dash))
            pn == "distribution" && (data[pn] = _panel_distribution(c, cell, x, dash))
            pn == "rolling" && (data[pn] = _panel_rolling(c, cell, x, dash))
            pn == "monthly" && (data[pn] = _panel_monthly(c, cell, x))
            pn == "stats" && (data[pn] = _panel_stats(c, cell, x, compare))
            pn == "correlation" && compare !== nothing && (data[pn] = _panel_correlation(c, cell, x, compare))
            pn == "comparison" && compare !== nothing && (data[pn] = _panel_comparison(c, cell, x, compare))
        end
    end
    print(io, "</svg>\n")
    d = SimLevPlot(String(take!(io)), data, x, "SimLevResult")
    file === nothing || _write_svg(file, d, "plot_dashboard")
    return d
end

"""
    export_dashboard(x, filename = "dashboard.svg"; width = 14, height = 10, kwargs...)

Dashboard als SVG-Datei speichern (Größe in Zoll wie in R, 100 px je Zoll);
weitere Argumente gehen an [`plot_dashboard`](@ref) (unbekannte → Warnung).
`filename` auch als Schlüsselwort. Es gibt nur SVG: Eine andere Dateiendung
(R kann über ggsave auch .png/.pdf) bricht vor dem Zeichnen mit einer Meldung
ab, statt die Endung still zu ersetzen. Meldung wie in R nach `stderr`.
"""
function export_dashboard(x, filename_pos::AbstractString = "dashboard.svg"; filename::AbstractString = filename_pos, width::Real = 14, height::Real = 10, kwargs...)
    _check_svg_file(filename, "export_dashboard")
    d = plot_dashboard(x; width = width * 100, height = height * 100, kwargs...)
    _write_svg(filename, d, "export_dashboard")
    _message("export_dashboard: Dashboard gespeichert in $filename")
    return nothing
end

const _PLOT_RESULT = _plot_method(plot_dashboard, "SimLevResult")

"Wie R's `plot(<SimLevResult>)` (= `r_plot(x; …)`): `SimLevPlot`, Datei nur mit `file`."
plot(x::SimLevResult, args...; kwargs...) = _PLOT_RESULT(x, args...; kwargs...)

register_plot!("SimLevResult", _PLOT_RESULT)
