# ─────────────────────────────────────────────────────────────────────────────
# Ergebnisobjekt der Simulation (R-Klasse `SimLevResult`) mit print und summary
# (print.SimLevResult, summary.SimLevResult, print.summary.SimLevResult)
# ─────────────────────────────────────────────────────────────────────────────

# ── Ergebnisobjekt (R-Klasse SimLevResult) ─────────────────────────────────

"""
    SimLevResult

Ergebnis von [`simulation`](@ref) (R-Klasse `SimLevResult`). Zugriff auf alle
R-Elemente über `res.name` oder `res["name"]`, Reihenfolge wie in R: `dates`,
`filled`, `worth`, `twr_index`, `invested`, `external_flows`, `cagr`, `ttwror`,
`drawdowns`, `statistics` (RList), `buys`/`sells` (RVector je Asset), `report`
(RList je Asset mit `worth`, `money`, `flows`, `total`, `share`), `tax_report`
(RList; `tariff_years` als RFrame, `next_year` als RList), `undefined_metrics`
(RFrame `metric`, `reason`, `detail`), `open_lots` (RList je Asset oder
`nothing`) sowie ggf. `fees_paid` und `harvest_days`. Zusätzlich (nur Julia)
liefert `res.trades` die Lots, Verkäufe, Steuer- und Gebührenbuchungen je Asset.
"""
struct SimLevResult <: AbstractDict{String,Any}
    data::RList
    trades::Any
end
Base.length(x::SimLevResult) = length(getfield(x, :data))
Base.iterate(x::SimLevResult, i::Int = 1) = iterate(getfield(x, :data), i)
Base.getindex(x::SimLevResult, k::AbstractString) = getfield(x, :data)[k]
Base.getindex(x::SimLevResult, k::Symbol) = k === :trades ? getfield(x, :trades) : getfield(x, :data)[String(k)]
Base.getindex(x::SimLevResult, i::Integer) = getfield(x, :data)[i]
Base.haskey(x::SimLevResult, k::AbstractString) = haskey(getfield(x, :data), k)
Base.haskey(x::SimLevResult, k::Symbol) = haskey(getfield(x, :data), String(k))
Base.get(x::SimLevResult, k::Union{AbstractString,Symbol}, d) = get(getfield(x, :data), String(k), d)
Base.keys(x::SimLevResult) = keys(getfield(x, :data))
Base.values(x::SimLevResult) = values(getfield(x, :data))
function Base.getproperty(x::SimLevResult, s::Symbol)
    s === :data && return getfield(x, :data)
    s === :trades && return getfield(x, :trades)
    return getfield(x, :data)[String(s)]
end
Base.propertynames(x::SimLevResult, private::Bool = false) = Tuple(Symbol.(keys(getfield(x, :data))))
# wie eine R-Liste erweiterbar (R: `res$tactical <- ...`)
Base.setindex!(x::SimLevResult, v, k::AbstractString) = (getfield(x, :data)[String(k)] = v; x)
Base.setindex!(x::SimLevResult, v, k::Symbol) = setindex!(x, v, String(k))
function Base.setproperty!(x::SimLevResult, s::Symbol, v)
    s in (:data, :trades) && error("SimLevResult: Feld $s ist nicht änderbar")
    getfield(x, :data)[String(s)] = v
end
Base.delete!(x::SimLevResult, k::AbstractString) = (delete!(getfield(x, :data), k); x)
Base.copy(x::SimLevResult) = SimLevResult(copy(getfield(x, :data)), getfield(x, :trades))
r_class(::SimLevResult) = ["SimLevResult"]
Base.show(io::IO, ::MIME"text/plain", x::SimLevResult) = print(io, format_result(x))
Base.show(io::IO, x::SimLevResult) =
    print(io, "SimLevResult(", length(x["worth"]), " Tage, Endwert ", r_sprintf("%.2f", x["worth"][end]), " EUR)")

"Ergebnis von `summary(<SimLevResult>)` (R-Klasse `summary.SimLevResult`)."
struct SimLevSummary <: AbstractDict{String,Any}
    data::RList
end
@_rlist_wrapper SimLevSummary ("summary.SimLevResult",)
Base.show(io::IO, x::SimLevSummary) = print(io, "SimLevSummary(", x["n_days"], " Tage)")

# ── Druckausgabe (print.SimLevResult) ──────────────────────────────────────

const _RULE = "═"^62
const _SUBRULE = "  " * "─"^21

_isna_any(x) = x === nothing || x === missing || (x isa AbstractFloat && isnan(x))

function _undef_text(x, metric::String)
    um = get(x, "undefined_metrics", nothing)
    d = nothing
    if um isa RFrame
        j = findfirst(==(metric), um["metric"])
        j !== nothing && (d = um["detail"][j])
    end
    return d === nothing ? "nicht definiert" : "nicht definiert ($d)"
end

"Text von `print(result)` aus dem R-Paket (zeichengleich, ohne abschließenden Zeilenumbruch)."
function format_result(x)
    s = x["statistics"]
    ext = _is_true(get(x, "external_flows", false))
    io = IOBuffer()
    ln(t) = println(io, t)
    ln(""); ln(_RULE); ln("                 SimLev Simulationsergebnisse                 "); ln(_RULE); ln("")
    ln("  Wertentwicklung"); ln(_SUBRULE)
    pct(v, metric, suffix = "") = _isna_any(v) ? _undef_text(x, metric) : r_sprintf("%+.2f%%%s", v * 100, suffix)
    if ext
        ln("  CAGR:             " * pct(x["cagr"], "cagr", " (geldgewichtet, XIRR)"))
        ln("  TTWROR:           " * pct(x["ttwror"], "ttwror", " (zeitgewichtet)"))
    else
        ln("  CAGR:             " * pct(x["cagr"], "cagr"))
        ln("  TTWROR:           " * pct(x["ttwror"], "ttwror"))
    end
    ln(r_sprintf("  Endwert:          %.2f EUR", x["worth"][end]))
    ext && ln(r_sprintf("  Eingezahlt:       %.2f EUR (Start + Sparraten)", x["invested"][end]))
    ln("")
    ln(ext ? "  Risiko (zeitgewichtet, ohne Einzahlungseffekte)" : "  Risiko")
    ln(_SUBRULE)
    ln(r_sprintf("  Max. Drawdown:    %.2f%%", s["max_drawdown"] * 100))
    ln(r_sprintf("  Mittl. Drawdown:  %.2f%%", s["average_drawdown"] * 100))
    ln(r_sprintf("  Ulcer Index:      %.4f", s["ulcer_index"]))
    ln("  Längster DD:      " * _n_tage(s["longest_drawdown"]))
    ln("  Mittl. Erholung:  " * (_isna_any(s["avg_recovery_time"]) ? "–" : _n_tage(r_sprintf("%.0f", s["avg_recovery_time"]))))
    ln("")
    ln("  Kennzahlen"); ln(_SUBRULE)
    fr(v) = _isna_any(v) ? "–" : r_sprintf("%+.3f", v)
    ln("  Sharpe:           " * fr(s["sharpe"]))
    ln("  Sortino:          " * fr(s["sortino"]))
    ln("  Calmar:           " * fr(s["calmar"]))
    ln("  Omega:            " * fr(s["omega"]))
    ln("  Gain/Pain:        " * fr(s["gain_to_pain"]))
    ln("  Serenity:         " * fr(s["serenity"]))
    ln("  Martin Ratio:     " * fr(s["martin_ratio"]))
    ext && ln("  (Calmar, Serenity, Martin mit TTWROR)")
    ln("")
    ln("  Verteilung"); ln(_SUBRULE)
    ln(r_sprintf("  Mittel je Tag:    %+.4f%%", s["mean"] * 100))
    ln(r_sprintf("  Std.-Abw. je Tag: %.4f%%", s["sd"] * 100))
    num3(v, metric) = _isna_any(v) ? _undef_text(x, metric) : r_sprintf("%.3f", v)
    ln("  Schiefe:          " * num3(s["skewness"], "skewness"))
    ln("  Wölbung:          " * num3(s["kurtosis"], "kurtosis"))
    ln("")
    tr = get(x, "tax_report", nothing)
    if tr !== nothing && tr["total_taxes_paid"] > 0
        ln("  Steuern"); ln(_SUBRULE)
        ln(r_sprintf("  Gezahlte Steuern: %.2f EUR", tr["total_taxes_paid"]))
        ln(r_sprintf("  Verlustvortrag:   %.2f EUR (§ 20) / %.2f EUR (§ 23)", tr["loss_carryforward_capital"], tr["loss_carryforward_private"]))
        otd = get(tr, "open_tax_debt", nothing)
        (otd isa Real && !isnan(otd) && otd > 0) && ln(r_sprintf("  Steuerschuld:     %.2f EUR (offen, nicht gedeckt)", otd))
        if tr["sparer_pauschbetrag_annual"] > 0
            ln(r_sprintf("  SPB genutzt:      %.2f EUR (Ersparnis: %.2f EUR)", tr["sparer_pauschbetrag_used"], tr["sparer_pauschbetrag_tax_saved"]))
        end
        ln("")
    end
    print(io, _RULE)
    return String(take!(io))
end

# ── summary.SimLevResult ───────────────────────────────────────────────────

function _summary_result(object)
    worth = object["worth"]
    n_days = length(worth)
    s = object["statistics"]
    ext = _is_true(get(object, "external_flows", false))
    invested = get(object, "invested", nothing)
    twr = get(object, "twr_index", nothing)
    res = RList(; class = ["summary.SimLevResult"])
    res["n_days"] = n_days
    res["n_years"] = r_round(n_days / 365.25, 2)
    res["start_value"] = worth[1]
    res["start_capital"] = invested !== nothing ?
        invested[1] - r_sum(Float64[rp["flows"][1] for (_, rp) in object["report"]]; na_rm = true) : NA
    res["end_value"] = worth[end]
    res["total_return_twr"] = ext ? twr[end] / twr[1] - 1 : (worth[end] / worth[1]) - 1
    res["return_on_invested"] = NA
    res["total_return"] = NA
    res["invested"] = invested !== nothing ? invested[end] : worth[1]
    res["cagr"] = object["cagr"]
    res["ttwror"] = object["ttwror"]
    for k in ("sharpe", "sortino", "calmar", "omega", "gain_to_pain", "serenity", "martin_ratio", "max_drawdown",
              "average_drawdown", "ulcer_index", "longest_drawdown", "avg_recovery_time")
        res[k] = s[k]
    end
    res["statistics"] = s
    res["tax_report"] = get(object, "tax_report", nothing)
    res["undefined_metrics"] = get(object, "undefined_metrics", nothing)
    res["external_flows"] = ext
    res["total_return"] = res["total_return_twr"]
    res["return_on_invested"] = (res["end_value"] - res["invested"]) / res["invested"]
    return SimLevSummary(res)
end

"Text von `print(summary(result))` aus dem R-Paket (ohne abschließenden Zeilenumbruch)."
function format_summary(x)
    s = x["statistics"]
    n_days = x["n_days"]
    ext = _is_true(get(x, "external_flows", false))
    io = IOBuffer()
    ln(t) = println(io, t)
    ln(""); ln(_RULE); ln("                    SimLev Zusammenfassung                    "); ln(_RULE); ln("")
    ln(r_sprintf("  Zeitraum:         %s (%.1f Jahre)", _n_tage(n_days), x["n_years"]))
    sc = get(x, "start_capital", nothing)
    (sc !== nothing && !_isna_any(sc)) && ln(r_sprintf("  Startkapital:     %.2f EUR", sc))
    ln(r_sprintf("  Depotwert Starttag: %.2f EUR", x["start_value"]))
    ln(r_sprintf("  Ende:             %.2f EUR", x["end_value"]))
    pct(v, metric, suffix = "") = _isna_any(v) ? _undef_text(x, metric) : r_sprintf("%+.2f%%%s", v * 100, suffix)
    if ext
        ln(r_sprintf("  Eingezahlt:       %.2f EUR (Start + Sparraten)", x["invested"]))
        ln(r_sprintf("  Gesamtrendite (zeitgewichtet): %+.2f %%", x["total_return_twr"] * 100))
        ln(r_sprintf("  Gewinn je eingezahltem EUR:    %+.2f %% (Endwert %.2f EUR / Eingezahlt %.2f EUR - 1)",
                     x["return_on_invested"] * 100, x["end_value"], x["invested"]))
        ln("  CAGR:             " * pct(x["cagr"], "cagr", " (geldgewichtet, XIRR)"))
        ln("  TTWROR:           " * pct(x["ttwror"], "ttwror", " (zeitgewichtet)"))
    else
        ln(r_sprintf("  Gesamtrendite:    %+.2f%%", x["total_return"] * 100))
        ln("  CAGR:             " * pct(x["cagr"], "cagr"))
        ln("  TTWROR:           " * pct(x["ttwror"], "ttwror"))
    end
    ln("")
    fmt(v, p = false) = _isna_any(v) ? "–" : (p ? r_sprintf("%.2f%%", v * 100) : r_sprintf("%.3f", v))
    rows = ["Sharpe" => fmt(s["sharpe"]), "Sortino" => fmt(s["sortino"]), "Calmar" => fmt(s["calmar"]),
            "Omega" => fmt(s["omega"]), "Gain/Pain" => fmt(s["gain_to_pain"]), "Serenity" => fmt(s["serenity"]),
            "Martin" => fmt(s["martin_ratio"]), "Max. DD" => fmt(s["max_drawdown"], true),
            "Mittl. DD" => fmt(s["average_drawdown"], true), "Ulcer" => fmt(s["ulcer_index"]),
            "Längster DD" => r_sprintf("%d d", s["longest_drawdown"]),
            "Mittl. Erholung" => (_isna_any(s["avg_recovery_time"]) ? "–" : r_sprintf("%.0f d", s["avg_recovery_time"]))]
    for (k, v) in rows
        ln("  " * rpad(k, 16) * " " * v)
    end
    ext && ln("  (Drawdowns zeitgewichtet; Calmar, Serenity, Martin mit TTWROR)")
    ln("")
    print(io, _RULE)
    return String(take!(io))
end

"""
    summary(result::SimLevResult; verbose = false, io = stdout)

Zusammenfassung wie R's `summary.SimLevResult`: gibt ein `SimLevSummary`
(R-Klasse `summary.SimLevResult`) zurück, dessen Druckausgabe der R-Methode
entspricht; mit `verbose = true` wird sie zusätzlich auf `io` gedruckt.
Ebenso über das generische `r_summary(result)`.
"""
function Base.summary(x::SimLevResult; verbose::Bool = false, io::IO = stdout)
    res = _summary_result(x)
    verbose && println(io, format_summary(res))
    return res
end

register_print!("SimLevResult", (io, x) -> print(io, format_result(x)))
register_print!("summary.SimLevResult", (io, x) -> print(io, format_summary(x)))
register_summary!("SimLevResult", (x, args...; kw...) -> _summary_result(x))
