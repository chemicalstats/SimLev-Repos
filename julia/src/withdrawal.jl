# Withdrawal – r/R/withdrawal.R (Vorlage python/simlev/withdrawal.py)
#
# Entnahme-Simulationen (Ruhestand / Decumulation):
#   withdrawal_rule        Regel-Objekt (14 Regeln)
#   withdrawal_cohorts     historische rollierende Kohorten (Bengen/Trinity)
#   withdrawal_paths       Periodenrenditen aus Bootstrap-Pfaden, Ergebnislisten oder Studien
#   result_index           zeitgewichteter Wertindex eines Simulationsergebnisses
#   withdrawal_simulation  schneller Kern über viele Pfade, optional mit Steuern
#   perfect_withdrawal_rate, withdrawal_max_rate, horizon_model
#
# PROZENT-KONVENTION: rate, ceiling, floor, cut, raise, exp_return usw. in
# Prozent (rate = 4 bedeutet 4 % p. a.), wie im restlichen Paket.
module Withdrawal

import ..SimLev
using Dates
using Printf

export withdrawal_rule, withdrawal_cohorts, result_index, withdrawal_paths, perfect_withdrawal_rate,
       withdrawal_simulation, withdrawal_max_rate, horizon_model

const RList = SimLev.RList
const RFrame = SimLev.RFrame
const RVector = SimLev.RVector
const NamedMat = SimLev.NamedMat
const NA = SimLev.NA

# Gemeinsame Hilfen aus Bootstrap
const B = SimLev.Bootstrap
const _MISSING = B._MISSING
const _Missing = B._Missing
import ..Bootstrap: _stop, _warn, _message, _sp, _fmt1, _fmtstrs, _show, _as_char, _round0, _isnum, _numvec, _num1, _f1,
                    _dvec, _ivec, _mat, _get, _names, _values, _len, _rval, _rsum, _rmean, _rprod, _rpow, _rlog, _rexp,
                    _cumprod, _cummax, _median, _quantile7, _weighted_mean, _wquantile, _with_rng_restore, _uniq,
                    _match_arg, _todate, _seq_dates, _days, _is_boot_result, _is_study, _is_result, _deparse,
                    _quiet, _no_messages, _aux_type_of, _cfg_list, _as_numeric_col, _pmax, _pmin, _istrue

const _WD_RULES = ["constant" => 1, "percent" => 2, "vanguard" => 3, "guyton_klinger" => 4, "floor_ceiling" => 5,
                   "clyatt" => 6, "ratchet" => 7, "endowment" => 8, "one_over_n" => 9, "vpw" => 10, "abw" => 11,
                   "cape" => 12, "sensible" => 13, "hebeler" => 14]
const _WD_RULE_NAMES = Tuple(first.(_WD_RULES))
_rule_code(t) = last(_WD_RULES[findfirst(p -> p.first == t, _WD_RULES)])

const _WD_LABELS = Dict(
    "constant" => "Konstante reale Entnahme (Bengen/Trinity)",
    "percent" => "Fester Prozentsatz des Depots",
    "vanguard" => "Vanguard Dynamic Spending (Ceiling/Floor)",
    "guyton_klinger" => "Guyton-Klinger-Entscheidungsregeln",
    "floor_ceiling" => "Floor-and-Ceiling (Bengen 2001)",
    "clyatt" => "Clyatt 95-%-Regel",
    "ratchet" => "Kitces-Ratchet",
    "endowment" => "Endowment-/Yale-Regel (Tobin)",
    "one_over_n" => "1/N (Restlaufzeit)",
    "vpw" => "Variable Percentage Withdrawal (Bogleheads)",
    "abw" => "Amortisationsbasierte Entnahme (ABW)",
    "cape" => "CAPE-basierte Regel",
    "sensible" => "Sensible Withdrawals",
    "hebeler" => "Hebeler Autopilot II")

_wcore() = SimLev.WithdrawalCore

"R-`show()` (NULL → \"NULL\", TRUE/FALSE, sonst `paste(format(x), collapse = \", \")`)."
function _rshow(x)
    x === nothing && return "NULL"
    x isa Bool && return x ? "TRUE" : "FALSE"
    x === missing && return "NA"
    return _show(x)
end
_wshow(x) = x === nothing ? "" : _rshow(x)
"`format()` eines Rechenergebnisses."
_fmt_nan(x; kw...) = _fmt1(Float64(x); kw...)

_is_rule(x) = x isa RList && SimLev.inherits(x, "withdrawal_rule")
_is_wp(x) = x isa RList && SimLev.inherits(x, "withdrawal_paths")
_is_horizon(x) = x isa RList && SimLev.inherits(x, "SimLevHorizon")

"R-Zahlwert eines Arguments (Int → Float64)."
_num(x) = x isa Bool ? x : x isa Integer ? Float64(x) : x

# ═══════════════════════════════════════════════════════════════════════════
# Regeln
# ═══════════════════════════════════════════════════════════════════════════

"""
    withdrawal_rule(type = "constant"; rate = 4, ceiling = nothing, floor = nothing, cut = 10, raise = 10,
                    cpr_years = 15, inflation_cap = Inf, skip_inflation = true, smoothing = nothing,
                    exp_return = nothing, stock_share = 60, age = 65, max_age = 100, fv = 0, cape_a = 1.75,
                    cape_b = 0.5, ratchet_threshold = 1.5, ratchet_gap = 3, extra = 10, floor95 = 95,
                    min_real = 0, max_real = Inf, max_rate = 100)

Entnahmeregel definieren (Port von `withdrawal_rule()`).
"""
function withdrawal_rule(type_pos = nothing; type = type_pos, type_ = type, rate = 4, ceiling = nothing, floor = nothing, cut = 10, raise = 10,
                         cpr_years = 15, inflation_cap = Inf, skip_inflation = true, smoothing = nothing,
                         exp_return = nothing, stock_share = 60, age = 65, max_age = 100, fv = 0, cape_a = 1.75,
                         cape_b = 0.5, ratchet_threshold = 1.5, ratchet_gap = 3, extra = 10, floor95 = 95,
                         min_real = 0, max_real = Inf, max_rate = 100, kwargs...)
    if !isempty(kwargs)
        k, v = first(kwargs)
        _stop(string("unused argument (", k, " = ", _deparse(v), ")"))
    end
    t = _match_arg(type_, _WD_RULE_NAMES)
    function chk(x, arg; lo = -Inf, hi = Inf, what = "", inf_ok = false, null_ok = false)
        x === nothing && null_ok && return
        v = _numvec(x)
        if v === nothing || length(v) != 1 || isnan(v[1]) || (!inf_ok && !isfinite(v[1])) || v[1] < lo || v[1] > hi
            _stop(@sprintf("withdrawal_rule: %s muss %s sein (erhalten: %s).", arg, what, _rshow(x)))
        end
    end
    v = _numvec(rate)
    if v === nothing || length(v) != 1 || !isfinite(v[1]) || v[1] < 0 || v[1] > 100
        _stop(@sprintf("rate muss zwischen 0 und 100 Prozent liegen (z. B. 4; erhalten: %s).", _rshow(rate)))
    end
    0 < rate < 0.2 && t in ("constant", "percent", "vanguard", "guyton_klinger") &&
        _warn("rate wirkt wie eine Dezimalzahl. PROZENT-KONVENTION: 4 bedeutet 4 %.")
    chk(ceiling, "ceiling"; lo = 0, what = "NULL oder eine Zahl >= 0 in Prozent (z. B. 20)", null_ok = true)
    chk(floor, "floor"; lo = 0, hi = 100, what = "NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 20)", null_ok = true)
    chk(cut, "cut"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
    chk(raise, "raise"; lo = 0, what = "eine Zahl >= 0 in Prozent (z. B. 10)")
    chk(cpr_years, "cpr_years"; lo = 0, what = "eine Zahl von Jahren >= 0 (z. B. 15)")
    chk(inflation_cap, "inflation_cap"; lo = 0, what = "eine Zahl >= 0 in Prozent oder Inf (unbegrenzt)", inf_ok = true)
    if !(skip_inflation isa Bool)
        _stop(@sprintf("withdrawal_rule: skip_inflation muss TRUE oder FALSE sein (erhalten: %s).", _rshow(skip_inflation)))
    end
    chk(smoothing, "smoothing"; lo = 0, hi = 100, what = "NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 70)", null_ok = true)
    chk(exp_return, "exp_return"; lo = -99.99, what = "NULL oder eine Zahl in Prozent p. a. über -100 (z. B. 3.5)", null_ok = true)
    chk(stock_share, "stock_share"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 60)")
    chk(age, "age"; lo = 0, what = "ein Alter in Jahren >= 0 (z. B. 65)")
    chk(max_age, "max_age"; lo = 0, what = "ein Alter in Jahren >= 0 (z. B. 100)")
    if t == "vpw" && age >= max_age
        _stop(@sprintf("withdrawal_rule('vpw'): age (%s) muss kleiner als max_age (%s) sein.", _fmt1(_num(age)), _fmt1(_num(max_age))))
    end
    chk(fv, "fv"; lo = 0, what = "ein Geldbetrag >= 0 (reales Zielvermögen)")
    chk(cape_a, "cape_a"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 1.75)")
    chk(cape_b, "cape_b"; lo = 0, what = "eine Zahl >= 0 (Faktor auf 1 / CAPE, z. B. 0.5)")
    chk(ratchet_threshold, "ratchet_threshold"; lo = 0, what = "ein Faktor > 0 (z. B. 1.5 = 150 %)")
    chk(ratchet_gap, "ratchet_gap"; lo = 0, what = "eine Zahl von Jahren >= 0 (z. B. 3)")
    chk(extra, "extra"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
    chk(floor95, "floor95"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 95)")
    chk(min_real, "min_real"; lo = 0, what = "ein Geldbetrag >= 0")
    chk(max_real, "max_real"; lo = 0, what = "ein Geldbetrag >= 0 oder Inf", inf_ok = true)
    if min_real > max_real
        _stop(@sprintf("withdrawal_rule: min_real (%s) darf nicht größer als max_real (%s) sein.", _fmt1(_num(min_real)), _fmt1(_num(max_real))))
    end
    chk(max_rate, "max_rate"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 100)")
    if t == "vpw" && max_rate == 0
        _stop("withdrawal_rule('vpw'): max_rate = 0 erlaubt keine Entnahme; Höchstsatz in Prozent > 0 angeben (z. B. 100).")
    end
    frac = Pair{String,Float64}["ceiling" => ceiling === nothing ? NaN : Float64(ceiling),
                                "floor" => floor === nothing ? NaN : Float64(floor), "cut" => Float64(cut),
                                "raise" => Float64(raise), "smoothing" => smoothing === nothing ? NaN : Float64(smoothing),
                                "inflation_cap" => Float64(inflation_cap), "extra" => Float64(extra),
                                "floor95" => Float64(floor95), "max_rate" => Float64(max_rate)]
    frac = [p for p in frac if !isnan(p.second) && 0 < p.second < 0.2]
    if !isempty(frac)
        a = _fmtstrs(Float64[p.second for p in frac])
        b = _fmtstrs(Float64[100 * p.second for p in frac])
        _warn(@sprintf("withdrawal_rule: %s wirkt wie ein Anteil; PROZENT-KONVENTION: 5 bedeutet 5 %% (gemeint vermutlich %s).",
                       join([string(p.first, " = ", s) for (p, s) in zip(frac, a)], ", "),
                       join([string(p.first, " = ", s) for (p, s) in zip(frac, b)], ", ")))
    end
    dflt = t == "vanguard" ? (5.0, 2.5) : t == "guyton_klinger" ? (20.0, 20.0) : t == "floor_ceiling" ? (20.0, 15.0) : (0.0, 0.0)
    ceiling = ceiling === nothing ? dflt[1] : ceiling
    floor = floor === nothing ? dflt[2] : floor
    smoothing = smoothing === nothing ? (t == "hebeler" ? 75.0 : 70.0) : smoothing
    exp_return = exp_return === nothing ? (5.0 * stock_share / 100 + 1.9 * (1 - stock_share / 100)) : exp_return
    return RList("type" => t, "rate" => _num(rate), "ceiling" => _num(ceiling), "floor" => _num(floor), "cut" => _num(cut),
                 "raise" => _num(raise), "cpr_years" => _num(cpr_years), "inflation_cap" => _num(inflation_cap),
                 "skip_inflation" => skip_inflation, "smoothing" => _num(smoothing), "exp_return" => _num(exp_return),
                 "age" => _num(age), "max_age" => _num(max_age), "fv" => _num(fv), "cape_a" => _num(cape_a),
                 "cape_b" => _num(cape_b), "ratchet_threshold" => _num(ratchet_threshold), "ratchet_gap" => _num(ratchet_gap),
                 "extra" => _num(extra), "floor95" => _num(floor95), "min_real" => _num(min_real),
                 "max_real" => _num(max_real), "max_rate" => _num(max_rate); class = ["withdrawal_rule", "list"])
end

_as_integer(x) = Int(trunc(Float64(x)))

function _print_rule(io::IO, x)
    print(io, "Entnahmeregel\n-------------\n")
    t = x["type"]
    print(io, _sp("  Typ:       %s (%s)\n", t, _WD_LABELS[t]))
    t in ("one_over_n", "vpw", "abw", "cape", "hebeler") || print(io, _sp("  Rate:      %.2f %%\n", x["rate"]))
    ex = if t == "vanguard"
        _sp("  Ceiling/Floor (real): +%.2f %% / -%.2f %%\n", x["ceiling"], x["floor"])
    elseif t == "guyton_klinger"
        _sp("  Guardrails: +%.0f %% / -%.0f %%, Kürzung %.0f %%, Erhöhung %.0f %%, CPR bis %d J. vor Ende\n",
            x["ceiling"], x["floor"], x["cut"], x["raise"], _as_integer(x["cpr_years"]))
    elseif t == "floor_ceiling"
        _sp("  Korridor:  -%.0f %% / +%.0f %% um reale Erstentnahme\n", x["floor"], x["ceiling"])
    elseif t == "endowment"
        _sp("  Glättung:  %.0f %%\n", x["smoothing"])
    elseif t == "hebeler"
        _sp("  Glättung:  %.0f %%, erwartete Realrendite %.2f %%\n", x["smoothing"], x["exp_return"])
    elseif t == "vpw"
        _sp("  Alter %d bis %d, erwartete Realrendite %.2f %%\n", _as_integer(x["age"]), _as_integer(x["max_age"]), x["exp_return"])
    elseif t == "abw"
        _sp("  Erwartete Realrendite %.2f %%, Zielvermögen %.0f\n", x["exp_return"], x["fv"])
    elseif t == "cape"
        _sp("  Rate = %.2f %% + %.2f / CAPE\n", x["cape_a"], x["cape_b"])
    elseif t == "ratchet"
        _sp("  +%.0f %% bei Depot > %.2f x Start, alle %d Jahre\n", x["raise"], x["ratchet_threshold"], _as_integer(x["ratchet_gap"]))
    elseif t == "sensible"
        _sp("  Zusatz: %.0f %% des realen Vorjahresgewinns\n", x["extra"])
    elseif t == "clyatt"
        _sp("  Mindestens %.0f %% der Vorjahresentnahme\n", x["floor95"])
    else
        ""
    end
    print(io, ex)
    if x["min_real"] > 0 || isfinite(x["max_real"])
        print(io, _sp("  Grenzen:   %.0f bis %s (real)\n", x["min_real"], _fmt1(Float64(x["max_real"]))))
    end
    nothing
end

"Parametervektor für den Kern (Reihenfolge = enum in withdrawal_core.cpp)."
function _wd_param_vector(rule)
    r = rule
    f(k) = Float64(r[k])
    return Float64[f("rate") / 100, f("ceiling") / 100, f("floor") / 100, f("cut") / 100, f("raise") / 100, f("cpr_years"),
                   f("inflation_cap") / 100, f("smoothing") / 100, f("exp_return") / 100, f("cape_a") / 100, f("cape_b"),
                   f("ratchet_threshold"), f("ratchet_gap"), f("extra") / 100, f("min_real"), f("max_real"), f("age"),
                   f("max_age"), f("fv"), f("floor95") / 100, _istrue(r["skip_inflation"]) ? 1.0 : 0.0, f("max_rate") / 100]
end

"Perioden je Jahr (`.wd_ppy`)."
function _wd_ppy(frequency)
    frequency == "year" && return 1
    frequency == "quarter" && return 4
    frequency == "month" && return 12
    _stop("frequency muss 'year', 'quarter' oder 'month' sein.")
end

"Letzte Zeile je Kalenderperiode (1-basiert), Port von `.period_ends`."
function _period_ends(dates, frequency)
    d = _todate(dates, "dates")
    key = [frequency == "year" ? Dates.year(x) : frequency == "quarter" ? Dates.year(x) * 10 + (Dates.month(x) - 1) ÷ 3 :
           Dates.year(x) * 100 + Dates.month(x) for x in d]
    isempty(key) && return Int[]
    return findall(vcat(key[2:end] .!= key[1:end-1], true))
end

# ═══════════════════════════════════════════════════════════════════════════
# withdrawal_paths-Objekte, Kohorten, Wertindex
# ═══════════════════════════════════════════════════════════════════════════

_fill_locf(v) = _dvec(SimLev.Backcast._fill_na(_dvec(v), "locf"))

_dfnames(data) = data isa RFrame ? names(data) : something(_names(data), String[])
_dfcol(data, nm) = data isa RFrame ? data[nm] : _get(data, nm)

"R's `x^y` elementweise mit Recycling."
function _pow_vec(x, y)
    x = _dvec(x); y = _dvec(y)
    (isempty(x) || isempty(y)) && return Float64[]
    n = max(length(x), length(y))
    return Float64[_rpow(x[(i-1)%length(x)+1], y[(i-1)%length(y)+1]) for i in 1:n]
end

"`apply(M, 2, f)`: Vektor bei Länge 1 je Spalte, sonst Matrix (Ergebnis × Spalten)."
function _apply_cols(M::AbstractMatrix, f)
    res = [_dvec(f(M[:, j])) for j in 1:size(M, 2)]
    isempty(res) && return Float64[]
    all(r -> length(r) == 1, res) && return Float64[r[1] for r in res]
    return reduce(hcat, res)
end
_agg_prod(c, k) = Float64[_rprod(c[i:min(i + k - 1, length(c))]) for i in 1:k:length(c)]
_as_matrix(x) = x isa RFrame ? reduce(hcat, [_dvec(c) for c in x.cols]) : x isa AbstractVector ? reshape(_dvec(x), :, 1) :
                x isa Number ? fill(Float64(x), 1, 1) : _mat(x)

"""
    withdrawal_cohorts(data; price = "value", inflation = nothing, years = 30, frequency = "year",
                       step = "month", wrap = false, cape = nothing, base_rate = nothing, inflation_type = "level")

Historische Entnahme-Kohorten bilden (Port von `withdrawal_cohorts()`).
`data`: RFrame mit `date` und Kursspalte oder ein SimLevResult.
"""
function withdrawal_cohorts(data; price = "value", inflation = nothing, years = 30, frequency = nothing, step = nothing,
                            wrap = false, cape = nothing, base_rate = nothing, inflation_type = _MISSING)
    data = SimLev.as_rframe(data)
    it_given = inflation_type !== _MISSING
    frequency = _match_arg(frequency, ("year", "quarter", "month"))
    step = _match_arg(step, ("month", "year"))
    inflation_type = _match_arg(it_given ? inflation_type : nothing, ("level", "rate_pa"))
    if _is_result(data)
        if inflation isa AbstractString || cape !== nothing || base_rate !== nothing
            _stop("Bei einem SimLevResult sind nur numerische Inflation und keine Zusatzspalten möglich.")
        end
        data = result_index(data)
        price = "value"
    end
    nms = _dfnames(data)
    ("date" in nms && price in nms) || _stop("data braucht 'date' und die Kursspalte.")
    at = data isa RFrame ? get(SimLev.attrs(data), "aux_type", nothing) : nothing
    attr_rate = inflation isa AbstractString && at !== nothing && _aux_type_of(at, inflation) == "rate"
    if attr_rate && it_given && inflation_type != "rate_pa"
        _stop(@sprintf("inflation_type = '%s' passt nicht zu aux_type['%s'] = 'rate' (Attribut aus bootstrap_data()); inflation_type weglassen oder 'rate_pa' angeben.",
                       inflation_type, inflation))
    end
    infl_rate = inflation isa AbstractString && (attr_rate || inflation_type == "rate_pa")
    dd = _todate(_dfcol(data, "date"), "withdrawal_cohorts: data\$date")
    o = sortperm(_days.(dd); alg = MergeSort)
    dates = dd[o]
    col(name) = _as_numeric_col(_dfcol(data, name))[o]
    px = _fill_locf(col(price))
    ends = _period_ends(dates, "month")
    mdates = dates[ends]
    mpx = px[ends]
    mi = Int[Dates.year(x) * 12 + Dates.month(x) for x in mdates]
    dmi = diff(mi)
    gap = findall(!=(1), dmi)
    if !isempty(gap)
        _stop(@sprintf("withdrawal_cohorts braucht lückenlose Monatsdaten (mindestens ein Datum je Kalendermonat), aber nach %s folgt %s%s.",
                       string(mdates[gap[1]]), string(mdates[gap[1]+1]),
                       _median(Float64.(dmi)) >= 12 ? " (Jahresdaten? Dann Jahresrenditen als Matrix Jahre x Kohorten an withdrawal_simulation() übergeben)" : ""))
    end
    cpi = if inflation === nothing
        ones(length(ends))
    elseif infl_rate
        v = _fill_locf(col(inflation))
        dt = Float64[_days(dates[i+1]) - _days(dates[i]) for i in 1:length(dates)-1] ./ 365.25
        lvf = _cumprod(vcat(1.0, _pow_vec(1 .+ v[2:end] ./ 100, dt)))
        lv = lvf[ends]
        f = lv[2:end] ./ lv[1:end-1]
        bad = .!isfinite.(f) .| (f .<= 0)
        if any(bad)
            _stop(@sprintf("Spalte '%s' (Rate in Prozent p. a.) ergibt nicht endliche oder nicht positive Monatsfaktoren (z. B. %s; Rate <= -100 %%?).",
                           inflation, _fmt_nan(f[bad][1]; digits = 4)))
        end
        lv
    elseif inflation isa AbstractString
        _fill_locf(col(inflation))[ends]
    else
        _pow_vec(1 + Float64(_f1(inflation)) / 100, Float64[_days(m) - _days(mdates[1]) for m in mdates] ./ 365.25)
    end
    capev = cape === nothing ? nothing : _fill_locf(col(cape))[ends]
    brv = base_rate === nothing ? nothing : _fill_locf(col(base_rate))[ends]
    mret = mpx[2:end] ./ mpx[1:end-1]
    minf = cpi[2:end] ./ cpi[1:end-1]
    nm = length(mret)
    ppy = _wd_ppy(frequency)
    mpp = 12 ÷ ppy
    yv = _numvec(years)
    if yv === nothing || length(yv) != 1 || !isfinite(yv[1]) || yv[1] <= 0 ||
       abs(yv[1] * 12 - _round0(yv[1] * 12)) > 1e-8 || rem(_round0(yv[1] * 12), mpp) != 0
        _stop(@sprintf("years muss eine positive Zahl sein, die ganze Perioden der frequency '%s' ergibt (bei 'year' ganze Jahre; erhalten: %s).",
                       frequency, _show(years)))
    end
    len_m = Int(_round0(yv[1] * 12))
    starts = if step == "month"
        collect(1:nm)
    else
        nm < 1 && _stop("wrong sign in 'by' argument")
        collect(1:12:nm)
    end
    wrap || (starts = starts[starts .+ len_m .- 1 .<= nm])
    isempty(starts) && _stop("Zu kurze Historie für die gewählte Kohortenlänge.")
    take(v, s) = v[((s - 1) .+ (1:len_m) .- 1) .% nm .+ 1]
    agg(M) = mpp == 1 ? M : _apply_cols(M, c -> _agg_prod(c, mpp))
    ns = length(starts)
    Rm = agg(reduce(hcat, [take(mret, s) for s in starts]))
    Im = agg(reduce(hcat, [take(minf, s) for s in starts]))
    to_mat(A) = A isa AbstractVector ? reshape(A, :, ns) : A
    pick_start(v) = v === nothing ? nothing : reduce(hcat, [take(v[1:end-1], s) for s in starts])[1:mpp:len_m, :]
    return RList("returns" => to_mat(Rm), "inflation" => to_mat(Im), "cape" => pick_start(capev),
                 "base_rate" => pick_start(brv), "frequency" => frequency, "start_dates" => mdates[starts],
                 "historical" => true, "wrap" => Bool(wrap), "source" => price; class = "withdrawal_paths")
end

_report_items(rep) = rep === nothing ? Any[] : rep isa AbstractDict ? collect(values(rep)) : rep isa NamedTuple ? collect(values(rep)) :
                     rep isa AbstractVector ? collect(rep) : Any[]

"""
    result_index(x; base = 100)

Zeitgewichteter Wertindex eines Simulationsergebnisses: RFrame mit `date`,
`value`, `worth`, `flows`.
"""
function result_index(x; base = 100)
    x = SimLev.as_rframe(x)
    _is_result(x) || _stop("x muss ein SimLevResult (Ergebnis von simulation()) sein.")
    w = _dvec(_get(x, "worth"))
    fls = [_dvec(_get(a, "flows")) for a in _report_items(_get(x, "report"))]
    fl = if !isempty(fls) && length(w) > 1
        Float64[_rsum(Float64[f[i] for f in fls]) for i in eachindex(w)]
    elseif !isempty(fls)
        Float64[f[1] for f in fls]
    else
        zeros(length(w))
    end
    twr = _get(x, "twr_index")
    idx = if twr !== nothing && _len(twr) == length(w)
        _dvec(twr)
    else
        g = vcat(1.0, Float64[(w[i] - fl[i]) / w[i-1] for i in 2:length(w)])
        for i in eachindex(g)
            isfinite(g[i]) || (g[i] = 1.0)
        end
        _cumprod(g)
    end
    dts = _get(x, "dates")
    dts = eltype(dts) <: Integer ? [Date(1970, 1, 1) + Day(d) for d in dts] : _todate(dts, "dates")
    return RFrame("date" => dts, "value" => Float64(base) .* idx, "worth" => w, "flows" => fl)
end

"Periodenenden als Jahrestage ab Startdatum (1-basierte Zeilen), Port von `.anniv_ends`."
function _anniv_ends(dates, frequency)
    stp = frequency == "year" ? 12 : frequency == "quarter" ? 3 : 1
    d = _todate(dates, "dates")
    d0, d1 = d[1], d[end]
    nmon = (Dates.year(d1) - Dates.year(d0)) * 12 + Dates.month(d1) - Dates.month(d0)
    last = fld(nmon, stp) * stp
    ks = last >= 0 ? collect(0:stp:last) : Int[]
    tg = _todate(SimLev.DataPrep._add_months(d0, ks), "dates")
    tg = tg[tg .<= d1]
    dd = _days.(d)
    out = Int[]
    for t in tg
        v = searchsortedlast(dd, _days(t))
        v in out || push!(out, v)
    end
    return out
end

function _aux_kind(cfg, inflation, it_given, inflation_type)
    sets = _cfg_list(cfg, "aux_type_set")
    (!(inflation isa AbstractString) || !(inflation in sets)) && return nothing
    k = _aux_type_of(_get(cfg, "aux_type"), inflation)
    it = k == "level" ? "level" : "rate_pa"
    if it_given && inflation_type != it
        _stop(@sprintf("inflation_type = '%s' passt nicht zu aux_type['%s'] = '%s' in bootstrap_config(); inflation_type weglassen oder '%s' angeben.",
                       inflation_type, inflation, k, it))
    end
    return k
end

function _is_result_list(x)
    (x isa RList || x isa RFrame) && return false
    vals = x isa AbstractDict || x isa NamedTuple ? collect(values(x)) : x isa AbstractVector ? collect(x) : nothing
    vals === nothing && return false
    return !isempty(vals) && all(_is_result, vals)
end

_vapply_mat(vecs, L) = L == 1 ? reshape(Float64[v[1] for v in vecs], :, 1) :
                       (isempty(vecs) ? zeros(L, 0) : reduce(hcat, [_dvec(v) for v in vecs]))

"""
    withdrawal_paths(x; column = nothing, strategy = nothing, inflation = nothing, inflation_type = "level",
                     frequency = "year", dates = nothing, start_date = "2000-01-01", cape = nothing)

Pfade in Periodenrenditen für Entnahmen umwandeln (Port von `withdrawal_paths()`).
`x`: SimLevBootstrapStudy, Liste von SimLevResult oder bootstrap_result.
"""
function withdrawal_paths(x; column = nothing, strategy = nothing, inflation = nothing, inflation_type = _MISSING,
                          frequency = nothing, dates = nothing, start_date = "2000-01-01", cape = nothing)
    x = SimLev.as_rframe(x)
    it_given = inflation_type !== _MISSING
    frequency = _match_arg(frequency, ("year", "quarter", "month"))
    inflation_type = _match_arg(it_given ? inflation_type : nothing, ("level", "rate_pa"))
    if inflation !== nothing
        okv = inflation isa AbstractString || (_isnum(inflation) && isfinite(Float64(inflation)))
        okv || _stop("inflation muss NULL, eine Zahl (Prozent p. a.) oder der Name einer Zusatzreihe sein.")
    end
    function infl_from(n_per, n_paths, ends_dates)
        inflation === nothing && return ones(n_per, n_paths)
        inflation isa AbstractString && return nothing
        f = _pow_vec(1 + Float64(inflation) / 100, Float64[_days(ends_dates[i+1]) - _days(ends_dates[i]) for i in 1:length(ends_dates)-1] ./ 365.25)
        return reshape(Float64[f[(i-1)%length(f)+1] for i in 1:n_per*n_paths], n_per, n_paths)
    end
    mk(R, I, C, w, src, freq) = RList("returns" => _as_matrix(R), "inflation" => _as_matrix(I),
                                      "cape" => C === nothing ? nothing : _as_matrix(C), "base_rate" => nothing,
                                      "frequency" => freq, "start_dates" => nothing, "historical" => false,
                                      "weights" => w, "source" => src; class = "withdrawal_paths")
    # 1) Gespeicherte Bootstrap-Studie
    if _is_study(x)
        rets = _get(x, "returns")
        rets === nothing && _stop("Die Studie enthält keine Periodenrenditen; bootstrap_study(..., keep_returns = 'year') verwenden.")
        rn = collect(String, keys(rets))
        strategy = strategy === nothing ? rn[1] : strategy
        strategy in rn || _stop(@sprintf("Strategie '%s' nicht gespeichert. Verfügbar: %s", strategy, join(rn, ", ")))
        freq = x["returns_frequency"]
        R = _mat(rets[strategy])
        ok = Bool[!any(isnan, view(R, :, j)) for j in 1:size(R, 2)]
        if inflation isa AbstractString
            ar = _get(x, "aux_returns")
            (ar === nothing || _get(ar, inflation) === nothing) && _stop(@sprintf("Zusatzreihe '%s' nicht gespeichert (keep_aux).", inflation))
            kind = _aux_kind(x["config"], inflation, it_given, inflation_type)
            if kind === nothing && it_given && inflation_type == "rate_pa"
                _stop(@sprintf("inflation_type = 'rate_pa': die mit keep_aux gespeicherten Faktoren der Zusatzreihe '%s' sind die Niveau-Variante (Reihe nicht in aux_type genannt). Für eine Rate in Prozent p. a. aux_type = c(%s = 'rate') in bootstrap_config() angeben und die Studie neu rechnen.",
                               inflation, inflation))
            end
            I0 = _mat(ar[inflation])
            r = vec(I0[:, ok])
            bad = .!isfinite.(r) .| (r .<= 0)
            if any(bad)
                msg = kind == "rate" ? "Zusatzreihe '%s' (aux_type 'rate') ergibt nicht endliche oder nicht positive Periodenfaktoren (z. B. %s)." :
                      "Zusatzreihe '%s' ist kein positives Niveau (gespeicherte Periodenverhältnisse nicht endlich oder <= 0, z. B. %s); für eine Rate in Prozent p. a. aux_type = c(<Name> = 'rate') in bootstrap_config() angeben."
                _stop(_sp(msg, inflation, _fmt_nan(r[bad][1]; digits = 4)))
            end
            I = I0
        else
            I = infl_from(size(R, 1), size(R, 2), x["returns_dates"])
        end
        w = _get(x, "path_weights")
        return mk(R[:, ok], I[:, ok], nothing, w === nothing ? nothing : _dvec(w)[ok], "study:" * strategy, freq)
    end
    # 2) Liste von simulation()-Ergebnissen
    if !_is_boot_result(x) && _is_result_list(x)
        inflation isa AbstractString && _stop("Bei Ergebnislisten ist 'inflation' ein Prozentsatz p. a.")
        lst = x isa AbstractDict || x isa NamedTuple ? collect(values(x)) : collect(x)
        idx = [result_index(r) for r in lst]
        ends = _anniv_ends(idx[1]["date"], frequency)
        length(ends) < 2 && _stop("Ergebnisse zu kurz für eine volle Periode.")
        vecs = Vector{Float64}[]
        for d in idx
            SimLev.nrow(d) != SimLev.nrow(idx[1]) && _stop("Alle Ergebnisse müssen gleich lang sein.")
            v = d["value"][ends]
            push!(vecs, v[2:end] ./ v[1:end-1])
        end
        R = _vapply_mat(vecs, length(ends) - 1)
        return mk(R, infl_from(size(R, 1), size(R, 2), idx[1]["date"][ends]), nothing, nothing, "results", frequency)
    end
    # 3) bootstrap()-Pfade
    _is_boot_result(x) || _stop("x muss ein bootstrap_result, eine Liste von SimLevResult oder eine SimLevBootstrapStudy sein.")
    column === nothing && _stop("Bei bootstrap_result muss 'column' angegeben werden.")
    P1 = x["paths"][1]
    cn = something(B._colnames(P1), String[])
    column in cn || _stop(@sprintf("Spalte '%s' nicht im Pfad. Verfügbar: %s", column, join(cn, ", ")))
    nr = B._nrow(P1)
    if dates === nothing
        dates = _seq_dates(_todate(start_date, "start_date")[1], nr)
    else
        dates = _todate(dates, "dates")
        length(dates) != nr && _stop(@sprintf("dates hat Länge %d, die Pfade haben %d Zeilen (path_length + 1); ein Datum je Pfadzeile angeben.", length(dates), nr))
        dv = _days.(dates)
        any(diff(dv) .<= 0) && _stop("dates muss streng aufsteigend sein und darf kein NA enthalten.")
    end
    ends = _anniv_ends(dates, frequency)
    length(ends) < 2 && _stop("Pfade zu kurz für eine volle Periode der gewählten frequency.")
    e1 = ends[2:end]; e0 = ends[1:end-1]
    per(v) = (v = _dvec(v); v[e1] ./ v[e0])
    pcol(P, c) = P isa RFrame ? _dvec(P[c]) : _mat(P)[:, findfirst(==(c), B._colnames(P))]
    n_per = length(ends) - 1
    R = _vapply_mat([per(pcol(P, column)) for P in x["paths"]], n_per)
    I = infl_from(size(R, 1), size(R, 2), dates[ends])
    if I === nothing
        inflation in cn || _stop(@sprintf("Zusatzreihe '%s' nicht im Pfad. Verfügbar: %s", inflation, join(cn, ", ")))
        kind = _aux_kind(_get(x, "config", RList()), inflation, it_given, inflation_type)
        kind === nothing || (inflation_type = kind == "level" ? "level" : "rate_pa")
        dt = Float64[_days(dates[i+1]) - _days(dates[i]) for i in 1:length(dates)-1] ./ 365.25
        vecs = Vector{Float64}[]
        for P in x["paths"]
            if inflation_type == "rate_pa"
                v = pcol(P, inflation)
                r = per(_cumprod(vcat(1.0, _pow_vec(1 .+ v[2:end] ./ 100, dt))))
                bad = .!isfinite.(r) .| (r .<= 0)
                if any(bad)
                    _stop(@sprintf("Zusatzreihe '%s' (Rate in Prozent p. a.) ergibt nicht endliche oder nicht positive Periodenfaktoren (z. B. %s; Rate <= -100 %%?).",
                                   inflation, _fmt_nan(r[bad][1]; digits = 4)))
                end
                push!(vecs, r)
                continue
            end
            lv = P isa NamedMat ? get(P.attrs, "aux_level", nothing) : P isa RFrame ? get(SimLev.attrs(P), "aux_level", nothing) : nothing
            v = if kind == "level"
                pcol(P, inflation)
            elseif lv !== nothing && inflation in something(B._colnames(lv), String[])
                pcol(lv, inflation)
            elseif _get(x, "method") in ("wild", "reset")
                pcol(P, inflation)
            else
                _stop(@sprintf("inflation_type = 'level': Pfad ohne Niveau-Variante der Reihe '%s' (Attribut aux_level); beim Verfahren '%s' springen die Originalwerte an Blockgrenzen. Pfade mit bootstrap() neu erzeugen.",
                               inflation, _get(x, "method")))
            end
            r = per(v)
            any(.!isfinite.(r) .| (r .<= 0)) &&
                _stop(@sprintf("Zusatzreihe '%s' ist kein positives Niveau (Verhältnisse nicht endlich oder <= 0); für eine Rate inflation_type = 'rate_pa' verwenden.", inflation))
            push!(vecs, r)
        end
        I = _vapply_mat(vecs, n_per)
    end
    C = nothing
    if cape !== nothing
        cv = [pcol(P, cape)[e0] for P in x["paths"]]
        C = n_per == 1 ? Float64[v[1] for v in cv] : reduce(hcat, cv)
    end
    return mk(R, I, C, _get(x, "weights"), column, frequency)
end

# ═══════════════════════════════════════════════════════════════════════════
# Perfect Withdrawal Rate
# ═══════════════════════════════════════════════════════════════════════════

"Reale Jahresrenditen aus Perioden-Matrizen (Port von `.annual_real`)."
function _annual_real(wp)
    ppy = _wd_ppy(_get(wp, "frequency"))
    real = _mat(_get(wp, "returns")) ./ _mat(_get(wp, "inflation"))
    ppy == 1 && return real
    ny = size(real, 1) ÷ ppy
    return _apply_cols(real[1:ny*ppy, :], c -> _agg_prod(c, ppy))
end

"""
    perfect_withdrawal_rate(real_returns; legacy = 0)

Perfect Withdrawal Rate (PWR) je Pfad in Prozent. `real_returns`: Matrix
(Jahre × Pfade) realer Brutto-Jahresrenditen, Vektor (ein Pfad) oder
`withdrawal_paths`-Objekt.
"""
function perfect_withdrawal_rate(real_returns; legacy = 0)
    _is_wp(real_returns) && (real_returns = _annual_real(real_returns))
    R = try
        _numvec(real_returns) === nothing ? nothing : _as_matrix(real_returns)
    catch
        nothing
    end
    if R === nothing || isempty(R) || any(isnan, R) || any(!isfinite, R)
        _stop("perfect_withdrawal_rate: real_returns muss eine Matrix endlicher realer Brutto-Jahresrenditen sein (1.05 = +5 %).")
    end
    med = _median(vec(R))
    if med < 0.5
        _stop(@sprintf("perfect_withdrawal_rate: real_returns sieht nicht wie Brutto-Renditen aus (Median %s); erwartet z. B. 1.05 für +5 %%, nicht 0.05 (Nettorendite: 1 + r übergeben).",
                       _fmt1(med; digits = 4)))
    end
    any(<(0), R) && _stop("perfect_withdrawal_rate: Brutto-Renditen in real_returns müssen >= 0 sein (0 = Totalverlust).")
    lv = _numvec(legacy)
    if lv === nothing || length(lv) != 1 || !isfinite(lv[1]) || lv[1] < 0
        _stop(@sprintf("perfect_withdrawal_rate: legacy muss ein Anteil >= 0 sein (0.5 = 50 %% des Startvermögens; erhalten: %s).", _show(legacy)))
    end
    lg = lv[1]
    out = Vector{Float64}(undef, size(R, 2))
    for j in 1:size(R, 2)
        r = R[:, j]
        tp = reverse(_cumprod(reverse(r)))
        out[j] = (_rprod(r) - lg) / _rsum(tp) * 100
    end
    return out
end

# ═══════════════════════════════════════════════════════════════════════════
# Lots der Ansparphase
# ═══════════════════════════════════════════════════════════════════════════

_lots_df(a) = _get(a, "lots")
_lcol(L, nm) = L === nothing ? Float64[] : _dvec(L isa RFrame ? L[nm] : _get(L, nm))
_lrows(L) = L === nothing ? 0 : L isa RFrame ? SimLev.nrow(L) : length(_lcol(L, "units"))
function _last_worth(report, nm)
    r = _get(report, nm)
    wv = _dvec(_get(r, "worth", Float64[]))
    return isempty(wv) ? wv : wv[end:end]
end
_list_names(ol) = ol === nothing ? String[] : collect(String, something(_names(ol), String[]))

"Am Ende der Ansparphase gehaltene Assets (Port von `.wd_held`)."
function _wd_held(ol, report, sv; tol = 1e-12)
    out = String[]
    for nm in _list_names(ol)
        L = _lots_df(_get(ol, nm))
        wv = _last_worth(report, nm)
        if _lrows(L) > 0 && _rsum(_lcol(L, "units")) > 0 && length(wv) == 1 && isfinite(wv[1]) && wv[1] > tol * sv
            push!(out, nm)
        end
    end
    return out
end

"Offene Lots als FIFO-Bestand für den Kern (Port von `.wd_lots`)."
function _wd_lots(ol, report, sv; tol = 1e-12)
    n = Float64[]; basis = Float64[]; vp = Float64[]; group = Int[]
    g = 0
    assets = 0.0
    for nm in _wd_held(ol, report, sv; tol = tol)
        L = _lots_df(_get(ol, nm))
        units = _lcol(L, "units")
        U = _rsum(units)
        keep = units .> 0
        u = units[keep]
        pr = _lcol(L, "price")[keep]
        v = _lcol(L, "vp")[keep]
        wv = _last_worth(report, nm)[1]
        append!(n, u ./ U .* wv)
        append!(basis, u .* pr)
        append!(vp, v)
        append!(group, fill(g, length(u)))
        g += 1
        assets = assets + wv
    end
    cash = sv - assets
    if abs(cash) > tol * sv
        push!(n, cash); push!(basis, cash); push!(vp, 0.0); push!(group, g)
    end
    return RList("n" => n, "basis" => basis, "vp" => vp, "group" => group)
end

"Ist eine Ordergebühr gesetzt (Zahl oder Liste(fixed, percent, min, max))?"
function _wd_fee_set(f)
    f === nothing && return false
    v = Any[]
    if f isa Union{RList,NamedTuple,AbstractDict}
        for k in something(_names(f), String[])
            k in ("fixed", "percent", "min") || continue
            x = _get(f, k)
            x === nothing && continue
            append!(v, x isa AbstractVector ? collect(x) : [x])
        end
    else
        append!(v, f isa AbstractVector ? collect(f) : [f])
    end
    out = Float64[]
    for z in v
        push!(out, z isa Bool ? Float64(z) : z isa Real ? Float64(z) : z isa AbstractString ? something(tryparse(Float64, strip(z)), NaN) : NaN)
    end
    return any(z -> isfinite(z) && z != 0, out)
end

# ═══════════════════════════════════════════════════════════════════════════
# withdrawal_simulation()
# ═══════════════════════════════════════════════════════════════════════════

_dflt(x, d) = x === _MISSING ? d : x
_sv_get(r, path...) = (v = r; for k in path; v = _get(v, k); end; v)

"Mittel bzw. Summe je Spalte in long double (colMeans/colSums)."
function _col_ld(M::Matrix{Float64}, mean::Bool)
    out = Vector{Float64}(undef, size(M, 2))
    for j in 1:size(M, 2)
        s = SimLev.F80(0.0)
        for i in 1:size(M, 1)
            s = s + SimLev.F80(M[i, j])
        end
        mean && (s = s / SimLev.F80(size(M, 1)))
        out[j] = Float64(s)
    end
    return out
end

"""
    withdrawal_simulation(x, rule = withdrawal_rule("constant"); start_value = 1e6, inflation = 0,
                          frequency = "year", strategy = nothing, years = nothing, timing = "start",
                          income = nothing, tax_mode = "none", tax_rate = 26.375, asset_bonus = 30,
                          sparer_pauschbetrag = 1000, base_rate = 3.20, vorabpauschale = true, sale_cost = 0,
                          cost_basis = 100, loss_carryforward = 0, gamma = 2, keep_paths = true, horizon = nothing)

Entnahme-Simulation über viele Pfade (Port von `withdrawal_simulation()`).
`x`: withdrawal_paths, Renditematrix (Perioden × Pfade), SimLevResult,
Liste von SimLevResult oder Bootstrap-Studie. Ergebnis: RList der Klasse
`SimLevWithdrawal`.
"""
function withdrawal_simulation(x, rule_pos = _MISSING; rule = _MISSING, start_value = 1e6, inflation = 0,
                               frequency = nothing, strategy = nothing, years = nothing, timing = nothing,
                               income = nothing, tax_mode = nothing, tax_rate = 26.375, asset_bonus = _MISSING,
                               sparer_pauschbetrag = 1000, base_rate = 3.20, vorabpauschale = _MISSING,
                               sale_cost = _MISSING, cost_basis = _MISSING, loss_carryforward = _MISSING,
                               gamma = 2, keep_paths = true, horizon = nothing)
    x = SimLev.as_rframe(x)
    rule_pos === _MISSING || (rule = rule_pos)
    rule === _MISSING && (rule = withdrawal_rule("constant"))
    ab_missing = asset_bonus === _MISSING; vp_missing = vorabpauschale === _MISSING
    sc_missing = sale_cost === _MISSING; cb_missing = cost_basis === _MISSING; lc_missing = loss_carryforward === _MISSING
    asset_bonus = _num(_dflt(asset_bonus, 30.0)); vorabpauschale = _dflt(vorabpauschale, true)
    sale_cost = _num(_dflt(sale_cost, 0.0)); cost_basis = _num(_dflt(cost_basis, 100.0))
    loss_carryforward = _num(_dflt(loss_carryforward, 0.0))
    freq_arg = frequency
    timing = _match_arg(timing, ("start", "end"))
    tax_mode = _match_arg(tax_mode, ("none", "person"))
    if horizon !== nothing && !_is_horizon(horizon)
        if !_num1(horizon) || _f1(horizon) <= 0
            _stop(@sprintf("withdrawal_simulation: 'horizon' muss NULL, ein Objekt aus horizon_model() oder eine Zahl von Jahren > 0 sein, nicht %s.",
                           _show(horizon)))
        end
        horizon = horizon_model("fixed"; years = horizon)
    end
    _is_rule(rule) || _stop("rule muss mit withdrawal_rule() erstellt werden.")
    inflation === nothing && (inflation = 0)
    function chk(v, arg, what; lo = 0.0, hi = Inf)
        if !_num1(v) || _f1(v) < lo || _f1(v) > hi
            _stop(@sprintf("withdrawal_simulation: '%s' muss %s sein, nicht %s.", arg, what, _rshow(v)))
        end
    end
    function frac(v, arg; hi = 1.0, unit = "%")
        if _num1(v) && 0 < _f1(v) < hi
            _warn(@sprintf("withdrawal_simulation: %s = %s wird als %s %s gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                           arg, _fmt1(_num(v)), _fmt1(_num(v)), unit, _fmt1(_f1(v) * 100)))
        end
    end
    chk(tax_rate, "tax_rate", "eine Zahl von 0 bis 100 in Prozent (z. B. 26.375)"; lo = 0.0, hi = 100.0); frac(tax_rate, "tax_rate")
    chk(asset_bonus, "asset_bonus", "eine Zahl von 0 bis 100 in Prozent (z. B. 30)"; lo = 0.0, hi = 100.0); frac(asset_bonus, "asset_bonus")
    chk(sparer_pauschbetrag, "sparer_pauschbetrag", "eine Zahl >= 0 (EUR je Planjahr, z. B. 1000)")
    chk(sale_cost, "sale_cost", "eine Zahl von 0 bis unter 100 in Prozent (z. B. 0.1)"; lo = 0.0, hi = 99.999)
    chk(cost_basis, "cost_basis", "eine Zahl >= 0 in Prozent des Startwerts (z. B. 100)"); frac(cost_basis, "cost_basis")
    chk(loss_carryforward, "loss_carryforward", "eine Zahl >= 0 (EUR)")
    chk(gamma, "gamma", "eine Zahl >= 0 (relative Risikoaversion, z. B. 2)")
    for (a, v) in (("vorabpauschale", vorabpauschale), ("keep_paths", keep_paths))
        v isa Bool || _stop(@sprintf("withdrawal_simulation: '%s' muss TRUE oder FALSE sein, nicht %s.", a, _rshow(v)))
    end
    infl_is_mat = inflation isa AbstractMatrix
    if (_isnum(inflation)) || (inflation isa AbstractVector && length(inflation) == 1 && _numvec(inflation) !== nothing)
        chk(inflation, "inflation", "eine Zahl in Prozent p. a. über -100 (z. B. 2) oder eine Matrix"; lo = -99.999)
        frac(inflation, "inflation"; hi = 0.05, unit = "% p. a.")
    end
    br_is_mat = base_rate isa AbstractMatrix
    br_is_mat || frac(base_rate, "base_rate"; hi = 0.05)
    if years !== nothing && (!_num1(years) || _f1(years) <= 0)
        _stop(@sprintf("years muss eine positive Zahl von Jahren sein (erhalten: %s).", _show(years)))
    end
    (!br_is_mat && !_num1(base_rate)) && _stop("base_rate muss eine Zahl (Prozent) oder eine Matrix Perioden x Pfade sein.")
    if income isa Union{RList,NamedTuple,AbstractDict} && _get(income, "amount") !== nothing &&
       !(_get(income, "amount") isa Union{RList,NamedTuple,AbstractDict})
        income = Any[income]
    end
    if income !== nothing
        okinc = income isa AbstractVector && all(e -> e isa Union{RList,NamedTuple,AbstractDict} && _num1(_get(e, "amount")), income)
        okinc || _stop("income muss eine Liste von list(start = Jahr, end = Jahr, amount = Betrag) sein (amount: realer Jahresbetrag).")
    end
    lots = nothing
    adopted = RList()
    spb_used1 = 0.0
    if _is_result(start_value)
        sres = start_value
        acc = result_index(sres)
        sv = acc["worth"][end]
        if !isfinite(sv) || sv <= 0
            debt = _sv_get(sres, "tax_report", "open_tax_debt")
            debt === nothing && (debt = 0.0)
            extra = (_num1(debt) && _f1(debt) > 0) ? _sp(" (offene, nicht gedeckte Steuerschuld der Ansparphase: %s EUR, tax_report\$open_tax_debt)", _sp("%.2f", _f1(debt))) : ""
            _stop(_sp("start_value: Endwert der Ansparphase (SimLevResult) ist %s EUR; withdrawal_simulation() braucht ein positives Startvermögen%s.",
                      _sp("%.2f", sv), extra))
        end
        ol = _get(sres, "open_lots")
        ol_names = _list_names(ol)
        has_lots = !isempty(ol_names) && all(nm -> begin
                a = _get(ol, nm); L = _lots_df(a)
                (L isa RFrame && all(c -> haskey(L, c), ("units", "price", "vp"))) && _isnum(_get(a, "cash"))
            end, ol_names)
        cb_given = !cb_missing
        report = _get(sres, "report")
        rep_names = _list_names(report)
        if !cb_given
            held = [_last_worth(report, nm) for nm in rep_names]
            held_v = Float64[length(h) == 1 ? h[1] : NaN for h in held]
            if !isempty(held_v) && all(isfinite, held_v) && all(==(0), held_v)
                cost_basis = 100.0
            elseif has_lots
                bs = Float64[]
                for nm in ol_names
                    a = _get(ol, nm); L = _lots_df(a)
                    push!(bs, _rsum(_lcol(L, "units") .* _lcol(L, "price")) + _rsum(_lcol(L, "vp")) + Float64(_get(a, "cash")))
                end
                basis = _rsum(bs)
                cost_basis = 100 * basis / sv
                tax_mode == "person" && (lots = _wd_lots(ol, report, sv))
            else
                tax_mode == "person" && _warn("cost_basis: Näherung 100 x (Startwert brutto + Einzahlungen) / Endwert, da das Ansparergebnis keine offenen Lots enthält (simulation() ohne tax_mode = 'person' oder älteres Ergebnis); realisierte Gewinne und Cash zählen dabei als stille Reserven. Für genaue Werte die Ansparphase mit tax_mode = 'person' rechnen oder cost_basis angeben.")
                inv = _get(sres, "invested")
                inv = inv === nothing ? Float64[] : _dvec(inv)
                start_gross = !isempty(inv) ? inv[1] : acc["worth"][1]
                fl = acc["flows"]
                invested = start_gross + _rsum(Float64[_pmax(f, 0.0) for f in fl[2:end]])
                cost_basis = 100 * invested / sv
            end
        end
        if tax_mode == "person" && has_lots
            hold_n = _wd_held(ol, report, sv)
            hold = [_get(ol, nm) for nm in hold_n]
            reg = String[string(_get(a, "regime", "investment_fund")) for a in hold]
            fund = reg .== "investment_fund"
            mixed = any(fund) && !all(fund)
            if !isempty(hold) && !any(fund) && vp_missing
                vorabpauschale = false
                adopted["vorabpauschale"] = false
            end
            if mixed
                _warn(_sp("Am Ende gehaltene Assets mit verschiedenen Regimen (Investmentfonds: %s; andere: %s): withdrawal_simulation() wendet Vorabpauschale (vorabpauschale = %s) und Teilfreistellung (asset_bonus = %g %%) auf den ganzen Bestand an; beide werden nicht übernommen.",
                          join(hold_n[fund], ", "), join(hold_n[.!fund], ", "), _istrue(vorabpauschale) ? "TRUE" : "FALSE", asset_bonus))
            end
            if any(==("private_sale"), reg)
                _warn(_sp("Assets mit Regime 'private_sale' (Paragraf 23 EStG: %s) am Ende der Ansparphase: Spekulationsfrist und Freigrenze bildet withdrawal_simulation() nicht ab; deren Gewinne werden wie Fondsgewinne mit Teilfreistellung asset_bonus = %g %% besteuert.",
                          join(hold_n[reg .== "private_sale"], ", "), asset_bonus))
            end
            fs = reg .!= "private_sale"
            tfs_all = Float64[r == "investment_fund" ? Float64(_get(a, "asset_bonus", 0.0)) : 0.0 for (a, r) in zip(hold, reg)]
            tfs = tfs_all[fs]
            fs_names = hold_n[fs]
            if ab_missing && !mixed && !isempty(tfs) && all(fs) && all(abs.(tfs .- tfs[1]) .< 1e-9)
                asset_bonus = tfs[1]
                adopted["asset_bonus"] = asset_bonus
            elseif !mixed && !isempty(tfs) && any(abs.(tfs .- asset_bonus) .> 1e-9)
                _warn(_sp("asset_bonus = %g %%, aber die am Ende gehaltenen Assets haben die Teilfreistellung %s; withdrawal_simulation() rechnet mit einer Teilfreistellung für den ganzen Bestand (asset_bonus passend angeben; bei verschiedenen Werten keine exakte Abbildung).",
                          asset_bonus, join([_sp("%s %g %%", n, t) for (n, t) in zip(fs_names, tfs)], ", ")))
            end
            tr = _get(sres, "tax_report")
            ny_ = _get(tr, "next_year")
            num1p(v) = _num1(v) && _f1(v) >= 0
            ny_is_list = ny_ isa Union{RList,NamedTuple,AbstractDict}
            lc = (ny_is_list && num1p(_get(ny_, "loss_carryforward_capital"))) ? _get(ny_, "loss_carryforward_capital") :
                 _get(tr, "loss_carryforward_capital")
            if lc_missing && num1p(lc)
                loss_carryforward = _f1(lc)
                adopted["loss_carryforward"] = _f1(lc)
            end
            ny_is_list && num1p(_get(ny_, "sparer_pauschbetrag_used")) && (spb_used1 = _f1(_get(ny_, "sparer_pauschbetrag_used")))
            spr = Float64[(s = _get(a, "asset_spread"); _isnum(s) ? Float64(s) : NA) for a in hold]
            if sc_missing && !isempty(spr) && !any(isnan, spr)
                if all(abs.(spr .- spr[1]) .< 1e-12)
                    sale_cost = spr[1] / 2
                    adopted["sale_cost"] = sale_cost
                else
                    _warn(_sp("sale_cost nicht übernommen: die gehaltenen Assets haben verschiedene Spreads (%s); withdrawal_simulation() rechnet mit einem Verkaufskostensatz für den ganzen Bestand (sale_cost angeben).",
                              join([_sp("%s %g %%", n, s) for (n, s) in zip(hold_n, spr)], ", ")))
                end
            end
            fee_set = Bool[_wd_fee_set(_get(a, "order_fee")) for a in hold]
            if any(fee_set)
                _warn(_sp("Ordergebühren der Ansparphase (%s) bildet withdrawal_simulation() beim Verkauf nicht ab; gegebenenfalls in sale_cost (Prozent des Verkaufsbetrags) berücksichtigen.",
                          join(hold_n[fee_set], ", ")))
            end
        end
        spb_used1 > 0 && (adopted["sparer_pauschbetrag_used_year1"] = spb_used1)
        if lots !== nothing
            adopted["lots"] = length(lots["n"])
        elseif !cb_given && tax_mode == "person"
            adopted["cost_basis"] = cost_basis
        end
        if length(adopted) > 0
            parts = String[]
            for (k, v) in adopted
                if k == "lots"
                    push!(parts, @sprintf("%d Lots (FIFO)", v))
                elseif v isa Bool
                    push!(parts, string(k, " = ", v ? "TRUE" : "FALSE"))
                else
                    push!(parts, string(k, " = ", _fmt1(SimLev.RFmt.signif(Float64(v), 8))))
                end
            end
            _message("Hinweis: aus der Ansparphase übernommen: " * join(parts, ", ") * ".")
        end
        start_value = sv
    end
    (!_num1(start_value) || _f1(start_value) <= 0) &&
        _stop(@sprintf("start_value muss ein positiver Geldbetrag (Zahl > 0) oder ein SimLevResult sein (erhalten: %s).", _wshow(start_value)))
    start_value = Float64(_f1(start_value))
    src_taxed = false
    if _is_result(x)
        tp = _sv_get(x, "tax_report", "total_taxes_paid")
        src_taxed = _num1(tp) && _f1(tp) > 0
        (_isnum(inflation)) || _stop("Bei einem SimLevResult ist 'inflation' ein Prozentsatz p. a.")
        x = withdrawal_cohorts(x; inflation = inflation, years = years === nothing ? 30 : years,
                               frequency = _match_arg(freq_arg, ("year", "quarter", "month")))
    elseif _is_study(x) || _is_result_list(x)
        if !_is_study(x)
            lst = x isa AbstractDict || x isa NamedTuple ? collect(values(x)) : collect(x)
            src_taxed = any(r -> (tp = _sv_get(r, "tax_report", "total_taxes_paid"); _num1(tp) && _f1(tp) > 0), lst)
        end
        x = withdrawal_paths(x; strategy = strategy, inflation = inflation, frequency = _match_arg(freq_arg, ("year", "quarter", "month")))
    end
    if src_taxed && tax_mode == "person" && _istrue(vorabpauschale)
        _warn("Das Quellergebnis wurde mit Steuern gerechnet (Vorabpauschale im Index enthalten); vorabpauschale = FALSE oder eine Quelle mit tax_mode = 'none' vermeidet Doppelzählung.")
    end
    if !_is_wp(x)
        frequency = _match_arg(freq_arg, ("year", "quarter", "month"))
        R = _numvec(x) === nothing ? nothing : _as_matrix(x)
        (R === nothing || isempty(R)) && _stop("x muss eine numerische Matrix (Perioden x Pfade) von Brutto-Periodenrenditen sein.")
        any(v -> !isnan(v) && v < 0, R) && _stop("x muss Brutto-Periodenrenditen enthalten (z. B. 1.05 für +5 %).")
        any(isnan, R) && _stop("missing value where TRUE/FALSE needed")
        _median(vec(R)) < 0.5 && _stop("x muss Brutto-Periodenrenditen enthalten (z. B. 1.05 für +5 %).")
        if infl_is_mat && size(inflation) != size(R)
            _stop(@sprintf("inflation als Matrix braucht dieselbe Dimension wie die Renditen (%d x %d), hat aber %d x %d.",
                           size(R, 1), size(R, 2), size(inflation, 1), size(inflation, 2)))
        end
        (!infl_is_mat && !_num1(inflation)) && _stop("inflation muss eine Zahl (Prozent p. a.) oder eine Matrix Perioden x Pfade sein.")
        I = infl_is_mat ? _mat(inflation) : fill(_rpow(1 + _f1(inflation) / 100, 1 / _wd_ppy(frequency)), size(R))
        x = RList("returns" => R, "inflation" => I, "cape" => nothing, "base_rate" => nothing, "frequency" => frequency,
                  "historical" => false, "start_dates" => nothing, "weights" => nothing, "source" => "matrix";
                  class = "withdrawal_paths")
    end
    ppy = _wd_ppy(_get(x, "frequency"))
    R = _get(x, "returns"); I = _get(x, "inflation")
    (!(R isa AbstractMatrix) || size(R, 1) == 0 || size(R, 2) == 0) && _stop("Keine Renditen (leere Matrix bzw. keine Pfade).")
    R = _mat(R); I = _mat(I)
    (any(isnan, R) || any(isnan, I)) && _stop("Renditen/Inflation enthalten NA.")
    size(I) != size(R) && _stop(@sprintf("Inflation (%d x %d) passt nicht zu den Renditen (%d x %d).", size(I, 1), size(I, 2), size(R, 1), size(R, 2)))
    xcape = _get(x, "cape"); xbase = _get(x, "base_rate")
    if br_is_mat
        base_rate = _mat(base_rate)
        if xbase === nothing && size(base_rate) != size(R)
            _stop(@sprintf("base_rate als Matrix braucht dieselbe Dimension wie die Renditen (%d x %d Perioden x Pfade), hat aber %d x %d.",
                           size(R, 1), size(R, 2), size(base_rate, 1), size(base_rate, 2)))
        end
    end
    if years !== nothing
        yy = _f1(years)
        abs(yy * ppy - _round0(yy * ppy)) > 1e-8 && _stop(@sprintf("years = %s ergibt keine ganze Zahl von Perioden (%d je Jahr).", _fmt1(_num(years)), ppy))
        kr = min(size(R, 1), Int(_round0(yy * ppy)))
        R = R[1:kr, :]; I = I[1:kr, :]
        xcape === nothing || (xcape = _mat(xcape)[1:kr, :])
        xbase === nothing || (xbase = _mat(xbase)[1:kr, :])
        br_is_mat && (base_rate = base_rate[1:kr, :])
    end
    size(R, 1) % ppy != 0 && _warn("Periodenzahl ist kein Vielfaches eines Jahres; letztes Planjahr unvollständig.")
    ny = cld(size(R, 1), ppy)
    nfy = size(R, 1) ÷ ppy
    rule["type"] == "cape" && xcape === nothing && _stop("Die CAPE-Regel braucht eine CAPE-Reihe (Argument cape in withdrawal_cohorts/withdrawal_paths).")
    CAPE = xcape !== nothing ? _mat(xcape) : zeros(size(R, 1), 0)
    BASE = xbase !== nothing ? _mat(xbase) : br_is_mat ? base_rate : fill(Float64(_f1(base_rate)), size(R))
    inc = zeros(ny)
    for e in something(income, Any[])
        s0 = _get(e, "start", 1.0); e0 = _get(e, "end", _get(e, "end_", Inf))
        sv0 = _numvec(s0); ev0 = _numvec(e0)
        if sv0 === nothing || ev0 === nothing || length(sv0) != 1 || length(ev0) != 1 || isnan(sv0[1]) || isnan(ev0[1]) || ev0[1] < sv0[1]
            _stop(@sprintf("income: start und end müssen Planjahre mit start <= end sein (erhalten: start = %s, end = %s).", _wshow(s0), _wshow(e0)))
        end
        s1 = max(1, Int(ceil(sv0[1])))
        e1 = isfinite(ev0[1]) ? min(ny, Int(floor(ev0[1]))) : ny
        if s1 <= e1
            amt = Float64(_f1(_get(e, "amount")))
            for k in s1:e1
                inc[k] = inc[k] + amt
            end
        end
    end
    rp = _wd_param_vector(rule)
    t0 = time()
    core = _wcore().wd_simulate(R, I, CAPE, BASE, ppy, _rule_code(rule["type"]), rp, timing == "start", start_value, inc,
                                tax_mode == "person", Float64(tax_rate) / 100, Float64(asset_bonus) / 100, Float64(sparer_pauschbetrag),
                                _istrue(vorabpauschale), Float64(sale_cost) / 100, Float64(cost_basis) / 100, Float64(loss_carryforward),
                                _istrue(keep_paths) || horizon !== nothing,
                                lots === nothing ? Float64[] : lots["n"], lots === nothing ? Float64[] : lots["basis"],
                                lots === nothing ? Float64[] : lots["vp"], lots === nothing ? Int[] : lots["group"],
                                spb_used1 > 0 ? max(0.0, Float64(sparer_pauschbetrag) - spb_used1) : -1.0, horizon !== nothing)
    sp = core["spending"]
    w0 = sp[1, :]
    gamma = Float64(gamma)
    function ce_fun(c)
        c = Float64[_pmax(v, 1e-9 * start_value) for v in c]
        abs(gamma - 1) < 1e-12 && return _rexp(_rmean(Float64[_rlog(v) for v in c]))
        return _rpow(_rmean(_pow_vec(c, 1 - gamma)), 1 / (1 - gamma))
    end
    dd_fun(c) = (m = _cummax(c); maximum(1 .- c ./ m))
    ncol = size(sp, 2)
    function per_path(fun, H = fill(ny, ncol))
        Float64[(r = min(Int(H[i]), nfy); r > 0 ? fun(sp[1:r, i]) : NA) for i in 1:ncol]
    end
    pwr = (ppy == 1 || size(R, 1) >= ppy) ?
          perfect_withdrawal_rate(_annual_real(RList("returns" => R, "inflation" => I, "frequency" => x["frequency"]))) : nothing
    pwr = pwr === nothing ? Union{Missing,Bool}[missing for _ in 1:ncol] :
          Float64[pwr[(i-1)%length(pwr)+1] for i in 1:ncol]
    dep = Float64[ceil(v / ppy) for v in core["depletion_period"]]
    cols = Pair{String,Any}["success" => core["failed"] .== 0, "depletion_year" => dep,
            "terminal_real" => core["terminal_real"], "terminal_nominal" => core["terminal_nominal"],
            "first_withdrawal" => w0, "mean_spending" => nfy == ny ? _col_ld(sp, true) : per_path(_rmean),
            "min_spending" => per_path(minimum), "spending_drawdown" => per_path(dd_fun), "ce_spending" => per_path(ce_fun),
            "total_spending" => _col_ld(sp, false), "taxes" => core["taxes_real"], "pwr" => pwr]
    paths = RFrame(cols...)
    sd = _get(x, "start_dates")
    sd === nothing || (paths["start"] = _todate(sd, "dates"))
    wealth = core["wealth"]
    if horizon !== nothing
        H = _draw_horizon(horizon, size(R, 2))
        if maximum(H) > ny
            _warn(@sprintf("Horizont bis %d Jahre, Pfade nur %d Jahre: längere Horizonte werden auf %d gekürzt.", maximum(H), ny, ny))
            H = min.(H, ny)
        end
        dy = dep
        paths["success_full"] = copy(paths["success"])
        paths["horizon"] = H
        paths["success"] = Bool[isnan(dy[i]) || dy[i] > H[i] for i in eachindex(H)]
        paths["depletion_year"] = Float64[!isnan(dy[i]) && dy[i] <= H[i] ? dy[i] : NA for i in eachindex(H)]
        paths["terminal_real"] = Float64[core["wealth_end"][H[i]+1, i] for i in eachindex(H)]
        paths["taxes"] = Float64[core["taxes_end"][H[i]+1, i] for i in eachindex(H)]
        paths["mean_spending"] = per_path(_rmean, H); paths["min_spending"] = per_path(minimum, H)
        paths["total_spending"] = Float64[_rsum(sp[1:H[i], i]) for i in eachindex(H)]
        paths["spending_drawdown"] = per_path(dd_fun, H); paths["ce_spending"] = per_path(ce_fun, H)
        if ppy == 1
            AR = _annual_real(RList("returns" => R, "inflation" => I, "frequency" => x["frequency"]))
            paths["pwr"] = Float64[perfect_withdrawal_rate(AR[1:H[i], i:i])[1] for i in eachindex(H)]
        else
            paths["pwr"] = fill(NA, length(H))
        end
        _istrue(keep_paths) || (wealth = nothing)
    end
    w = _get(x, "weights")
    w = w === nothing ? ones(size(R, 2)) : _dvec(w)
    return RList("paths" => paths, "spending" => sp, "planned" => core["planned"],
                 "wealth" => _istrue(keep_paths) ? wealth : nothing, "rule" => rule, "start_value" => start_value,
                 "frequency" => x["frequency"], "years" => ny, "full_years" => nfy, "horizon" => horizon,
                 "historical" => _istrue(_get(x, "historical")), "weights" => w, "tax_mode" => tax_mode, "gamma" => gamma,
                 "timing" => timing, "source" => _get(x, "source"), "adopted" => length(adopted) > 0 ? adopted : nothing,
                 "elapsed" => time() - t0; class = "SimLevWithdrawal")
end

"""
    withdrawal_max_rate(x, rule = withdrawal_rule("constant"); success = 0.95, lower = 0.5, upper = 20,
                        tol = 0.005, kwargs...)

Maximale Anfangsrate für eine Ziel-Erfolgsquote (Bisektion). Ergebnis:
RVector der Länge 1 (Rate in Prozent, NA wenn schon `lower` die Zielquote
verfehlt) mit Attribut `success` (`attrs(r)["success"]`).
"""
function withdrawal_max_rate(x, rule_pos = _MISSING; rule = _MISSING, success = 0.95, lower = 0.5, upper = 20, tol = 0.005, kwargs...)
    x = SimLev.as_rframe(x)
    rule_pos === _MISSING || (rule = rule_pos)
    rule === _MISSING && (rule = withdrawal_rule("constant"))
    _is_rule(rule) || _stop("rule muss mit withdrawal_rule() erstellt werden.")
    if rule["type"] in ("one_over_n", "vpw", "abw", "cape", "hebeler")
        _stop(@sprintf("withdrawal_max_rate: Die Regel '%s' nutzt rate nicht; eine Suche über rate ist dafür nicht möglich.", rule["type"]))
    end
    if !_num1(success) || _f1(success) <= 0 || _f1(success) > 1
        hint = (_num1(success) && 1 < _f1(success) <= 100) ? "; gemeint vermutlich " * _fmt1(_f1(success) / 100) : ""
        _stop(@sprintf("withdrawal_max_rate: success muss ein Anteil mit 0 < success <= 1 sein (0.95 = 95 %%; erhalten: %s)%s.", _show(success), hint))
    end
    if !_num1(lower) || !_num1(upper) || lower < 0 || upper > 100 || lower >= upper
        _stop(@sprintf("withdrawal_max_rate: lower und upper müssen Raten in Prozent mit 0 <= lower < upper <= 100 sein (erhalten: lower = %s, upper = %s).",
                       _show(lower), _show(upper)))
    end
    if !_num1(tol) || _f1(tol) <= 0
        _stop(@sprintf("withdrawal_max_rate: tol muss eine Zahl > 0 in Prozentpunkten sein (z. B. 0.005; erhalten: %s).", _show(tol)))
    end
    lower = Float64(lower); upper = Float64(upper); success = Float64(success); tol = Float64(tol)
    first = Ref(true)
    function f(rate)
        rl = copy(rule)
        rl["rate"] = rate
        s = if first[]
            withdrawal_simulation(x, rl; keep_paths = false, kwargs...)
        else
            _quiet(() -> _no_messages(() -> withdrawal_simulation(x, rl; keep_paths = false, kwargs...)))
        end
        first[] = false
        return _weighted_mean(Float64.(s["paths"]["success"]), s["weights"])
    end
    mk(v, s) = RVector([v]; attrs = Dict{String,Any}("success" => s))
    s_lo = f(lower)
    s_lo < success && return mk(NA, s_lo)
    s_up = f(upper)
    s_up >= success && return mk(upper, s_up)
    while upper - lower > tol
        mid = (lower + upper) / 2
        s_mid = f(mid)
        if s_mid >= success
            lower = mid; s_lo = s_mid
        else
            upper = mid
        end
    end
    return mk(lower, s_lo)
end

# ═══════════════════════════════════════════════════════════════════════════
# Zusammenfassung, Ausgabe, Grafik
# ═══════════════════════════════════════════════════════════════════════════

"Zusammenfassung (R: `summary.SimLevWithdrawal`)."
function _summary_wd(obj; probs = [0.05, 0.25, 0.5, 0.75, 0.95])
    p = obj["paths"]
    w = _dvec(obj["weights"])
    probs = _dvec(probs)
    wq(v) = _wquantile(_dvec(v), w, probs)
    wm(v) = _weighted_mean(_dvec(v), w; na_rm = true)
    yrs = obj["years"]
    H = haskey(p, "horizon") ? p["horizon"] : nothing
    nfy = _get(obj, "full_years", yrs)
    spm = _mat(obj["spending"])
    function pick(y)
        j = H === nothing ? collect(1:size(spm, 2)) : findall(H .>= y)
        (y > nfy || isempty(j)) && return fill(NA, length(probs))
        return _wquantile(spm[y, j], w[j], probs)
    end
    succ = Bool.(p["success"])
    sby = NamedMat(permutedims(reduce(hcat, [pick(1), pick(10), pick(20), pick(30)])); rownames = ["Jahr 1", "Jahr 10", "Jahr 20", "Jahr 30"])
    pwr = _dvec(p["pwr"])
    swr = if _istrue(obj["historical"])
        fin = pwr[.!isnan.(pwr)]
        if isempty(fin)
            _warn("no non-missing arguments to min; returning Inf")
            Inf
        else
            minimum(fin)
        end
    else
        _wquantile(pwr, w, 0.05)[1]
    end
    return RList("rule" => obj["rule"], "n_paths" => SimLev.nrow(p), "years" => yrs, "historical" => obj["historical"],
                 "success_rate" => wm(succ),
                 "depletion" => any(.!succ) ? _wquantile(_dvec(p["depletion_year"])[.!succ], w[.!succ], probs) : nothing,
                 "terminal_real" => wq(p["terminal_real"]),
                 "preserve_rate" => wm(_dvec(p["terminal_real"]) .>= obj["start_value"]),
                 "first_withdrawal" => wq(p["first_withdrawal"]),
                 "mean_spending" => wq(p["mean_spending"]), "min_spending" => wq(p["min_spending"]),
                 "spending_drawdown" => wq(p["spending_drawdown"]), "ce_spending" => wq(p["ce_spending"]),
                 "spending_by_year" => sby, "taxes" => wq(p["taxes"]), "pwr" => wq(pwr), "swr" => swr,
                 "probs" => probs, "start_value" => obj["start_value"], "tax_mode" => obj["tax_mode"], "gamma" => obj["gamma"];
                 class = "summary.SimLevWithdrawal")
end

const _WLINE = repeat("═", 62)
_fw(s) = (r = SimLev.RFmt.format(s; width = 28); r isa AbstractString ? String(r) : String(first(r)))

function _print_summary_wd(io::IO, x)
    function q(v; pct = false)
        join([isnan(z) ? _sp("%10s", "–") : pct ? _sp("%9.2f%%", z) : _sp("%10.0f", z) for z in _dvec(v)])
    end
    probs = _dvec(x["probs"])
    hdr = join([_sp("%10s", _sp("q%02d", _round0(100 * p))) for p in probs])
    print(io, "\n", _WLINE, "\n")
    print(io, "                 SimLev Entnahme-Simulation                    \n")
    print(io, _WLINE, "\n\n")
    print(io, _sp("  Regel:            %s\n", _WD_LABELS[x["rule"]["type"]]))
    print(io, _sp("  Pfade:            %d %s über %d Jahre, Startvermögen %.0f\n", x["n_paths"],
                  _istrue(x["historical"]) ? "historische Kohorten" : "Pfade", x["years"], x["start_value"]))
    print(io, _sp("  Steuern:          %s\n\n", x["tax_mode"] == "person" ? "deutsche Privatperson (vereinfacht)" : "keine"))
    print(io, _sp("  Erfolgsquote:     %.1f %% (Depot reicht für alle geplanten Entnahmen)\n", 100 * x["success_rate"]))
    print(io, _sp("  Kapitalerhalt:    %.1f %% (reales Endvermögen >= Start)\n", 100 * x["preserve_rate"]))
    if _get(x, "depletion") !== nothing
        print(io, _sp("  Erschöpfung:      Median im Jahr %.0f (bei gescheiterten Pfaden)\n", _dvec(x["depletion"])[cld(length(probs), 2)]))
    end
    print(io, _sp("  %s: %.2f %% der Startsumme\n", _istrue(x["historical"]) ? "SWR historisch (min. PWR)" : "SWR (5-%-Quantil PWR)", x["swr"]))
    print(io, _sp("\n  %s%s\n", _fw("real, in Startkaufkraft"), hdr))
    print(io, _sp("  %s%s\n", _fw("Endvermögen"), q(x["terminal_real"])))
    print(io, _sp("  %s%s\n", _fw("Entnahme Jahr 1"), q(x["first_withdrawal"])))
    sby = x["spending_by_year"]
    for (i, r) in enumerate(sby.rownames)
        print(io, _sp("  %s%s\n", _fw("Konsum " * r), q(sby.data[i, :])))
    end
    print(io, _sp("  %s%s\n", _fw("Konsum Durchschnitt"), q(x["mean_spending"])))
    print(io, _sp("  %s%s\n", _fw("Konsum Minimum"), q(x["min_spending"])))
    print(io, _sp("  %s%s\n", _fw(_sp("Sicherheitsäquiv. (g=%g)", x["gamma"])), q(x["ce_spending"])))
    print(io, _sp("  %s%s\n", _fw("Max. Konsumrückgang"), q(100 .* _dvec(x["spending_drawdown"]); pct = true)))
    print(io, _sp("  %s%s\n", _fw("PWR"), q(x["pwr"]; pct = true)))
    x["tax_mode"] == "person" && print(io, _sp("  %s%s\n", _fw("Steuern gesamt"), q(x["taxes"])))
    print(io, "\n", _WLINE)   # ohne abschließenden Zeilenumbruch
end

_print_wd(io::IO, x) = _print_summary_wd(io, _summary_wd(x))

"Fächer des realen Vermögens und des realen Jahreskonsums als SVG (R: `plot.SimLevWithdrawal`)."
function _plot_wd(x; probs = [0.05, 0.25, 0.5, 0.75, 0.95], file = nothing, width = 900, height = 380)
    probs = _dvec(probs)
    w = _dvec(x["weights"])
    panels = Any[]
    _get(x, "wealth") === nothing || push!(panels, (_mat(x["wealth"]), "Reales Vermögen", 0))
    push!(panels, (_mat(x["spending"]), "Realer Konsum je Jahr", 1))
    np = length(panels)
    pw = width / np
    io = IOBuffer()
    print(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\" font-family=\"sans-serif\" font-size=\"12\">\n")
    print(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n")
    k = length(probs)
    for (pi_, (M, main, x0)) in enumerate(panels)
        Q = reduce(hcat, [_wquantile(M[i, :], w, probs) for i in 1:size(M, 1)]) ./ 1000
        xs = collect(x0:x0+size(M, 1)-1)
        fin = filter(isfinite, vec(Q))
        ylo, yhi = isempty(fin) ? (0.0, 1.0) : (minimum(fin), maximum(fin))
        yhi == ylo && (yhi = ylo + 1)
        xlo, xhi = first(xs), max(last(xs), first(xs) + 1)
        ox = (pi_ - 1) * pw
        ml, mr, mt, mb = 60, 15, 35, 45
        aw, ah = pw - ml - mr, height - mt - mb
        sx(v) = ox + ml + (v - xlo) / (xhi - xlo) * aw
        sy(v) = mt + ah - (v - ylo) / (yhi - ylo) * ah
        print(io, "<text x=\"", ox + pw / 2, "\" y=\"20\" text-anchor=\"middle\" font-weight=\"bold\">", main, "</text>\n")
        print(io, "<rect x=\"", ox + ml, "\" y=\"$mt\" width=\"$aw\" height=\"$ah\" fill=\"none\" stroke=\"black\"/>\n")
        print(io, "<text x=\"", ox + ml + aw / 2, "\" y=\"", height - 10, "\" text-anchor=\"middle\">Jahr</text>\n")
        for i in 1:(k ÷ 2)
            up = [string(@sprintf("%.2f", sx(xs[j])), ",", @sprintf("%.2f", sy(Q[i, j]))) for j in eachindex(xs) if isfinite(Q[i, j])]
            dn = [string(@sprintf("%.2f", sx(xs[j])), ",", @sprintf("%.2f", sy(Q[k+1-i, j]))) for j in reverse(eachindex(xs)) if isfinite(Q[k+1-i, j])]
            print(io, "<polygon fill=\"#2C6E9B\" fill-opacity=\"0.18\" stroke=\"none\" points=\"", join(vcat(up, dn), " "), "\"/>\n")
        end
        mid = cld(k, 2)
        pts = [string(@sprintf("%.2f", sx(xs[j])), ",", @sprintf("%.2f", sy(Q[mid, j]))) for j in eachindex(xs) if isfinite(Q[mid, j])]
        print(io, "<polyline fill=\"none\" stroke=\"#2C6E9B\" stroke-width=\"2\" points=\"", join(pts, " "), "\"/>\n")
    end
    print(io, "</svg>\n")
    svg = String(take!(io))
    file === nothing || write(file, svg)
    return svg
end

# ═══════════════════════════════════════════════════════════════════════════
# Laufzeitmodell
# ═══════════════════════════════════════════════════════════════════════════

"""
    horizon_model(type = "fixed"; years = nothing, prob = nothing, min = nothing, max = nothing,
                  mean = nothing, sd = nothing, mode = nothing, seed = 1)

Laufzeit der Entnahmephase nach eigenen Annahmen (Port von `horizon_model()`).
"""
function horizon_model(type_pos = nothing; type = type_pos, type_ = type, years = nothing, prob = nothing, min = nothing, max = nothing,
                       mean = nothing, sd = nothing, mode = nothing, seed = 1)
    t = _match_arg(type_, ("fixed", "uniform", "discrete", "normal", "triangular", "sample"))
    need = Dict("fixed" => ["years"], "uniform" => ["min", "max"], "discrete" => ["years", "prob"],
                "normal" => ["mean", "sd", "min", "max"], "triangular" => ["min", "mode", "max"], "sample" => ["years"])[t]
    given = Dict{String,Any}("years" => years, "prob" => prob, "min" => min, "max" => max, "mean" => mean, "sd" => sd, "mode" => mode)
    miss = [k for k in need if given[k] === nothing]
    isempty(miss) || _stop(@sprintf("horizon_model('%s') braucht: %s", t, join(miss, ", ")))
    for k in need
        v = given[k]
        multi = k == "prob" || (k == "years" && t in ("discrete", "sample"))
        a = _numvec(v)
        if a === nothing || isempty(a) || any(!isfinite, a) || (!multi && length(a) != 1)
            _stop(@sprintf("horizon_model('%s'): %s muss %s sein (erhalten: %s).", t, k,
                           multi ? "ein endlicher Zahlenvektor" : "eine endliche Zahl", _show(v)))
        end
    end
    for k in [k for k in need if k in ("years", "min", "max", "mean", "mode")]
        any(_numvec(given[k]) .<= 0) &&
            _stop(@sprintf("horizon_model('%s'): %s muss > 0 sein (Laufzeit in Jahren; erhalten: %s).", t, k, _show(given[k])))
    end
    if t == "discrete"
        yv, pv = _numvec(years), _numvec(prob)
        (length(yv) != length(pv) || any(pv .< 0) || _rsum(pv) <= 0) &&
            _stop("horizon_model('discrete'): years und prob gleich lang, prob >= 0 mit Summe > 0.")
    end
    min !== nothing && max !== nothing && _f1(min) > _f1(max) && _stop("min <= max erforderlich.")
    if t == "triangular" && (mode < min || mode > max)
        _stop(_sp("horizon_model('triangular'): mode (%g) muss zwischen min (%g) und max (%g) liegen.", mode, min, max))
    end
    t == "normal" && sd < 0 && _stop("horizon_model('normal'): sd muss >= 0 sein.")
    out = RList("type" => t, "seed" => seed; class = "SimLevHorizon")
    for k in need
        out[k] = _rval(given[k])
    end
    return out
end

"`seq(a, b)` (Schritt 1)."
function _seq_from_to(a, b)
    a = Float64(a); b = Float64(b)
    n = Int(floor(b - a + 1e-10))
    return Float64[a + i for i in 0:n]
end

"Laufzeiten ziehen (Port von `.draw_horizon`); ganzzahlig, mindestens 1."
function _draw_horizon(h, n)
    n = Int(n)
    function pick(x, prob = nothing)
        x = _dvec(x)
        ix = prob === nothing ? SimLev.RRng.sample_int(length(x), n; replace = true) :
             SimLev.RRng.sample_int(length(x), n; replace = true, prob = _dvec(prob))
        return x[_ivec(ix)]
    end
    function body()
        t = h["type"]
        t == "fixed" && return fill(Float64(_f1(h["years"])), n)
        t == "uniform" && return pick(_seq_from_to(_f1(h["min"]), _f1(h["max"])))
        t == "discrete" && return pick(h["years"], h["prob"])
        if t == "normal"
            z = _dvec(SimLev.RRng.rnorm(n, Float64(_f1(h["mean"])), Float64(_f1(h["sd"]))))
            r = Float64[_round0(v) for v in z]
            return Float64[_pmin(Float64(_f1(h["max"])), _pmax(Float64(_f1(h["min"])), v)) for v in r]
        end
        if t == "triangular"
            u = _dvec(SimLev.RRng.runif(n))
            a, b, c = Float64(_f1(h["min"])), Float64(_f1(h["max"])), Float64(_f1(h["mode"]))
            b == a && return fill(a, n)
            f = (c - a) / (b - a)
            return Float64[_round0(ui < f ? a + sqrt(ui * (b - a) * (c - a)) : b - sqrt((1 - ui) * (b - a) * (b - c))) for ui in u]
        end
        return pick(h["years"])
    end
    seed = _get(h, "seed")
    out = seed === nothing ? body() : _with_rng_restore(body; seed = seed)
    return Int[Int(trunc(_pmax(1.0, v))) for v in out]
end

function _print_horizon(io::IO, x)
    d = _draw_horizon(x, 20000)
    print(io, _sp("Laufzeit der Entnahmephase (%s): Mittel %.1f Jahre, Median %g, 90 %%-Quantil %g, Bereich %g bis %g\n",
                  x["type"], SimLev.r_mean_int(d), _median(Float64.(d)), _quantile7(Float64.(d), 0.9)[1],
                  Float64(minimum(d)), Float64(maximum(d))))
end

function __init__()
    SimLev.register_print!("withdrawal_rule", _print_rule)
    SimLev.register_print!("SimLevWithdrawal", _print_wd)
    SimLev.register_print!("summary.SimLevWithdrawal", _print_summary_wd)
    SimLev.register_print!("SimLevHorizon", _print_horizon)
    SimLev.register_summary!("SimLevWithdrawal", (x, args...; kw...) -> _summary_wd(x; kw...))
    SimLev.register_plot!("SimLevWithdrawal", SimLev._plot_method(_plot_wd, "SimLevWithdrawal"))
end

end # module
