# ─────────────────────────────────────────────────────────────────────────────
# Grafikmodul: `SimLevPlot`, einheitliche plot-API und alle SVG-Zeichenbausteine
#
# Alle Grafiken entstehen ohne externe Pakete als SVG. Diese Datei (im Modul
# SimLev, eingebunden vor dashboard.jl und den Untermodulen) ist das Gegenstück
# zu python/simlev/svg.py; beide haben dieselbe Gliederung und dieselben Namen
# (Julias `name!` heißt dort `name`):
#
#  1. Grafikobjekt: `SimLevPlot`
#  2. Einheitliche Grafik-API: `_check_svg_file`, `_write_svg`, `_warn_unknown_kw`, `_plot_method`
#  3. Gemeinsame Hilfen: `_esc`, `r_pretty`, Farben, Datumshilfen
#  4. Stil Dashboard (plot_dashboard): `_Canvas`, `_text!`, `_line!`, `_rect!`, `_Panel`, …
#  5. Stil Analysegrafiken `_ana_*` (deep_analysis, analysis_tests, planning)
#  6. Stil Rastergrafiken `_grid_*` (dependence, regimes)
#  7. Stil Ergebnisgrafiken `_res_*` (overfitting, param_search, sensitivity)
#  8. Stil Rückrechnung `_bc_*` (backcast)
#  9. Stil Allokationsgrafiken `_alloc_*` (optimize, tactical)
# 10. Zahlen wie in Julia (nur in Python nötig)
#
# Die Untermodule enthalten nur ihre Zeichenfunktionen (`_plot_*`/`plot_SimLev*`)
# mit der Datenaufbereitung und holen die Bausteine mit `using ..SimLev: …`.
# Die Grafiken von withdrawal (SimLevWithdrawal) und bootstrap
# (SimLevBootstrapStudy) schreiben ihr SVG direkt in der Zeichenfunktion.
# ─────────────────────────────────────────────────────────────────────────────

# ═════════════════════════════════════════════════════════════════════════════
# 1. Grafikobjekt
# ═════════════════════════════════════════════════════════════════════════════

"""
    SimLevPlot

Eine gerenderte Grafik (SVG) mit den dargestellten Daten; Ergebnis von
[`plot_dashboard`](@ref) und aller `r_plot`-Methoden. Felder:

- `svg::String`: die fertige Grafik (in Jupyter, Pluto und VS Code direkt sichtbar),
- `data::RList`: die dargestellten Werte je Panel als `RFrame` (Schlüssel =
  Panelname, Reihenfolge wie gezeichnet; nicht ausgedünnt, unskaliert),
- `source`: das Eingabeobjekt (keine Kopie),
- `kind::String`: Klasse des Eingabeobjekts, z. B. `"SimLevResult"`.

`write(io, p)` schreibt das SVG; mit `file = "….svg"` speichern die plot-Methoden
selbst, [`export_dashboard`](@ref) speichert ein Dashboard.
"""
struct SimLevPlot
    svg::String
    data::RList
    source::Any
    kind::String
end
"Übergang (Stufe B): nur SVG, `data` leer; `_plot_method` setzt `source` und `kind`."
SimLevPlot(svg::AbstractString) = SimLevPlot(String(svg), RList(), nothing, "")
Base.show(io::IO, ::MIME"image/svg+xml", d::SimLevPlot) = print(io, d.svg)
Base.show(io::IO, d::SimLevPlot) = print(io, "SimLevPlot(", d.kind, ", SVG, ", sizeof(d.svg), " Bytes",
                                         isempty(d.data) ? "" : ", Panels: " * join(keys(d.data), ", "), ")")
Base.write(io::IO, d::SimLevPlot) = write(io, d.svg)

# ═════════════════════════════════════════════════════════════════════════════
# 2. Einheitliche Grafik-API
# ═════════════════════════════════════════════════════════════════════════════
# `r_plot(x; …)`, `plot_dashboard` und alle plot-Methoden der Erweiterungen
# liefern ein `SimLevPlot` (SVG und Daten) und schreiben nur, wenn `file = "….svg"`
# angegeben ist (kein stilles `Rplots.svg`). Andere Dateiendungen brechen mit
# einer Meldung ab (es gibt nur SVG; keine stille Umbenennung). Unbekannte
# Schlüsselwörter ergeben eine Warnung statt stillem Übergehen (R ignoriert
# `...`; hier soll ein Tippfehler auffallen).

"Prüft, dass `file` auf `.svg` endet (Grafiken entstehen nur als SVG); liefert den Pfad."
function _check_svg_file(file, who::AbstractString)
    file isa AbstractString || error("$who: file muss ein Dateiname (Zeichenkette) sein, nicht $(typeof(file)).")
    f = String(file)
    ext = splitext(f)[2]
    lowercase(ext) == ".svg" ||
        error("$who: Grafiken werden nur als SVG gespeichert; '$f' hat " *
              (isempty(ext) ? "keine Dateiendung" : "die Endung '$ext'") *
              ". Bitte einen Dateinamen auf .svg angeben (z. B. \"dashboard.svg\").")
    return f
end

"SVG von `d` nach `file` schreiben (nur `.svg`)."
function _write_svg(file, d::SimLevPlot, who::AbstractString)
    f = _check_svg_file(file, who)
    open(io -> write(io, d.svg), f, "w")
    return d
end

"Warnung für unbekannte Schlüsselwörter (deutsch, alle in einer Meldung)."
function _warn_unknown_kw(who::AbstractString, bad)
    isempty(bad) && return nothing
    nm = join(("'$k'" for k in bad), ", ")
    @warn length(bad) == 1 ? "$who: unbekanntes Argument $nm wird ignoriert (Tippfehler?)." :
                             "$who: unbekannte Argumente $nm werden ignoriert (Tippfehler?)."
    return nothing
end

"Deklarierte Schlüsselwörter aller Methoden von `f` (ohne `kw...`)."
function _kwnames(f)
    out = Set{Symbol}()
    for m in methods(f), k in Base.kwarg_decl(m)
        endswith(String(k), "...") || push!(out, k)
    end
    return out
end

"`data` einer Zeichenfunktion vereinheitlichen: `RList` mit `RFrame`-Einträgen."
_as_plotdata(::Nothing, who) = RList()
function _as_plotdata(d, who)
    (d isa AbstractDict || d isa AbstractVector{<:Pair} || d isa Tuple) ||
        error("$who: die Grafikmethode lieferte keine Daten als RList (sondern $(typeof(d))).")
    out = RList()
    for (k, v) in (d isa AbstractDict ? pairs(d) : d)
        out[String(k)] = v isa RFrame ? v : as_rframe(v)
    end
    return out
end

"Ergebnis einer Zeichenfunktion → `SimLevPlot(svg, data, x, cls)`; ein reiner String ergibt leere `data` (Übergang)."
_as_plot(d::SimLevPlot, who, x, cls) = SimLevPlot(d.svg, d.data, x, String(cls))
_as_plot(s::AbstractString, who, x, cls) = SimLevPlot(String(s), RList(), x, String(cls))
_as_plot(t::Tuple{AbstractString,Any}, who, x, cls) = SimLevPlot(String(t[1]), _as_plotdata(t[2], who), x, String(cls))
_as_plot(r, who, x, cls) = error("$who: die Grafikmethode lieferte kein SVG (sondern $(typeof(r))).")

"""
    _plot_method(f, cls) -> Funktion `(x, args...; file = nothing, kw...)`

Macht aus einer Zeichenfunktion `f(x; kw...)` die plot-Methode für die
S3-Klasse `cls` (für `register_plot!`): nur die von `f` deklarierten
Schlüsselwörter werden weitergegeben, unbekannte ergeben eine Warnung;
Positionsargumente nach `x` ergeben eine Warnung und werden ignoriert. `f`
liefert `(svg, data)` (`data`: `RList`, `Dict` oder Paare `"panel" => RFrame`),
ein `SimLevPlot` oder (Übergang) nur den SVG-Text, dann ist `data` leer.
Ergebnis immer `SimLevPlot(svg, data, x, cls)`; geschrieben wird nur mit
`file = "….svg"` (deklariert `f` selbst `file`, bekommt es `file = nothing`).
"""
function _plot_method(f, cls::AbstractString)
    who = "plot.$cls"
    known = _kwnames(f)
    takes_file = :file in known
    return function (x, args...; file = nothing, kw...)
        isempty(args) || @warn "$who: $(length(args)) zusätzliche(s) Positionsargument(e) wird/werden ignoriert; Optionen bitte als Schlüsselwort angeben."
        _warn_unknown_kw(who, [k for k in keys(kw) if !(k in known)])
        file === nothing || _check_svg_file(file, who)
        good = (k => v for (k, v) in kw if k in known)
        res = takes_file ? f(x; good..., file = nothing) : f(x; good...)
        d = _as_plot(res, who, x, cls)
        file === nothing || _write_svg(file, d, who)
        return d
    end
end

# ═════════════════════════════════════════════════════════════════════════════
# 3. Gemeinsame Hilfen (alle Stile)
# ═════════════════════════════════════════════════════════════════════════════

# ── Textschutz ──────────────────────────────────────────────────────────────
# Ein `_esc` für Titel, Achsen- und Legendentexte aller Stile (& < > ").
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

# ── R-Achsenteilung ─────────────────────────────────────────────────────────
"Nachbildung von R's `pretty()` (R_pretty aus src/appl/pretty.c)."
function r_pretty(lo::Real, hi::Real, n::Int = 5; min_n::Int = n ÷ 3)
    lo = Float64(lo); hi = Float64(hi)
    (isfinite(lo) && isfinite(hi)) || return [0.0]
    hi < lo && ((lo, hi) = (hi, lo))
    h = 1.5; h5 = 0.5 + 1.5 * h
    epsv = 1e-10
    dx = hi - lo
    local cell::Float64
    if dx == 0 && hi == 0
        cell = 1.0; i_small = true
    else
        cell = max(abs(lo), abs(hi))
        u = 1 + (h5 >= 1.5 * h + 0.5 ? 1 / (1 + h) : 1.5 / (1 + h5))
        u *= max(1, n) * eps(Float64)
        i_small = dx < cell * u * 3
    end
    if i_small
        cell > 10 && (cell = 9 + cell / 10)
        cell *= 0.75
        min_n > 1 && (cell /= min_n)
    else
        cell = dx
        n > 1 && (cell /= n)
    end
    base = _libm_pow(10.0, floor(_libm_log10(cell)))   # R: pow(10., floor(log10(cell))) (libm, nicht Base.^)
    unit = base
    if 2 * base - cell < h * (cell - unit)
        unit = 2 * base
        if 5 * base - cell < h5 * (cell - unit)
            unit = 5 * base
            10 * base - cell < h * (cell - unit) && (unit = 10 * base)
        end
    end
    ns = floor(lo / unit + epsv)
    nu = ceil(hi / unit - epsv)
    while ns * unit > lo + epsv * unit
        ns -= 1
    end
    while nu * unit < hi - epsv * unit
        nu += 1
    end
    k = Int(floor(0.5 + nu - ns))
    if k < min_n
        k = min_n - k
        if ns >= 0
            nu += k ÷ 2; ns -= k ÷ 2 + k % 2
        else
            ns -= k ÷ 2; nu += k ÷ 2 + k % 2
        end
    end
    return [i * unit for i in ns:nu]
end

# ── Farben (grDevices::col2rgb / adjustcolor) ───────────────────────────────
const _R_PALETTE = ("black", "#DF536B", "#61D04F", "#2297E6", "#28E2E5", "#CD0BBC", "#F5C710", "gray62")
const _COLOR_TABLE = Ref{Union{Nothing,Dict{String,String}}}(nothing)
function _color_table()
    if _COLOR_TABLE[] === nothing
        tab = Dict{String,String}()
        for ln in readlines(joinpath(@__DIR__, "..", "data", "r_colors.csv"))[2:end]
            isempty(ln) && continue
            nm, hx = split(ln, ",")
            tab[String(nm)] = String(hx)
        end
        _COLOR_TABLE[] = tab
    end
    return _COLOR_TABLE[]
end

"`col2rgb(v, alpha = TRUE) / 255` für einen Wert; Fehler wie in R."
function _col2rgba(v)
    v isa Bool && error("invalid color name '$(v ? "TRUE" : "FALSE")'")
    if v isa Real
        f = Float64(v)
        isnan(f) && return (1.0, 1.0, 1.0, 0.0)
        f < 0 && error("numerical color values must be >= 0, found $(Int(trunc(f)))")
        i = Int(trunc(f))
        i == 0 && error("numerical color values must be positive")
        return _col2rgba(_R_PALETTE[(i-1)%length(_R_PALETTE)+1])
    end
    v isa AbstractString || error("invalid color specification")
    if startswith(v, "#")
        length(v) in (7, 9) || error("invalid RGB specification")
        vals = try
            [parse(Int, v[i:i+1]; base = 16) for i in 2:2:length(v)]
        catch
            error("invalid hex digit in 'color' or 'lty'")
        end
        length(vals) == 3 && push!(vals, 255)
        return Tuple(c / 255 for c in vals)
    end
    v in ("NA", "transparent") && return (1.0, 1.0, 1.0, 0.0)
    isdigit(first(v * " ")) && return _col2rgba(all(isdigit, v) ? Float64(parse(Int, v)) : NaN)
    hx = get(_color_table(), lowercase(replace(v, " " => "")), nothing)
    hx === nothing && error("invalid color name '$v'")
    return _col2rgba(hx)
end

_svgcol(rgba) = r_sprintf("#%02X%02X%02X", round(Int, rgba[1] * 255), round(Int, rgba[2] * 255), round(Int, rgba[3] * 255))
_svgop(rgba) = r_sprintf("%.3f", rgba[4])
_col(c) = _svgcol(_col2rgba(c))
_alpha(c, a::Integer) = (r = _col2rgba(c); (r[1], r[2], r[3], r[4] * a / 255))

# ── Datumshilfen (Tage seit 1970) ───────────────────────────────────────────
# from_days, to_days, days_from_civil aus src/dates.jl (Python: _ym, _days_from_civil, _to_days).
const _MONATE_KURZ = ("Jan", "Feb", "Mär", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez")

"`format(<Date>)` eines Tages (Tage seit 1970; für Achsen ohne Jahresmarke)."
function _fmt_day(day::Real)
    y, m, dd = Dates.yearmonthday(from_days(Int(day)))
    string(y < 0 ? "-" * lpad(-y, 4, '0') : lpad(y, 4, '0'), "-", lpad(m, 2, '0'), "-", lpad(dd, 2, '0'))
end

# ═════════════════════════════════════════════════════════════════════════════
# 4. Stil Dashboard
# ═════════════════════════════════════════════════════════════════════════════
# plot_dashboard bzw. plot(<SimLevResult>) (dashboard.jl): Zeichenkontext `_Canvas` mit
# Farbtabelle, Panels `_Panel` mit Datenbereich, Koordinaten mit `%.1f` (`_c`).

_c(x) = r_sprintf("%.1f", x)
mutable struct _Canvas
    io::IOBuffer
    col::Dict{String,Any}
end
_svg!(c::_Canvas, s::AbstractString) = (print(c.io, s, "\n"); nothing)
function _text!(c, x, y, s; size = 11, color = "#333333", anchor = "start", weight = "normal", baseline = "middle", rot = 0, bg = nothing)
    if bg !== nothing
        w = 0.58 * size * length(s); h = 1.25 * size
        x0 = anchor == "start" ? x : anchor == "end" ? x - w : x - w / 2
        _svg!(c, "<rect x=\"$(_c(x0 - 2))\" y=\"$(_c(y - h / 2))\" width=\"$(_c(w + 4))\" height=\"$(_c(h))\" fill=\"$(_svgcol(bg))\" fill-opacity=\"$(_svgop(bg))\"/>")
    end
    _svg!(c, "<text x=\"$(_c(x))\" y=\"$(_c(y))\" font-size=\"$size\" fill=\"$color\" text-anchor=\"$anchor\" " *
             "font-weight=\"$weight\" dominant-baseline=\"$baseline\"" *
             (rot != 0 ? " transform=\"rotate($rot $(_c(x)) $(_c(y)))\"" : "") * ">$(_esc(s))</text>")
end
_line!(c, x1, y1, x2, y2; color = "#999999", width = 1, dash = "") =
    _svg!(c, "<line x1=\"$(_c(x1))\" y1=\"$(_c(y1))\" x2=\"$(_c(x2))\" y2=\"$(_c(y2))\" stroke=\"$color\" " *
             "stroke-width=\"$width\"" * (isempty(dash) ? "" : " stroke-dasharray=\"$dash\"") * "/>")
_rect!(c, x, y, w, h; fill = "none", stroke = "none", sw = 1, opacity = 1.0) =
    _svg!(c, "<rect x=\"$(_c(x))\" y=\"$(_c(y))\" width=\"$(_c(w))\" height=\"$(_c(h))\" fill=\"$fill\" " *
             "stroke=\"$stroke\" stroke-width=\"$sw\"" * (opacity < 1 ? " fill-opacity=\"$(r_sprintf("%.3f", opacity))\"" : "") * "/>")

struct _Panel
    x0::Float64; y0::Float64; w::Float64; h::Float64
    xlo::Float64; xhi::Float64; ylo::Float64; yhi::Float64
end
_px(p::_Panel, x) = p.x0 + (x - p.xlo) / (p.xhi == p.xlo ? 1.0 : p.xhi - p.xlo) * p.w
_py(p::_Panel, y) = p.y0 + p.h - (y - p.ylo) / (p.yhi == p.ylo ? 1.0 : p.yhi - p.ylo) * p.h

function _decimate(xs::Vector{Float64}, ys::Vector{Float64}, maxn::Int = 1600)
    n = length(xs)
    n <= maxn && return xs, ys
    bucket = ceil(Int, n / (maxn ÷ 2))
    ox = Float64[]; oy = Float64[]
    for s in 1:bucket:n
        seg = s:min(n, s + bucket - 1)
        good = [i for i in seg if isfinite(ys[i])]
        isempty(good) && continue
        imin = good[argmin(ys[good])]; imax = good[argmax(ys[good])]
        for i in sort(unique([imin, imax]))
            push!(ox, xs[i]); push!(oy, ys[i])
        end
    end
    return ox, oy
end
function _path(p::_Panel, xs, ys; step::Bool = false)
    io = IOBuffer(); first = true; prev = 0.0
    for (x, y) in zip(xs, ys)
        if !isfinite(y)
            first = true; continue
        end
        if step && !first
            print(io, "L", _c(_px(p, x)), " ", _c(_py(p, prev)))
        end
        print(io, first ? "M" : "L", _c(_px(p, x)), " ", _c(_py(p, y)))
        first = false; prev = y
    end
    return String(take!(io))
end
_polyline!(c, p, xs, ys; color, width = 1.5, dash = "", step = false) =
    _svg!(c, "<path d=\"$(_path(p, xs, ys; step = step))\" fill=\"none\" stroke=\"$color\" stroke-width=\"$width\" stroke-linejoin=\"round\"" *
             (isempty(dash) ? "" : " stroke-dasharray=\"$dash\"") * "/>")
function _area!(c, p, xs, ys, base, fill)
    d = _path(p, xs, ys)
    isempty(d) && return
    _svg!(c, "<path d=\"$d L$(_c(_px(p, xs[end]))) $(_c(_py(p, base))) L$(_c(_px(p, xs[1]))) $(_c(_py(p, base))) Z\" " *
             "fill=\"$(_svgcol(fill))\" fill-opacity=\"$(_svgop(fill))\" stroke=\"none\"/>")
end

function _date_ticks(z0::Float64, z1::Float64)
    d0 = from_days(Int(floor(z0))); d1 = from_days(Int(ceil(z1)))
    years = Dates.year(d1) - Dates.year(d0)
    ticks = Tuple{Float64,String}[]
    if years >= 2
        step = years <= 8 ? 1 : years <= 16 ? 2 : years <= 40 ? 5 : 10
        for y in Dates.year(d0):Dates.year(d1)
            y % step == 0 || continue
            z = Float64(days_from_civil(y, 1, 1))
            z0 <= z <= z1 && push!(ticks, (z, string(y)))
        end
    else
        months = 12 * years + Dates.month(d1) - Dates.month(d0)
        step = months <= 8 ? 1 : months <= 16 ? 2 : months <= 30 ? 3 : 6
        y, m = Dates.year(d0), Dates.month(d0)
        while true
            z = Float64(days_from_civil(y, m, 1))
            z > z1 && break
            ((m - 1) % step == 0 && z >= z0) && push!(ticks, (z, string(_MONATE_KURZ[m], " ", y)))
            m += 1; m > 12 && (m = 1; y += 1)
        end
    end
    return ticks
end

function _frame!(c, p::_Panel; title = "", xlabel = "", ylabel = "", yticks = Float64[], ylabels = String[],
                 xticks = Tuple{Float64,String}[], grid = true)
    col = c.col
    _rect!(c, p.x0, p.y0, p.w, p.h; fill = "white", stroke = "#CED4DA", sw = 0.8)
    if grid
        for t in yticks
            p.ylo <= t <= p.yhi && _line!(c, p.x0, _py(p, t), p.x0 + p.w, _py(p, t); color = _col(col["grid"]), width = 0.8)
        end
        for (t, _) in xticks
            _line!(c, _px(p, t), p.y0, _px(p, t), p.y0 + p.h; color = _col(col["grid"]), width = 0.8)
        end
    end
    for (t, l) in zip(yticks, ylabels)
        p.ylo <= t <= p.yhi && _text!(c, p.x0 - 6, _py(p, t), l; size = 10, color = "#495057", anchor = "end")
    end
    for (t, l) in xticks
        _text!(c, _px(p, t), p.y0 + p.h + 14, l; size = 10, color = "#495057", anchor = "middle")
    end
    _title!(c, p, title)
    isempty(xlabel) || _text!(c, p.x0 + p.w / 2, p.y0 + p.h + 32, xlabel; size = 11, color = "#495057", anchor = "middle")
    isempty(ylabel) || _text!(c, p.x0 - 58, p.y0 + p.h / 2, ylabel; size = 11, color = "#495057", anchor = "middle", rot = -90)
end
_title!(c, p, title) = isempty(title) || _text!(c, p.x0 + p.w / 2, p.y0 - 16, title; size = 15, color = _col(c.col["primary"]),
                                               anchor = "middle", weight = "bold")

function _r_range(lo, hi)     # yaxs = "r": 4 % Rand
    if lo == hi
        return lo == 0 ? (lo - 1, hi + 1) : (lo - 0.4 * abs(lo), hi + 0.4 * abs(hi))
    end
    d = (hi - lo) * 0.04
    return (lo - d, hi + d)
end

function _empty_panel!(c, p, title)
    _title!(c, p, title)
    _text!(c, p.x0 + p.w / 2, p.y0 + p.h / 2, "Zu wenige Daten"; size = 12, color = _col(c.col["neutral"]), anchor = "middle")
end

function _yaxis(lo, hi)
    t = r_pretty(lo, hi)
    return t, [r_format1(v) for v in t]
end

# ═════════════════════════════════════════════════════════════════════════════
# 5. Stil Analysegrafiken (`_ana_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevAnalysis>) (result_analysis), plot(<SimLevSignalAnalysis>) und
# plot(<SimLevHeatmap>) (analysis_tests), plot(<SimLevGoalPlan>) (planning): Zeichenfläche
# `_AnaSvg` mit Feldern `_ana_panel` (Rand 60/30 px, log. y-Achse möglich), Koordinaten
# `string(round(v; digits = 2))` (`_ana_n`), Schrift sans-serif.

"Einfache SVG-Zeichenfläche mit Feldern (Panels) in Benutzerkoordinaten."
mutable struct _AnaSvg
    w::Float64
    h::Float64
    buf::IOBuffer
end
_AnaSvg(w = 900, h = 560) = (s = _AnaSvg(Float64(w), Float64(h), IOBuffer());
    print(s.buf, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$(Int(w))\" height=\"$(Int(h))\" viewBox=\"0 0 $(Int(w)) $(Int(h))\" font-family=\"sans-serif\">\n<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n");
    s)
_ana_n(v) = isfinite(v) ? string(round(v; digits = 2)) : "0"

"`log10(max(v, 1e-300))` (NaN bleibt NaN)."
_ana_lg(v) = log10(max(v, 1e-300))

"Feld: Pixelrechteck (x0, y0, w, h) und Wertebereiche; `logy` = logarithmische y-Achse."
struct _AnaPanel
    x0::Float64; y0::Float64; w::Float64; h::Float64
    xr::Tuple{Float64,Float64}; yr::Tuple{Float64,Float64}
    logy::Bool
end
function _ana_panel(s::_AnaSvg, x0, y0, w, h, xr, yr; logy = false, title = "", xlab = "", ylab = "",
                    xticks = nothing, xlabels = nothing, yticks = nothing, ylabels = nothing, box = true)
    xr = _ana_fixr(xr); yr = logy ? (_ana_lg(yr[1]), _ana_lg(yr[2])) : yr
    yr = _ana_fixr(yr)
    p = _AnaPanel(x0 + 60, y0 + 30, w - 75, h - 70, xr, yr, logy)
    box && print(s.buf, "<rect x=\"$(_ana_n(p.x0))\" y=\"$(_ana_n(p.y0))\" width=\"$(_ana_n(p.w))\" height=\"$(_ana_n(p.h))\" fill=\"none\" stroke=\"#333\"/>\n")
    isempty(title) || print(s.buf, "<text x=\"$(_ana_n(p.x0 + p.w / 2))\" y=\"$(_ana_n(y0 + 18))\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"bold\">$(_esc(title))</text>\n")
    isempty(xlab) || print(s.buf, "<text x=\"$(_ana_n(p.x0 + p.w / 2))\" y=\"$(_ana_n(p.y0 + p.h + 34))\" text-anchor=\"middle\" font-size=\"11\">$(_esc(xlab))</text>\n")
    isempty(ylab) || print(s.buf, "<text x=\"$(_ana_n(x0 + 12))\" y=\"$(_ana_n(p.y0 + p.h / 2))\" text-anchor=\"middle\" font-size=\"11\" transform=\"rotate(-90 $(_ana_n(x0 + 12)) $(_ana_n(p.y0 + p.h / 2)))\">$(_esc(ylab))</text>\n")
    xt = xticks === nothing ? _ana_pretty(xr) : xticks
    xl = xlabels === nothing ? [_ana_tick_lab(v) for v in xt] : xlabels
    for (v, l) in zip(xt, xl)
        px = _ana_px(p, v)
        print(s.buf, "<text x=\"$(_ana_n(px))\" y=\"$(_ana_n(p.y0 + p.h + 14))\" text-anchor=\"middle\" font-size=\"9\">$(_esc(l))</text>\n")
    end
    yt = yticks === nothing ? _ana_pretty(yr) : yticks
    yl = ylabels === nothing ? [_ana_tick_lab(logy ? 10.0^v : v) for v in yt] : ylabels
    for (v, l) in zip(yt, yl)
        py = p.y0 + p.h - (v - p.yr[1]) / (p.yr[2] - p.yr[1]) * p.h
        print(s.buf, "<text x=\"$(_ana_n(p.x0 - 4))\" y=\"$(_ana_n(py + 3))\" text-anchor=\"end\" font-size=\"9\">$(_esc(l))</text>\n")
    end
    p
end
_ana_fixr(r) = (a = Float64(r[1]); b = Float64(r[2]); (!isfinite(a) || !isfinite(b)) ? (0.0, 1.0) : a == b ? (a - 0.5, b + 0.5) : (a, b))
function _ana_pretty(r; n = 5)
    a, b = r
    d = (b - a) / n
    m = 10.0^floor(log10(d)); f = d / m
    st = (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * m
    collect(ceil(a / st) * st:st:b)
end
_ana_tick_lab(v) = abs(v) >= 1e5 || (abs(v) < 1e-3 && v != 0) ? string(round(v; sigdigits = 3)) :
                   (v == round(v) ? string(Int(round(v))) : string(round(v; sigdigits = 4)))
_ana_px(p::_AnaPanel, x) = p.x0 + (x - p.xr[1]) / (p.xr[2] - p.xr[1]) * p.w
_ana_py(p::_AnaPanel, y) = (yy = p.logy ? _ana_lg(y) : y; p.y0 + p.h - (yy - p.yr[1]) / (p.yr[2] - p.yr[1]) * p.h)
_ana_polyline_txt(col, lwd, dash, pts) = "<polyline fill=\"none\" stroke=\"$col\" stroke-width=\"$lwd\"$(isempty(dash) ? "" : " stroke-dasharray=\"$dash\"") points=\"$(join(pts, " "))\"/>\n"
function _ana_lines(s::_AnaSvg, p::_AnaPanel, x, y; col = "#000", lwd = 1.2, dash = "")
    pts = String[]
    for (a, b) in zip(x, y)
        if isfinite(a) && isfinite(b)
            push!(pts, _ana_n(_ana_px(p, a)) * "," * _ana_n(_ana_py(p, b)))
        elseif !isempty(pts)
            print(s.buf, _ana_polyline_txt(col, lwd, dash, pts))
            empty!(pts)
        end
    end
    isempty(pts) || print(s.buf, _ana_polyline_txt(col, lwd, dash, pts))
end
_ana_hline(s::_AnaSvg, p::_AnaPanel, y; col = "grey", dash = "3,3") = _ana_lines(s, p, [p.xr[1], p.xr[2]], [y, y]; col = col, lwd = 1, dash = dash)
function _ana_rect(s::_AnaSvg, p::_AnaPanel, x1, y1, x2, y2; fill = "#2C6E9B")
    a = _ana_px(p, x1); b = _ana_px(p, x2); c = _ana_py(p, y1); d = _ana_py(p, y2)
    print(s.buf, "<rect x=\"$(_ana_n(min(a, b)))\" y=\"$(_ana_n(min(c, d)))\" width=\"$(_ana_n(abs(b - a)))\" height=\"$(_ana_n(abs(d - c)))\" fill=\"$fill\"/>\n")
end
function _ana_text(s::_AnaSvg, p::_AnaPanel, x, y, t; size = 8, anchor = "middle")
    print(s.buf, "<text x=\"$(_ana_n(_ana_px(p, x)))\" y=\"$(_ana_n(_ana_py(p, y) + size / 3))\" text-anchor=\"$anchor\" font-size=\"$size\">$(_esc(t))</text>\n")
end
function _ana_points(s::_AnaSvg, p::_AnaPanel, x, y; col = "#2C6E9B", r = 1.5, opacity = 0.4)
    for (a, b) in zip(x, y)
        (isfinite(a) && isfinite(b)) || continue
        print(s.buf, "<circle cx=\"$(_ana_n(_ana_px(p, a)))\" cy=\"$(_ana_n(_ana_py(p, b)))\" r=\"$r\" fill=\"$col\" fill-opacity=\"$opacity\"/>\n")
    end
end
function _ana_legend(s::_AnaSvg, p::_AnaPanel, labels, cols; x = nothing, y = nothing, box = false)
    lx = x === nothing ? p.x0 + 8 : x; ly = y === nothing ? p.y0 + 14 : y
    for (i, (l, c)) in enumerate(zip(labels, cols))
        yy = ly + (i - 1) * 13
        if box
            print(s.buf, "<rect x=\"$(_ana_n(lx))\" y=\"$(_ana_n(yy - 8))\" width=\"10\" height=\"10\" fill=\"$c\"/>\n")
        else
            print(s.buf, "<line x1=\"$(_ana_n(lx))\" y1=\"$(_ana_n(yy - 3))\" x2=\"$(_ana_n(lx + 16))\" y2=\"$(_ana_n(yy - 3))\" stroke=\"$c\" stroke-width=\"2\"/>\n")
        end
        print(s.buf, "<text x=\"$(_ana_n(lx + 20))\" y=\"$(_ana_n(yy))\" font-size=\"10\">$(_esc(l))</text>\n")
    end
end
"Farbverlauf wie `colorRampPalette(cols)(n)`."
function _ana_ramp(cols::Vector{String}, n::Int)
    rgb = [(parse(Int, c[2:3]; base = 16), parse(Int, c[4:5]; base = 16), parse(Int, c[6:7]; base = 16)) for c in cols]
    n == 1 && return [cols[1]]
    out = String[]
    for i in 0:n-1
        t = i / (n - 1) * (length(cols) - 1)
        k = min(Int(floor(t)) + 1, length(cols) - 1); f = t - (k - 1)
        c = ntuple(j -> round(Int, rgb[k][j] + f * (rgb[k+1][j] - rgb[k][j])), 3)
        push!(out, "#" * join(string.(c; base = 16, pad = 2)))
    end
    out
end
"SVG abschließen; Text zurück, mit `file` zusätzlich in die Datei geschrieben."
function _ana_svg_done(s::_AnaSvg, file)
    print(s.buf, "</svg>\n")
    txt = String(take!(s.buf))
    file === nothing && return txt
    write(file, txt)
    txt
end

"Jahresmarken für eine Zeitachse (Tage seit 1970): Positionen und Beschriftungen."
function _ana_year_ticks(days)
    a = from_days(Int(minimum(days))); b = from_days(Int(maximum(days)))
    ys = Dates.year(a):Dates.year(b)
    step = max(1, ceil(Int, length(ys) / 8))
    t = Float64[]; l = String[]
    for y in ys[1]:step:ys[end]
        d = Float64(days_from_civil(y, 1, 1))
        d >= to_days(a) && d <= to_days(b) && (push!(t, d); push!(l, string(y)))
    end
    if isempty(t)
        t = [Float64(to_days(a))]; l = [_fmt_day(to_days(a))]
    end
    t, l
end

# ═════════════════════════════════════════════════════════════════════════════
# 6. Stil Rastergrafiken (`_grid_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevDependence>), plot(<SimLevTailRegression>), plot(<SimLevCoVaR>) (dependence),
# plot(<SimLevHMM>) (regimes): Felder `_GridBox` im Raster (`_grid_svg`), Achsen mit
# `_grid_axes`, Koordinaten `@sprintf("%.1f")` (`_grid_c`).

_grid_c(x) = @sprintf("%.1f", x)

struct _GridBox
    x0::Float64; y0::Float64; w::Float64; h::Float64
end

function _grid_svg(keys, makefn; ncol = 2, file = nothing, width = 900, height = 650)
    n = length(keys)
    nc = n == 1 ? 1 : min(ncol, n)
    nr = cld(n, nc)
    io = IOBuffer()
    println(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\" ",
            "font-family=\"Helvetica, Arial, sans-serif\">")
    println(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>")
    cw = width / nc; ch = height / nr
    for (k, key) in enumerate(keys)
        r = div(k - 1, nc); cidx = (k - 1) % nc
        box = _GridBox(cidx * cw + 60, r * ch + 40, cw - 85, ch - 85)
        makefn(key)(io, box)
    end
    println(io, "</svg>")
    d = SimLevPlot(String(take!(io)))
    file === nothing || write(String(file), d.svg)
    d
end

function _grid_range(vals, lim)
    lim !== nothing && return Float64(lim[1]), Float64(lim[2])
    v = filter(isfinite, vals)
    isempty(v) && return 0.0, 1.0
    lo, hi = minimum(v), maximum(v)
    lo == hi && (lo -= 0.5; hi += 0.5)
    pad = (hi - lo) * 0.04
    lo - pad, hi + pad
end

_grid_tx(b::_GridBox, x, lo, hi) = b.x0 + (x - lo) / (hi - lo) * b.w
_grid_ty(b::_GridBox, y, lo, hi) = b.y0 + b.h - (y - lo) / (hi - lo) * b.h

function _grid_ticks(lo, hi; n = 5)
    span = hi - lo
    span <= 0 && return [lo]
    step = 10.0^floor(log10(span / n))
    for m in (1, 2, 5, 10)
        span / (m * step) <= n && (step *= m; break)
    end
    t0 = ceil(lo / step) * step
    collect(t0:step:hi)
end

_grid_tick_lab(t) = @sprintf("%g", round(t; sigdigits = 6))

function _grid_axes!(io, b::_GridBox, xlo, xhi, ylo, yhi; title = "", xlabel = "", ylabel = "", dates = false, xticks = nothing)
    println(io, "<rect x=\"$(_grid_c(b.x0))\" y=\"$(_grid_c(b.y0))\" width=\"$(_grid_c(b.w))\" height=\"$(_grid_c(b.h))\" fill=\"none\" stroke=\"#444\"/>")
    for t in _grid_ticks(ylo, yhi)
        y = _grid_ty(b, t, ylo, yhi)
        println(io, "<line x1=\"$(_grid_c(b.x0 - 4))\" y1=\"$(_grid_c(y))\" x2=\"$(_grid_c(b.x0))\" y2=\"$(_grid_c(y))\" stroke=\"#444\"/>")
        println(io, "<text x=\"$(_grid_c(b.x0 - 6))\" y=\"$(_grid_c(y + 3))\" font-size=\"10\" text-anchor=\"end\">$(_esc(_grid_tick_lab(t)))</text>")
    end
    xt = if xticks !== nothing
        xticks
    elseif dates
        y0 = Dates.year(from_days(Int(floor(xlo)))); y1 = Dates.year(from_days(Int(floor(xhi))))
        st = max(1, cld(y1 - y0 + 1, 8))
        [(Float64(days_from_civil(y, 1, 1)), string(y)) for y in y0:st:(y1+1) if xlo <= days_from_civil(y, 1, 1) <= xhi]
    else
        [(t, _grid_tick_lab(t)) for t in _grid_ticks(xlo, xhi)]
    end
    for (t, l) in xt
        x = _grid_tx(b, t, xlo, xhi)
        println(io, "<line x1=\"$(_grid_c(x))\" y1=\"$(_grid_c(b.y0 + b.h))\" x2=\"$(_grid_c(x))\" y2=\"$(_grid_c(b.y0 + b.h + 4))\" stroke=\"#444\"/>")
        println(io, "<text x=\"$(_grid_c(x))\" y=\"$(_grid_c(b.y0 + b.h + 15))\" font-size=\"10\" text-anchor=\"middle\">$(_esc(l))</text>")
    end
    isempty(title) || println(io, "<text x=\"$(_grid_c(b.x0 + b.w / 2))\" y=\"$(_grid_c(b.y0 - 10))\" font-size=\"13\" font-weight=\"bold\" text-anchor=\"middle\">$(_esc(title))</text>")
    isempty(xlabel) || println(io, "<text x=\"$(_grid_c(b.x0 + b.w / 2))\" y=\"$(_grid_c(b.y0 + b.h + 32))\" font-size=\"11\" text-anchor=\"middle\">$(_esc(xlabel))</text>")
    isempty(ylabel) || println(io, "<text x=\"$(_grid_c(b.x0 - 45))\" y=\"$(_grid_c(b.y0 + b.h / 2))\" font-size=\"11\" text-anchor=\"middle\" " *
                               "transform=\"rotate(-90 $(_grid_c(b.x0 - 45)) $(_grid_c(b.y0 + b.h / 2)))\">$(_esc(ylabel))</text>")
end

function _grid_hline!(io, b, y, xlo, xhi, ylo, yhi, col)
    (isfinite(y) && ylo <= y <= yhi) || return
    yy = _grid_ty(b, y, ylo, yhi)
    println(io, "<line x1=\"$(_grid_c(b.x0))\" y1=\"$(_grid_c(yy))\" x2=\"$(_grid_c(b.x0 + b.w))\" y2=\"$(_grid_c(yy))\" stroke=\"$col\" stroke-dasharray=\"4 3\"/>")
end

function _grid_legend!(io, b, items)
    for (k, (lab, col)) in enumerate(items)
        y = b.y0 + 12 + 13 * (k - 1)
        println(io, "<line x1=\"$(_grid_c(b.x0 + 8))\" y1=\"$(_grid_c(y))\" x2=\"$(_grid_c(b.x0 + 24))\" y2=\"$(_grid_c(y))\" stroke=\"$col\" stroke-width=\"2\"/>")
        println(io, "<text x=\"$(_grid_c(b.x0 + 28))\" y=\"$(_grid_c(y + 3))\" font-size=\"9\">$(_esc(lab))</text>")
    end
end

"Linien (Reihen `(x, y, Farbe, Name)`), optional Band `(x, lo, hi)`, Punkte und waagrechte Linien."
function _grid_lines!(io, b::_GridBox, series; ylim = nothing, hline = Tuple{Float64,String}[], dates = false, title = "",
                      xlabel = "", ylabel = "", points = false, band = nothing, xticks = nothing)
    allx = reduce(vcat, [Float64.(s[1]) for s in series]; init = Float64[])
    ally = reduce(vcat, [Float64.(s[2]) for s in series]; init = Float64[])
    band !== nothing && (ally = vcat(ally, band[2], band[3]))
    ally = vcat(ally, Float64[h[1] for h in hline])
    xlo, xhi = _grid_range(allx, nothing); ylo, yhi = _grid_range(ally, ylim)
    _grid_axes!(io, b, xlo, xhi, ylo, yhi; title = title, xlabel = xlabel, ylabel = ylabel, dates = dates, xticks = xticks)
    if band !== nothing
        bx, blo, bhi = band
        pts = vcat([(_grid_tx(b, bx[i], xlo, xhi), _grid_ty(b, blo[i], ylo, yhi)) for i in eachindex(bx) if isfinite(blo[i])],
                   reverse([(_grid_tx(b, bx[i], xlo, xhi), _grid_ty(b, bhi[i], ylo, yhi)) for i in eachindex(bx) if isfinite(bhi[i])]))
        isempty(pts) || println(io, "<polygon points=\"$(join(["$(_grid_c(p[1])),$(_grid_c(p[2]))" for p in pts], " "))\" fill=\"#2C6E9B\" fill-opacity=\"0.15\"/>")
    end
    for h in hline
        _grid_hline!(io, b, h[1], xlo, xhi, ylo, yhi, h[2])
    end
    for (xs, ys, col, _) in series
        d = IOBuffer(); first = true
        for (x, y) in zip(xs, ys)
            if !isfinite(y)
                first = true; continue
            end
            print(d, first ? "M" : "L", _grid_c(_grid_tx(b, x, xlo, xhi)), " ", _grid_c(_grid_ty(b, clamp(y, ylo, yhi), ylo, yhi)))
            first = false
        end
        println(io, "<path d=\"$(String(take!(d)))\" fill=\"none\" stroke=\"$col\" stroke-width=\"1.4\"/>")
        if points
            for (x, y) in zip(xs, ys)
                isfinite(y) && println(io, "<circle cx=\"$(_grid_c(_grid_tx(b, x, xlo, xhi)))\" cy=\"$(_grid_c(_grid_ty(b, y, ylo, yhi)))\" r=\"2.5\" fill=\"$col\"/>")
            end
        end
    end
    _grid_legend!(io, b, [(s[4], s[3]) for s in series])
end

"Balken mit optionalen Intervallen `lo`/`hi` und Punkten `pts`."
function _grid_bars!(io, b::_GridBox, labels, vals; lo = nothing, hi = nothing, pts = nothing, ylim = nothing, title = "", ylabel = "")
    n = length(vals)
    ylo, yhi = _grid_range(vals, ylim)
    _grid_axes!(io, b, 0.0, Float64(n), ylo, yhi; title = title, ylabel = ylabel, xticks = [(k - 0.5, String(labels[k])) for k in 1:n])
    _grid_hline!(io, b, 0.0, 0.0, n, ylo, yhi, "#666")
    z = _grid_ty(b, clamp(0.0, ylo, yhi), ylo, yhi)
    for k in 1:n
        isfinite(vals[k]) || continue
        x = _grid_tx(b, k - 0.8, 0.0, n); w = _grid_tx(b, k - 0.2, 0.0, n) - x
        y = _grid_ty(b, clamp(vals[k], ylo, yhi), ylo, yhi)
        println(io, "<rect x=\"$(_grid_c(x))\" y=\"$(_grid_c(min(y, z)))\" width=\"$(_grid_c(w))\" height=\"$(_grid_c(abs(z - y)))\" fill=\"#2C6E9B\"/>")
        if lo !== nothing && isfinite(lo[k]) && isfinite(hi[k])
            xm = _grid_tx(b, k - 0.5, 0.0, n)
            println(io, "<line x1=\"$(_grid_c(xm))\" y1=\"$(_grid_c(_grid_ty(b, lo[k], ylo, yhi)))\" x2=\"$(_grid_c(xm))\" y2=\"$(_grid_c(_grid_ty(b, hi[k], ylo, yhi)))\" stroke=\"black\"/>")
        end
        if pts !== nothing && isfinite(pts[k])
            println(io, "<circle cx=\"$(_grid_c(_grid_tx(b, k - 0.5, 0.0, n)))\" cy=\"$(_grid_c(_grid_ty(b, pts[k], ylo, yhi)))\" r=\"3\" fill=\"#B5562B\"/>")
        end
    end
end

"Streudiagramm mit Farben je Punkt und Rechtecken `(x0, y0, x1, y1, Farbe)`."
function _grid_scatter!(io, b::_GridBox, x, y, cols; rects = (), xlabel = "", ylabel = "", title = "")
    xlo, xhi = _grid_range(x, nothing); ylo, yhi = _grid_range(y, nothing)
    _grid_axes!(io, b, xlo, xhi, ylo, yhi; title = title, xlabel = xlabel, ylabel = ylabel)
    for i in eachindex(x)
        (isfinite(x[i]) && isfinite(y[i])) || continue
        println(io, "<circle cx=\"$(_grid_c(_grid_tx(b, x[i], xlo, xhi)))\" cy=\"$(_grid_c(_grid_ty(b, y[i], ylo, yhi)))\" r=\"1.6\" fill=\"$(cols[i])\"/>")
    end
    for (a0, b0, a1, b1, col) in rects
        X0 = _grid_tx(b, a0, xlo, xhi); X1 = _grid_tx(b, a1, xlo, xhi); Y0 = _grid_ty(b, b1, ylo, yhi); Y1 = _grid_ty(b, b0, ylo, yhi)
        println(io, "<rect x=\"$(_grid_c(X0))\" y=\"$(_grid_c(Y0))\" width=\"$(_grid_c(X1 - X0))\" height=\"$(_grid_c(Y1 - Y0))\" fill=\"none\" stroke=\"$col\"/>")
    end
end

# ═════════════════════════════════════════════════════════════════════════════
# 7. Stil Ergebnisgrafiken (`_res_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevPBO>), plot(<SimLevWalkForward>) (overfitting), plot(<SimLevParamSearch>)
# (param_search), plot(<SimLevSensitivity>) (sensitivity): Abbildung `_ResFig` mit Panels
# `_ResPanel` (Gitterlinien, log. y-Achse möglich), Koordinaten `string(round(x; digits = 1))`
# (`_res_c`).

mutable struct _ResFig
    io::IOBuffer
    w::Float64
    h::Float64
end
struct _ResPanel
    x0::Float64; y0::Float64; w::Float64; h::Float64
    xlo::Float64; xhi::Float64; ylo::Float64; yhi::Float64
    logy::Bool
end
_res_c(x) = string(round(Float64(x); digits = 1))
function _res_fig(w = 720, h = 420)
    f = _ResFig(IOBuffer(), w, h)
    print(f.io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$w\" height=\"$h\" viewBox=\"0 0 $w $h\" ",
          "font-family=\"Helvetica, Arial, sans-serif\">\n<rect width=\"$w\" height=\"$h\" fill=\"white\"/>\n")
    f
end
"SVG abschließen; liefert den Text (für `(svg, data)` an `_plot_method`)."
function _res_finish(f::_ResFig; file = nothing)
    print(f.io, "</svg>\n")
    svg = String(take!(f.io))
    file === nothing || write(String(file), svg)
    svg
end
_res_svg!(f::_ResFig, s) = print(f.io, s, "\n")
_res_text!(f, x, y, s; size = 11, anchor = "middle", color = "#222", rot = 0, weight = "normal") =
    _res_svg!(f, "<text x=\"$(_res_c(x))\" y=\"$(_res_c(y))\" font-size=\"$size\" text-anchor=\"$anchor\" fill=\"$color\" font-weight=\"$weight\"" *
                 (rot != 0 ? " transform=\"rotate($rot $(_res_c(x)) $(_res_c(y)))\"" : "") * ">$(_esc(s))</text>")
_res_tx(p::_ResPanel, x) = p.x0 + (x - p.xlo) / (p.xhi == p.xlo ? 1.0 : p.xhi - p.xlo) * p.w
_res_yv(p::_ResPanel, y) = p.logy ? log10(y) : y
_res_ty(p::_ResPanel, y) = p.y0 + p.h - (_res_yv(p, y) - p.ylo) / (p.yhi == p.ylo ? 1.0 : p.yhi - p.ylo) * p.h
function _res_ticks(lo, hi; n = 5)
    (isfinite(lo) && isfinite(hi)) || return Float64[]
    hi == lo && return [lo]
    raw = (hi - lo) / n
    mag = 10.0^floor(log10(raw))
    st = raw / mag
    step = (st < 1.5 ? 1 : st < 3 ? 2 : st < 7 ? 5 : 10) * mag
    t0 = ceil(lo / step) * step
    return [t for t in t0:step:hi + step * 1e-9]
end
_res_tick_lab(v) = (a = abs(v); a == 0 ? "0" : a >= 1e4 || a < 1e-3 ? string(round(v; sigdigits = 3)) : string(round(v; sigdigits = 4)))
function _res_range(v)
    w = filter(isfinite, Float64.(collect(v)))
    isempty(w) && return (0.0, 1.0)
    lo, hi = extrema(w)
    lo == hi && return (lo - 0.5, hi + 0.5)
    pad = 0.04 * (hi - lo)
    return (lo - pad, hi + pad)
end
"Panel mit Achsen, Titel und Beschriftungen."
function _res_panel(f::_ResFig, x0, y0, w, h, xlim, ylim; title = "", xlab = "", ylab = "", logy = false,
                    xticks = nothing, xticklabels = nothing, yticks = nothing, yticklabels = nothing, grid = true)
    ylo, yhi = logy ? (log10(ylim[1]), log10(ylim[2])) : ylim
    p = _ResPanel(x0, y0, w, h, xlim[1], xlim[2], ylo, yhi, logy)
    _res_svg!(f, "<rect x=\"$(_res_c(x0))\" y=\"$(_res_c(y0))\" width=\"$(_res_c(w))\" height=\"$(_res_c(h))\" fill=\"none\" stroke=\"#555\"/>")
    xt = xticks === nothing ? _res_ticks(xlim...) : xticks
    for (i, t) in enumerate(xt)
        X = _res_tx(p, t)
        grid && _res_svg!(f, "<line x1=\"$(_res_c(X))\" y1=\"$(_res_c(y0))\" x2=\"$(_res_c(X))\" y2=\"$(_res_c(y0 + h))\" stroke=\"#e6e6e6\"/>")
        _res_text!(f, X, y0 + h + 14, xticklabels === nothing ? _res_tick_lab(t) : xticklabels[i]; size = 9)
    end
    yt = yticks === nothing ? (logy ? [10.0^k for k in floor(ylo):ceil(yhi) if ylo <= k <= yhi] : _res_ticks(ylim...)) : yticks
    logy && length(yt) < 2 && (yt = [ylim[1], ylim[2]])
    for (i, t) in enumerate(yt)
        Y = _res_ty(p, t)
        grid && _res_svg!(f, "<line x1=\"$(_res_c(x0))\" y1=\"$(_res_c(Y))\" x2=\"$(_res_c(x0 + w))\" y2=\"$(_res_c(Y))\" stroke=\"#e6e6e6\"/>")
        _res_text!(f, x0 - 5, Y + 3, yticklabels === nothing ? _res_tick_lab(t) : yticklabels[i]; size = 9, anchor = "end")
    end
    isempty(title) || _res_text!(f, x0 + w / 2, y0 - 10, title; size = 13, weight = "bold")
    isempty(xlab) || _res_text!(f, x0 + w / 2, y0 + h + 32, xlab; size = 11)
    isempty(ylab) || _res_text!(f, x0 - 42, y0 + h / 2, ylab; size = 11, rot = -90)
    p
end
function _res_line!(f, p::_ResPanel, xs, ys; color = "#2C6E9B", width = 1.5, dash = "")
    io = IOBuffer(); first = true
    for (x, y) in zip(xs, ys)
        ok = isfinite(x) && isfinite(y) && (!p.logy || y > 0)
        ok || (first = true; continue)
        print(io, first ? "M" : "L", _res_c(_res_tx(p, x)), " ", _res_c(_res_ty(p, y)))
        first = false
    end
    s = String(take!(io))
    isempty(s) || _res_svg!(f, "<path d=\"$s\" fill=\"none\" stroke=\"$color\" stroke-width=\"$width\"" *
                             (isempty(dash) ? "" : " stroke-dasharray=\"$dash\"") * "/>")
end
function _res_points!(f, p::_ResPanel, xs, ys; color = "#2C6E9B", r = 3, opacity = 1.0)
    for (i, (x, y)) in enumerate(zip(xs, ys))
        (isfinite(x) && isfinite(y)) || continue
        col = color isa AbstractVector ? color[i] : color
        _res_svg!(f, "<circle cx=\"$(_res_c(_res_tx(p, x)))\" cy=\"$(_res_c(_res_ty(p, y)))\" r=\"$r\" fill=\"$col\" fill-opacity=\"$opacity\"/>")
    end
end
_res_vline!(f, p::_ResPanel, x; color = "#B5562B", width = 2, dash = "") = isfinite(x) &&
    _res_svg!(f, "<line x1=\"$(_res_c(_res_tx(p, x)))\" y1=\"$(_res_c(p.y0))\" x2=\"$(_res_c(_res_tx(p, x)))\" y2=\"$(_res_c(p.y0 + p.h))\" stroke=\"$color\" stroke-width=\"$width\"" *
                 (isempty(dash) ? "" : " stroke-dasharray=\"$dash\"") * "/>")
_res_hline!(f, p::_ResPanel, y; color = "grey", width = 1, dash = "2,3") = isfinite(y) &&
    _res_svg!(f, "<line x1=\"$(_res_c(p.x0))\" y1=\"$(_res_c(_res_ty(p, y)))\" x2=\"$(_res_c(p.x0 + p.w))\" y2=\"$(_res_c(_res_ty(p, y)))\" stroke=\"$color\" stroke-width=\"$width\"" *
                 (isempty(dash) ? "" : " stroke-dasharray=\"$dash\"") * "/>")
function _res_abline!(f, p::_ResPanel, a, b; color = "#B5562B", width = 2)
    (isfinite(a) && isfinite(b)) || return
    _res_line!(f, p, [p.xlo, p.xhi], [a + b * p.xlo, a + b * p.xhi]; color = color, width = width)
end
function _res_rect!(f, p::_ResPanel, x1, y1, x2, y2; fill = "#2C6E9B", stroke = "none")
    X1, X2 = minmax(_res_tx(p, x1), _res_tx(p, x2)); Y1, Y2 = minmax(_res_ty(p, y1), _res_ty(p, y2))
    _res_svg!(f, "<rect x=\"$(_res_c(X1))\" y=\"$(_res_c(Y1))\" width=\"$(_res_c(X2 - X1))\" height=\"$(_res_c(Y2 - Y1))\" fill=\"$fill\" stroke=\"$stroke\"/>")
end
function _res_legend!(f, x, y, labels, colors)
    for (i, (l, c)) in enumerate(zip(labels, colors))
        Y = y + (i - 1) * 15
        _res_svg!(f, "<line x1=\"$(_res_c(x))\" y1=\"$(_res_c(Y))\" x2=\"$(_res_c(x + 18))\" y2=\"$(_res_c(Y))\" stroke=\"$c\" stroke-width=\"2\"/>")
        _res_text!(f, x + 24, Y + 4, l; size = 10, anchor = "start")
    end
end
"Farbverlauf wie `colorRampPalette(c(\"#B5562B\", \"#F2E9DC\", \"#2C6E9B\"))(64)`."
function _res_ramp(t)
    a = (0xB5, 0x56, 0x2B) .% Int; b = (0xF2, 0xE9, 0xDC) .% Int; c = (0x2C, 0x6E, 0x9B) .% Int   # Int: UInt8-Differenzen liefen über
    t = clamp(t, 0.0, 1.0)
    u, v, s = t < 0.5 ? (a, b, 2t) : (b, c, 2t - 1)
    rgb = [round(Int, u[i] + (v[i] - u[i]) * s) for i in 1:3]
    return "#" * join(string.(rgb; base = 16, pad = 2))
end

# ═════════════════════════════════════════════════════════════════════════════
# 8. Stil Rückrechnung (`_bc_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevBackcastFit>), plot(<SimLevBackcast>) (backcast): Liniendiagramme mit fünf
# gleichmäßigen Achsenmarken (`%g`, Datum), Zahlen mit `string(x)`.

"Wie `_esc`, aber ohne `\"` (Anführungszeichen bleiben)."
_bc_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

"""
    _bc_panel(io, series; x0, y0, w, h, title, xlab, ylab, logy = false, hlines = [], vlines = [])

Ein Liniendiagramm in ein SVG schreiben. `series`: Vektor aus
`(x::Vector{Float64}, y::Vector{Float64}, farbe, linienbreite, strich)`.
"""
function _bc_panel(io, series; x0 = 0, y0 = 0, w = 720, h = 360, title = "", xlab = "", ylab = "",
                   logy = false, hlines = Float64[], vlines = Float64[], xdate = false, legend = Tuple{String,String}[])
    ml, mr, mt, mb = 70, 15, 30, 45
    xs = Float64[]; ys = Float64[]
    for s in series
        for (a, b) in zip(s[1], s[2])
            (isfinite(a) && isfinite(b) && (!logy || b > 0)) && (push!(xs, a); push!(ys, logy ? log10(b) : b))
        end
    end
    isempty(xs) && (xs = [0.0, 1.0]; ys = [0.0, 1.0])
    xlo, xhi = extrema(xs); ylo, yhi = extrema(ys)
    for v in hlines
        yv = logy ? log10(v) : v
        ylo = min(ylo, yv); yhi = max(yhi, yv)
    end
    xhi == xlo && (xhi = xlo + 1); yhi == ylo && (yhi = ylo + 1)
    pad = 0.04 * (yhi - ylo); ylo -= pad; yhi += pad
    px(a) = x0 + ml + (a - xlo) / (xhi - xlo) * (w - ml - mr)
    py(b) = y0 + mt + (yhi - b) / (yhi - ylo) * (h - mt - mb)
    print(io, "<rect x=\"$(x0 + ml)\" y=\"$(y0 + mt)\" width=\"$(w - ml - mr)\" height=\"$(h - mt - mb)\" fill=\"none\" stroke=\"#333\"/>\n")
    print(io, "<text x=\"$(x0 + w / 2)\" y=\"$(y0 + 18)\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"bold\">$(_bc_esc(title))</text>\n")
    print(io, "<text x=\"$(x0 + w / 2)\" y=\"$(y0 + h - 8)\" text-anchor=\"middle\" font-size=\"12\">$(_bc_esc(xlab))</text>\n")
    print(io, "<text x=\"$(x0 + 14)\" y=\"$(y0 + h / 2)\" text-anchor=\"middle\" font-size=\"12\" transform=\"rotate(-90 $(x0 + 14) $(y0 + h / 2))\">$(_bc_esc(ylab))</text>\n")
    for k in 0:4
        yv = ylo + k / 4 * (yhi - ylo)
        lab = logy ? SimLev.DataPrep._sprintf("%g", 10.0^yv) : SimLev.DataPrep._sprintf("%g", yv)
        print(io, "<text x=\"$(x0 + ml - 4)\" y=\"$(py(yv) + 4)\" text-anchor=\"end\" font-size=\"10\">$(lab)</text>\n")
        xv = xlo + k / 4 * (xhi - xlo)
        xl = xdate ? SimLev.DataPrep._date_str(xv) : SimLev.DataPrep._sprintf("%g", xv)
        print(io, "<text x=\"$(px(xv))\" y=\"$(y0 + h - mb + 14)\" text-anchor=\"middle\" font-size=\"10\">$(xl)</text>\n")
    end
    for v in hlines
        yv = logy ? log10(v) : v
        print(io, "<line x1=\"$(px(xlo))\" x2=\"$(px(xhi))\" y1=\"$(py(yv))\" y2=\"$(py(yv))\" stroke=\"#7f7f7f\" stroke-dasharray=\"5,4\"/>\n")
    end
    for v in vlines
        print(io, "<line x1=\"$(px(v))\" x2=\"$(px(v))\" y1=\"$(y0 + mt)\" y2=\"$(y0 + h - mb)\" stroke=\"#666\" stroke-dasharray=\"2,3\"/>\n")
    end
    for (sx, sy, col, lw) in series
        pts = String[]
        for (a, b) in zip(sx, sy)
            if isfinite(a) && isfinite(b) && (!logy || b > 0)
                push!(pts, string(round(px(a); digits = 2), ",", round(py(logy ? log10(b) : b); digits = 2)))
            end
        end
        isempty(pts) || print(io, "<polyline fill=\"none\" stroke=\"$(col)\" stroke-width=\"$(lw)\" points=\"$(join(pts, " "))\"/>\n")
    end
    for (i, (lab, col)) in enumerate(legend)
        yy = y0 + mt + 14 * i
        print(io, "<line x1=\"$(x0 + ml + 8)\" x2=\"$(x0 + ml + 28)\" y1=\"$(yy - 4)\" y2=\"$(yy - 4)\" stroke=\"$(col)\" stroke-width=\"1.5\"/>\n")
        print(io, "<text x=\"$(x0 + ml + 32)\" y=\"$(yy)\" font-size=\"11\">$(_bc_esc(lab))</text>\n")
    end
end

function _bc_doc(f, w, h, file)
    io = IOBuffer()
    print(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$(w)\" height=\"$(h)\" viewBox=\"0 0 $(w) $(h)\" font-family=\"sans-serif\">\n")
    print(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n")
    f(io)
    print(io, "</svg>\n")
    svg = String(take!(io))
    file === nothing || write(file, svg)
    return svg
end

# ═════════════════════════════════════════════════════════════════════════════
# 9. Stil Allokationsgrafiken (`_alloc_*`)
# ═════════════════════════════════════════════════════════════════════════════
# plot(<SimLevOptimization>), plot(<SimLevFrontier>) (optimize), plot(<SimLevWeights>)
# (tactical): Einzelgrafik mit festen Rändern (L, R, T, B in der Zeichenfunktion), Achsen
# `_alloc_ticks`, Koordinaten `string(round(v; digits = 2))` (`_alloc_c`).

"Koordinate `string(round(v; digits = 2))`."
_alloc_c(v) = string(round(v; digits = 2))

"Achsenteilung wie `pretty()` (vereinfacht)."
function _alloc_ticks(lo, hi; n = 5)
    (isfinite(lo) && isfinite(hi)) || return Float64[]
    hi <= lo && (hi = lo + 1)
    raw = (hi - lo) / n
    p = 10.0^floor(log10(raw))
    step = minimum(s for s in (1, 2, 5, 10) .* p if s >= raw)
    collect((ceil(lo / step) * step):step:(hi+1e-12))
end

"Farbverlauf wie `colorRampPalette(c(...))(n)`."
function _alloc_ramp(n)
    base = [(0x2C, 0x6E, 0x9B), (0x3E, 0x8E, 0x5A), (0xC4, 0x9A, 0x2C), (0xB5, 0x56, 0x2B), (0x8A, 0x5B, 0xA8), (0x4A, 0x4A, 0x4A)]
    n == 1 && return ["#2C6E9B"]
    out = String[]
    for i in 0:(n-1)
        p = i / (n - 1) * (length(base) - 1)
        k = min(Int(floor(p)), length(base) - 2)
        f = p - k
        c = [round(Int, (1 - f) * base[k+1][j] + f * base[k+2][j]) for j in 1:3]
        push!(out, "#" * join(string(v; base = 16, pad = 2) for v in c))
    end
    out
end

# ═════════════════════════════════════════════════════════════════════════════
# 10. Zahlen wie in Julia (nur Python)
# ═════════════════════════════════════════════════════════════════════════════
# Julia schreibt Zahlen mit Base (`string`, `round`, `@sprintf`, `10.0^k`, `log10`, …);
# python/simlev/svg.py bildet diese Funktionen in diesem Abschnitt nach (`_jl_str`, `_jl_round`, …).
