# ─────────────────────────────────────────────────────────────────────────────
# Bausteine für simulation() (Port von r/R/sim_blocks.R, Etappe 6.3, Anhang C)
#
# Jeder Baustein ist ein Konstruktor mit Prüfung der Argumente (deutsche Meldungen
# wie in R), einer R-Klasse (RList mit class) und einer Druckausgabe wie die
# R-print-Methode:
#
#   sim_costs(order_fee, dca_fee)                                        → costs
#   dca_plan(value, span; days, unit, anchor, start, skip, fill_deficits) → dca
#   rebalance_plan(span, days; unit, anchor, start, skip, thresh, thresh_type,
#                  event_col, event_mode, event_weight)                   → rebalance
#   split_rule(thresh)                                                   → splits
#   tax_profile(rate; church_tax, sparer_pauschbetrag, private_sale_threshold,
#               base_rate, guenstigerpruefung, income, harvest)          → tax
#     income_rate(marginal_rate, soli_rate), income_tariff(taxable_income, tariff),
#     harvest_rule(day, loss_pot)
#
# `nothing` heißt aus. `_sim_from_blocks` übersetzt die Bausteine in die internen
# Werte der Engine (`_simulation_flat`), die unverändert rechnet.
# funds_costs(fee, performance_fee) ist der Kostenbaustein für den Fonds-Wrapper (folgt,
# Etappe 6.5c); simulation() nimmt ihn nicht an (der alte Fondsmodus ist entfernt).
# ─────────────────────────────────────────────────────────────────────────────

# ── Prüfhilfen ────────────────────────────────────────────────────────────────

_blk_show(x) = x === nothing ? "NULL" : r_deparse(x)
_blk_one(x) = _is_num(x) && isfinite(Float64(x))
_blk_vec(x) = x isa Union{AbstractVector,Tuple} ? collect(Any, x) : x isa RVector ? collect(Any, x.values) : Any[x]

function _blk_num(who, x, arg, what; mn = 0.0, null_ok = false)
    @nospecialize
    x === nothing && null_ok && return nothing
    if !_blk_one(x) || (mn !== nothing && x < mn)
        error("$who: '$arg' muss $what sein, nicht $(_blk_show(x)).")
    end
    return nothing
end

function _blk_lgl(who, x, arg)
    @nospecialize
    x isa Bool || error("$who: '$arg' muss TRUE oder FALSE sein, nicht $(_blk_show(x)).")
    return nothing
end

function _blk_frac_warn(who, x, arg, hi = 1.0)
    @nospecialize
    if _blk_one(x) && 0 < x < hi
        @warn "$who: $arg = $(r_format1(x)) wird als $(r_format1(x)) % gelesen (Prozent-Konvention); gemeint war vermutlich $(r_format1(x * 100))."
    end
    return nothing
end

function _blk_days(who, x)
    @nospecialize
    x === nothing && return nothing
    v = _num_vec(x)
    if v === nothing || any(isnan, v) || any(d -> d < 1 || d > 31 || d != r_round(d), v)
        error("$who: days muss ganze Zahlen von 1 bis 31 enthalten, nicht $(join(r_format(_blk_vec(x)), ", ")).")
    end
    u = unique(v)
    if length(u) < length(v)
        @warn "$who: days enthält doppelte Tage ($(join(r_format(v), ", "))); jeder Tag ergibt nur einen Termin, verwendet wird days = $(r_deparse(u))."
        return u
    end
    return x
end

function _blk_start(who, x)
    @nospecialize
    x === nothing && return nothing
    d = try
        _as_date(x)
    catch
        nothing
    end
    d === nothing && error("$who: start = '$(x isa AbstractString ? x : r_format1(x))' ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\").")
    return nothing
end

"Klasse wie `paste(class(x), collapse = \"/\")` in R (für Meldungen)."
function _blk_cls(@nospecialize(x))
    c = r_class(x)
    isempty(c) || return join(c, "/")
    x isa Integer && !(x isa Bool) && return "numeric"     # Julia-Ganzzahl steht für eine R-Zahl (42, nicht 42L)
    return _r_class1(x)
end

function _blk_check(x, cls, arg, ctor)
    @nospecialize
    if x !== nothing && !inherits(x, cls)
        error("simulation: $arg muss NULL oder ein Objekt aus $ctor() sein, nicht $(_blk_cls(x)).")
    end
    return nothing
end

# ── Druckhilfen ───────────────────────────────────────────────────────────────

function _blk_print(io::IO, title, rows)
    println(io, title)
    w = maximum(length(k) for (k, _) in rows) + 1
    for (k, v) in rows
        println(io, "  ", rpad(k * ":", w), " ", v)
    end
    return nothing
end

_blk_fmt(x) = r_format1(Float64(x); digits = 15)

function _blk_fee_text(x)
    @nospecialize
    x === nothing && return "keine"
    _is_num(x) && return "$(_blk_fmt(x)) EUR je Order"
    d = Dict(_kvpairs(x))
    g(k) = get(d, k, nothing)
    p = String[]
    g("fixed") === nothing || push!(p, "$(_blk_fmt(g("fixed"))) EUR")
    g("percent") === nothing || push!(p, "$(_blk_fmt(g("percent"))) %")
    s = isempty(p) ? "0 EUR" : join(p, " + ")
    q = String[]
    g("min") === nothing || push!(q, "mindestens $(_blk_fmt(g("min"))) EUR")
    g("max") === nothing || push!(q, "höchstens $(_blk_fmt(g("max"))) EUR")
    isempty(q) || (s = "$s ($(join(q, ", ")))")
    return s
end

function _blk_sched_text(span, unit, days, anchor)
    @nospecialize
    span === nothing && (span = 1)
    per = unit == "month" ? ("jeden Monat", "Monate") : unit == "quarter" ? ("jedes Quartal", "Quartale") :
          ("jedes Jahr", "Jahre")
    s = span == 1 ? per[1] : "alle $(_blk_fmt(span)) $(per[2])"
    d = if days === nothing
        "am ersten Tag der Periode"
    else
        dv = _num_vec(days)
        "$(length(dv) == 1 ? "an Tag" : "an den Tagen") $(join((_blk_fmt(v) for v in dv), ", ")) " *
        (anchor == "end" ? "vom Periodenende gezählt" : "der Periode")
    end
    return "$s, $d"
end

_blk_start_text(x) = x === nothing ? "erster Datentag" : fmt_date(_as_date(x))

"zvE als eine Zahl ohne Namen (R: `is.numeric(ti) && length(ti) == 1L && is.null(names(ti))`)."
function _blk_scalar_income(@nospecialize(ti))
    (_is_mapping(ti) || ti isa RFrame || (ti isa RVector && ti.names !== nothing)) && return false
    v = _num_vec(ti)
    return v !== nothing && length(v) == 1
end

# ── Konstruktoren ─────────────────────────────────────────────────────────────

"""
    sim_costs(order_fee = nothing, dca_fee = nothing)

Kosten für `simulation()` (R: `sim_costs()`): `order_fee` je Order (Zahl in EUR
oder benannte Liste `(fixed =, percent =, min =, max =)`), `dca_fee` für die
Sparplankäufe (`nothing`: wie `order_fee`). Ergebnis: `RList` der Klasse
`SimLevSimCosts`.
"""
function sim_costs(order_fee_pos = nothing, dca_fee_pos = nothing; order_fee = order_fee_pos, dca_fee = dca_fee_pos)
    @nospecialize
    _fee_spec(order_fee)
    _fee_spec(dca_fee)
    return RList("order_fee" => order_fee, "dca_fee" => dca_fee; class = ["SimLevSimCosts"])
end

"""
    dca_plan(value, span; days = nothing, unit = ("month", "quarter", "year"),
             anchor = ("start", "end"), start = nothing, skip = false, fill_deficits = false)

Sparplan für `simulation()` (R: `dca_plan()`): `value` EUR je Termin, alle `span`
Perioden (`unit`), an den Tagen `days` (vom Periodenanfang bzw. mit
`anchor = "end"` vom Periodenende), ab dem Bezugsdatum `start`; `skip`: kein
Termin am ersten Simulationstag; `fill_deficits`: zuerst Wert-Defizite auffüllen.
Ergebnis: `RList` der Klasse `SimLevDcaPlan`.
"""
function dca_plan(value_pos = _UNSET, span_pos = _UNSET, days_pos = nothing; value = value_pos, span = span_pos,
                  days = days_pos, unit = ("month", "quarter", "year"), anchor = ("start", "end"), start = nothing,
                  skip = false, fill_deficits = false)
    @nospecialize
    who = "dca_plan"
    value = _val(value, nothing)
    span = _val(span, nothing)
    if !_blk_one(value) || value <= 0
        error("$who: 'value' muss eine einzelne endliche Zahl > 0 sein (Betrag je Sparplan-Termin in EUR), nicht $(_blk_show(value)).")
    end
    if !_blk_one(span) || span < 1 || span != r_round(Float64(span))
        error("$who: 'span' muss eine einzelne ganze Zahl >= 1 sein (Perioden zwischen zwei Terminen), nicht $(_blk_show(span)).")
    end
    days = _blk_days(who, days)
    unit = match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = match_arg(anchor, ("start", "end"), "anchor")
    _blk_start(who, start)
    _blk_lgl(who, skip, "skip")
    _blk_lgl(who, fill_deficits, "fill_deficits")
    return RList("value" => value, "span" => span, "days" => days, "unit" => unit, "anchor" => anchor,
                 "start" => start, "skip" => skip, "fill_deficits" => fill_deficits; class = ["SimLevDcaPlan"])
end

"""
    rebalance_plan(span = nothing, days = nothing; unit = ("month", "quarter", "year"),
                   anchor = ("start", "end"), start = nothing, skip = false, thresh = nothing,
                   thresh_type = ("absolute", "relative"), event_col = nothing,
                   event_mode = ("additional", "replace"), event_weight = nothing)

Rebalancing für `simulation()` (R: `rebalance_plan()`): Termine wie bei
`dca_plan()`, Toleranzband `thresh` (Prozentpunkte oder mit
`thresh_type = "relative"` Prozent des Zielgewichts), Ereignisse aus der logischen
Spalte `event_col` (`event_mode = "replace"`: statt der Termine) mit den
Zielgewichten `event_weight`. Ergebnis: `RList` der Klasse `SimLevRebalancePlan`.
"""
function rebalance_plan(span_pos = nothing, days_pos = nothing; span = span_pos, days = days_pos,
                        unit = ("month", "quarter", "year"), anchor = ("start", "end"), start = nothing, skip = false,
                        thresh = nothing, thresh_type = ("absolute", "relative"), event_col = nothing,
                        event_mode = _UNSET, event_weight = nothing)
    @nospecialize
    who = "rebalance_plan"
    days = _blk_days(who, days)
    unit = match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = match_arg(anchor, ("start", "end"), "anchor")
    _blk_start(who, start)
    _blk_lgl(who, skip, "skip")
    _blk_num(who, thresh, "thresh", "NULL oder eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5)"; null_ok = true)
    _blk_frac_warn(who, thresh, "thresh", 0.2)
    thresh_type = match_arg(thresh_type, ("absolute", "relative"), "thresh_type")
    event_col === nothing && !(event_mode isa _Unset) &&
        @warn "rebalance_plan: event_mode wirkt nur zusammen mit event_col und wird ignoriert."
    event_mode = match_arg(_val(event_mode, ("additional", "replace")), ("additional", "replace"), "event_mode")
    if event_col !== nothing && !(event_col isa AbstractString)
        error("rebalance_plan: event_col muss NULL oder der Name einer logischen Spalte in data sein, nicht $(_blk_show(event_col)).")
    end
    event_col === nothing && event_weight !== nothing &&
        @warn "rebalance_plan: event_weight wirkt nur zusammen mit event_col und wird ignoriert."
    return RList("span" => span, "days" => days, "unit" => unit, "anchor" => anchor, "start" => start, "skip" => skip,
                 "thresh" => thresh, "thresh_type" => thresh_type, "event_col" => event_col,
                 "event_mode" => event_mode, "event_weight" => event_weight; class = ["SimLevRebalancePlan"])
end

"""
    split_rule(thresh)

Automatische Splits für `simulation()` (R: `split_rule()`): `thresh = [untere, obere]`;
über `obere` Split auf Kurs 100, unter `untere` Zusammenlegung auf Kurs 100.
Ergebnis: `RList` der Klasse `SimLevSplitRule`.
"""
function split_rule(thresh_pos = _UNSET; thresh = thresh_pos)
    @nospecialize
    thresh = _val(thresh, nothing)
    st = thresh === nothing ? nothing : _num_vec(thresh)
    if st === nothing || length(st) != 2 || any(isnan, st)
        error("split_rule: thresh muss ein Zahlenvektor c(untere, obere) der Länge 2 sein, nicht " *
              (thresh === nothing ? "NULL" : join(r_format(_blk_vec(thresh)), ", ")) * ".")
    end
    if !(st[1] < 100 < st[2])
        @warn "split_rule: thresh = c($(r_format1(st[1])), $(r_format1(st[2]))) schließt den Zielkurs 100 nicht ein (erwartet untere < 100 < obere). Ein Split setzt den Kurs auf 100; liegt 100 außerhalb der Schwellen, folgt danach an jedem Tag ein weiterer Split (mit fractions = FALSE jeweils mit Spitzenausgleich)."
    end
    return RList("thresh" => st; class = ["SimLevSplitRule"])
end

"""
    income_rate(marginal_rate, soli_rate = 0)

Einkommen mit festem Grenzsteuersatz für `tax_profile(; income = …)` (R:
`income_rate()`): `marginal_rate` in Prozent (0 bis 50), `soli_rate` Soli auf die
Einkommensteuer in Prozent (0 = ohne). Ergebnis: `RList` der Klasse `SimLevIncomeRate`.
"""
function income_rate(marginal_rate_pos = _UNSET, soli_rate_pos = 0; marginal_rate = marginal_rate_pos,
                     soli_rate = soli_rate_pos)
    @nospecialize
    who = "income_rate"
    marginal_rate = _val(marginal_rate, nothing)
    _blk_num(who, marginal_rate, "marginal_rate", "eine einzelne Zahl in Prozent von 0 bis 50 (z. B. 42)")
    _blk_frac_warn(who, marginal_rate, "marginal_rate")
    if marginal_rate > 50
        error("income_rate: marginal_rate muss ein Grenzsteuersatz in Prozent zwischen 0 und 50 sein (z. B. 42 für 42 %), nicht $(_blk_show(marginal_rate)).")
    end
    _blk_num(who, soli_rate, "soli_rate", "eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5.5; 0 = ohne Soli)")
    return RList("marginal_rate" => marginal_rate, "soli_rate" => soli_rate; class = ["SimLevIncomeRate"])
end

"""
    income_tariff(taxable_income, tariff = nothing)

Einkommen mit Einkommensteuertarif für `tax_profile(; income = …)` (R:
`income_tariff()`): `taxable_income` (zvE ohne die Erträge der Simulation; Zahl,
nach Jahren benannte Liste oder RFrame(year, taxable_income)), `tariff`
(`nothing`: mitgelieferte Tarifdatei, Dateipfad oder `tax_tariff()`).
Ergebnis: `RList` der Klasse `SimLevIncomeTariff`.
"""
function income_tariff(taxable_income_pos = _UNSET, tariff_pos = nothing; taxable_income = taxable_income_pos,
                       tariff = tariff_pos)
    @nospecialize
    if taxable_income isa _Unset || taxable_income === nothing
        error("income_tariff: taxable_income (zu versteuerndes Einkommen in EUR je Kalenderjahr ohne die Erträge der Simulation) fehlt.")
    end
    _check_taxable_income(taxable_income, Int[], "income_tariff")
    if tariff !== nothing && !inherits(tariff, "SimLevTaxTariff")
        tariff isa AbstractString ||
            error("income_tariff: tariff muss NULL (mitgelieferte Tarifdatei), ein Dateipfad oder ein Objekt aus tax_tariff() sein.")
        tariff = tax_tariff(tariff)
    end
    return RList("taxable_income" => taxable_income, "tariff" => tariff; class = ["SimLevIncomeTariff"])
end

"""
    harvest_rule(day = "12-15", loss_pot = true)

Freibetrag jährlich ausschöpfen für `tax_profile(; harvest = …)` (R:
`harvest_rule()`): ab `day` (MM-TT, nächster Handelstag), `loss_pot`: Verlusttopf
mitnutzen. Ergebnis: `RList` der Klasse `SimLevHarvestRule`.
"""
function harvest_rule(day_pos = "12-15", loss_pot_pos = true; day = day_pos, loss_pot = loss_pot_pos)
    @nospecialize
    if !(day isa AbstractString) || !occursin(r"^\d{2}-\d{2}$", day) || day >= "12-31"
        error("harvest_rule: day im Format 'MM-TT' und vor dem 31.12. angeben (z. B. '12-15').")
    end
    _blk_lgl("harvest_rule", loss_pot, "loss_pot")
    return RList("day" => day, "loss_pot" => loss_pot; class = ["SimLevHarvestRule"])
end

"""
    tax_profile(rate = 26.375; church_tax = 0, sparer_pauschbetrag = 1000,
                private_sale_threshold = 1000, base_rate = nothing, guenstigerpruefung = false,
                income = nothing, harvest = nothing)

Persönliche Besteuerung für `simulation()` (R: `tax_profile()`): Abgeltungsteuer
`rate` (nur ohne Kirchensteuer), `church_tax` (8 oder 9; dann gilt der Satz nach
§ 32d Abs. 1 EStG), `sparer_pauschbetrag` (0 = ohne), Freigrenze § 23 EStG,
Basiszins `base_rate` (Zahl in Prozent oder Spaltenname in `data`),
`guenstigerpruefung`, `income` (`income_rate()` oder `income_tariff()`) und
`harvest` (`harvest_rule()`). Ergebnis: `RList` der Klasse `SimLevTaxProfile`.
"""
function tax_profile(rate_pos = _UNSET; rate = rate_pos, church_tax = 0, sparer_pauschbetrag = 1000,
                     private_sale_threshold = 1000, base_rate = nothing, guenstigerpruefung = false, income = nothing,
                     harvest = nothing)
    @nospecialize
    who = "tax_profile"
    rate_given = !(rate isa _Unset)
    rate = _val(rate, 26.375)
    if !_is_num(rate) || isnan(Float64(rate)) || rate < 0 || rate > 100
        error("tax_profile: rate muss eine einzelne Zahl in Prozent zwischen 0 und 100 sein (z. B. 26.375 für 26,375 %), nicht $(_blk_show(rate)).")
    end
    _blk_frac_warn(who, rate, "rate")
    if church_tax !== nothing
        if !_is_num(church_tax) || isnan(Float64(church_tax)) || church_tax < 0 || church_tax > 100
            error("tax_profile: church_tax muss eine Zahl in Prozent zwischen 0 und 100 sein (in Deutschland 8 oder 9), nicht $(join(r_format(_blk_vec(church_tax)), ", ")).")
        end
        if 0 < church_tax < 1
            @warn "tax_profile: church_tax = $(r_format1(church_tax)) wird als $(r_format1(church_tax)) % gelesen (Prozent-Konvention); gemeint war vermutlich $(r_format1(church_tax * 100))."
        elseif church_tax > 9
            @warn "tax_profile: church_tax = $(r_format1(church_tax)) % ist ungewöhnlich hoch (Kirchensteuer in Deutschland: 8 oder 9 %)."
        end
        if church_tax > 0 && rate_given
            error("tax_profile: rate und church_tax schließen sich aus; rate gilt nur ohne Kirchensteuer (mit church_tax gilt der Satz nach § 32d Abs. 1 EStG).")
        end
    end
    _blk_num(who, sparer_pauschbetrag, "sparer_pauschbetrag", "eine einzelne endliche Zahl >= 0 (EUR je Jahr, z. B. 1000; 0 = ohne)")
    _blk_num(who, private_sale_threshold, "private_sale_threshold", "eine einzelne endliche Zahl >= 0 (Freigrenze in EUR, z. B. 1000)")
    msg = "tax_profile: 'base_rate' muss NULL, eine einzelne endliche Zahl (Basiszins in Prozent, z. B. 2.29; negativ erlaubt) oder der Name einer Spalte in data sein, nicht $(_blk_show(base_rate))."
    if base_rate isa AbstractString
        isempty(base_rate) && error(msg)
    else
        base_rate !== nothing && !_blk_one(base_rate) && error(msg)
        _blk_frac_warn(who, base_rate, "base_rate", 0.05)
    end
    _blk_lgl(who, guenstigerpruefung, "guenstigerpruefung")
    if income !== nothing && !(inherits(income, "SimLevIncomeRate") || inherits(income, "SimLevIncomeTariff"))
        error("tax_profile: income muss NULL, ein Objekt aus income_rate() oder aus income_tariff() sein (beide schließen sich aus), nicht $(_blk_cls(income)).")
    end
    if harvest !== nothing && !inherits(harvest, "SimLevHarvestRule")
        error("tax_profile: harvest muss NULL oder ein Objekt aus harvest_rule() sein, nicht $(_blk_cls(harvest)).")
    end
    return RList("rate" => rate, "church_tax" => church_tax, "sparer_pauschbetrag" => sparer_pauschbetrag,
                 "private_sale_threshold" => private_sale_threshold, "base_rate" => base_rate,
                 "guenstigerpruefung" => guenstigerpruefung, "income" => income, "harvest" => harvest;
                 class = ["SimLevTaxProfile"])
end

"""
    funds_costs(fee = 0.95, performance_fee = 5)

Kostenbaustein für den Fonds-Wrapper (folgt; R: `funds_costs()`): laufende Fondskosten
`fee` in Prozent p. a. und `performance_fee` in Prozent des Wertzuwachses über dem
Höchststand. Ergebnis: `RList` der Klasse `SimLevFundsCosts`.
"""
function funds_costs(fee_pos = 0.95, performance_fee_pos = 5; fee = fee_pos, performance_fee = performance_fee_pos)
    @nospecialize
    for (a, x) in (("fee", fee), ("performance_fee", performance_fee))
        if !_is_num(x) || isnan(Float64(x)) || x < 0 || x > 100
            error("funds_costs: $a muss eine Zahl in Prozent zwischen 0 und 100 sein (z. B. " *
                  (a == "fee" ? "0.95 für 0,95 % p. a." : "5 für 5 %") * "), nicht " *
                  (x === nothing ? "NULL" : join(r_format(_blk_vec(x)), ", ")) * ".")
        end
    end
    return RList("fee" => fee, "performance_fee" => performance_fee; class = ["SimLevFundsCosts"])
end

# ── Druckmethoden ─────────────────────────────────────────────────────────────

function _print_sim_costs(io::IO, x)
    _blk_print(io, "Kosten (sim_costs)",
               ["Ordergebühr" => _blk_fee_text(x["order_fee"]),
                "Sparplan-Gebühr" => x["dca_fee"] === nothing ? "wie Ordergebühr" : _blk_fee_text(x["dca_fee"])])
end

function _print_dca_plan(io::IO, x)
    _blk_print(io, "Sparplan (dca_plan)",
               ["Betrag" => "$(_blk_fmt(x["value"])) EUR je Termin",
                "Termine" => _blk_sched_text(x["span"], x["unit"], x["days"], x["anchor"]),
                "Bezugsdatum" => _blk_start_text(x["start"]),
                "Erster Simulationstag" => _is_true(x["skip"]) ? "ausgelassen" : "mit Termin",
                "Verteilung" => _is_true(x["fill_deficits"]) ? "zuerst Wert-Defizite auffüllen, Rest nach Strategie-Gewichten" :
                                "nach Strategie-Gewichten"])
end

function _print_rebalance_plan(io::IO, x)
    ev = x["event_col"] !== nothing
    repl = ev && x["event_mode"] == "replace"
    rows = Pair{String,String}[
        "Termine" => repl ? "keine (nur Ereignisse)" : _blk_sched_text(x["span"], x["unit"], x["days"], x["anchor"]),
        "Ereignisse" => !ev ? "keine" : "Spalte '$(x["event_col"])' ($(repl ? "statt der Termine" : "zusätzlich zu den Terminen"))"]
    if ev && x["event_weight"] !== nothing
        w = x["event_weight"]
        ps = w isa RVector ? [string(k) => v for (k, v) in zip(something(w.names, fill("", length(w.values))), w.values)] : _kvpairs(w)
        push!(rows, "Gewichte" => join(("$k = $(v isa AbstractString ? v : r_as_character(v))" for (k, v) in ps), ", "))
    end
    push!(rows, "Toleranzband" => x["thresh"] === nothing ? "keines (an jedem Termin)" :
                                  "$(_blk_fmt(x["thresh"])) $(x["thresh_type"] == "relative" ? "% des Zielgewichts" : "Prozentpunkte")")
    repl || push!(rows, "Bezugsdatum" => _blk_start_text(x["start"]))
    push!(rows, "Erster Simulationstag" => _is_true(x["skip"]) ? "ausgelassen" : "mit Termin")
    _blk_print(io, "Rebalancing (rebalance_plan)", rows)
end

function _print_split_rule(io::IO, x)
    t = x["thresh"]
    _blk_print(io, "Splits (split_rule)", ["Split" => "über $(_blk_fmt(t[2])) auf Kurs 100",
                                           "Zusammenlegung" => "unter $(_blk_fmt(t[1])) auf Kurs 100"])
end

function _blk_income_text(x)
    x === nothing && return "nicht angegeben"
    if inherits(x, "SimLevIncomeRate")
        return "Grenzsteuersatz $(_blk_fmt(x["marginal_rate"])) %" *
               (x["soli_rate"] != 0 ? " mit Soli $(_blk_fmt(x["soli_rate"])) %" : "")
    end
    ti = x["taxable_income"]
    return "Tarif ($(x["tariff"] === nothing ? "mitgelieferte Tarifdatei" : "eigener Tarif"), zvE " *
           (_blk_scalar_income(ti) ? "$(_blk_fmt(_num_vec(ti)[1])) EUR je Jahr" : "je Kalenderjahr") * ")"
end

_blk_harvest_text(x) = x === nothing ? "nein" :
    "jährlich ab $(x["day"]), Verlusttopf $(_is_true(x["loss_pot"]) ? "mitgenutzt" : "nicht genutzt")"

function _print_income_rate(io::IO, x)
    _blk_print(io, "Einkommen (income_rate)",
               ["Grenzsteuersatz" => "$(_blk_fmt(x["marginal_rate"])) %",
                "Soli" => x["soli_rate"] != 0 ? "$(_blk_fmt(x["soli_rate"])) %" : "ohne"])
end

function _print_income_tariff(io::IO, x)
    ti = x["taxable_income"]
    _blk_print(io, "Einkommen (income_tariff)",
               ["zvE" => _blk_scalar_income(ti) ? "$(_blk_fmt(_num_vec(ti)[1])) EUR je Jahr" : "je Kalenderjahr",
                "Tarif" => x["tariff"] === nothing ? "mitgelieferte Tarifdatei" : "eigener Tarif"])
end

function _print_harvest_rule(io::IO, x)
    _blk_print(io, "Freibetrag nutzen (harvest_rule)",
               ["Termin" => "jährlich ab $(x["day"]) (MM-TT, nächster Handelstag)",
                "Verlusttopf" => _is_true(x["loss_pot"]) ? "mitgenutzt" : "nicht genutzt"])
end

function _print_tax_profile(io::IO, x)
    ct = x["church_tax"] === nothing ? 0 : x["church_tax"]
    br = x["base_rate"]
    _blk_print(io, "Steuern (tax_profile)",
               ["Abgeltungsteuer" => ct > 0 ? "mit Kirchensteuer $(_blk_fmt(ct)) % (Satz nach § 32d Abs. 1 EStG)" :
                                     "$(_blk_fmt(x["rate"])) %",
                "Sparer-Pauschbetrag" => x["sparer_pauschbetrag"] == 0 ? "keiner" :
                                         "$(_blk_fmt(x["sparer_pauschbetrag"])) EUR je Jahr",
                "Freigrenze § 23" => "$(_blk_fmt(x["private_sale_threshold"])) EUR",
                "Basiszins" => br === nothing ? "keiner (keine Vorabpauschale)" :
                               br isa AbstractString ? "Spalte '$br'" : "$(_blk_fmt(br)) %",
                "Günstigerprüfung" => _is_true(x["guenstigerpruefung"]) ? "ja" : "nein",
                "Einkommen" => _blk_income_text(x["income"]),
                "Freibetrag nutzen" => _blk_harvest_text(x["harvest"])])
end

function _print_funds_costs(io::IO, x)
    _blk_print(io, "Fondskosten (funds_costs)",
               ["Fondskosten" => "$(_blk_fmt(x["fee"])) % p. a.",
                "Performancegebühr" => "$(_blk_fmt(x["performance_fee"])) % des Wertzuwachses über dem Höchststand"])
end

register_print!("SimLevSimCosts", _print_sim_costs)
register_print!("SimLevDcaPlan", _print_dca_plan)
register_print!("SimLevRebalancePlan", _print_rebalance_plan)
register_print!("SimLevSplitRule", _print_split_rule)
register_print!("SimLevIncomeRate", _print_income_rate)
register_print!("SimLevIncomeTariff", _print_income_tariff)
register_print!("SimLevHarvestRule", _print_harvest_rule)
register_print!("SimLevTaxProfile", _print_tax_profile)
register_print!("SimLevFundsCosts", _print_funds_costs)

# ── Übersetzer ────────────────────────────────────────────────────────────────

"""
Bausteine prüfen und in die Argumente der Engine übersetzen (R: `.sim_from_blocks`).

`rebalance_plan()` heißt `balance_mode = true`; nur mit `event_col`,
`event_mode = "replace"` und `skip = true` wird `balance_mode = false`.
`sparer_pauschbetrag = 0` heißt `use_sparer_pauschbetrag = false`.
Rückgabe: `Vector{Pair{Symbol,Any}}` der Schlüsselwörter von `_simulation_flat`.
"""
function _sim_from_blocks(costs, dca, rebalance, splits, tax)
    @nospecialize
    _blk_check(costs, "SimLevSimCosts", "costs", "sim_costs")
    _blk_check(dca, "SimLevDcaPlan", "dca", "dca_plan")
    _blk_check(rebalance, "SimLevRebalancePlan", "rebalance", "rebalance_plan")
    _blk_check(splits, "SimLevSplitRule", "splits", "split_rule")
    _blk_check(tax, "SimLevTaxProfile", "tax", "tax_profile")
    a = Pair{Symbol,Any}[:order_fee => costs === nothing ? nothing : costs["order_fee"],
                         :dca_fee => costs === nothing ? nothing : costs["dca_fee"]]
    if dca !== nothing
        append!(a, Pair{Symbol,Any}[:dca_mode => true, :dca_value => dca["value"], :dca_span => dca["span"],
                                    :dca_days => dca["days"], :dca_unit => dca["unit"], :dca_anchor => dca["anchor"],
                                    :dca_start => dca["start"], :dca_skip => dca["skip"],
                                    :balance_dca => dca["fill_deficits"]])
    end
    if rebalance !== nothing
        events_only = rebalance["event_col"] !== nothing && rebalance["event_mode"] == "replace"
        append!(a, Pair{Symbol,Any}[:balance_mode => !(events_only && _is_true(rebalance["skip"])),
                                    :balance_span => rebalance["span"], :balance_days => rebalance["days"],
                                    :balance_unit => rebalance["unit"], :balance_anchor => rebalance["anchor"],
                                    :balance_start => rebalance["start"], :balance_skip => rebalance["skip"],
                                    :balance_thresh => rebalance["thresh"], :balance_thresh_type => rebalance["thresh_type"],
                                    :event_col => rebalance["event_col"], :event_mode => rebalance["event_mode"],
                                    :event_weight => rebalance["event_weight"]])
    end
    splits === nothing || append!(a, Pair{Symbol,Any}[:split_mode => true, :split_thresh => splits["thresh"]])
    if tax !== nothing
        br = tax["base_rate"]
        chr = br isa AbstractString
        append!(a, Pair{Symbol,Any}[:tax_mode => "person", :tax_rate => tax["rate"], :church_tax => tax["church_tax"],
                                    :sparer_pauschbetrag => tax["sparer_pauschbetrag"],
                                    :use_sparer_pauschbetrag => tax["sparer_pauschbetrag"] > 0,
                                    :private_sale_threshold => tax["private_sale_threshold"],
                                    :base_rate => chr ? nothing : br, :base_rate_flex => chr,
                                    :base_rate_data => chr ? br : nothing,
                                    :use_guenstigerpruefung => tax["guenstigerpruefung"]])
        inc = tax["income"]
        if inherits(inc, "SimLevIncomeRate")
            append!(a, Pair{Symbol,Any}[:marginal_tax_rate => inc["marginal_rate"],
                                        :include_soli_on_income_tax => inc["soli_rate"] != 0,
                                        :soli_rate_income_tax => inc["soli_rate"]])
        elseif inherits(inc, "SimLevIncomeTariff")
            append!(a, Pair{Symbol,Any}[:taxable_income => inc["taxable_income"], :tax_tariff => inc["tariff"]])
        end
        h = tax["harvest"]
        h === nothing || append!(a, Pair{Symbol,Any}[:harvest_mode => true, :harvest_day => h["day"],
                                                     :harvest_loss_pot => h["loss_pot"]])
    end
    return a
end

# ── Aufrufer von simulation(): sim_args und Pfade (Etappe 6.4) ────────────────
# R: Abschnitt „Aufrufer von simulation()“ in r/R/sim_blocks.R. sim_args der Aufrufer sind Argumente von
# simulation() (auch Bausteine); Raster und Suchräume sprechen Parameter der Bausteine mit Pfad an
# („dca.value“, „rebalance.thresh“, „tax.income.marginal_rate“). Alte flache Namen ergeben einen Fehler.

const _SIM_TOP = ("start_value", "costs", "dca", "rebalance", "splits", "tax", "risk_free", "fractions",
                  "liquidate", "details")
const _SIM_BLOCKS = ["costs" => "sim_costs", "dca" => "dca_plan", "rebalance" => "rebalance_plan",
                     "splits" => "split_rule", "tax" => "tax_profile"]
const _SIM_BLOCK_PARAMS = Dict{String,Vector{String}}(
    "sim_costs" => ["order_fee", "dca_fee"],
    "dca_plan" => ["value", "span", "days", "unit", "anchor", "start", "skip", "fill_deficits"],
    "rebalance_plan" => ["span", "days", "unit", "anchor", "start", "skip", "thresh", "thresh_type", "event_col",
                         "event_mode", "event_weight"],
    "split_rule" => ["thresh"],
    "tax_profile" => ["rate", "church_tax", "sparer_pauschbetrag", "private_sale_threshold", "base_rate",
                      "guenstigerpruefung", "income", "harvest"],
    "income_rate" => ["marginal_rate", "soli_rate"],
    "income_tariff" => ["taxable_income", "tariff"],
    "harvest_rule" => ["day", "loss_pot"])
const _SIM_SUB = Dict{String,Vector{String}}("income" => ["income_rate", "income_tariff"], "harvest" => ["harvest_rule"])
const _SIM_CLASS_CTOR = Dict("SimLevIncomeRate" => "income_rate", "SimLevIncomeTariff" => "income_tariff",
                             "SimLevHarvestRule" => "harvest_rule")
# alte flache Argumente: Name => (Pfad, Hinweis); leerer Hinweis = aus dem Pfad gebildet
const _SIM_FLAT = Dict{String,Tuple{String,String}}(
    "spread" => ("", "den Spread je Asset (asset_config(spread = …))"),
    "dca_mode" => ("", "dca = dca_plan(…) (NULL = ohne Sparplan)"),
    "dca_value" => ("dca.value", ""), "dca_span" => ("dca.span", ""), "dca_days" => ("dca.days", ""),
    "dca_unit" => ("dca.unit", ""), "dca_anchor" => ("dca.anchor", ""), "dca_start" => ("dca.start", ""),
    "dca_skip" => ("dca.skip", ""), "balance_dca" => ("dca.fill_deficits", ""),
    "balance_mode" => ("", "rebalance = rebalance_plan(…) (NULL = ohne Rebalancing)"),
    "balance_span" => ("rebalance.span", ""), "balance_days" => ("rebalance.days", ""),
    "balance_unit" => ("rebalance.unit", ""), "balance_anchor" => ("rebalance.anchor", ""),
    "balance_start" => ("rebalance.start", ""), "balance_skip" => ("rebalance.skip", ""),
    "balance_thresh" => ("rebalance.thresh", ""), "balance_thresh_type" => ("rebalance.thresh_type", ""),
    "event_col" => ("rebalance.event_col", ""), "event_mode" => ("rebalance.event_mode", ""),
    "event_weight" => ("rebalance.event_weight", ""),
    "split_mode" => ("", "splits = split_rule(…) (NULL = ohne Splits)"),
    "split_thresh" => ("splits.thresh", ""),
    "tax_mode" => ("", "tax = tax_profile(…) (NULL = ohne)"),
    "tax_rate" => ("tax.rate", ""), "church_tax" => ("tax.church_tax", ""),
    "sparer_pauschbetrag" => ("tax.sparer_pauschbetrag", ""),
    "use_sparer_pauschbetrag" => ("", "tax = tax_profile(sparer_pauschbetrag = 0) (0 = ohne Pauschbetrag)"),
    "private_sale_threshold" => ("tax.private_sale_threshold", ""), "base_rate" => ("tax.base_rate", ""),
    "base_rate_flex" => ("", "tax = tax_profile(base_rate = \"<Spalte>\")"),
    "base_rate_data" => ("tax.base_rate", "tax = tax_profile(base_rate = \"<Spalte>\")"),
    "use_guenstigerpruefung" => ("tax.guenstigerpruefung", ""),
    "marginal_tax_rate" => ("tax.income.marginal_rate", ""),
    "include_soli_on_income_tax" => ("", "tax = tax_profile(income = income_rate(marginal_rate, soli_rate = …))"),
    "soli_rate_income_tax" => ("tax.income.soli_rate", ""),
    "taxable_income" => ("tax.income.taxable_income", ""), "tax_tariff" => ("tax.income.tariff", ""),
    "harvest_mode" => ("", "tax = tax_profile(harvest = harvest_rule(…))"),
    "harvest_day" => ("tax.harvest.day", ""), "harvest_loss_pot" => ("tax.harvest.loss_pot", ""),
    "order_fee" => ("costs.order_fee", ""), "dca_fee" => ("costs.dca_fee", ""))

_sim_block_ctor(b) = (i = findfirst(p -> p.first == b, _SIM_BLOCKS); i === nothing ? nothing : _SIM_BLOCKS[i].second)

function _sim_path_hint(path::AbstractString)
    s = split(path, ".")
    ctor = _sim_block_ctor(s[1])
    length(s) == 2 && return "$(s[1]) = $ctor($(s[2]) = …)"
    sub = first(c for c in _SIM_SUB[s[2]] if s[3] in _SIM_BLOCK_PARAMS[c])
    return "$(s[1]) = $ctor($(s[2]) = $sub($(s[3]) = …))"
end

function _sim_path_text()
    parts = String[]
    for (b, ctor) in _SIM_BLOCKS
        p = copy(_SIM_BLOCK_PARAMS[ctor])
        sub = String[]
        for sname in p
            haskey(_SIM_SUB, sname) || continue
            seen = String[]
            for c in _SIM_SUB[sname], q in _SIM_BLOCK_PARAMS[c]
                q in seen || push!(seen, q)
            end
            append!(sub, ["$sname.$q" for q in seen])
        end
        push!(parts, "$b ($(join(vcat(p, sub), ", ")))")
    end
    return join(parts, "; ")
end

function _sim_path_ok(p::AbstractString)
    s = split(p, ".")
    (length(s) < 2 || length(s) > 3 || any(isempty, s)) && return false
    ctor = _sim_block_ctor(s[1])
    ctor === nothing && return false
    s[2] in _SIM_BLOCK_PARAMS[ctor] || return false
    return length(s) == 2 || (haskey(_SIM_SUB, s[2]) && any(c -> s[3] in _SIM_BLOCK_PARAMS[c], _SIM_SUB[s[2]]))
end

"Namen von sim_args, Raster oder Suchraum prüfen (R: `.sim_check_names`)."
function _sim_check_names(nms, who)
    for k0 in nms
        k = String(string(k0))
        k in _SIM_TOP && continue
        if haskey(_SIM_FLAT, k)
            path, hint = _SIM_FLAT[k]
            isempty(hint) && (hint = _sim_path_hint(path))
            error("$who: $k gibt es nicht mehr; bitte $hint$(isempty(path) ? "" : " (Pfad \"$path\")").")
        end
        if occursin('.', k)
            _sim_path_ok(k) ||
                error("$who: unbekannter Pfad \"$k\"; möglich sind die Bausteine mit ihren Parametern: $(_sim_path_text()).")
            continue
        end
        error("$who: unbekanntes Argument $(isempty(k) ? "ohne Namen" : k) für simulation(); möglich sind " *
              "$(join(_SIM_TOP, ", ")) sowie Pfade zu Parametern der Bausteine (z. B. \"dca.value\").")
    end
    return nothing
end

"Schlüssel-Wert-Paare (String-Schlüssel) aus RList, NamedTuple, Dict oder Pair-Vektor."
function _sim_kv(x)
    @nospecialize
    x === nothing && return Pair{String,Any}[]
    x isa RList && return Pair{String,Any}[String(k) => v for (k, v) in x]
    x isa NamedTuple && return Pair{String,Any}[String(k) => v for (k, v) in pairs(x)]
    x isa AbstractDict && return Pair{String,Any}[String(string(k)) => v for (k, v) in x]
    x isa Pair && return Pair{String,Any}[String(string(x.first)) => x.second]
    x isa AbstractVector && all(p -> p isa Pair, x) && return Pair{String,Any}[String(string(p.first)) => p.second for p in x]
    x isa AbstractVector && isempty(x) && return Pair{String,Any}[]
    error("sim_args muss eine benannte Liste sein (RList, NamedTuple, Dict oder Pair-Vektor).")
end

const _SIM_CTORS = Dict{String,Function}("sim_costs" => sim_costs, "dca_plan" => dca_plan,
    "rebalance_plan" => rebalance_plan, "split_rule" => split_rule, "tax_profile" => tax_profile,
    "income_rate" => income_rate, "income_tariff" => income_tariff,
    "harvest_rule" => harvest_rule)

_sim_fields(obj) = obj === nothing ? Pair{String,Any}[] : Pair{String,Any}[String(k) => v for (k, v) in obj]
_sim_ctor_call(ctor, f) = _SIM_CTORS[ctor](; (Symbol(k) => v for (k, v) in f)...)
function _sim_fset!(f::Vector{Pair{String,Any}}, k, v)
    i = findfirst(p -> p.first == k, f)
    i === nothing ? push!(f, k => v) : (f[i] = k => v)
    return f
end
_sim_fget(f, k) = (i = findfirst(p -> p.first == k, f); i === nothing ? nothing : f[i].second)

"Baustein aus Feldern neu bauen (R: `.sim_build`)."
function _sim_build(ctor, f, set)
    if ctor == "tax_profile" && !("rate" in set)
        ct = _sim_fget(f, "church_tax")
        ct isa Real && !isnan(Float64(ct)) && ct > 0 && filter!(p -> p.first != "rate", f)
    end
    if ctor == "rebalance_plan" && !("event_mode" in set) && _sim_fget(f, "event_col") === nothing
        filter!(p -> p.first != "event_mode", f)
    end
    return _sim_ctor_call(ctor, f)
end

_sim_class(x) = (c = r_class(x); isempty(c) ? nothing : c[1])

"""
Argumente für `simulation()` setzen (R: `.sim_args_set`): oberste Ebene wie `modifyList` (`nothing`
entfernt das Argument), Pfade bauen den Baustein neu. Ergebnis: `RList`.
"""
function _sim_args_set(args, over, who)
    @nospecialize
    out = RList(_sim_kv(args)...)
    ov = _sim_kv(over)
    isempty(ov) && return out
    nm = String[p.first for p in ov]
    _sim_check_names(nm, who)
    for (k, v) in ov
        occursin('.', k) && continue
        v === nothing ? (haskey(out, k) && delete!(out, k)) : (out[k] = v)
    end
    paths = [p for p in ov if occursin('.', p.first)]
    isempty(paths) && return out
    blocks = String[]
    for p in paths
        b = String(split(p.first, ".")[1])
        b in blocks || push!(blocks, b)
    end
    for b in blocks
        ctor = _sim_block_ctor(b)
        f = _sim_fields(get(out, b, nothing))
        set = String[]
        mine = [p for p in paths if split(p.first, ".")[1] == b]
        for p in mine
            s = split(p.first, ".")
            length(s) == 2 || continue
            _sim_fset!(f, String(s[2]), p.second); push!(set, String(s[2]))
        end
        three = [p for p in mine if length(split(p.first, ".")) == 3]
        subs = String[]
        for p in three
            sn = String(split(p.first, ".")[2]); sn in subs || push!(subs, sn)
        end
        for sname in subs
            jj = [p for p in three if split(p.first, ".")[2] == sname]
            ks = [String(split(p.first, ".")[3]) for p in jj]
            base = _sim_fget(f, sname)
            bctor = base === nothing ? nothing : get(_SIM_CLASS_CTOR, something(_sim_class(base), ""), nothing)
            sctor = if bctor !== nothing && all(k -> k in _SIM_BLOCK_PARAMS[bctor], ks)
                bctor
            else
                cand = [c for c in _SIM_SUB[sname] if all(k -> k in _SIM_BLOCK_PARAMS[c], ks)]
                isempty(cand) && error("$who: die Pfade $(join(["\"$(p.first)\"" for p in jj], ", ")) passen zu keinem " *
                                       "Baustein für $sname ($(join(["$c()" for c in _SIM_SUB[sname]], ", "))).")
                cand[1]
            end
            sf = sctor == bctor ? _sim_fields(base) : Pair{String,Any}[]
            for (p, k) in zip(jj, ks)
                _sim_fset!(sf, k, p.second)
            end
            _sim_fset!(f, sname, _sim_ctor_call(sctor, sf)); push!(set, sname)
        end
        out[b] = _sim_build(ctor, f, set)
    end
    return out
end

"`simulation()` mit aufgelösten sim_args aufrufen (R: `.sim_call`)."
_sim_call(data, strategy, args) = simulation(data, strategy; (Symbol(k) => v for (k, v) in args)...)
