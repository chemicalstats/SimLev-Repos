# ─────────────────────────────────────────────────────────────────────────────
# simulation(), Phase 6: Auswertung (sim_evaluate.R) und Hauptfunktion
# ─────────────────────────────────────────────────────────────────────────────

# Seit E17 Stufe 3 rechnet der C++-Kern core/evaluate_core_impl.h (simlev_c_eval_*) Wertreihen, Renditen, XIRR,
# Drawdowns, Kennzahlen und die Ursachen nicht definierter Kennzahlen; Warnungen, Abbrüche und Ursachen kommen als
# Codes mit Werten, die Texte setzt dieses Modul wortgleich zu R. Hier bleiben risk_free (Spalte von data), die
# Texte und das Ergebnisobjekt.

struct _Eval
    total_worth::Vector{Float64}
    twr_index::Vector{Float64}
    invested::Vector{Float64}
    has_ext_flows::Bool
    cagr::Float64
    ttwror::Float64
    open_tax_debt::Float64
    drawdowns::Vector{Float64}
end

"Reihe `risk_free` in Prozent (Zahl auf alle Tage, `nothing` wie 0, oder Spalte von `data`)."
function _sim_risk_free(risk_free, fr::_Frame, n_days_sim::Int)
    @nospecialize
    risk_free === nothing && (risk_free = 0)
    if risk_free isa AbstractString
        haskey(fr, risk_free) || error("risk_free: Spalte '$risk_free' fehlt im Datensatz.")
        col = fr.cols[risk_free]
        k = fr.kinds[risk_free]
        k == :numeric && return Float64.(copy(col))
        k == :logical && return Float64[x === missing || x === nothing ? NA : Float64(x) for x in col]
        if k == :character   # as.numeric wie R: nicht lesbarer Text ergibt NA mit Warnung
            coerced = false
            v = Float64[]
            for x in col
                if x === missing || x === nothing
                    push!(v, NA)
                    continue
                end
                y = r_as_numeric(string(x))
                isna_strict(y) && !all(isspace, string(x)) && strip(string(x)) != "NA" && (coerced = true)
                push!(v, y)
            end
            coerced && @warn "NAs introduced by coercion"
            return v
        end
        return Float64[x isa Real ? Float64(x) : NA for x in col]
    end
    return fill(Float64(risk_free), n_days_sim)
end

# Namen der Kennzahlen und Ursachen (enum Stat, Metric, Reason in core/evaluate_core_impl.h)
const _EVAL_STATS = ("mean", "sd", "cv", "risk_free", "skewness", "kurtosis", "lpm", "hpm", "sharpe", "sortino",
                     "calmar", "omega", "gain_to_pain", "serenity", "martin_ratio", "max_drawdown", "average_drawdown",
                     "ulcer_index", "longest_drawdown", "avg_recovery_time")
const _EVAL_METRICS = ("cagr", "ttwror", _EVAL_STATS..., "buys", "sells")
const _EVAL_REASONS = ("too_short", "negative_end_value", "no_irr_solution", "zero_start_value", "nonpositive_twr_index",
                       "not_finite", "zero_mean_return", "zero_volatility", "no_negative_returns", "no_drawdown",
                       "no_recovery")
const _EVAL_FIXED = Dict(6 => "Rechnung ergibt keinen endlichen Wert", 7 => "keine Tagesrendite (Einzeltag)",
                         9 => "kein Drawdown im Zeitraum (max_drawdown 0)", 11 => "mittlere Tagesrendite ist 0",
                         13 => "keine negativen Überschussrenditen (Downside-Abweichung 0)",
                         14 => "keine negativen Tagesrenditen", 15 => "kein Drawdown im Zeitraum (Ulcer Index 0)",
                         16 => "kein Drawdown im Zeitraum")

"Klartext einer Ursache (enum Detail in core/evaluate_core_impl.h)."
function _eval_detail(d::Integer, v, why_text)
    d == 0 && return "Zeitraum $(_n_tage(Int(v[1]))), Laufzeit 0 Jahre (Einzeltag)"
    d == 1 && return r_sprintf("Endwert %.2f EUR negativ", v[1])
    d == 2 && return r_sprintf("Endwert %.2f EUR negativ: offene Steuerschuld %.2f EUR", v[1], v[2])
    d == 3 && return r_sprintf("kein interner Zinsfuß: Startwert %.2f EUR, Einzahlungen %.2f EUR, Endwert %.2f EUR",
                               v[1], v[2], v[3])
    d == 4 && return r_sprintf("Depotwert am Starttag %.2f EUR", v[1])
    d == 5 && return r_sprintf("zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %%)",
                               fmt_date(Int(v[1])), v[2])
    if d == 8
        k = Int(v[1])
        return "nur $k $(k == 1 ? "Tagesrendite" : "Tagesrenditen"), mindestens $(Int(v[2])) nötig"
    end
    d == 10 && return "Standardabweichung der $(Int(v[1])) Tagesrenditen ist 0 (konstanter Verlauf)"
    d == 12 && return "Standardabweichung der $(Int(v[1])) Überschussrenditen ist 0"
    d == 17 && return "Drawdown bis zum Ende nicht aufgeholt (längster Drawdown $(_n_tage(Int(v[1]))))"
    d == 18 && return "Zeitraum $(_n_tage(Int(v[1]))), Laufzeit 0 Jahre: keine Anzahl je Jahr (Einzeltag)"
    if d == 19
        k = Int(v[1])
        return "$(_EVAL_METRICS[k+1]) nicht definiert: $(why_text[k+1])"
    end
    return _EVAL_FIXED[Int(d)]
end

"Warnung der Auswertung (Code des Kerns) mit dem Text von R."
function _eval_warn(code::Integer, v)
    if 1 <= code <= 3
        @warn _XIRR_WARN[code]
    elseif code == 10
        @warn r_sprintf("simulation: geldgewichtete Rendite (cagr) mit Einzahlungen nicht bestimmbar (Startwert %.2f EUR, Einzahlungen %.2f EUR, Endwert %.2f EUR): kein interner Zinsfuß gefunden; cagr = NA.",
                        v[1], v[2], v[3])
    elseif code == 11
        @warn r_sprintf("simulation: Endwert negativ (%.2f EUR, %s); Verlust über 100 %%: cagr und ttwror sind nicht definiert (NA), Drawdowns auf 100 %% begrenzt.",
                        v[1], v[2] > 0 ? r_sprintf("offene Steuerschuld %.2f EUR", v[2]) : "nicht gedeckte Steuerschuld")
    elseif code == 12
        @warn "simulation: zeitgewichteter Wertindex wird negativ (Tagesrendite unter -100 %); ttwror ist nicht definiert (NA)."
    elseif code == 13
        @warn "simulation: Zeitraum $(_n_tage(Int(v[1]))) (Laufzeit 0 Jahre): cagr und ttwror sind nicht definiert (NA)."
    elseif code == 14
        @warn r_sprintf("simulation: Depotwert am Starttag %.2f EUR: cagr ist nicht definiert (NA).", v[1])
    elseif code == 15
        @warn r_sprintf("simulation: zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %% bei Depotwert %.2f EUR am Vortag und Einzahlung %.2f EUR); TTWROR und die zeitgewichteten Drawdowns sind nicht aussagekräftig (Drawdowns auf 100 %% begrenzt).",
                        fmt_date(Int(v[1])), v[2], v[3], v[4])
    elseif code == 16
        @warn r_sprintf("simulation: Depotwert am %s negativ (%.2f EUR, Steuerschuld); Drawdowns auf 100 %% begrenzt.",
                        fmt_date(Int(v[1])), v[2])
    elseif code == 17
        @warn "no non-missing arguments to max; returning -Inf"
    else
        error("simulation: interner Fehler: unbekannter Ereigniscode $code der Auswertung.")
    end
    return nothing
end

"Auswertung im Kern (E17 Stufe 3); Meldungen in der Reihenfolge von R (Warnungen, risk_free, Abbruch)."
function _sim_evaluate(R::Run, sim::Sim, start_date::Int, stopp_date::Int, fr::_Frame)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    na = length(fl.flag_assets)
    n = length(fl.flag_date)
    rf = Float64[]
    rf_err = nothing
    try
        rf = _sim_risk_free(cfg.risk_free, fr, n)
    catch e
        rf_err = e
    end
    day = Float64.(fl.flag_date)
    filled = any(fl.flag_filled) ? Int32.(fl.flag_filled) : Int32[]
    sc = Float64[start_date, stopp_date, cfg.start_value, R.tax_unpaid_total]
    sm = Float64[sim.status[a].money for a in 1:na]
    nb = Float64[length(sim.trades[a].buys) for a in 1:na]
    ns = Float64[length(sim.trades[a].sells) for a in 1:na]
    cnt = zeros(Int64, 2)
    tw = zeros(n); twr = zeros(n); inv = zeros(n); dd = zeros(n); scal = zeros(3); ints = zeros(Int32, 4)
    stv = zeros(20); buys = zeros(na); sells = zeros(na); why_i = zeros(Int32, 6); why_v = zeros(6)
    err = zeros(Int32, 2)
    um_i = Int32[]; um_v = Float64[]; msg_c = Int32[]; msg_v = Float64[]
    h = ccall((:simlev_c_eval_new, LIBSLC), Ptr{Cvoid}, ())
    h == C_NULL && throw(OutOfMemoryError())
    try
        pt = Ptr{Float64}[pointer(sim.report[a].total) for a in 1:na]
        pf = Ptr{Float64}[pointer(sim.report[a].flows) for a in 1:na]
        pw = Ptr{Float64}[pointer(sim.report[a].worth) for a in 1:na]
        pm = Ptr{Float64}[pointer(sim.report[a].money) for a in 1:na]
        pp = Ptr{Float64}[pointer(sim.market[a].asset_price) for a in 1:na]
        GC.@preserve sim pt pf pw pm pp day filled sc sm nb ns rf cnt begin
            rc = ccall((:simlev_c_eval_run, LIBSLC), Cint,
                       (Ptr{Cvoid}, Int64, Int64, Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}},
                        Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64},
                        Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Int64, Int32, Ptr{Int64}),
                       h, n, na, pt, pf, pw, pm, pp, day, isempty(filled) ? Ptr{Int32}(C_NULL) : pointer(filled), sc, sm,
                       nb, ns, rf_err === nothing ? pointer(rf) : Ptr{Float64}(C_NULL),
                       rf_err === nothing ? length(rf) : 0, Int32(rf_err === nothing), cnt)
        end
        CAbi.check(rc)
        um_i = zeros(Int32, 3 * cnt[1]); um_v = zeros(3 * cnt[1]); msg_c = zeros(Int32, cnt[2]); msg_v = zeros(4 * cnt[2])
        ccall((:simlev_c_eval_get, LIBSLC), Cvoid,
              (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64},
               Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64},
               Ptr{Int32}),
              h, tw, twr, inv, dd, scal, ints, stv, buys, sells, why_i, why_v, um_i, um_v, msg_c, msg_v, err)
    finally
        ccall((:simlev_c_eval_free, LIBSLC), Cvoid, (Ptr{Cvoid},), h)
    end
    for i in eachindex(msg_c)
        _eval_warn(msg_c[i], view(msg_v, 4i-3:4i))
    end
    err[2] == 1 && error("missing value where TRUE/FALSE needed")
    rf_err === nothing || throw(rf_err)
    err[2] == 2 && error("missing value where TRUE/FALSE needed")
    statistics = RList((k => stv[j] for (j, k) in enumerate(_EVAL_STATS))...)
    statistics["longest_drawdown"] = Int(ints[4])
    why_text = [why_i[3k+1] != 0 ? _eval_detail(why_i[3k+3], view(why_v, 3k+1:3k+3), nothing) : "" for k in 0:1]
    k = length(um_i) ÷ 3
    undefined_metrics = RFrame("metric" => String[_EVAL_METRICS[um_i[3i+1]+1] for i in 0:k-1],
                               "reason" => String[_EVAL_REASONS[um_i[3i+2]+1] for i in 0:k-1],
                               "detail" => String[_eval_detail(um_i[3i+3], view(um_v, 3i+1:3i+3), why_text) for i in 0:k-1];
                               class = ["data.frame"])
    nms = sim.names
    ev = _Eval(tw, twr, inv, ints[1] != 0, scal[1], scal[2], scal[3], dd)
    return ev, statistics, undefined_metrics, RVector(buys; names = nms), RVector(sells; names = nms)
end

function _sim_compact_trades(sim::Sim)
    return RList([sim.names[a] => (buys = sim.trades[a].buys, sells = sim.trades[a].sells, taxes = sim.trades[a].taxes)
                  for a in eachindex(sim.names)]...)
end

function _sim_result(R::Run, sim::Sim, r::_Eval, statistics::RList, undefined_metrics::RFrame, buys::RVector, sells::RVector)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    flag_date = fl.flag_date
    tax_mode = cfg.tax_mode
    te = cfg.tariff_env
    open_lots = nothing
    if tax_mode == "person"
        open_lots = RList()
        for (a, nm) in enumerate(sim.names)
            lots = [b for b in sim.trades[a].buys if b.remaining > 0]
            sp_ = get(cfg.strategy[a].second, "spread", nothing)
            open_lots[nm] = RList("lots" => RFrame("date" => Date[from_days(b.date) for b in lots],
                                                   "units" => Float64[b.remaining for b in lots],
                                                   "price" => Float64[b.price for b in lots],
                                                   "vp" => Float64[b.vp for b in lots]; class = ["data.frame"]),
                                  "regime" => fl.tax_regimes[a], "partial_exemption" => 100 * sim.assets[a].bonus,
                                  "cash" => sim.status[a].money,
                                  "spread" => sp_ === nothing ? 0.0 : sp_,
                                  "order_fee" => cfg.order_fee)
        end
    end
    t = sim.totals
    tax_report = RList("total_taxes_paid" => t.total_taxes, "loss_carryforward_capital" => t.loss_capital_gains,
                       "loss_carryforward_private" => t.loss_private_sales,
                       "sparer_pauschbetrag_annual" => t.sparer_pauschbetrag_annual,
                       "sparer_pauschbetrag_used" => t.sparer_pauschbetrag_used_total,
                       "sparer_pauschbetrag_tax_saved" => t.sparer_pauschbetrag_used_total * cfg.effective_tax_rate,
                       "open_tax_debt" => r.open_tax_debt)
    if te !== nothing && !isempty(te.rows)
        cols = keys(te.rows[1])
        tax_report["tariff_years"] = RFrame([c => (c == "year" ? Int[rw[c] for rw in te.rows] :
                                                   c == "guenstiger" ? Bool[rw[c] for rw in te.rows] :
                                                   Float64[rw[c] for rw in te.rows]) for c in cols]...; class = ["data.frame"])
    end
    if tax_mode == "person"
        use_spb = cfg.use_sparer_pauschbetrag
        ny = t.current_year
        nyd = RList("year" => ny,
                    "sparer_pauschbetrag_used" => use_spb ? _rmax(0.0, t.sparer_pauschbetrag_annual - t.sparer_pauschbetrag_remaining) : 0.0,
                    "sparer_pauschbetrag_remaining" => use_spb ? t.sparer_pauschbetrag_remaining : 0.0,
                    "loss_carryforward_capital" => t.loss_capital_gains,
                    "loss_carryforward_private" => t.loss_private_sales,
                    "capital_income_taxed" => t.cgt_base_taxed_ytd,
                    "loss_capital_added" => t.cgt_loss_added_ytd,
                    "loss_capital_used" => t.cgt_loss_used_ytd,
                    "loss_capital_start" => t.cgt_pool_start_ytd,
                    "private_sale_net" => t.private_sale_gains_ytd - t.private_sale_losses_ytd)
        if te !== nothing
            ks = get(te.ks, string(ny), NA)
            nyd["church_tax_settlement"] = isnan(ks) ? 0.0 : ks
            nyd["tariff_assessed"] = any(rw -> rw["year"] == ny, te.rows)
        end
        tax_report["next_year"] = nyd
    end
    report = RList()
    for (a, nm) in enumerate(sim.names)
        rp = sim.report[a]
        report[nm] = RList("worth" => rp.worth, "money" => rp.money, "flows" => rp.flows, "total" => rp.total, "share" => rp.share)
    end
    res = RList(; class = ["SimLevResult"])
    res["dates"] = Date[from_days(z) for z in flag_date]
    res["filled"] = Vector{Bool}(fl.flag_filled)
    res["worth"] = r.total_worth
    res["twr_index"] = r.twr_index
    res["invested"] = r.invested
    res["external_flows"] = r.has_ext_flows
    res["cagr"] = r.cagr
    res["ttwror"] = r.ttwror
    res["drawdowns"] = r.drawdowns
    res["statistics"] = statistics
    res["buys"] = buys
    res["sells"] = sells
    res["report"] = report
    res["tax_report"] = tax_report
    res["undefined_metrics"] = undefined_metrics
    res["open_lots"] = open_lots
    cfg.fees_on && (res["fees_paid"] = R.fee_paid)
    _is_true(cfg.harvest_mode) && (res["harvest_days"] = Date[from_days(flag_date[i]) for i in findall(fl.flag_harvest)])
    cfg.wrappers !== nothing && length(cfg.wrappers) > 0 && (res["wrappers"] = cfg.wrappers)   # nur mit details = true
    return SimLevResult(res, _sim_compact_trades(sim))
end

# ── Hauptfunktion ──────────────────────────────────────────────────────────

"""
    simulation(data, strategy; start_value = 10000, costs = sim_costs(), dca = nothing,
               rebalance = nothing, splits = nothing, tax = nothing, risk_free = 0,
               fractions = true, liquidate = false, details = false, io = stdout)

Portfolio-Simulation (Backtest) mit Sparplan, Rebalancing und deutscher
Besteuerung; bitgleiche Portierung von `simulation()` aus dem R-Paket SimLev
0.5.0. Die Einstellungen kommen als Bausteine (Etappe 6.3): `costs =
sim_costs()` (Standard), `dca = dca_plan()`, `rebalance = rebalance_plan()`,
`splits = split_rule()`, `tax = tax_profile()` (mit `income = income_rate()`
oder `income_tariff()` und `harvest = harvest_rule()`); `nothing` heißt aus. Den
alten Fondsmodus (`funds = funds_costs()`) gibt es seit Etappe 6.5c nicht mehr.
Alle Raten und Schwellen **in Prozent** (`risk_free = 2` …).

`data`: RFrame, NamedTuple, Dict oder Pair-Vektor mit Spalte `date` (Date)
und je Asset einer Kursspalte. `strategy`: Ergebnis von `create_strategy()`
oder eine benannte Liste (Dict, NamedTuple, Pair-Vektor) von Asset-
Konfigurationen. `risk_free`: Zahl in Prozent p. a. oder Spaltenname in `data`.

Hinweise (R: `message()`) gehen nach `stderr`, Warnungen über `@warn`, Fehler
als `ErrorException` (Texte wie in R). Die `details`-Ausgabe geht nach `io`.
Rückgabe: [`SimLevResult`](@ref).
"""
function simulation(data, strategy; start_value = 10000, costs = sim_costs(), dca = nothing, rebalance = nothing,
                    splits = nothing, tax = nothing, risk_free = 0, fractions = true,
                    liquidate = false, details = false, io::IO = stdout)
    @nospecialize
    flat = _sim_from_blocks(costs, dca, rebalance, splits, tax)
    return _simulation_flat(data, strategy; start_value = start_value, risk_free = risk_free, fractions = fractions,
                            liquidate = liquidate, details = details, io = io, _blocks = true, flat...)
end

"""
    _simulation_flat(data, strategy; start_value, spread, details, liquidate, dca_mode, …, io)

Engine mit den flachen Argumenten bis Etappe 6.2 (R: `.simulation_flat`).
`simulation()` übersetzt die Bausteine mit `_sim_from_blocks` hierher
(`_blocks = true`: Prüfungen der Bausteine entfallen, Meldungen nennen die
Bausteine). Die Aufrufer mit `sim_args` gehen seit Etappe 6.4 über
`simulation()` (`_sim_args_set`, `_sim_call` in sim_blocks.jl).
`tax_tariff`: `nothing`, Dateipfad oder `tax_tariff()`.
"""
function _simulation_flat(data, strategy; start_value = 10000, spread = nothing, details = false, liquidate = false,
                    dca_mode = false, dca_value = nothing, dca_span = nothing, dca_days = nothing,
                    dca_unit = ("month", "quarter", "year"), dca_anchor = ("start", "end"), dca_start = nothing,
                    dca_skip = false, balance_mode = false, balance_span = nothing, balance_days = nothing,
                    balance_unit = ("month", "quarter", "year"), balance_anchor = ("start", "end"),
                    balance_start = nothing, balance_skip = false, balance_dca = false, balance_thresh = nothing,
                    balance_thresh_type = ("absolute", "relative"), tax_mode = ("none", "person"),
                    tax_rate = _UNSET, marginal_tax_rate = _UNSET, use_guenstigerpruefung = false,
                    private_sale_threshold = 1000, sparer_pauschbetrag = 1000, use_sparer_pauschbetrag = true,
                    include_soli_on_income_tax = _UNSET, soli_rate_income_tax = _UNSET, base_rate = nothing,
                    base_rate_flex = false, base_rate_data = nothing, fractions = true, risk_free = 0, split_mode = false, split_thresh = nothing, event_col = nothing,
                    event_mode = _UNSET, event_weight = nothing, church_tax = 0, order_fee = nothing,
                    dca_fee = nothing, harvest_mode = false, harvest_day = "12-15", harvest_loss_pot = true,
                    taxable_income = nothing, tax_tariff = nothing, io::IO = stdout, _blocks::Bool = false)
    @nospecialize
    given = _Given(Dict("tax_rate" => !(tax_rate isa _Unset), "marginal_tax_rate" => !(marginal_tax_rate isa _Unset),
                        "include_soli_on_income_tax" => !(include_soli_on_income_tax isa _Unset),
                        "soli_rate_income_tax" => !(soli_rate_income_tax isa _Unset),
                        "event_mode" => !(event_mode isa _Unset)))
    _blocks && (given = _Given(Dict(k => false for k in keys(given.d))))
    tax_rate = _val(tax_rate, 26.375)
    marginal_tax_rate = _val(marginal_tax_rate, nothing)
    include_soli_on_income_tax = _val(include_soli_on_income_tax, false)
    soli_rate_income_tax = _val(soli_rate_income_tax, 5.5)
    event_mode = _val(event_mode, ("additional", "replace"))
    details = details == true
    cfg, fr = _sim_check_inputs(data, strategy, start_value, spread, details, dca_mode, dca_value, dca_span, dca_days,
                                balance_mode, balance_days, balance_thresh, balance_thresh_type, tax_mode, tax_rate,
                                marginal_tax_rate, use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                                use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax, base_rate,
                                fractions, risk_free, split_mode, split_thresh, event_col, church_tax,
                                order_fee, dca_fee, harvest_mode, harvest_day, taxable_income, tax_tariff, given, io,
                                _blocks)
    split_thresh !== nothing && (split_thresh = _num_vec(split_thresh))
    start_date, stopp_date = _sim_prepare_data(fr, cfg.pre_filled, base_rate_flex, base_rate_data, _blocks)
    sim = _sim_build_state(fr, cfg.strategy, cfg.start_value, start_date, stopp_date, cfg.sparer_pauschbetrag,
                           cfg.use_sparer_pauschbetrag, cfg.base_rate, base_rate_flex, base_rate_data, _blocks)
    fl, ew = _sim_build_calendar(fr, sim, cfg.strategy, start_date, stopp_date, liquidate, cfg.dca_mode, dca_span,
                                 dca_unit, cfg.dca_days, cfg.dca_value, dca_anchor, dca_start, dca_skip, cfg.balance_mode,
                                 balance_span, balance_unit, cfg.balance_days, balance_anchor, balance_start,
                                 balance_skip, cfg.event_col, event_mode, event_weight, _blocks)
    cfg.event_col !== nothing && (event_weight = ew)
    event_weight isa Union{Nothing,Vector{Pair{String,Any}}} || (event_weight = Pair{String,Any}[p for p in _kvpairs(event_weight)])
    R = Run(cfg, fl, details, io, 0.0, 0.0)
    # 3.-5. Termine, Flags, Startgewichte (E17 Stufe 2), Tagesschleife und Abschluss des letzten Jahres im C++-Kern
    # (sim_engine.jl)
    _sim_engine_run!(R, sim, fr, liquidate, event_weight, split_thresh, balance_dca, harvest_loss_pot, stopp_date,
                     harvest_day)
    # 6. Auswertung im C++-Kern (E17 Stufe 3) und Ergebnisobjekt
    ret, statistics, um, buys, sells = _sim_evaluate(R, sim, start_date, stopp_date, fr)
    return _sim_result(R, sim, ret, statistics, um, buys, sells)
end

