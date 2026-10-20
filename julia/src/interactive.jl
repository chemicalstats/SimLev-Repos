# ─────────────────────────────────────────────────────────────────────────────
# Interaktives HTML-Dashboard (Port von plot_interactive.R, eingebauter Writer)
#
# Erzeugt eine vollständig eigenständige HTML-Datei (Inline-SVG + JavaScript),
# die offline in jedem Browser funktioniert; byte-identisch zur Ausgabe des
# R-Pakets ohne plotly. `engine = "plotly"` gibt es in Julia nicht (wie R ohne
# plotly: Warnung, dann der HTML-Writer).
# ─────────────────────────────────────────────────────────────────────────────

include("html_templates.jl")

const _PANELS = ("performance", "drawdown", "weights")
const _PAL = ("#2C7FB8", "#D95F02", "#1B9E77", "#7570B3", "#E7298A", "#66A61E", "#E6AB02", "#A6761D")

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

"`unique(c(round(seq(1, n, length.out = max_points)), n))` wie in R."
function _thin_index(n::Int, max_points::Int)
    n <= max_points && return collect(1:n)
    n1 = max_points - 1
    by = (n - 1) / n1
    sq = [1.0; [1.0 + k * by for k in 1:n1-1]; Float64(n)]
    out = Int[]
    seen = Set{Int}()
    for v in [Int.(round.(sq, RoundNearest)); n]
        v in seen && continue
        push!(seen, v); push!(out, v)
    end
    return out
end

"R: `.build_dashboard_data`: Daten je Serie, gleichmäßig auf `max_points` ausgedünnt."
function _build_dashboard_data(x, max_points::Int)
    dates = _xget(x, "dates")
    n = length(dates)
    keep = _thin_index(n, max_points)
    report = _xget(x, "report")
    assets = report === nothing ? String[] : collect(keys(report))
    totals = [collect(Float64, report[a]["total"])[keep] for a in assets]
    tot_sum = isempty(totals) ? Float64[] : reduce((a, b) -> a .+ b, totals)
    fi = _dashboard_returns(x)
    invested = fi.invested[keep]
    ddx = _xget(x, "drawdowns")
    dd = if ddx !== nothing
        collect(Float64, ddx)[keep]
    else
        w = collect(Float64, _xget(x, "worth")); cm = r_cummax(w)
        (-(cm .- w) ./ cm .* 0 .+ (w ./ cm .- 1))[keep]
    end
    weights = [Float64[tot_sum[i] > 0 ? 100 * t[i] / tot_sum[i] : 0.0 for i in eachindex(t)] for t in totals]
    fx = _xget(x, "filled")
    return (dates = String[Dates.format(d, dateformat"yyyy-mm-dd") for d in dates[keep]],
            filled = fx === nothing ? Bool[] : Vector{Bool}(fx)[keep], assets = assets,
            worth = collect(Float64, _xget(x, "worth"))[keep], invested = invested, totals = totals,
            weights = weights, drawdown = 100 .* dd, stats = _xget(x, "statistics"), cagr = _xget(x, "cagr"),
            external_flows = fi.external_flows)
end

_num2js(v) = "[" * join((isfinite(a) ? r_sprintf("%.6g", a) : "null" for a in Float64.(v)), ",") * "]"
_chr2js(v) = "[\"" * join(v, "\",\"") * "\"]"

function _js_panel(pid, title, series, unit; fill_first::Bool = false)
    ser = String[]
    for s in series
        push!(ser, r_sprintf("{name:\"%s\",col:\"%s\",w:%s,dash:%s,v:%s}", s.name, s.col, r_as_character(s.width),
                             get(s, :dash, false) ? "true" : "false", _num2js(s.vals)))
    end
    return r_sprintf("makePanel(\"%s\",\"%s\",[%s],\"%s\",%s);", pid, title, join(ser, ","), unit,
                     fill_first ? "true" : "false")
end

function _stat_line(d)
    st = d.stats
    st === nothing && return ""
    num(v) = v === nothing ? NA : Float64(v)
    fmt = d.external_flows === true ?
          "CAGR (geldgewichtet) %.2f%% &middot; Sharpe %.2f &middot; Max. Drawdown (zeitgewichtet) %.1f%%" :
          "CAGR %.2f%% &middot; Sharpe %.2f &middot; Max. Drawdown %.1f%%"
    return r_sprintf(fmt, 100 * num(d.cagr), num(get(st, "sharpe", nothing)), 100 * num(get(st, "max_drawdown", nothing)))
end

"R: `.build_dashboard_html`: der vollständige HTML-Text."
function _build_dashboard_html(d, panels)
    series_perf = Any[(name = a, col = _PAL[(i-1)%length(_PAL)+1], vals = d.totals[i], width = 1.4) for (i, a) in enumerate(d.assets)]
    push!(series_perf, (name = "Gesamt", col = "#111111", vals = d.worth, width = 2.4))
    push!(series_perf, (name = "Einzahlungen (inkl. Start, brutto)", col = "#888888", vals = d.invested, width = 1.4, dash = true))
    series_w = [(name = a, col = _PAL[(i-1)%length(_PAL)+1], vals = d.weights[i], width = 1.6) for (i, a) in enumerate(d.assets)]
    calls = String[]; divs = String[]
    if "performance" in panels
        push!(divs, "<div class=\"panel\" id=\"performance\"></div>")
        push!(calls, _js_panel("performance", "Wertentwicklung des Depots", series_perf, " EUR"))
    end
    if "drawdown" in panels
        push!(divs, "<div class=\"panel\" id=\"drawdown\"></div>")
        push!(calls, _js_panel("drawdown", d.external_flows === true ? "Drawdown (zeitgewichtet)" : "Drawdown",
                               [(name = "Drawdown", col = "#C0392B", vals = d.drawdown, width = 1.6)], " %"; fill_first = true))
    end
    if "weights" in panels
        push!(divs, "<div class=\"panel\" id=\"weights\"></div>")
        push!(calls, _js_panel("weights", "Asset-Gewichte", series_w, " %"))
    end
    return _HTML_HEAD * _stat_line(d) * _HTML_SUB * join(divs, "\n") * _HTML_MID1 * _chr2js(d.dates) *
           ";\nvar FILLED=" * _num2js(Float64.(d.filled)) * _HTML_SCRIPT * join(calls, "\n") * _HTML_TAIL
end

"`match.arg(arg, choices, several.ok = TRUE)`: nicht passende Werte werden still verworfen."
function _match_arg_several(arg, choices)
    arg === nothing && return [choices[1]]
    vals = arg isa AbstractString ? [arg] : arg isa Union{AbstractVector,Tuple} ? collect(arg) : nothing
    (vals === nothing || !all(v -> v isa AbstractString, vals)) && error("'arg' must be NULL or a character vector")
    isempty(vals) && error("'arg' must be of length >= 1")
    idx = [_pmatch(String(v), choices) for v in vals]
    if all(isnothing, idx)
        chs = unique([c for c in choices if !isempty(c)])
        error((length(chs) == 1 ? "'arg' should be " : "'arg' should be one of ") * join(("“$(c)”" for c in chs), ", "))
    end
    return [choices[i] for i in idx if i !== nothing]
end

"""
    plot_interactive(x; file = nothing, panels = ("performance", "drawdown", "weights"),
                     max_points = 6000, open = isinteractive(), engine = ("auto", "plotly", "html"))

Interaktives Dashboard mit Hover-Tooltips, synchronem Fadenkreuz und klickbarer
Legende als eigenständige HTML-Datei (byte-identisch zu R ohne plotly).
Rückgabe: Pfad der HTML-Datei.
"""
function plot_interactive(x; file = nothing, panels = _PANELS, max_points::Integer = 6000,
                          open::Bool = isinteractive(), engine = ("auto", "plotly", "html"))
    engine = match_arg(engine, ("auto", "plotly", "html"), "engine")
    panels = _match_arg_several(panels, _PANELS)
    file === nothing && (file = tempname() * ".html"; file = joinpath(dirname(file), "simlev_dashboard_" * basename(file)))
    engine == "auto" && (engine = "html")
    if engine == "plotly"
        @warn "plotly ist nicht installiert - nutze den eingebauten HTML-Writer."
        engine = "html"
    end
    d = _build_dashboard_data(x, Int(max_points))
    html = _build_dashboard_html(d, panels)
    Base.open(file, "w") do io
        write(io, html, "\n")
    end
    if open
        try
            cmd = Sys.isapple() ? `open $file` : Sys.iswindows() ? `cmd /c start $file` : `xdg-open $file`
            run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false)
        catch
        end
    end
    return file
end
