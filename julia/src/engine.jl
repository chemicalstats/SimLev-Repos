# ─────────────────────────────────────────────────────────────────────────────
# Backtest-Engine: simulation() mit Vorbereitung, Kern-Aufruf und Auswertung (Gegenstück zu r/R/simulation.R und python/simlev/engine.py)
#
# Die Struktur folgt den Phasen des R-Pakets (simulation.R, sim_base.R, sim_validate.R,
# sim_prepare.R, sim_engine.R, sim_evaluate.R), damit beide
# Implementierungen Zeile für Zeile vergleichbar bleiben und bitgleich rechnen:
#
#   1. _sim_check_inputs   Eingabeprüfung, Steuer- und Gebühreneinstellungen
#   2. _sim_prepare_data   Kalenderraster, LOCF; _sim_build_state (sim_mem);
#      _sim_build_calendar (Angaben der Termine, Ereignis-Spalte, Prüfungen)
#   3.-5. _sim_engine_run! Termine, Tages-Flags und Startgewichte (core/prepare_core_impl.h; bis 1.3.0
#      _sim_build_calendar, _sim_init_weights!, _sim_build_schedule!), Tagesschleife und Abschluss des letzten
#      Jahres im gemeinsamen C++-Kern (core/engine_core_impl.h; bis 1.3.0 _sim_run_days! und _sim_close_years!)
#   6. _sim_returns, _sim_risk_stats, _sim_undefined_metrics, _sim_result
#
# Tagesindizes (`time`) sind wie in R 1-basiert. Hier stehen die Terminangaben, der
# Tarifweg (Prüfung, TariffEnv) und die Kennzahlen aus sim_base.R (Python: _sim_base.py); die
# Phasen in sim_*.jl.
# ─────────────────────────────────────────────────────────────────────────────

include("tax_tariff.jl")

const _DOUBLE_LINE = "═"^62

"Sentinel für nicht angegebene Argumente (R: `missing(arg)`)."
struct _Unset end
const _UNSET = _Unset()
_val(x, d) = x isa _Unset ? d : x

_rmin(a::Real, b::Real) = r_min2(Float64(a), Float64(b))
_rmax(a::Real, b::Real) = r_max2(Float64(a), Float64(b))

"R `isTRUE()`."
_is_true(x) = x isa Bool && x
_is_num(x) = x isa Real && !(x isa Bool)

"`.n_tage()`: \"1 Tag\" bzw. \"n Tage\"."
function _n_tage(n)
    s = n isa AbstractString ? String(n) : string(Int(n))
    return s == "1" ? "1 Tag" : s * " Tage"
end

"Zahlenvektor aus Skalar/Folge (nothing, wenn nicht numerisch)."
function _num_vec(x)
    @nospecialize
    _is_num(x) && return Float64[Float64(x)]
    x isa RVector && (x = x.values)
    if x isa Union{AbstractVector,Tuple}
        vals = collect(Any, x)
        all(v -> _is_num(v) || v === nothing || v === missing, vals) || return nothing
        return Float64[_is_num(v) ? Float64(v) : NA for v in vals]
    end
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# Datumswerte
# ═══════════════════════════════════════════════════════════════════════════

"`as.Date(s, format = \"%Y-%m-%d\")` wie R's strptime (Ziffernfelder, Rest ignoriert; core/slc_rbase_date.c)."
_r_strptime_ymd(s::AbstractString) = _rb_strptime_ymd(s, '-')

"`as.Date(x)` für einen Wert (Text JJJJ-MM-TT bzw. JJJJ/MM/TT, Datum, Zahl); nothing = NA."
function _as_date(x)
    @nospecialize
    x === nothing && return nothing
    if x isa Union{AbstractVector,Tuple}
        length(x) == 1 || return nothing
        x = first(x)
    end
    if x isa AbstractString
        z = _r_strptime_ymd(x)
        if z === nothing && occursin(r"^\s*\d{1,4}/\d{1,2}/\d", x)
            z = _r_strptime_ymd(replace(x, "/" => "-"; count = 2))
        end
        return z
    end
    x isa Date && return to_days(x)
    x isa DateTime && return to_days(Date(x))
    if _is_num(x)
        isnan(Float64(x)) && return nothing
        return Int(floor(Float64(x)))
    end
    return nothing
end

function _date_or_fail(x)
    z = _as_date(x)
    z === nothing && error("character string is not in a standard unambiguous format")
    return z
end

# ═══════════════════════════════════════════════════════════════════════════
# Gebühren (R: .fee_env, .fee_spec; Gebühr je Order im Kern engine_core_impl.h)
# ═══════════════════════════════════════════════════════════════════════════

struct FeeSpec
    fixed::Float64
    percent::Float64
    min::Float64
    max::Float64
end

function _fee_spec(x)
    @nospecialize
    x === nothing && return nothing
    _is_num(x) && (x = ["fixed" => x])
    _is_mapping(x) || error("order_fee/dca_fee: Zahl (EUR je Order) oder list(fixed, percent, min, max).")
    ps = _kvpairs(x)
    unk = [p.first for p in ps if !(p.first in ("fixed", "percent", "min", "max"))]
    if !isempty(ps) && (any(p -> isempty(p.first), ps) || !isempty(unk))
        error("order_fee/dca_fee: unbekannte oder unbenannte Felder (" * join(isempty(unk) ? ["ohne Namen"] : unk, ", ") *
              "); erlaubt sind fixed, percent, min, max.")
    end
    d = Dict(ps)
    g(k, dflt) = (v = get(d, k, nothing); v === nothing ? dflt : Float64(v))
    s = FeeSpec(g("fixed", 0.0), g("percent", 0.0) / 100, g("min", 0.0), g("max", Inf))
    (s.fixed < 0 || s.percent < 0 || s.min < 0 || s.max < s.min) && error("Gebühren müssen nicht negativ sein (min <= max).")
    (s.fixed == 0 && s.percent == 0 && s.min == 0) && return nothing
    return s
end

# ═══════════════════════════════════════════════════════════════════════════
# Termine und Flags
# ═══════════════════════════════════════════════════════════════════════════

# die Termine rechnet der Kern core/prepare_core_impl.h (dates_flags, Monatsarithmetik wie seq.Date)
const _Sched = Tuple{Vector{Int32},Float64,Vector{Float64},Vector{Int32}}

"""Angaben eines Terminplans für den Kern: (si, start, days, dcode) wie `.sched_spec` in R; den Schritt
liest R aus `"<span> months"` (`as.integer`), den Tag von `days` für anchor = "start" aus `as.Date("2000-1-<days>")`
(0 = NA). Ohne days sind days und dcode leer (si[6] = 0)."""
function _sched_spec(mode, span, unit, days, dates::Vector{Int}, value, anchor, start_date, skip_start)::_Sched
    @nospecialize
    if !_truthy_mode(mode) || unit === nothing || (value !== nothing && value <= 0)
        return (zeros(Int32, 7), 0.0, Float64[], Int32[])
    end
    span === nothing && (span = 1)
    unit = match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = match_arg(anchor, ("start", "end"), "anchor")
    start = start_date === nothing ? minimum(dates) : _date_or_fail(start_date)
    dmax = maximum(dates)
    step = trunc(Int, parse(Float64, r_as_character(unit == "quarter" ? span * 3 : span)))
    sy, sm, _ = ymd(start)
    ty, tm, _ = ymd(dmax)
    first = days_from_civil(sy, unit == "year" ? 1 : sm, 1)
    on = 1
    if step < 1 || first > dmax   # wie seq(): Fehler, sonst höchstens first (= letzter Tag)
        sy == ty && (unit == "year" || sm == tm) ||
            error(step == 0 ? "invalid '(to - from)/by'" : "wrong sign in 'by' argument")
        on, step = Int(first == dmax), 1
    end
    dd = days === nothing ? Float64[] : _num_vec(days)
    dcode = Int32[(z = _r_strptime_ymd("2000-1-" * r_as_character(v)); z === nothing ? 0 : z - 10956) for v in dd]
    si = Int32[on, unit == "year", unit == "quarter", anchor == "end", skip_start == true, days !== nothing,
               min(step, typemax(Int32))]
    return (si, Float64(start), dd, dcode)
end

function _calculate_dates_flags(mode, span, unit, days, dates::Vector{Int}, value, anchor, start_date,
                                skip_start, liquidate)
    @nospecialize
    si, start, dd, dcode = _sched_spec(mode, span, unit, days, dates, value, anchor, start_date, skip_start)
    d = Float64.(dates)
    out = zeros(Int32, length(d))
    rc = ccall((:simlev_c_dates_flags, LIBSLC), Cint,
               (Int64, Ptr{Float64}, Ptr{Int32}, Float64, Int64, Ptr{Float64}, Ptr{Int32}, Int32, Ptr{Int32}),
               length(d), d, si, start, length(dd), dd, dcode, Int32(si[1] != 0 && liquidate == true), out)
    CAbi.check(rc)
    return BitVector(out .!= 0)
end
_truthy_mode(m) = m isa Bool ? m : (m isa Real ? m != 0 : false)

# ═══════════════════════════════════════════════════════════════════════════
# Lauf-Kontext (Gebühren, Ausgabe, Konfiguration)
# ═══════════════════════════════════════════════════════════════════════════

mutable struct TariffEnv
    tariff::Any
    zve_all::Union{Nothing,Float64}
    zve::Union{Nothing,Dict{String,Float64}}
    ks::Dict{String,Float64}
    church_k::Float64
    kapest_rate::Float64
    use_gp::Bool
    rows::Vector{RList}
    refund_due::Float64
    due_info::Vector{NamedTuple{(:year, :D, :p23, :ded, :by_p23),Tuple{Int,Float64,Float64,Float64,Bool}}}
end
TariffEnv() = TariffEnv(nothing, nothing, nothing, Dict{String,Float64}(), 0.0, 0.25, false, RList[], 0.0,
                        NamedTuple{(:year, :D, :p23, :ded, :by_p23),Tuple{Int,Float64,Float64,Float64,Bool}}[])

mutable struct Cfg
    tax_mode::String
    start_value::Float64
    tax_rate::Float64
    marginal_tax_rate::Union{Nothing,Float64}
    effective_tax_rate::Float64
    soli_factor_income::Float64
    church_k::Float64
    tariff_env::Union{Nothing,TariffEnv}
    private_sale_threshold::Float64
    sparer_pauschbetrag::Float64
    use_sparer_pauschbetrag::Bool
    fractions::Bool
    fee_order::Union{Nothing,FeeSpec}
    fee_dca::Union{Nothing,FeeSpec}
    fees_on::Bool
    order_fee::Any
    dca_mode::Any
    dca_value::Any
    dca_days::Any
    balance_mode::Any
    balance_days::Any
    balance_thresh::Union{Nothing,Float64}
    balance_thresh_type::String
    base_rate::Any
    risk_free::Any
    harvest_mode::Any
    split_mode::Any
    event_col::Any
    pre_filled::BitVector
    strategy::Vector{Pair{String,Dict{String,Any}}}
    no_split::Vector{String}       # Fonds-Wrapper: Assets ohne Splits (Anteilswert)
    wrappers::Any                  # Fonds-Wrapper: RList der Anteilswerte (nur mit details = true), sonst nothing
end

mutable struct Flags
    flag_date::Vector{Int}
    flag_filled::BitVector
    flag_assets::Vector{String}
    dca::_Sched                         # Terminplan Sparplan (_sched_spec)
    balance::_Sched                     # Terminplan Rebalancing
    flag_event::Union{Nothing,BitVector}   # event_col als TRUE/FALSE (ohne event_col nothing)
    event_replace::Bool
    flag_harvest::BitVector             # Freibetragstage (setzt _sim_engine_run! aus dem Kern)
    tax_regimes::Vector{String}         # Steuerregime je Asset (setzt _sim_engine_run!)
end

mutable struct Run
    cfg::Cfg
    fl::Flags
    details::Bool
    io::IO
    tax_unpaid_total::Float64
    fee_paid::Float64
end

@inline _cat(R::Run, s::AbstractString) = print(R.io, s)
_message(s::AbstractString) = println(SimLev.RParallel.r_stderr(), s)

# ═══════════════════════════════════════════════════════════════════════════
# Tarifweg (taxable_income, tax_tariff)
# ═══════════════════════════════════════════════════════════════════════════

# plan_ok (income_tariff()): ein Vektor ohne Namen (ein Wert je Planjahr von withdrawal_simulation()) ist zulässig;
# Ergebnis dann mit plan (Werte)
function _check_taxable_income(x, years::Vector{Int}, who::String = "simulation"; plan_ok::Bool = false)
    @nospecialize
    form = "eine Zahl (zvE in EUR für alle Jahre), ein nach Kalenderjahren benannter Zahlenvektor (z. B. c(\"2024\" = 50000, \"2025\" = 52000)) oder ein data.frame mit den Spalten year und taxable_income"
    nms = nothing
    vals = nothing
    yrname(v) = _is_num(v) ? r_as_character(v) : string(v)
    if x isa RFrame
        nm = lowercase.(names(x))
        yc = something(findfirst(==("year"), nm), findfirst(==("jahr"), nm), Some(nothing))
        vc = nothing
        for c in ("taxable_income", "betrag", "amount", "zve")
            j = findfirst(==(c), nm)
            j !== nothing && (vc = j; break)
        end
        if yc === nothing || vc === nothing
            ncol(x) != 2 && error("$who: taxable_income als data.frame braucht die Spalten year und taxable_income (oder genau zwei Spalten Jahr, Betrag); vorhanden: $(join(names(x), ", ")).")
            yc, vc = 1, 2
        end
        kind, col = _column(x.cols[vc])
        kind != :numeric && error("$who: taxable_income: Spalte '$(names(x)[vc])' (Betrag) muss numerisch sein.")
        vals = collect(Float64, col)
        nms = [_isna_val(v) ? "NA" : yrname(v) for v in x.cols[yc]]
    elseif x isa RVector
        vals = _num_vec(x.values)
        x.names !== nothing && (nms = copy(x.names))
    elseif x isa AbstractDict || x isa NamedTuple || x isa AbstractVector{<:Pair}
        ps = x isa AbstractVector{<:Pair} ? [p.first => p.second for p in x] : collect(pairs(x))
        if !isempty(ps) && all(p -> _is_num(p.second), ps)
            vals = Float64[Float64(p.second) for p in ps]
            nms = [yrname(p.first) for p in ps]
        end
    else
        vals = _num_vec(x)
        vals !== nothing && isempty(vals) && (vals = nothing)
    end
    if vals === nothing || x isa AbstractMatrix
        shown = r_format(x isa Union{AbstractVector,Tuple} ? collect(Any, x) : x)
        error("$who: taxable_income muss $form sein, nicht $(join(first(shown, 3), ", ")).")
    end
    for (i, v) in enumerate(vals)
        isfinite(v) || error("$who: taxable_income enthält einen ungültigen Wert ($(r_format1(v))" *
                             (nms !== nothing ? " für $(nms[i])" : "") * "); erwartet werden endliche Beträge in EUR.")
    end
    length(vals) == 1 && nms === nothing && return (all = vals[1], by_year = nothing)
    plan_ok && nms === nothing && return (all = nothing, by_year = nothing, plan = vals)
    if nms === nothing || any(isempty, nms)
        error("$who: taxable_income mit $(length(vals)) Werten muss nach Kalenderjahren benannt sein; erwartet wird $form" *
              (nms === nothing ? " (ein Vektor ohne Namen, ein Wert je Planjahr, gilt nur in withdrawal_simulation())" : "") * ".")
    end
    yy = Int[]
    for nm in nms
        t = strip(nm)
        y = occursin(r"^[-+]?\d+(\.\d*)?([eE][-+]?\d+)?$", t) ? (v = r_as_numeric(t); isfinite(v) ? Int(trunc(v)) : nothing) : nothing
        (y === nothing || string(y) != t) && error("$who: taxable_income: Name '$nm' ist kein Kalenderjahr (erwartet z. B. \"2024\").")
        push!(yy, y)
    end
    for (i, y) in enumerate(yy)
        y in yy[1:i-1] && error("$who: taxable_income: Jahr $y kommt mehrfach vor.")
    end
    miss = [y for y in years if !(y in yy)]
    if !isempty(miss)
        error("$who: taxable_income fehlt für " * (length(miss) == 1 ? "Simulationsjahr" : "Simulationsjahre") * " " *
              join(miss, ", ") * " (angegeben: " * join(sort(yy), ", ") * "); je Kalenderjahr der Simulation (" *
              string(minimum(years)) * " bis " * string(maximum(years)) * ") wird ein Betrag benötigt.")
    end
    return (all = nothing, by_year = Dict{String,Float64}(string(y) => v for (y, v) in zip(yy, vals)))
end

# ═══════════════════════════════════════════════════════════════════════════
# Kennzahlen
# ═══════════════════════════════════════════════════════════════════════════

const _XIRR_WARN = ("-Inf replaced by maximally negative value", "NA/Inf replaced by maximum positive value",
                    "_NOT_ converged in 1000 iterations")

"`.xirr_rate()`: interner Zinsfuß p. a. (Brent über u = T log(1 + r)); im C++-Kern
(core/evaluate_core_impl.h, `simlev_c_xirr`), Warnungen von `uniroot` mit den Texten von R."
function xirr_rate(t::Union{Real,AbstractVector}, amount::Union{Real,AbstractVector}, end_value::Real, horizon::Real)
    tt = Float64[x for x in t]; aa = Float64[x for x in amount]
    length(tt) == length(aa) || throw(BoundsError(tt, length(aa)))
    v = Ref(0.0); nw = Ref{Int64}(0); w = zeros(Int32, 1100)
    rc = ccall((:simlev_c_xirr, LIBSLC), Cint,
               (Int64, Ptr{Float64}, Ptr{Float64}, Float64, Float64, Ref{Float64}, Ptr{Int32}, Int64, Ref{Int64}),
               length(tt), tt, aa, Float64(end_value), Float64(horizon), v, w, length(w), nw)
    CAbi.check(rc)
    for i in 1:min(nw[], length(w))
        @warn _XIRR_WARN[w[i]]
    end
    return v[]
end

"Stichproben-Schiefe wie `calculate_skewness(x, na.rm = TRUE)`."
function calculate_skewness(x::AbstractVector; na_rm::Bool = true)
    a = collect(Float64, x)
    na_rm && (a = _dropnan(a))
    n = length(a)
    n < 3 && return NA
    mean_x = r_mean(a)
    sd_x = r_sd(a)
    sd_x == 0 && return NA
    return (n / ((n - 1.0) * (n - 2.0))) * r_sum(r_pow(v - mean_x, 3.0) for v in a) / r_pow(sd_x, 3.0)
end

"Stichproben-Kurtosis wie `calculate_kurtosis(x, na.rm = TRUE, excess = TRUE)`."
function calculate_kurtosis(x::AbstractVector; na_rm::Bool = true, excess::Bool = true)
    a = collect(Float64, x)
    na_rm && (a = _dropnan(a))
    n = length(a)
    n < 4 && return NA
    mean_x = r_mean(a)
    sd_x = r_sd(a)
    sd_x == 0 && return NA
    nf = Float64(n)
    kurt = (nf * (nf + 1)) / ((nf - 1) * (nf - 2) * (nf - 3)) * r_sum(r_pow(v - mean_x, 4.0) for v in a) / r_pow(sd_x, 4.0)
    excess && (kurt = kurt - (3 * r_pow(nf - 1, 2.0)) / ((nf - 2) * (nf - 3)))
    return kurt
end

"`calculate_dates_flags()`: logischer Vektor der Termine (Sparplan, Rebalancing) zu `dates`."
function calculate_dates_flags(mode, span, unit, days, dates; value = nothing, anchor = ("start", "end"),
                               start_date = nothing, skip_start = false, liquidate = false)
    dates isa AbstractVector || (dates = [dates])   # ein Tag (R: Vektor der Länge 1)
    d = Int[x isa Date ? to_days(x) : Int(x) for x in dates]
    return _calculate_dates_flags(mode, span, unit, days, d, value, anchor, start_date, skip_start, liquidate)
end

include("sim_phases.jl")
include("sim_engine.jl")   # Tagesengine im C++-Kern
include("sim_evaluate.jl")
include("sim_blocks.jl")
include("wrapper.jl")       # Fonds-Wrapper: Anteilswert über simulation()
