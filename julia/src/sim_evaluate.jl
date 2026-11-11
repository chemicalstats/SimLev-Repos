# ─────────────────────────────────────────────────────────────────────────────
# simulation(), Phase 6: Auswertung (sim_evaluate.R) und Hauptfunktion
# ─────────────────────────────────────────────────────────────────────────────

# rechnet der C++-Kern core/evaluate_core_impl.h (simlev_c_eval_*) Wertreihen, Renditen, XIRR,
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
        haskey(fr, risk_free) || chk_stop("a.m_sim_risk_free", risk_free)
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
# Texte aus core/meldungen.tsv (meldungen.jl); Ursachen ohne Werte (Text fest)
const _EVAL_FIXED = Dict(k => _MELD_EVAL_DETAIL[string(k)] for k in (6, 7, 9, 11, 13, 14, 15, 16))

"Klartext einer Ursache (enum Detail in core/evaluate_core_impl.h); Texte aus `_MELD_EVAL_DETAIL`."
function _eval_detail(d::Integer, v, why_text)
    m = _MELD_EVAL_DETAIL
    d == 0 && return r_sprintf(m["0"], _n_tage(Int(v[1])))
    d == 1 && return r_sprintf(m["1"], v[1])
    d == 2 && return r_sprintf(m["2"], v[1], v[2])
    d == 3 && return r_sprintf(m["3"], v[1], v[2], v[3])
    d == 4 && return r_sprintf(m["4"], v[1])
    d == 5 && return r_sprintf(m["5"], fmt_date(Int(v[1])), v[2])
    if d == 8
        k = Int(v[1])
        return r_sprintf(m["8"], k, k == 1 ? m["8.eins"] : m["8.mehr"], Int(v[2]))
    end
    d == 10 && return r_sprintf(m["10"], Int(v[1]))
    d == 12 && return r_sprintf(m["12"], Int(v[1]))
    d == 17 && return r_sprintf(m["17"], _n_tage(Int(v[1])))
    d == 18 && return r_sprintf(m["18"], _n_tage(Int(v[1])))
    if d == 19
        k = Int(v[1])
        return r_sprintf(m["19"], _EVAL_METRICS[k+1], why_text[k+1])
    end
    return _EVAL_FIXED[Int(d)]
end

"Warnung der Auswertung (Code des Kerns) mit dem Text von R; Texte aus `_MELD_EVAL_WARN`."
function _eval_warn(code::Integer, v)
    m = _MELD_EVAL_WARN
    if 1 <= code <= 3
        @warn _XIRR_WARN[code]
    elseif code == 10
        @warn r_sprintf(m["10"], v[1], v[2], v[3])
    elseif code == 11
        @warn r_sprintf(m["11"], v[1], v[2] > 0 ? r_sprintf(m["11.offen"], v[2]) : m["11.ungedeckt"])
    elseif code == 12
        @warn m["12"]
    elseif code == 13
        @warn r_sprintf(m["13"], _n_tage(Int(v[1])))
    elseif code == 14
        @warn r_sprintf(m["14"], v[1])
    elseif code == 15
        @warn r_sprintf(m["15"], fmt_date(Int(v[1])), v[2], v[3], v[4])
    elseif code == 16
        @warn r_sprintf(m["16"], fmt_date(Int(v[1])), v[2])
    elseif code == 17
        @warn m["17"]
    else
        error(r_sprintf(m["unbekannt"], code))
    end
    return nothing
end

"""Teile der Auswertung ohne den Engine-Lauf (seit 1.6.5 eigene Funktion, Paket E: der Studienkern sim_prepared.jl merkt
sie sich): rf, rf_err (Fehler von risk_free bzw. nothing), day, filled, sc (start_date, stopp_date, start_value)."""
function _sim_eval_static(R::Run, start_date::Int, stopp_date::Int, fr::_Frame)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    n = length(fl.flag_date)
    rf = Float64[]
    rf_err = nothing
    try
        rf = _sim_risk_free(cfg.risk_free, fr, n)
    catch e
        rf_err = e
    end
    return (rf = rf, rf_err = rf_err, day = Float64.(fl.flag_date),
            filled = any(fl.flag_filled) ? Int32.(fl.flag_filled) : Int32[],
            sc = Float64[start_date, stopp_date, cfg.start_value])
end

"Auswertung im Kern; Meldungen in der Reihenfolge von R (Warnungen, risk_free, Abbruch)."
function _sim_evaluate(R::Run, sim::Sim, start_date::Int, stopp_date::Int, fr::_Frame, st = nothing)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    na = length(fl.flag_assets)
    n = length(fl.flag_date)
    st === nothing && (st = _sim_eval_static(R, start_date, stopp_date, fr))   # st: schon aus _capture (Studienkern)
    rf, rf_err, day, filled = st.rf, st.rf_err, st.day, st.filled
    sc = Float64[st.sc[1], st.sc[2], st.sc[3], R.tax_unpaid_total]
    sm = Float64[sim.status[a].money for a in 1:na]
    nb = Float64[length(sim.trades[a].buys) for a in 1:na]
    ns = Float64[length(sim.trades[a].sells) for a in 1:na]
    cnt = zeros(Int64, 2)
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
        return _sim_eval_output(h, n, na, cnt, rf_err, sim.names)
    finally
        ccall((:simlev_c_eval_free, LIBSLC), Cvoid, (Ptr{Cvoid},), h)
    end
end

"""Ergebnis der Auswertung (Objekt h nach dem Lauf, cnt Zahl der Zeilen und Warnungen) mit Meldungen in der Reihenfolge von R
(seit 1.6.5 eigene Funktion, auch für den Studienkern)."""
function _sim_eval_output(h::Ptr{Cvoid}, n::Int, na::Int, cnt::Vector{Int64}, rf_err, nms)
    @nospecialize
    tw = zeros(n); twr = zeros(n); inv = zeros(n); dd = zeros(n); scal = zeros(3); ints = zeros(Int32, 2)
    stv = zeros(20); buys = zeros(na); sells = zeros(na); why_i = zeros(Int32, 4); why_v = zeros(6)
    err = zeros(Int32, 1)
    um_i = zeros(Int32, 3 * cnt[1]); um_v = zeros(3 * cnt[1]); msg_c = zeros(Int32, cnt[2]); msg_v = zeros(4 * cnt[2])
    ccall((:simlev_c_eval_get, LIBSLC), Cvoid,
          (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64},
           Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64},
           Ptr{Int32}),
          h, tw, twr, inv, dd, scal, ints, stv, buys, sells, why_i, why_v, um_i, um_v, msg_c, msg_v, err)
    for i in eachindex(msg_c)
        _eval_warn(msg_c[i], view(msg_v, 4i-3:4i))
    end
    err[1] == 1 && error("missing value where TRUE/FALSE needed")
    rf_err === nothing || throw(rf_err)
    err[1] == 2 && error("missing value where TRUE/FALSE needed")
    statistics = RList((k => stv[j] for (j, k) in enumerate(_EVAL_STATS))...)
    statistics["longest_drawdown"] = Int(ints[2])
    why_text = [why_i[2k+1] != 0 ? _eval_detail(why_i[2k+2], view(why_v, 3k+1:3k+3), nothing) : "" for k in 0:1]
    k = length(um_i) ÷ 3
    undefined_metrics = RFrame("metric" => String[_EVAL_METRICS[um_i[3i+1]+1] for i in 0:k-1],
                               "reason" => String[_EVAL_REASONS[um_i[3i+2]+1] for i in 0:k-1],
                               "detail" => String[_eval_detail(um_i[3i+3], view(um_v, 3i+1:3i+3), why_text) for i in 0:k-1];
                               class = ["data.frame"])
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
    (cfg.fees_on || cfg.fee_cust !== nothing) && (res["fees_paid"] = R.fee_paid)   # seit 1.6.5 auch mit Depotgebühr
    _is_true(cfg.harvest_mode) && (res["harvest_days"] = Date[from_days(flag_date[i]) for i in findall(fl.flag_harvest)])
    cfg.wrappers !== nothing && length(cfg.wrappers) > 0 && (res["wrappers"] = cfg.wrappers)   # nur mit details = true
    return SimLevResult(res, _sim_compact_trades(sim))
end

# ── Hauptfunktion ──────────────────────────────────────────────────────────

"""
    simulation(data, strategy; start_value = 10000, costs = sim_costs(), dca = nothing,
               rebalance = nothing, splits = nothing, tax = nothing, risk_free = 0,
               fractions = true, liquidate = false, details = false, io = stdout)

Portfolio-Simulation (Backtest) mit Bausteinen (Anhang C).

Backtestet eine oder mehrere Asset-Strategien auf historischen oder synthetischen Preisreihen. Die Engine
verarbeitet jede Preisreihe so, wie sie übergeben wird – Hebelung, Dividenden und Finanzierungskosten sind
Bestandteil der Inputreihe und werden nicht intern berechnet.

Die Simulation unterstützt Buy-and-Hold (`"bnh"`), signalgesteuerte Strategien (`"signal"`), DCA-Sparpläne,
periodisches Rebalancing, ereignisbasiertes Rebalancing sowie die Deutsche Investmentbesteuerung (§§ 18–20
InvStG, § 23 EStG).

# Argumente
- `data`: `data.frame` (`RFrame`; nur Tabellen, NamedTuple oder Dict vorher mit `RFrame(pairs(x)...)`,
  einen Vektor von Paaren mit `RFrame(x...)` umwandeln) mit täglichen Marktdaten. Pflichtfelder: `date`
  (Klasse `Date`, aufsteigend) und je eine Kursspalte pro Asset (Niveaus, keine Renditen; Name muss mit dem
  Asset-Namen in `strategy` übereinstimmen; für Fonds-Wrapper die Spalten der inneren Strategie, siehe Abschnitt
  „Fonds-Wrapper“). Optionale Spalten: Basiszins in Prozent (Spaltenname in `tax_profile(base_rate = )`),
  Signalspalten (für `trading = "signal"`; `true`/`false` oder `0`/`1`, NA erlaubt, andere Zahlen sind ein
  Fehler), Risk-Free-Reihe in Prozent p.a. (Name in `risk_free`), logische Trigger- und numerische
  Gewichtsspalten für `rebalance_plan(event_col, event_weight)`. Fehlende Kalendertage werden
  automatisch per LOCF aufgefüllt (logische Spalten mit `false`; seit 1.6.5 mit Hinweis nur, wenn eine Lücke
  länger als 5 Kalendertage ist); aufgefüllte Tage werden in `filled` markiert
  und aus Risikometriken ausgeschlossen. Trägt `data` das Attribut `filled` aus `series_align`, gelten Tage,
  an denen keines der Strategie-Assets einen echten Kurs hat, ebenso als aufgefüllt (kein Handel, nicht in den
  Risikometriken). Passt die Zeilenzahl des Attributs nicht zu `data` (z. B. nach einer Zeilenauswahl der
  `series_align()`-Ausgabe), wird es mit Warnung ignoriert; den Zeitraum daher mit `series_align(..., start =,
  end =)` wählen.
  Seit 1.6.4 darf `date` kein Faktor sein (vorher still in Text umgewandelt).

  Eingabeprüfung: `date` als Text im Format `"JJJJ-MM-TT"` (oder Faktor) wird mit Hinweis in `Date`
  umgewandelt; unsortierte Zeilen werden mit Hinweis aufsteigend sortiert; doppelte Daten und doppelte
  Spaltennamen führen zu einem Fehler. Kurse müssen positiv sein (`<= 0` oder unendlich: Fehler) und seit 1.6.4 zwischen 1e-100 und 1e100 liegen (sonst Fehler). Einzelne
  fehlende Kurse (`NA`) werden mit Hinweis per LOCF gefüllt; sind in einer Zeile alle Kurse `NA`, gilt der Tag
  als aufgefüllt. Hat ein Asset erst ab einem späteren Tag Kurse (führende `NA`, etwa aus `series_align(range
  = "all")`), wird es wie mit `start` = erster Kurstag behandelt. Mindestens ein Asset muss am ersten Tag
  handelbar sein. Andere Tabelle (RFrame)-Klassen (z. B. tibble) werden in einen `data.frame` umgewandelt.
- `strategy`: Benannte Liste von Asset-Konfigurationen, idealerweise erzeugt mit `create_strategy` und
  `asset_config`. Direkte Listen-Übergabe ist ebenfalls möglich (Backward-Kompatibilität). Die Zielgewichte
  `share` (Anteile, 0--1) müssen sich auf exakt 1 summieren (Toleranz 1e-6); sie werden nicht normiert, sonst
  bricht die Funktion mit Fehler ab. Asset-Namen müssen eindeutig sein. Assets mit späterem `start` erhalten
  ab dem Start ihr volles Zielgewicht (das Startkapital verteilt sich bis dahin auf die übrigen Assets); am
  Starttag wird immer auf die Zielgewichte umgeschichtet (Verkauf der übrigen Assets, Kauf des neuen; mit
  Steuern, Spreads und Gebühren wie bei jedem Rebalancing), auch ohne `rebalance`; ein zusätzlicher
  Handelsblock (z. B. Kauf aus einer Sparrate vor der Umschichtung) läuft an diesem Tag nicht. Mit `rebalance
  = rebalance_plan()` gilt danach der normale Rhythmus. Liegt `start` nach dem letzten Datentag, bricht die
  Funktion mit Fehler ab (das Asset wäre nie handelbar).
- `start_value`: Numerisch. Anfangskapital in EUR. Standard: `10000`.
- `costs`: Kosten: `sim_costs(order_fee, dca_fee; custody_fee)` (Ordergebühren, Gebühren der Sparplankäufe, seit 1.6.5 Depotgebühr) oder `nothing`
  (keine Kosten). Standard: `sim_costs()` (keine Gebühren). Der Bid-Ask-Spread gilt je Asset (`spread` in
  `asset_config`).
- `dca`: Sparplan: `dca_plan(value, span, days, unit, anchor, start, skip, fill_deficits)` oder `nothing`
  (Standard: kein Sparplan).
- `rebalance`: Rebalancing: `rebalance_plan(span, days, unit, anchor, start, skip, thresh, thresh_type,
  event_col, event_mode, event_weight)` oder `nothing` (Standard: kein Rebalancing). Mit Rebalancing wird am
  ersten Simulationstag (und am Starttag später startender Assets) nur über das Rebalancing gekauft (Erstkauf
  nach Zielgewichten); ein zusätzlicher Handelsblock mit anschließender Umschichtung von Resten entfällt.
- `splits`: Automatische Splits: `split_rule(thresh = [untere, obere])` oder `nothing` (Standard: keine
  Splits).
- `tax`: Persönliche Besteuerung (§§ 18--20 InvStG, § 23 EStG) mit FIFO-Buchführung: `tax_profile(rate,
  church_tax, sparer_pauschbetrag, private_sale_threshold, base_rate, guenstigerpruefung, income, harvest)`
  oder `nothing` (Standard: keine Steuern).
- `risk_free`: Numerisch oder Character. Annualisierte risikolose Rendite **in Prozent** (z. B. `3` = 3 %
  p.a.) oder Name einer Spalte in `data` mit einer täglichen, annualisierten Zeitreihe in Prozent (z. B. SOFR
  als `5.31`; nur Zahlenspalten, Text-, logische und Faktorspalten sind ein Fehler). Seit 1.6.5 sind fehlende Werte (NA) in der
  Spalte und Zinsen von -100 oder weniger ein Fehler. `nothing` und `0` sind äquivalent. Jede Tagesrate wird in ihr Tagesäquivalent umgerechnet und
  von der jeweiligen Tagesrendite abgezogen; Sharpe und Sortino werden auf den Überschussrenditen berechnet.
  LOCF-aufgefüllte Tage werden konsistent ausgeschlossen. Standard: `0`. Zahlen über 0 und unter 0,05
  (vermutlich Anteil, z. B. `0.02` für 2 %) werden mit Warnung als Prozent gelesen; kleine echte Prozentsätze
  wie `0.25` (Geldmarkt 2016--2019) warnen nicht. Für eine Spalte gilt dieselbe Schwelle für den Median ihrer
  Werte (ohne `NA` und 0).
- `fractions`: Logisch. Bruchteile von Anteilen erlauben? Bei `false` werden bei einem Split entstehende
  Bruchteile einmalig zum Kurs des Split-Tages verkauft (Spitzenausgleich, ohne Spread und Gebühr; steuerlich
  ein Verkauf nach FIFO). Zwangsverkäufe für eine Steuerzahlung (Vorabpauschale, § 23) verkaufen die
  aufgerundete Stückzahl und bei verbleibendem Fehlbetrag ein weiteres Stück; ein Überschuss bleibt als Cash.
  Reicht ein Asset nicht, zahlen die übrigen Assets; ein dann noch offener Betrag bleibt als negativer
  Geldbestand (mit Warnung) stehen und wird nie still gestrichen. Standard: `true`. Nur `true` oder `false`
  (sonst Fehler).
- `liquidate`: Logisch. Portfolio am letzten Simulationstag vollständig liquidieren (inkl. Steuerabrechnung)?
  Übersteigt die Ordergebühr den Erlös einer Position, bleibt sie mit Warnung stehen. Am Liquidationstag
  finden kein Rebalancing und keine Sparrate statt, auch wenn ein Termin von einem aufgefüllten Tag dorthin
  verschoben wurde. Standard: `false`.
- `details`: Logisch. Detaillierte Steuer-/Trade-Ausgaben auf der Konsole? Standard: `false`.
- `io`: Ausgabestrom für Meldungen und die details-Ausgabe (Standard `stdout`).

# Rückgabe
Liste der Klasse `"SimLevResult"` mit:

- `dates`: Date-Vektor. Tägliche Simulationsdaten (Kalendertage inkl. aufgefüllter Tage).
- `filled`: Logischer Vektor (gleiche Länge wie `dates`). `true` = dieser Tag wurde per LOCF aufgefüllt (kein
  echter Handelstag). Aufgefüllte Tage werden aus allen renditebasierten Risikometriken ausgeschlossen.
- `worth`: Numerischer Vektor. Tägliche Portfoliowerte (Depotwert einschließlich Einzahlungen) in EUR.
- `twr_index`: Numerischer Vektor. Zeitgewichteter Wertindex (Start = 1), verkettet aus den um Einzahlungen
  bereinigten Tagesrenditen wie für `ttwror`: an Tagen ohne Einzahlung (W_t - W_t-1) / W_t-1. An Tagen mit
  Einzahlung F_t (angelegt zum Schlusskurs) wird zum Zeitpunkt der Zahlung bewertet (echte zeitgewichtete
  Rendite): V^pre_t = Vortagesbestand zum heutigen Schlusskurs plus Vortages-Cash, Tagesfaktor (V^pre_t /
  W_t-1) · W_t / (V^pre_t + F_t). Ohne Kosten entspricht die Tagesrendite damit der Kursrendite; Kaufkosten
  der Einzahlung (Spread, Gebühr) und alles, was am selben Tag danach geschieht, belasten das Kapital nach der
  Zahlung.
- `invested`: Numerischer Vektor. `start_value` plus kumulierte Einzahlungen (Sparplan, einschließlich einer
  Rate am Starttag) je Tag in EUR, brutto (vor Kaufkosten).
- `external_flows`: Logisch. `true`, wenn nach dem Starttag Einzahlungen erfolgten (Sparplan, `dca =
  dca_plan()`); eine Einzahlung am Starttag steckt im Startwert.
- `cagr`: Numerisch. Compound Annual Growth Rate (annualisierte Gesamtrendite) als Anteil (`0.05` = 5 % p.a.;
  Jahre = Kalendertage / 365,25). Mit Einzahlungen (`external_flows = true`) die geldgewichtete Jahresrendite:
  interner Zinsfuß (XIRR) aus Startbetrag, datierten Einzahlungen und Endwert, S (1+r)^T + Σ_i F_i (1+r)^T -
  t_i = W_n mit Startbetrag S = `start_value` plus Rate am Starttag (brutto, wie die übrigen Einzahlungen) und
  t_i = Kalendertage seit Start / 365,25 (Nullstelle nach Brent; auch bei Beinahe-Totalverlust mit Rendite
  nahe -100 %); ohne Einzahlungen nach dem Starttag (W_n / S)^1/T - 1. Seit 1.6.5 ist der Bezug immer S, also vor den
  Kaufkosten am Starttag (bis 1.6.4 ohne spätere Einzahlungen W_1 nach den Kaufkosten); Spread und Ordergebühr
  des Startkaufs mindern damit `cagr`, `ttwror`, `twr_index` (erste Stufe W_1 / S), die Drawdowns und alle
  Renditekennzahlen. Gibt es keine Lösung, ist `cagr = NA`
  (mit Warnung). Ist der Endwert negativ (nicht gedeckte Steuerschuld, Verlust über 100 %), sind `cagr` und
  `ttwror` nicht definiert: `NA` mit Warnung (nicht -1, das den Verlust untertreiben würde); der Endwert
  bleibt unverändert (nicht auf 0 begrenzt). Bei einem Einzeltag (Laufzeit 0 Jahre) sind `cagr` und `ttwror`
  ebenfalls `NA` (mit Warnung). Die Ursache steht in `undefined_metrics`. Die zeitgewichtete Rendite steht in
  `ttwror`.
- `ttwror`: Numerisch. True Time-Weighted Rate of Return (um DCA-Zuflüsse bereinigt, annualisiert) als Anteil;
  verkettete Tagesrenditen wie `twr_index` (Bewertung zum Zahlungszeitpunkt). Ohne Zuflüsse unverändert (W_t -
  W_t-1) / W_t-1.
- `drawdowns`: Numerischer Vektor. Tägliche Drawdowns vom jeweiligen Höchststand als positiver Anteil (`0.2` =
  20 % unter dem Höchststand; 0 = neuer Höchststand). Ohne Einzahlungen auf dem Depotwert, mit Einzahlungen
  auf `twr_index` (zeitgewichtet), damit Einzahlungen keinen Drawdown verdecken; das gilt ebenso für
  `max_drawdown`, `average_drawdown`, `ulcer_index`, `longest_drawdown` und `avg_recovery_time`. Fällt der
  Index durch eine Tagesrendite von -100 % oder weniger auf 0 oder darunter (Kaufkosten einer großen
  Einzahlung auf ein fast leeres Depot), werden die Drawdowns auf 1 begrenzt (mit Warnung). Ebenso werden
  Drawdowns allgemein auf [0, 1] begrenzt, wenn der Depotwert negativ wird (Steuerschuld; mit Warnung).
- `statistics`: Benannte Liste mit Risiko- und Renditekennzahlen. Grundlage sind die Tagesrenditen der echten
  Handelstage (ohne LOCF-Tage); bei Zuflüssen (DCA) die um Zuflüsse bereinigten Renditen (`mean`, `sd`,
  `sharpe`, `sortino`, `omega`, `gain_to_pain` usw.). Annualisiert wird mit der tatsächlichen Zahl der
  Beobachtungen je Jahr. Mit Einzahlungen verwenden `calmar`, `serenity` und `martin_ratio` statt `cagr` die
  zeitgewichtete Jahresrendite `ttwror`, damit Zähler und (zeitgewichteter) Drawdown-Nenner zusammenpassen.
  Renditen, Drawdowns und Ulcer Index als Anteil:

- `mean`: Mittlere tägliche Rendite (Handelstage). - `sd`: Tägliche Portfoliovolatilität (Handelstage). -
  `cv`: Variationskoeffizient `|sd / mean|`. - `risk_free`: Effektiv genutzte mittlere Risk-Free-Rate
  (annualisiert, in Prozent). - `skewness`: Schiefe der Tagesrenditen. - `kurtosis`: Überschuss-Kurtosis der
  Tagesrenditen. - `lpm`, `hpm`: Unteres bzw. oberes partielles Moment 1. Ordnung der Tagesrenditen (Schwelle
  0). - `sharpe`: Annualisierte Sharpe Ratio auf Überschussrenditen; `NA` ohne Schwankung (seit 1.6.5 auch
  bei reinem Rundungsrauschen, sd höchstens 16 √N ε (1 + max|x|); ebenso `cv`, `skewness`, `kurtosis`).
  - `sortino`: Annualisierte Sortino Ratio
  auf Überschussrenditen e_i: bar e · P / (D √(P)) mit P Beobachtungen je Jahr und Downside-Abweichung über
  alle Beobachtungen D = √(mean(min(e_i, 0)^2)) (Sortino/Price, wie `result_analysis`); `NA` ohne negative
  Überschussrendite. - `calmar`: Calmar Ratio (CAGR / Max Drawdown; mit Einzahlungen TTWROR / Max Drawdown). -
  `omega`: Omega Ratio (Schwelle 0). - `gain_to_pain`: Summe der Renditen / Summe der Verluste (Betrag). -
  `serenity`: Serenity Ratio nach KeyQuant (AlternativeSoft): (CAGR - risikoloser Zins) / (Ulcer Index · Pitfall), mit Einzahlungen TTWROR statt CAGR; Pitfall = CDaR / Volatilität. Eigene Festlegungen von SimLev (die Quelle nennt sie nicht): CDaR zum Niveau 95 % = Mittel der Tages-Drawdowns ab ihrem 95-%-Quantil, Volatilität jährlich wie bei `sharpe` (Standardabweichung der Überschussrenditen · Wurzel der Beobachtungen je Jahr), Rendite und Zins jährlich wie bei `martin_ratio`. NA ohne Drawdown oder ohne Schwankung. Seit 1.6.5 (bis 1.6.4 CAGR / (Ulcer Index · Max Drawdown)). - `martin_ratio`: Ulcer
  Performance Index nach Martin: (CAGR - risikoloser Zins) / Ulcer Index, mit Einzahlungen (TTWROR -
  risikoloser Zins) / Ulcer Index; risikoloser Zins = mittlere jährliche Rate wie `risk_free` (als Anteil;
  seit 1.6.5). - `max_drawdown`: Maximaler Drawdown (positiver Anteil).
  - `average_drawdown`: Mittlere Tiefe an Tagen unter dem Höchststand (Mittel der Tageswerte von
  `drawdowns` über alle Tage mit Drawdown größer 0; kein Mittel je Phase). - `ulcer_index`: Ulcer Index
  (Wurzel des mittleren quadrierten Drawdowns). - `longest_drawdown`: Längste Phase unter dem Höchststand in
  Kalendertagen. - `avg_recovery_time`: Mittlere Dauer abgeschlossener Phasen unter dem
  Höchststand: Zahl der Kalendertage unter dem Hoch je Phase, vom Tag nach dem Hoch bis vor das neue Hoch
  (ganze Phase, nicht erst ab dem Tief); eine am Ende offene Phase zählt nicht mit (`NA`, wenn keine
  abgeschlossene Erholung).
- `report`: Benannte Liste je Asset mit täglichen Vektoren: `worth` (Kurswert in EUR), `money` (Cash in EUR),
  `flows` (DCA-Zufluss des Tages in EUR), `total` (`worth + money`), `share` (Ist-Gewicht als Anteil).
- `tax_report`: Steuerzusammenfassung (Beträge in EUR): `total_taxes_paid` (gezahlte Steuern abzüglich
  Erstattungen; ein Fließkommarest unter 1e-9 EUR nach einer Erstattung im Jahresabschluss wird 0),
  `loss_carryforward_capital` (§ 20 EStG-Verlustvortrag), `loss_carryforward_private` (§ 23
  EStG-Verlustvortrag), `sparer_pauschbetrag_annual` (jährlicher Pauschbetrag), `sparer_pauschbetrag_used`
  (insgesamt genutzt), `sparer_pauschbetrag_tax_saved` (genutzter Pauschbetrag mal effektivem Steuersatz),
  `open_tax_debt` (am Ende offene, nicht gedeckte Steuerschuld: Summe der negativen Geldbestände am letzten
  Tag, wenn eine Steuerzahlung nicht gedeckt werden konnte; sonst 0). Nur mit `tax = tax_profile()`:
  `next_year`, der Steuerzustand des Jahres nach dem letzten Datentag (für eine Fortsetzung, z. B. in
  `withdrawal_simulation`): genau das, was die Engine diesem Jahr schon zugerechnet hat; endet die Simulation
  am 31.12., ist das die dort festgesetzte Vorabpauschale (Zufluss im Folgejahr, verrechnet mit Verlusttopf
  und Sparer-Pauschbetrag dieses Jahres; ein Zwangsverkauf für ihre Steuer am letzten Tag gehört zum Vorjahr),
  sonst nichts (Verbrauch 0). Liste mit `year`, `sparer_pauschbetrag_used` und `sparer_pauschbetrag_remaining`
  (EUR; mit `sparer_pauschbetrag = 0` 0), `loss_carryforward_capital` (§ 20-Verlusttopf danach),
  `loss_carryforward_private` (§ 23-Verlustvortrag), `capital_income_taxed` (im Jahr mit Abgeltungsteuer
  belastete Bemessungsgrundlage), `loss_capital_added`, `loss_capital_used`, `loss_capital_start` (im Jahr
  entstandene bzw. genutzte § 20-Verluste, Topf zu Jahresbeginn; Grundlage der Jahresend-Erstattung),
  `private_sale_net` (§ 23-Jahressaldo, hier 0); mit `taxable_income` zusätzlich `church_tax_settlement`
  (Kirchensteuer-Bescheid des letzten Jahres, am letzten Tag gezahlt (> 0) bzw. erstattet (< 0); Sonderausgabe
  dieses Jahres) und `tariff_assessed` (logisch: das Jahr wurde wegen einer nachlaufenden Vorabpauschale
  bereits veranlagt). Nur mit `taxable_income`: `tariff_years`, ein `data.frame` mit einer Zeile je
  abgeschlossenem Kalenderjahr (EUR): `year`, `taxable_income` (vorgegebenes zvE z_t),
  `church_tax_paid_deductible` (im Jahr gezahlte, abziehbare Kirchensteuer aus der Simulation: Nachzahlung aus
  dem Kirchensteuer-Bescheid des Vorjahres und, wenn die Günstigerprüfung günstiger ist, die im Jahr auf K
  einbehaltene Kirchensteuer), `church_tax_refunded` (im Jahr erstattete Kirchensteuer aus dem Bescheid des
  Vorjahres), `church_tax_net_deduction` (Saldo; negativ = Hinzurechnung), `taxable_income_net` (z_t minus
  Saldo, Basis der Veranlagung), `deduction_effect` (Änderung der tariflichen Belastung F des übrigen
  Einkommens durch den Saldo: negativ = Ersparnis), `gain_p23` (steuerpflichtiger § 23-Gewinn G23 nach
  Freigrenze und Verlustvortrag), `income_tax_p23`, `soli_p23`, `church_tax_p23`, `tax_p23` (§ 23-Anteil:
  ESt-, Soli-, KiSt-Zuwachs und Summe), `capital_income` (K), `abgeltung_burden` (per Saldo auf K erhobene
  Abgeltungsteuer mit Soli/KiSt), `church_tax_withheld_k` (darin enthaltene Kirchensteuer),
  `tariff_income_tax_k`, `tariff_soli_k`, `tariff_church_tax_k`, `tariff_burden` (Tarifbelastung von K bei
  Günstigerprüfung; `NA` ohne `guenstigerpruefung`), `burden_without_gp`, `burden_with_gp` (Gesamtbelastung
  durch die Simulation ohne bzw. mit Günstigerprüfung, siehe Abschnitt „Einkommensteuertarif“; `NA`, wenn
  keine Prüfung), `guenstiger` (logisch: Tarif für K günstiger), `settlement` (Abrechnung des Jahres am
  Abrechnungstag: positiv Nachzahlung, negativ Erstattung), `refund` (Erstattung = max(0, -`settlement`)),
  `church_tax_settlement_next_year` (Saldo des Kirchensteuer-Bescheids: positiv Zahlung, negativ Erstattung im
  Folgejahr). Die Spalten `church_tax_deduction` und `church_tax_deductible_next_year` der vorigen Fassung
  sind durch `church_tax_net_deduction` bzw. `church_tax_settlement_next_year` ersetzt; `refund` enthält jetzt
  die saldierte Erstattung des Jahres (Günstigerprüfung, § 23-Nachzahlung und Sonderausgaben-Wirkung
  zusammen).
- `undefined_metrics`: `data.frame(metric, reason, detail)` mit einer Zeile je Kennzahl, die `NA` ist (`cagr`,
  `ttwror`, Felder von `statistics` sowie `buys` und `sells`, je eine Zeile für den ganzen Vektor); 0 Zeilen
  mit denselben Spalten, wenn alles definiert ist. Abgrenzung: Die übrigen Ergebniselemente werden nicht `NA`:
  `worth`, `invested`, `report` (`share` = 0, wenn der Depotwert nicht positiv ist), `twr_index` (nicht
  endliche Tagesfaktoren zählen als 1) und `drawdowns` (0 ohne positiven Höchststand) sind immer endlich. In
  `tax_report["tariff_years"]` sind die Spalten `tariff_*` ohne `guenstigerpruefung` bewusst `NA` (nicht
  gerechnet); sie stehen nicht in `undefined_metrics`. `detail` ist ein deutscher Klartext mit Beträgen, z. B.
  „Endwert -800.00 EUR negativ: offene Steuerschuld 800.00 EUR“. `reason`:

- `negative_end_value`: Endwert negativ (nicht gedeckte Steuerschuld): `cagr`, `ttwror`. - `no_irr_solution`:
  mit Einzahlungen kein interner Zinsfuß (z. B. Einzahlung am letzten Tag größer als der Endwert): `cagr`. -
  `too_short`: Einzeltag (Laufzeit 0 Jahre: `cagr`, `ttwror`, `buys`, `sells`, `avg_recovery_time` und alle
  Renditekennzahlen) bzw. zu wenige Tagesrenditen (Schiefe ab 3, Kurtosis ab 4, Sharpe ab 2). -
  `zero_start_value`: Startbetrag (`start_value` plus Rate am Starttag) nicht positiv (`cagr`; wegen `start_value > 0` praktisch nicht
  erreichbar). - `nonpositive_twr_index`: zeitgewichteter Wertindex fällt auf 0 oder darunter (Tagesrendite
  unter -100 %): `ttwror`. - `zero_volatility`: Standardabweichung der Tagesrenditen 0 (seit 1.6.5 auch reines Rundungsrauschen): `skewness`,
  `kurtosis`, `sharpe`, `serenity` (seit 1.6.5). - `zero_mean_return`: mittlere Tagesrendite 0: `cv`. - `no_negative_returns`: keine
  negativen (Überschuss-)Renditen: `sortino`, `omega`, `gain_to_pain`. - `no_drawdown`: kein Drawdown:
  `calmar`, `serenity`, `martin_ratio`. Ist die Jahresrendite (`cagr`, mit Einzahlungen `ttwror`) nicht
  definiert, erben diese drei deren Ursache. - `no_recovery`: keine abgeschlossene Erholung:
  `avg_recovery_time`. - `not_finite`: Auffangcode für sonstige nicht endliche Werte.

`print()` und `summary()` zeigen eine nicht definierte `cagr` bzw. `ttwror` (und in `print()` Schiefe und
Kurtosis) als „nicht definiert (<detail>)“ statt `NA`; Kennzahlen, die schon bisher als „–“ erscheinen,
bleiben so.
- `open_lots`: Nur mit `tax = tax_profile()` gefüllt (sonst `nothing`): benannte Liste je Asset mit `lots`
  (`data.frame` der am letzten Tag gehaltenen Lots in FIFO-Reihenfolge: `date` Kaufdatum, `units` verbleibende
  Stück, `price` Anschaffungskurs je Stück wie in der FIFO-Gewinnrechnung, d. h. Briefkurs einschließlich
  anteiliger Ordergebühr, nach Splits umgerechnet, `vp` bereits versteuerte, bei Verkauf nach § 19 InvStG
  anzurechnende Vorabpauschale dieser Stück in EUR), `regime` (`"investment_fund"`, `"capital_gains"` oder
  `"private_sale"`), `partial_exemption` (Teilfreistellung in Prozent), `cash` (Geldbestand des Assets am Ende
  in EUR), `spread` (voller Bid-Ask-Spread in Prozent wie in `asset_config`) und `order_fee` (das Argument
  `order_fee` wie übergeben, `nothing` = keine Ordergebühr), damit Verkaufskosten in späteren Rechnungen
  übernommen werden können. Ein Verkauf zum Verkaufskurs P (Kurs mal 1 - halber Spread, abzüglich Ordergebühr
  je Stück) verbraucht die Lots in Zeilenreihenfolge; aus Lot i werden s_i ≤ units_i Stück verkauft. Die
  Engine rechnet: Gewinn G = Σ_i s_i (P - price_i); Fonds (`investment_fund`): steuerpflichtig (G - Σ_i vp_i
  s_i / units_i) (1 - asset\\_bonus / 100), danach Verlusttopf, Sparer-Pauschbetrag und Abgeltungsteuer (§ 20
  EStG); `capital_gains`: steuerpflichtig G (ohne Teilfreistellung und Vorabpauschale), weiter wie bei Fonds;
  `private_sale` (§ 23 EStG): je Lot s_i (P - price_i), in den Jahressaldo (Freigrenze, Verlustvortrag) nur,
  wenn der Verkaufstag nicht nach demselben Kalendertag des Folgejahres liegt (Kauf am 29.02.: 28.02.), sonst
  steuerfrei (Gewinne und Verluste).
- `buys`: Benannter Vektor. Mittlere Anzahl Käufe je Jahr und Asset (Einzeltag, Laufzeit 0 Jahre: `NA`, siehe
  `undefined_metrics`).
- `sells`: Benannter Vektor. Mittlere Anzahl Verkäufe je Jahr und Asset (Einzeltag: `NA`).
- `fees_paid`: Nur wenn `order_fee` oder `dca_fee` eine Gebühr ungleich 0 festlegt oder (seit 1.6.5) `custody_fee`
  gesetzt ist: Summe der gezahlten Order- und Depotgebühren in EUR.
- `harvest_days`: Nur mit `tax_profile(harvest = harvest_rule())`: Date-Vektor der Termine der
  Gewinnrealisierung.
- `wrappers`: Nur mit `details = true` und Fonds-Wrapper-Assets (`asset_config(wrapper = )`): benannte Liste
  je Wrapper-Asset mit dem `SimLevWrapperNav` aus `wrapper_nav` (Anteilswert, Brutto, Gebühren,
  High-Water-Mark, inneres Ergebnis als Attribut `inner`). Ohne `details` gibt es das Feld nicht.

# Terminverschiebung an aufgefüllten Tagen
Geplante Ereignisse (DCA, periodisches Rebalancing, Splits, Liquidation, Asset-Starts), die auf einen per LOCF
aufgefüllten Tag (Wochenende/Feiertag) fallen, werden automatisch auf den **nächsten echten Handelstag**
verschoben. Würde die Verschiebung den Monat verlassen (Monatsende), wird das Ereignis stattdessen auf den
**vorherigen** echten Handelstag **vorgezogen**. Die **Festsetzung** der Vorabpauschale bleibt kalendarisch am
31.12. (maßgeblich ist der letzte Rücknahmepreis des Jahres, per LOCF): je am 31.12. gehaltenem Lot VP =
Bestand x max(0, min(P_Anfang x 0,7 x Basiszins, P_Ende - P_Anfang)) x f mit P_Anfang = erster im Kalenderjahr
festgesetzter Kurs (Kurs des ersten nicht aufgefüllten Tages des Jahres bzw. der Simulation; § 18 Abs. 1 Satz
3 InvStG: ein aufgefüllter 1.1. trägt nur den Vorjahresschluss und zählt nicht), P_Ende = letzter Kurs des
Jahres und f = 1 bei Erwerb vor dem Jahr, sonst (13 - Erwerbsmonat)/12 (§ 18 Abs. 1-2 InvStG; Ausschüttungen
gibt es im Modell nicht). Die Lot-Werte mindern später den Veräußerungsgewinn (§ 19 InvStG). **Zufluss und
Steuer** folgen gemäß § 18 Abs. 3 InvStG am ersten Handelstag des Folgejahres, nach dem Jahresabschluss und
vor allen Trades dieses Tages, zu dessen Kursen (Cash-Abzug bzw. Zwangsverkauf): Teilfreistellung,
Verlusttopf, Sparer-Pauschbetrag und Günstigerprüfung des **Zuflussjahres**; die Vorabpauschale ist
Kapitalertrag dieses Jahres. Hat das Folgejahr in den Daten keinen Handelstag (alle Tage aufgefüllt), wird am
1.1. des Folgejahres mit dessen Töpfen abgerechnet. Zwangsverkäufe schätzen die Steuer wie der Verkauf selbst
(§ 19-Anrechnung der Lot-Vorabpauschale, Teilfreistellung, Verlusttopf, freier Sparer-Pauschbetrag, effektiver
Satz); ebenso Umschichtungen (Rebalancing, Asset-Aktivierung), so dass kein Rückkauf desselben Assets am
selben Tag nötig ist. Am selben Tag wird danach die § 23-Steuer des Vorjahres gezahlt. Enthält die Simulation
keinen weiteren Tag, wird so gerechnet, als begänne das Folgejahr (Jahresabschluss, Pauschbetrag voll), und
die Steuer am letzten Simulationstag belastet; ein Zwangsverkauf dafür findet an diesem Tag statt und gehört
mit seinem Gewinn (Sparer-Pauschbetrag, Verlusttopf) zum Jahr des letzten Datentags, die Vorabpauschale selbst
zum Folgejahr (eine Differenz zur endgültigen Steuer, z. B. wenn der Verkaufsgewinn den Verlustvortrag
mindert, wird ausgeglichen). Fließen mehrere Vorabpauschalen am selben Tag zu, werden sie gemeinsam mit
Verlusttopf und Sparer-Pauschbetrag verrechnet; Steuer und Pauschbetrag werden anteilig nach der
Vorabpauschale nach Teilfreistellung auf die Assets verteilt (unabhängig von ihrer Reihenfolge in `strategy`).
Eine § 20-Erstattung aus diesem letzten Jahresabschluss (Verlust nach versteuerten Gewinnen im selben Jahr)
wird dem Cash gutgeschrieben und ist im Endwert enthalten, auch ohne offene Vorabpauschale oder § 23-Steuer.
Die Vorabpauschale wird wie in der Bankpraxis mit dem allgemeinen § 20-Verlusttopf verrechnet (vor dem
Sparer-Pauschbetrag); die T-2-Jahresenderstattung erfasst damit auch VP-Steuer bei später im Zuflussjahr
realisierten Verlusten.

# Einkommensteuertarif (taxable_income)
Mit `tax_profile(income = income_tariff(taxable_income))` (zvE z_t des Jahres t ohne die Erträge der
Simulation) rechnet die Engine mit dem Tarif der Datei `tax_tariff` (`tax_tariff`). Rechtsgrundlagen (Fassung
ab VZ 2026, mitgelieferte Datei):

- § 32a Abs. 1 EStG: zvE auf volle Euro abrunden; bis 12 348 EUR: 0; 12 349 bis 17 799: (914,51 y + 1400) y;
  17 800 bis 69 878: (173,10 z + 2397) z + 1034,87; 69 879 bis 277 825: 0,42 x - 11 135,63; ab 277 826: 0,45 x
  - 19 470,38 mit y = (x - 12 348) / 10 000, z = (x - 17 799) / 10 000; Steuerbetrag auf volle Euro abrunden
  (T(x)). Nur Einzelveranlagung (Grundtarif), kein Splitting.
- §§ 3 Abs. 3, 4 SolZG: Soli 5,5 % der Einkommensteuer, nur wenn diese 20 350 EUR übersteigt (Freigrenze,
  Einzelveranlagung), höchstens 11,9 % des Mehrbetrags (Milderungszone); Bruchteile eines Cents bleiben außer
  Ansatz (S(E)). Auf die Abgeltungsteuer weiterhin 5,5 % (in `tax_profile(rate)`).
- Veranlagung je Jahr: tarifliche Belastung F(x) = T(x) + S(T(x)) + k T(x) (k = `church_tax` / 100,
  Kirchensteuer nicht gerundet). Die Simulation trägt den Unterschied zur Belastung des vorgegebenen zvE ohne
  Simulation, F(...) - F(z_t); damit gehört auch die Wirkung ihrer Kirchensteuer-Sonderausgaben auf das übrige
  Einkommen zur Simulation.
- § 23 EStG: steuerpflichtiger Gewinn G23 (nach Freigrenze und Verlustvortrag) erhöht das zvE: ohne
  Günstigerprüfung X_0 = F(z_t - N_t + G23) - F(z_t) + A_t mit A_t = Abgeltungsbelastung auf K (siehe unten)
  und N_t = Saldo der im Jahr gezahlten/erstatteten Kirchensteuer aus dem Vorjahresbescheid.
- § 32d Abs. 6 Satz 1 EStG (`tax_profile(guenstigerpruefung = true)`): unterjährig wird die Abgeltungsteuer
  wie bei einer Bank einbehalten (auch die Steuerschätzung beim Umschichten rechnet mit `tax_profile(rate)`).
  Im Jahresabschluss ist K die Bemessungsgrundlage, auf die im Jahr per Saldo Abgeltungsteuer erhoben wurde
  (Kapitaleinkünfte nach § 20 nach Teilfreistellung, Vorabpauschale des Zuflussjahres, Verlustverrechnung und
  Sparer-Pauschbetrag), A_t = K mal `tax_profile(rate)` die darauf einbehaltene Abgeltungsteuer mit Soli und
  Kirchensteuer, darin die Kirchensteuer C_t = K x 0,25 / (1 + 0,25 k) x k. Verglichen wird die
  Gesamtbelastung: mit Günstigerprüfung X_1 = F(z_t - N_t - C_t + G23 + K) - F(z_t) (die einbehaltene
  Kirchensteuer C_t ist dann im Jahr der Zahlung Sonderausgabe), ohne X_0 wie oben. Günstiger, wenn X_1 < X_0.
  Abrechnung am Abrechnungstag des Folgejahres (wie die übrigen Jahresabschluss-Buchungen; ohne weiteren Tag
  am letzten Simulationstag): `settlement` = X - A_t mit X = X_1 bzw. X_0; positiv als Nachzahlung aus dem
  Depot (wie die § 23-Steuer), negativ als Erstattung in den Geldbestand; in `total_taxes_paid` saldiert. K ≤
  0: keine Prüfung (Verluste aus Kapitalvermögen sind nicht mit anderen Einkünften verrechenbar).
- Kirchensteuer als Sonderausgabe (§ 10 Abs. 1 Nr. 4, § 11 EStG: Jahr der Zahlung): Der Kirchensteuer-Bescheid
  eines Jahres (Kirchensteuer auf den ESt-Unterschied abzüglich der angerechneten C_t, wenn die
  Günstigerprüfung günstiger ist) wird am Abrechnungstag im Folgejahr gezahlt (Sonderausgabe des Folgejahres)
  bzw. erstattet. Erstattungen werden mit den im Erstattungsjahr gezahlten Kirchensteuern aus der Simulation
  verrechnet (einschließlich C dieses Jahres bei Günstigerprüfung); ein Überhang wird dem Einkommen
  hinzugerechnet (§ 10 Abs. 4b Satz 2 und 3 EStG): N_t = gezahlt minus erstattet. Die Kirchensteuer als
  Zuschlag zur Kapitalertragsteuer ist nach § 10 Abs. 1 Nr. 4, 2. Halbsatz nicht abziehbar; dass der Abzug
  erhalten bleibt, wenn die Kapitalerträge per Günstigerprüfung tariflich besteuert werden, beruht auf der
  Darstellung der Rechtslage in der Fachliteratur (Haufe), nicht auf einem Urteil. Die Kirchensteuer auf die §
  23-ESt eines Jahres wird erst mit ihrer Zahlung im Folgejahr abgezogen; im selben Jahr wirkt nur die
  Kirchensteuer aus dem Vorjahresbescheid und (bei Günstigerprüfung) C_t.

Vereinfachungen: Die Datei gilt für alle Simulationsjahre (aktuelle Rechtslage auf alle Jahre projiziert, wie
im übrigen Paket). Die Kirchensteuer wird nicht gerundet (Landesrecht unterschiedlich); Kinderfreibeträge für
ihre Bemessungsgrundlage (§ 51a EStG) bildet das Modell nicht ab. Je Jahr gibt es einen
Kirchensteuer-Bescheid; Nachzahlung und Erstattung daraus werden saldiert. Vorauszahlungen und ein
Verlustrücktrag (§ 10d EStG) kommen im Modell nicht vor. Das Jahr nach dem letzten Simulationsjahr wird nicht
veranlagt: Zahlungen und Erstattungen aus dem letzten Bescheid (am letzten Simulationstag) wirken sich nicht
mehr als Sonderausgabe aus. Ausnahme: Fließt nach dem letzten Jahresabschluss noch eine Vorabpauschale zu
(Simulation endet am 31.12.), wird dieses Folgejahr mit Günstigerprüfung veranlagt, wenn `taxable_income`
dafür einen Wert hat (eine Zahl für alle Jahre oder das Jahr angegeben). Ein Grenzsteuersatz (`income_rate()`)
schließt diesen Weg aus. Ohne `taxable_income` bleibt alles unverändert. Die Jahreswerte stehen in
`tax_report["tariff_years"]`; `details = true` gibt die Tarifrechnung je Jahr aus.

# print und summary
`summary()` liefert unter anderem `total_return_twr` (zeitgewichtete Gesamtrendite: mit Einzahlungen letzter
Wert von `twr_index` minus 1, sonst Endwert / (`start_value` plus Rate am Starttag) - 1; seit 1.6.5 zählen die
Kaufkosten am Starttag mit), `return_on_invested` = (Endwert -
Eingezahlt) / Eingezahlt mit Eingezahlt = letzter Wert von `invested` (brutto) und `total_return` als
gleichwertigen Alias für `total_return_twr` (ältere Skripte). Mit Einzahlungen zeigt die Ausgabe beide Werte
(„Gesamtrendite (zeitgewichtet)“ und „Gewinn je eingezahltem EUR“ mit Endwert und Eingezahlt); ohne
Einzahlungen ist die Ausgabe unverändert. Nicht definierte Kennzahlen erscheinen als „nicht definiert
(Ursache)“ (siehe `undefined_metrics`); eine offene Steuerschuld zeigt `print()` im Steuerteil.

# Signalbewusstes Rebalancing (Cash-Reserve-Modell)
Die Rebalancing-Prozedur prüft die Signallogik eigenständig; der reguläre Signal-Trade-Block läuft an
Rebalancing-Tagen nicht (keine Doppelorders). Signal-aktive und signal-inaktive Assets werden nach ihrem
**Zielgewicht gleichbehandelt**: Ein signalbedingt nicht investiertes (aber aktiviertes) Signal-Asset hält
sein Zielgewicht als **eigene Cash-Position** (jedes Asset besitzt ein eigenes Cash-Konto). Da Ist-Gewichte
total-basiert sind (Kurswert + Cash), zählt die Reserve als Positionsgewicht; das Rebalancing gleicht sie über
reine **Cash-Transfers** mit dem Pool aus — der Pool wird also genau um den Betrag der inaktiven Assets
reduziert, bevor der Rest investiert wird. Für Signal-Assets gilt am Rebalancing-Tag:

- Position vorhanden + Verkaufssignal: vollständiger Signal-Exit; der Erlös wird zur Cash-Reserve des Assets.
- Keine Position + Kaufsignal: Signal-Entry aus der eigenen Cash-Reserve; danach normale Teilnahme am
  Gewichts-Rebalancing.
- Keine Position + kein Kaufsignal: die Cash-Reserve wird auf das Zielgewicht getrimmt (Auffüllen aus dem Pool
  bzw. Abschöpfen in den Pool), es findet aber **kein Aktienkauf** statt.
- Andernfalls nimmt das Asset normal am Gewichts-Rebalancing teil.

Verbleibendes Cash der übrigen Assets (z. B. DCA-Zuflüsse am selben Tag) wird noch am Rebalancing-Tag
reinvestiert; die Cash-Reserven signalbedingt wartender Signal-Assets bleiben davon unberührt.

Außerhalb von Rebalancing-Tagen gilt (unabhängig von `rebalance`): Ein Signal-Asset mit offener Position legt
neues Geld (Sparraten, Restcash, Umverteilungen, Erstattungen) sofort an wie Buy-and-Hold, außer am Tag eines
Verkaufssignals; das Signal steuert nur Ein- und Ausstieg. Ohne Bestand wartet das Geld als Cash auf das
Kaufsignal.

# Fonds-Wrapper
Ein Asset mit `asset_config(wrapper = wrapper_config(...))` ist ein Zertifikat bzw. Fonds über eine innere
Strategie. Vor der Engine rechnet `simulation()` je Wrapper-Asset den Anteilswert mit `wrapper_nav` aus den
inneren Spalten von `data` und hängt ihn als Kursspalte mit dem Asset-Namen an (vor dem Beginn und an Tagen
ohne inneren Kurs `NA`). Danach ist das Asset ein gewöhnliches Asset ohne `wrapper`: Spread, Order- und
Sparplangebühren, Steuern (nach `asset_class` bzw. `tax_regime`: Zertifikat = Kapitalforderung, `tax_regime =
"investment_fund"` mit Teilfreistellung und Vorabpauschale), Kirchensteuer, Pauschbetrag, Verlusttöpfe,
`harvest` und `open_lots` gelten wie für jedes Einzelpapier.

- Der Asset-Name ist keine Kursspalte; eine Spalte gleichen Namens in `data` ist ein Fehler. Gebraucht werden
  die Kursspalten (und Signal- bzw. Ereignisspalten) der inneren Strategie.
- `splits` gelten für die inneren Spalten; der Anteilswert selbst splittet nicht.
- Beginnen die inneren Kurse nach dem ersten Tag von `data`, beginnt der Anteilswert später; das Asset wird
  dann wie jedes später startende Asset behandelt (Hinweis „hat erst ab ... Kurse“). Ist der Wrapper das
  einzige Asset, ist das der Fehler „In der ersten Zeile von 'data' fehlen alle Kurse“.
- Meldungen der inneren Rechnung erscheinen als „Hinweis: Wrapper '<Name>' (innere Rechnung): ...“, Warnungen
  und Fehler als „simulation: Wrapper '<Name>' (innere Rechnung): ...“.
- Wrapper-Assets handeln nur mit `trading = "bnh"` (Signale gehen in der inneren Strategie).
- Aufrufer mit vielen Läufen (`bootstrap_study`, `param_search`, `sensitivity_grid`, `planning_lumpsum_vs_dca`
  u. a.) rechnen den Anteilswert je Lauf neu; Bootstrap-Pfade ziehen die inneren Spalten.

Mit `details = true` enthält das Ergebnis `wrappers` (siehe oben).

# Ereignisbasiertes Rebalancing
Zusammenspiel der Argumente von `rebalance_plan`:

- `event_col`: Character oder `nothing`. Name einer logischen Spalte in `data`, die ereignisbasiertes
  Rebalancing auslöst (`true` = Rebalancing-Tag). Erzeugt mit `rebalance_trigger`.
- `event_mode`: `"additional"` (zusätzlich zu periodischem Rebalancing) oder `"replace"` (ersetzt periodisches
  Rebalancing).
- `event_weight`: Benannter Vektor/Liste oder `nothing`: je Asset der Name einer Spalte mit dem Zielgewicht an
  Event-Tagen (siehe `rebalance_plan`).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 756
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["MSCI"] = 100 .* cumprod(1 .+ 4e-4 .+ 0.012 .* randn(rng, n))
d["BOND"] = 50 .* cumprod(1 .+ 1e-4 .+ 0.004 .* randn(rng, n))
st = create_strategy(MSCI = asset_config("etf"; share = 0.7, spread = 0.1, partial_exemption = 30),
                     BOND = asset_config("etf"; share = 0.3, spread = 0.1))
res = simulation(d, st; start_value = 10000, rebalance = rebalance_plan(; unit = "year"),
                 tax = tax_profile(26.375), liquidate = true, risk_free = 2)
println(res["cagr"], " ", res["tax_report"]["total_taxes_paid"])
```
"""
function simulation(data, strategy; start_value = 10000, costs = sim_costs(), dca = nothing, rebalance = nothing,
                    splits = nothing, tax = nothing, risk_free = 0, fractions = true,
                    liquidate = false, details = false, io::IO = stdout)
    @nospecialize
    # seit 1.6.4 Vektoren der Länge 1 wie Einzelwerte (Entscheidung 4; R: c(TRUE) ist TRUE)
    start_value, risk_free, fractions, liquidate, details = chk_scalar.((start_value, risk_free, fractions, liquidate, details))
    flat = _sim_from_blocks(costs, dca, rebalance, splits, tax)
    return _simulation_flat(data, strategy; start_value = start_value, risk_free = risk_free, fractions = fractions,
                            liquidate = liquidate, details = details, io = io, flat...)
end

"""
    _simulation_flat(data, strategy; start_value, details, liquidate, dca_mode, …, io)

Engine mit den flachen Argumenten (bis 0.8.0 öffentlich; R: `.simulation_flat`).
`simulation()` übersetzt die Bausteine mit `_sim_from_blocks` hierher (einziger
Aufrufer: Prüfungen der Bausteine entfallen, Meldungen nennen die Bausteine;
der flache Weg ohne Bausteine mit eigenen Prüfungen ist entfallen). Die Aufrufer mit `sim_args` gehen seit 0.9.0 über
`simulation()` (`_sim_args_set`, `_sim_call` in sim_blocks.jl).
`tax_tariff`: `nothing`, Dateipfad oder `tax_tariff()`.
"""
function _simulation_flat(data, strategy; start_value = 10000, details = false, liquidate = false,
                    dca_mode = false, dca_value = nothing, dca_span = nothing, dca_days = nothing,
                    dca_unit = ("month", "quarter", "year"), dca_anchor = ("start", "end"), dca_start = nothing,
                    dca_skip = false, balance_mode = false, balance_span = nothing, balance_days = nothing,
                    balance_unit = ("month", "quarter", "year"), balance_anchor = ("start", "end"),
                    balance_start = nothing, balance_skip = false, balance_dca = false, balance_thresh = nothing,
                    balance_thresh_type = ("absolute", "relative"), tax_mode = ("none", "person"),
                    tax_rate = 26.375, marginal_tax_rate = nothing, use_guenstigerpruefung = false,
                    private_sale_threshold = 1000, sparer_pauschbetrag = 1000, use_sparer_pauschbetrag = true,
                    include_soli_on_income_tax = false, soli_rate_income_tax = 5.5, base_rate = nothing,
                    base_rate_flex = false, base_rate_data = nothing, fractions = true, risk_free = 0, split_mode = false, split_thresh = nothing, event_col = nothing,
                    event_mode = ("additional", "replace"), event_weight = nothing, church_tax = 0, order_fee = nothing,
                    dca_fee = nothing, custody_fee = nothing, harvest_mode = false, harvest_day = "12-15", harvest_loss_pot = true,
                    taxable_income = nothing, tax_tariff = nothing, io::IO = stdout)
    @nospecialize
    function phases(pio)
        local cfg, fr, st, start_date, stopp_date, fill_src, sim, fl, ew
        # seit 1.6.4 prüft _sim_check_inputs details wie fractions (bis 1.6.3: details == true)
        cfg, fr = _sim_check_inputs(data, strategy, start_value, details, dca_mode, dca_value, dca_days,
                                    balance_mode, balance_days, balance_thresh, balance_thresh_type, tax_mode, tax_rate,
                                    marginal_tax_rate, use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                                    use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax, base_rate,
                                    fractions, risk_free, split_mode, split_thresh, event_col, church_tax,
                                    order_fee, dca_fee, harvest_mode, taxable_income, tax_tariff, pio; liquidate = liquidate)
        cfg.fee_cust = _fee_spec(custody_fee, "simulation", "custody_fee")   # seit 1.6.5 (Entscheidung 150)
        st = split_thresh === nothing ? nothing : _num_vec(split_thresh)
        start_date, stopp_date, fill_src = _sim_prepare_data(fr, cfg.pre_filled, base_rate_flex, base_rate_data)
        sim = _sim_build_state(fr, cfg.strategy, start_date, stopp_date, cfg.sparer_pauschbetrag,
                               cfg.use_sparer_pauschbetrag, cfg.base_rate, base_rate_flex, base_rate_data)
        fl, ew = _sim_build_calendar(fr, sim, cfg.strategy, start_date, stopp_date, cfg.dca_mode, dca_span,
                                     dca_unit, cfg.dca_days, cfg.dca_value, dca_anchor, dca_start, dca_skip, cfg.balance_mode,
                                     balance_span, balance_unit, cfg.balance_days, balance_anchor, balance_start,
                                     balance_skip, cfg.event_col, event_mode, event_weight)
        return (cfg, fr, st, start_date, stopp_date, fill_src, sim, fl, ew)
    end
    # seit 1.6.5 (Paket E, Studienkern sim_prepared.jl): in einer Studie rechnet ein Lauf, den _sim_call_study als
    # Vorlage merken will, die Phasen 1 und 2 zuerst still (_prep_probe); blieben sie ohne Meldung, gelten ihre
    # Ergebnisse (sie hätten nichts ausgegeben), sonst laufen sie wie bisher noch einmal mit allen Meldungen
    got = _prep_cap_take() ? _prep_probe(phases) : nothing
    cfg, fr, split_thresh, start_date, stopp_date, fill_src, sim, fl, ew = got === nothing ? phases(io) : got
    cfg.event_col !== nothing && (event_weight = ew)
    event_weight isa Union{Nothing,Vector{Pair{String,Any}}} || (event_weight = Pair{String,Any}[p for p in _kvpairs(event_weight)])
    R = Run(cfg, fl, details, io, 0.0, 0.0)
    # 3.-5. Termine, Flags, Startgewichte, Tagesschleife und Abschluss des letzten Jahres im C++-Kern
    # (sim_engine.jl)
    E = _sim_engine_input(R, sim, fr, liquidate, event_weight, split_thresh, balance_dca, harvest_loss_pot, stopp_date,
                          harvest_day)
    es = got === nothing ? nothing :
         _prep_capture(data, R, sim, fr, fill_src, E, start_date, stopp_date, details, base_rate_flex, base_rate_data,
                       event_weight)
    h = ccall((:simlev_c_engine_new, LIBSLC), Ptr{Cvoid}, ())
    h == C_NULL && throw(OutOfMemoryError())
    try
        flags_out = zeros(Int32, E.n)
        rc = _engine_ccall(h, C_NULL, E, sim, R.fl, flags_out, nothing)
        _sim_engine_output!(h, rc, R, sim, E, flags_out)
    finally
        ccall((:simlev_c_engine_free, LIBSLC), Cvoid, (Ptr{Cvoid},), h)
    end
    # 6. Auswertung im C++-Kern und Ergebnisobjekt
    ret, statistics, um, buys, sells = _sim_evaluate(R, sim, start_date, stopp_date, fr, es)
    return _sim_result(R, sim, ret, statistics, um, buys, sells)
end

