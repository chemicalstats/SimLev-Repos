# ─────────────────────────────────────────────────────────────────────────────
# simulation(), Phasen 4 und 5 über den gemeinsamen C++-Kern: Tagesengine core/engine_core_impl.h
#
# Der Kern rechnet die Tagesschleife (Batch- und Marktupdate, Aktivierung, Splits, Sparplan, Handel, Rebalancing,
# Freibetrag, Vorabpauschale, Liquidation, Jahreswechsel und Abrechnungen mit Steuer) und den Abschluss des letzten
# Jahres (bis 1.3.0 die Phasen _sim_run_days! und _sim_close_years!). Warnungen, details-Ausgaben und
# Abbrüche meldet der Kern als Codes mit Werten; die Texte setzt _sim_engine_signal wortgleich zu R 1.3.0, in
# derselben Reihenfolge (Ausgabe und Warnungen verzahnt). Gegenstücke: r/R/sim_engine.R,
# python/simlev/_sim_engine.py.
# ─────────────────────────────────────────────────────────────────────────────

# Feldlagen der flachen Felder: teilen Julia und die Kerne keine Strukturen mehr; diese Datei und
# sim_evaluate.jl nehmen aber feste Größen und Schrittweiten an (Eingaben ai, ad, ci, cd, tot0, pint, pdbl, Termine
# _sched_spec in engine.jl; Ausgaben status, Lots, Verkäufe, Steuerbuchungen, Ereignisse, Jahreszeilen,
# Kennzahlen). Sie stehen hier und werden beim Vorkompilieren mit simlev_c_flat_layout (core/simlev_cabi.cpp,
# Werte aus den Aufzählungen der Kerne) verglichen; sonst läse oder schriebe der Kern neben die Felder.
const _CABI_LAYOUT = (AI_N = 8, AD_N = 3, CI_N = 14, CD_N = 12, TT_N = 13, PI_N = 20, PD_N = 6, SI_N = 7, TR_N = 25,
                      ST_N = 20, status = 8, lot = 7, sell = 8, tax = 8, event_int = 9, event_dbl = 2)

"Feldlagen der flachen Felder mit der C-Hülle vergleichen (beim Vorkompilieren); Abweichung: Fehler mit Namen."
function _cabi_layout_check()
    want = collect(Int64, values(_CABI_LAYOUT))
    got = Int64[ccall((:simlev_c_flat_layout, LIBSLC), Int64, (Int64,), k) for k in 0:length(want)]
    got[1:end-1] == want && got[end] == -1 && return nothing
    bad = [string(k, ": Julia ", want[i], ", Hülle ", got[i] < 0 ? "fehlt" : string(got[i]))
           for (i, k) in enumerate(keys(_CABI_LAYOUT)) if got[i] != want[i]]
    got[end] == -1 || push!(bad, "Hülle meldet mehr Werte als Julia kennt ($(length(want)))")
    error("SimLev: Feldlagen der flachen Felder in julia/src/sim_engine.jl (_CABI_LAYOUT) passen nicht zur " *
          "C-Hülle (simlev_c_flat_layout in core/simlev_cabi.cpp); beide Seiten gleich halten und libslc neu " *
          "bauen (Pkg.build):\n  " * join(bad, "\n  "))
end
_cabi_layout_check()

"Länge eines flachen Eingabefelds für den Kern prüfen (Gegenstück zu _CABI_LAYOUT)."
@inline _flat_len(x, n::Int, what) = length(x) == n || _flat_len_fail(what, length(x), n)
@noinline _flat_len_fail(what, got, n) =
    error("SimLev: flaches Feld $what hat $got statt $n Werte (julia/src/sim_engine.jl, _CABI_LAYOUT)")

_engine_fee(f::Nothing) = (0.0, 0.0, 0.0, 0.0, 0.0)
_engine_fee(f::FeeSpec) = (1.0, f.fixed, f.percent, f.min, f.max)

const _ENGINE_REGIME = Dict("investment_fund" => Int32(1), "capital_gains" => Int32(2), "private_sale" => Int32(3))
const _ENGINE_REGIME_NAME = ("investment_fund", "capital_gains", "private_sale")
const _ENGINE_ROWS = ("year", "taxable_income", "church_tax_paid_deductible", "church_tax_refunded",
                      "church_tax_net_deduction", "taxable_income_net", "deduction_effect", "gain_p23", "income_tax_p23",
                      "soli_p23", "church_tax_p23", "tax_p23", "capital_income", "abgeltung_burden",
                      "church_tax_withheld_k", "tariff_income_tax_k", "tariff_soli_k", "tariff_church_tax_k",
                      "tariff_burden", "burden_without_gp", "burden_with_gp", "guenstiger", "settlement", "refund",
                      "church_tax_settlement_next_year")

"Freibetrag ab harvest_day (\"MM-TT\"): erster Monat * 100 + Tag, den der Zeichenvergleich zulässt (wie R)."
function _harvest_md(harvest_day)
    harvest_day isa AbstractString && occursin(r"^[0-9]{2}-[0-9]{2}$", harvest_day) &&
        return parse(Int, harvest_day[1:2]) * 100 + parse(Int, harvest_day[4:5])
    ok = [m * 100 + d for m in 1:12 for d in 1:31 if string(lpad(m, 2, '0'), "-", lpad(d, 2, '0')) >= harvest_day]
    return isempty(ok) ? 9999 : minimum(ok)
end

"Vorbereitung, Phasen 4 und 5 über den C++-Kern: Termine, Flags, Startgewichte, Tagesschleife und Abschluss des letzten Jahres."
function _sim_engine_run!(R::Run, sim::Sim, fr::_Frame, liquidate, event_weight, split_thresh, balance_dca,
                          harvest_loss_pot, stopp_date::Int, harvest_day)
    @nospecialize
    fl, cfg = R.fl, R.cfg
    n = length(fl.flag_date)
    na = length(fl.flag_assets)
    person = cfg.tax_mode == "person"
    day = Float64.(fl.flag_date)
    ew = Vector{Union{Nothing,Vector{Float64}}}(nothing, na)
    if event_weight !== nothing
        for a in 1:na
            j = findfirst(p -> p.first == fl.flag_assets[a], event_weight)
            j === nothing || (ew[a] = Float64.(fr.cols[event_weight[j].second]))
        end
    end
    fl.tax_regimes = String[sim.assets[a].tax_regime for a in 1:na]
    ai = Int32[]; ad = Float64[]
    for a in 1:na   # Startindizes und Start-Assets setzt die Vorbereitung
        mk = sim.market[a]
        append!(ai, (Int32(sim.assets[a].style == "signal"), Int32(0), Int32(0), Int32(0),
                     get(_ENGINE_REGIME, fl.tax_regimes[a], Int32(0)), Int32(fl.flag_assets[a] in cfg.no_split),
                     Int32(mk.signal_buy.logical), Int32(mk.signal_sell.logical)))
        append!(ad, (mk.spread_rate, Float64(cfg.strategy[a].second["share"]), sim.assets[a].bonus))
    end
    harvest_on = _is_true(cfg.harvest_mode) && person
    split_on = _truthy_mode(cfg.split_mode) && split_thresh !== nothing
    lo = split_on ? Float64(split_thresh[1]) : 0.0
    hi = split_on ? Float64(split_thresh[2]) : 0.0
    pint = Int32[liquidate == true, fl.event_replace, split_on, person, harvest_on,
                 harvest_on ? _harvest_md(harvest_day) : 0, fl.dca[1]..., fl.balance[1]...]
    pdbl = Float64[stopp_date, lo, hi, cfg.start_value, fl.dca[2], fl.balance[2]]
    starts = Float64[sim.assets[a].start for a in 1:na]
    filled = any(fl.flag_filled) ? Int32.(fl.flag_filled) : Int32[]
    event = fl.flag_event === nothing ? Int32[] : Int32.(fl.flag_event)
    flags_out = zeros(Int32, n)
    T = sim.totals
    tot0 = Float64[T.total_taxes, T.loss_capital_gains, T.loss_private_sales, T.private_sale_gains_ytd,
                   T.private_sale_losses_ytd, T.sparer_pauschbetrag_annual, T.sparer_pauschbetrag_remaining,
                   T.sparer_pauschbetrag_used_total, T.current_year, T.cgt_base_taxed_ytd, T.cgt_loss_added_ytd,
                   T.cgt_loss_used_ytd, T.cgt_pool_start_ytd]
    env = person ? cfg.tariff_env : nothing
    tariff_par = Float64[]; zve = Float64[]
    if env !== nothing
        tariff_par = Withdrawal._wd_tariff_par(env.tariff, env.church_k, env.use_gp)
        if env.zve_all === nothing && env.zve !== nothing
            for (y, v) in env.zve
                append!(zve, (Float64(parse(Int, y)), v))
            end
        end
    end
    dv = cfg.dca_value
    mtr = cfg.marginal_tax_rate
    ci = Int32[cfg.fractions, cfg.fees_on, _truthy_mode(cfg.balance_mode), _is_true(balance_dca),
               cfg.balance_thresh !== nothing, cfg.balance_thresh_type == "relative", person,
               cfg.use_sparer_pauschbetrag, _truthy_mode(harvest_loss_pot), liquidate == true, mtr !== nothing,
               year_of(stopp_date), env !== nothing && env.zve_all !== nothing, R.details]
    cd = Float64[cfg.balance_thresh === nothing ? 0.0 : cfg.balance_thresh, dv isa Real ? Float64(dv) : 0.0,
                 R.fee_paid, cfg.effective_tax_rate, mtr === nothing ? 0.0 : mtr, cfg.private_sale_threshold,
                 cfg.sparer_pauschbetrag, cfg.soli_factor_income, cfg.church_k,
                 lo, hi,
                 env !== nothing && env.zve_all !== nothing ? env.zve_all : 0.0]
    fees = Float64[_engine_fee(cfg.fee_order)..., _engine_fee(cfg.fee_dca)...]
    L = _CABI_LAYOUT
    _flat_len(ai, L.AI_N * na, "ai"); _flat_len(ad, L.AD_N * na, "ad"); _flat_len(ci, L.CI_N, "ci")
    _flat_len(cd, L.CD_N, "cd"); _flat_len(tot0, L.TT_N, "tot0"); _flat_len(pint, L.PI_N, "pint")
    _flat_len(pdbl, L.PD_N, "pdbl")
    h = ccall((:simlev_c_engine_new, LIBSLC), Ptr{Cvoid}, ())
    h == C_NULL && throw(OutOfMemoryError())
    try
        GC.@preserve sim day ew ai ad ci cd fees tot0 tariff_par zve pint pdbl starts filled event fl flags_out begin
            prices = Ptr{Float64}[pointer(sim.market[a].asset_price) for a in 1:na]
            sb = Ptr{Float64}[pointer(sim.market[a].signal_buy.v) for a in 1:na]
            ss = Ptr{Float64}[pointer(sim.market[a].signal_sell.v) for a in 1:na]
            ewp = event_weight === nothing ? Ptr{Ptr{Float64}}(C_NULL) :
                  Ptr{Float64}[ew[a] === nothing ? Ptr{Float64}(C_NULL) : pointer(ew[a]) for a in 1:na]
            brp = person ? Ptr{Float64}[pointer(sim.market[a].base_rates) for a in 1:na] : Ptr{Ptr{Float64}}(C_NULL)
            reps = Ptr{Float64}[]
            for a in 1:na
                r = sim.report[a]
                append!(reps, (pointer(r.worth), pointer(r.money), pointer(r.flows), pointer(r.total), pointer(r.share)))
            end
            GC.@preserve prices sb ss ewp brp reps begin
                dd, dc, bd, bc = fl.dca[3], fl.dca[4], fl.balance[3], fl.balance[4]
                rc = ccall((:simlev_c_engine_run, LIBSLC), Cint,
                           (Ptr{Cvoid}, Int64, Int64, Ptr{Float64}, Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}},
                            Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}}, Ptr{Int32}, Ptr{Float64},
                            Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Int64, Ptr{Float64},
                            Int64, Ptr{Ptr{Float64}}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32},
                            Int64, Ptr{Float64}, Ptr{Int32}, Int64, Ptr{Float64}, Ptr{Int32}, Ptr{Int32}),
                           h, n, na, day, prices, sb, ss, ewp, brp, ai, ad, ci, cd, fees, tot0, tariff_par,
                           length(tariff_par), zve, length(zve) ÷ 2, reps, pint, pdbl, starts,
                           isempty(filled) ? Ptr{Int32}(C_NULL) : pointer(filled),
                           fl.flag_event === nothing ? Ptr{Int32}(C_NULL) : pointer(event),
                           length(dd), dd, dc, length(bd), bd, bc, flags_out)
            end
        end
        rc == 0 || rc == 6 || CAbi.check(rc)
        fl.flag_harvest = BitVector((flags_out .& Int32(128)) .!= 0)
        status = zeros(8na); tv = zeros(13); nlots = zeros(Int64, na); nsells = zeros(Int64, na)
        ntaxes = zeros(Int64, na); pxc = zeros(Int32, na); cnt = zeros(Int64, 5); scal = zeros(3)
        err = zeros(Int32, 4); err_d0 = Ref{Float64}(0.0)
        ccall((:simlev_c_engine_counts, LIBSLC), Cvoid,
              (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Ptr{Int64}, Ptr{Int64}, Ptr{Int64}, Ptr{Int32}, Ptr{Int64},
               Ptr{Float64}, Ptr{Int32}, Ref{Float64}),
              h, status, tv, nlots, nsells, ntaxes, pxc, cnt, scal, err, err_d0)
        for a in 1:na
            o = 8 * (a - 1)
            s = sim.status[a]
            s.count, s.price, s.worth, s.money = status[o+1], status[o+2], status[o+3], status[o+4]
            s.total, s.target, s.actual, s.differ = status[o+5], status[o+6], status[o+7], status[o+8]
            tr = sim.trades[a]
            L = zeros(7 * nlots[a])
            ccall((:simlev_c_engine_lots, LIBSLC), Cvoid, (Ptr{Cvoid}, Int64, Ptr{Float64}), h, a - 1, L)
            empty!(tr.buys)
            for j in 0:(nlots[a] - 1)
                push!(tr.buys, Lot(Int(L[7j+1]), L[7j+2], L[7j+3], L[7j+4], L[7j+5], L[7j+6]))
            end
            S = zeros(8 * nsells[a])
            ccall((:simlev_c_engine_sells, LIBSLC), Cvoid, (Ptr{Cvoid}, Int64, Ptr{Float64}), h, a - 1, S)
            empty!(tr.sells)
            for j in 0:(nsells[a] - 1)
                rg = Int(S[8j+6])
                push!(tr.sells, SellEntry(Int(S[8j+1]), S[8j+2], S[8j+3], rg == 0 ? NA : S[8j+4], rg == 0 ? NA : S[8j+5],
                                          rg == 0 ? nothing : _ENGINE_REGIME_NAME[rg], rg == 3,
                                          S[8j+8] != 0 ? S[8j+7] : NA))
            end
            X = zeros(8 * ntaxes[a])
            ccall((:simlev_c_engine_taxes, LIBSLC), Cvoid, (Ptr{Cvoid}, Int64, Ptr{Float64}), h, a - 1, X)
            empty!(tr.taxes)
            for j in 0:(ntaxes[a] - 1)
                if Int(X[8j+1]) == 1
                    push!(tr.taxes, TaxEntry(Int(X[8j+2]), Int(X[8j+3]), "Vorabpauschale", X[8j+4], X[8j+5], X[8j+6],
                                             X[8j+7], X[8j+8]))
                else
                    push!(tr.taxes, TaxEntry(Int(X[8j+2]), 0, "Private sale tax", NA, NA, NA, NA, X[8j+8]))
                end
            end
            if pxc[a] != 0
                P = zeros(n)
                ccall((:simlev_c_engine_prices, LIBSLC), Cvoid, (Ptr{Cvoid}, Int64, Ptr{Float64}), h, a - 1, P)
                sim.market[a].asset_price = P
            end
        end
        T.total_taxes, T.loss_capital_gains, T.loss_private_sales = tv[1], tv[2], tv[3]
        T.private_sale_gains_ytd, T.private_sale_losses_ytd = tv[4], tv[5]
        T.sparer_pauschbetrag_annual, T.sparer_pauschbetrag_remaining, T.sparer_pauschbetrag_used_total = tv[6], tv[7], tv[8]
        T.current_year = Int(tv[9])
        T.cgt_base_taxed_ytd, T.cgt_loss_added_ytd, T.cgt_loss_used_ytd, T.cgt_pool_start_ytd = tv[10], tv[11], tv[12], tv[13]
        empty!(T.vp_pending); empty!(T.p23_due)
        if env !== nothing   # Tarifweg: Jahreszeilen (wie _tariff_close), KiSt-Salden, Erstattung
            nr, nk = Int(cnt[3]), Int(cnt[4])
            rows = zeros(25 * nr); ks = zeros(2 * nk)
            ccall((:simlev_c_engine_rows, LIBSLC), Cvoid, (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}), h, rows, ks)
            for i in 0:(nr - 1)
                x = rows[25i+1:25i+25]
                push!(env.rows, RList(Pair{String,Any}[f => (f == "year" ? Int(x[k]) : f == "guenstiger" ? x[k] != 0 : x[k])
                                                       for (k, f) in enumerate(_ENGINE_ROWS)]...))
            end
            for i in 0:(nk - 1)
                env.ks[string(Int(ks[2i+1]))] = ks[2i+2]
            end
            env.refund_due = scal[3]
            empty!(env.due_info)
        end
        nev = Int(cnt[1])
        evi = zeros(Int32, 9 * nev); evd = zeros(2 * nev); evy = zeros(Int32, Int(cnt[2])); evv = zeros(Int(cnt[5]))
        ccall((:simlev_c_engine_events, LIBSLC), Cvoid, (Ptr{Cvoid}, Ptr{Int32}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}),
              h, evi, evd, evy, evv)
        R.fee_paid = scal[1]
        R.tax_unpaid_total = scal[2]
        _sim_engine_signal(R, sim, fl, evi, evd, evy, evv, rc == 6, Int(err[4]), err_d0[])
    finally
        ccall((:simlev_c_engine_free, LIBSLC), Cvoid, (Ptr{Cvoid},), h)
    end
    return nothing
end

const _ENGINE_LABELS = ("Vorabpauschale", "§ 23-Steuer")
# Anlass der Käufe und Verkäufe (enum Reason in engine_core_impl.h)
const _ENGINE_REASONS = ("Handelssignal:", "Rebalancing:", "Rebalancing/Signal-Einstieg:", "Rebalancing/Signal-Ausstieg:",
                         "Liquidation:", "Steuerereignis:", "Split:", "Freibetrag:")

"Bezeichnung einer Steuerzahlung (.pay_tax label): Vorabpauschale, § 23-Steuer oder Veranlagung der Jahre."
_engine_label(aux::Int, ints) = aux < 2 ? _ENGINE_LABELS[aux+1] : "Steuer aus der Veranlagung " * join(string.(ints), "/")

"Warnungen, details-Ausgaben und Abbruch des Kerns mit den Texten von R 1.3.0 auslösen (Reihenfolge des Protokolls)."
function _sim_engine_signal(R::Run, sim::Sim, fl::Flags, evi::Vector{Int32}, evd::Vector{Float64}, evy::Vector{Int32},
                            evv::Vector{Float64}, failed::Bool, err_code::Int, err_d0::Float64)
    for k in 0:(length(evd) ÷ 2 - 1)
        code, day, asset = evi[9k+1], Int(evi[9k+3]), Int(evi[9k+4])
        aux, y_off, ny, v_off, nv = Int(evi[9k+5]), Int(evi[9k+6]), Int(evi[9k+7]), Int(evi[9k+8]), Int(evi[9k+9])
        d0, d1 = evd[2k+1], evd[2k+2]
        nm = asset >= 0 ? fl.flag_assets[asset+1] : ""
        ints = @view evy[y_off+1:y_off+ny]
        if code >= 200
            _sim_engine_detail(R, fl, Int(code), nm, aux, @view(evv[v_off+1:v_off+nv]), ints, fmt_date(fl.flag_date[day]))
        elseif code == 1
            @warn r_sprintf("perform_trade_buy: ungültiger Kurs (%.4f) für %s am %s; der Kauf wird übersprungen.",
                            d0, nm, fmt_date(fl.flag_date[day]))
        elseif code == 2
            @warn r_sprintf("perform_trade_sell: angeforderte Verkaufsmenge %.4f übersteigt den Bestand %.4f von %s; verkauft wird der gesamte Bestand.",
                            d0, d1, nm)
        elseif code == 3
            @warn r_sprintf("simulation: liquidate = TRUE: Position '%s' (Wert %.2f EUR) wurde nicht verkauft, weil die Ordergebühr den Erlös übersteigt.",
                            nm, d0)
        elseif code == 4
            @warn "no non-missing arguments to max; returning -Inf"
        elseif code == 5
            @warn r_sprintf("simulation: %s von %.2f EUR am %s: das Depot reicht nicht aus; %.2f EUR bleiben als negativer Geldbestand (Steuerschuld) bei '%s'.",
                            _engine_label(aux, ints), d0, fmt_date(fl.flag_date[day]), d1, nm)
        elseif code == 6
            @warn r_sprintf("simulation: Paragraf 23 EStG: Gewinne (%.2f EUR) erreichen die Freigrenze (%.2f EUR), ", d0, d1) *
                  "aber 'marginal_tax_rate' ist nicht gesetzt.\n" *
                  "Verwendet wird 42 % (Spitzensteuersatz); marginal_tax_rate in Prozent angeben (z. B. 42)."
        else
            error("simulation: interner Fehler: unbekannter Ereigniscode $code der Tagesengine.")
        end
    end
    if failed
        err_code == 101 && error("perform_asset_split: ratio muss > 0 sein (Split-Verhältnis), nicht $(r_format1(err_d0)).")
        error("missing value where TRUE/FALSE needed")
    end
    return nothing
end

"details-Ausgabe eines Ereignisses (DT_* in engine_core_impl.h), wortgleich zu R 1.3.0."
function _sim_engine_detail(R::Run, fl::Flags, code::Int, name::AbstractString, aux::Int, v, ints, ds::String)
    out(s) = _cat(R, s)
    anames(ix) = join((fl.flag_assets[k+1] for k in ix), ", ")
    if code == 201
        out(r_sprintf("%s\tKauf %.2fx %s zu %.2f EUR je Anteil am %s\n", _ENGINE_REASONS[aux+1], v[1], name, v[2], ds))
    elseif code == 202
        out(r_sprintf("\t\t=> Vorabpauschale-Anrechnung (§ 19 InvStG): %.2f EUR\n", v[1]))
    elseif code == 203
        out(r_sprintf("\t\t=> Sparerpauschbetrag: %.2f EUR (verbleibend: %.2f EUR)\n", v[1], v[2]))
    elseif code == 204
        out(r_sprintf("\t\t=> Steuerfreier Gewinn (Haltedauer > 1 Jahr): %.2f EUR\n", v[1]))
    elseif code == 205
        out(r_sprintf("\t\t=> Nicht verrechenbarer Verlust (Haltedauer > 1 Jahr): %.2f EUR\n", v[1]))
    elseif code == 206
        out(r_sprintf("\t\t=> Steuerpflichtiger Gewinn (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n", v[1], v[2]))
    elseif code == 207
        out(r_sprintf("\t\t=> Verrechenbarer Verlust (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n", v[1], v[2]))
    elseif code == 208
        out(r_sprintf("%s\tVerkauf %.2fx %s zu %.2f EUR je Anteil am %s\n", _ENGINE_REASONS[aux+1], v[1], name, v[2], ds))
    elseif code == 209   # ifelse(gain < 0, ...) mit NA: "NA" wie R
        out(r_sprintf("\t\t=> %s: %.2f EUR; Steuer: %.2f EUR\n", isnan(v[1]) ? "NA" : v[1] < 0 ? "Verlust" : "Gewinn", v[1], v[2]))
    elseif code == 210
        out(r_sprintf("Freibetrag:\tRealisierung von Gewinnen %.2f EUR mit %.4fx %s (freier Sparer-Pauschbetrag/Verlusttopf %.2f EUR)\n",
                      v[1], v[2], name, v[3]))
    elseif code == 211
        desc = aux == 1 ? "1 : " * r_format1(v[1]; digits = 5) : r_format1(v[1]; digits = 5) * " : 1"
        out("Split-Ereignis:\t$(aux == 1 ? "Split" : "Reverse-Split") $name im Verhältnis $desc am $ds\n")
    elseif code == 212
        out("Split-Ereignis:\t$name ohne Bestand: Kursreihe $(aux == 1 ? "1 :" : ": 1") $(r_format1(v[1]; digits = 5)) am $ds\n")
    elseif code == 213
        out("Marktereignis:\tHandel mit $(anames(ints)) ab jetzt möglich.\n")
    elseif code == 214
        parts = join((r_sprintf("%s %.2f EUR", fl.flag_assets[k+1], v[j+1]) for (j, k) in enumerate(ints)), "; ")
        out(r_sprintf("Einzahlung:\t%.2f EUR in das Depot am %s\n\t\t=> ", v[1], ds) * parts * "\n")
    elseif code == 215
        out("Rebalancing:\tErzwungenes Rebalancing am $ds wegen neu handelbarer Assets: $(anames(ints))\n")
    elseif code == 216
        out(r_sprintf("Rebalancing:\tRebalancing am %s (max. Abweichung: %.2f%% > Schwelle: %.2f%%)\n", ds, v[1], v[2]))
    elseif code == 217
        out(r_sprintf("\t\t=> %s: Ziel=%.1f%%, Ist=%.1f%%, Abweichung=%.2f%%\n", name, v[1], v[2], v[3]))
    elseif code == 218
        out(r_sprintf("Rebalancing:\tKein Rebalancing am %s (max. Abweichung: %.2f%% < Schwelle: %.2f%%)\n", ds, v[1], v[2]))
    elseif code == 219
        out(r_sprintf("\t\t%.2f EUR von %s in den Rebalancing-Topf\n", v[1], name))
    elseif code == 220
        out(r_sprintf("Rebalancing:\t%.2f EUR aus dem Rebalancing-Topf an %s\n", v[1], name))
    elseif code == 221
        out(r_sprintf("\t\t=> %s hält %.2f EUR als Cash-Reserve (Signal inaktiv)\n", name, v[1]))
    elseif code == 222
        out(r_sprintf("\t\tRestverteilung von %.2f EUR aus dem Rebalancing-Topf\n", v[1]))
    elseif code == 223
        out(r_sprintf("\t\t=> %.2f EUR an %s\n", v[1], name))
    elseif code == 224
        out(r_sprintf("Steuerereignis:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (Zufluss und Steuer am ersten Handelstag des Folgejahres)\n",
                      name, v[1], ds))
    elseif code == 225
        out(r_sprintf("Steuerereignis:\tZahlung %s %.2f EUR für %s aus dem Geldbestand am %s\n", _engine_label(aux, ints), v[1], name, ds))
    elseif code == 226
        out(r_sprintf("Steuerereignis:\tTeilzahlung %s %.2f EUR aus dem Geldbestand am %s\n", _engine_label(aux, ints), v[1], ds))
    elseif code == 227
        out(r_sprintf("\t\t=> Anteile verkauft für den Rest von %.2f EUR (%s)\n", v[1], _engine_label(aux, ints)))
    elseif code == 228
        out(r_sprintf("Steuerereignis:\tVeranlagung %d: Nachzahlung %.2f EUR (davon § 23 %.2f EUR, Kirchensteuer-Sonderausgaben %.2f EUR%s) am %s, aufgeteilt %s\n",
                      Int(v[1]), v[2], v[3], v[4], aux & 1 != 0 ? r_sprintf(", Günstigerprüfung %.2f EUR", v[5]) : "", ds,
                      aux & 2 != 0 ? "nach dem § 23-Jahressaldo je Asset" : "zu gleichen Teilen auf die Assets"))
    elseif code == 229
        out(r_sprintf("\t\t=> Anteil %s: %.2f EUR\n", name, v[1]))
    elseif code == 230
        out(r_sprintf("Steuerereignis:\t§ 23 EStG: Steuer %.2f EUR (%s) am %s\n", v[1], name, ds))
    elseif code == 231
        out(r_sprintf("Steuerereignis:\tGünstigerprüfung: Erstattung %.2f EUR in den Geldbestand am %s\n", v[1], ds))
    elseif code == 232
        out(r_sprintf("Steuerereignis:\tVorabpauschale %s (festgesetzt %s): %.2f EUR, nach TFS %.2f EUR, SPB %.2f EUR, Steuer %.2f EUR am %s\n",
                      name, fmt_date(Int(v[1])), v[2], v[3], v[4], v[5], ds))
    elseif code == 240
        out("\n" * _DOUBLE_LINE * "\n")
        out("  JAHRESWECHSEL: $(Int(v[1])) -> $(Int(v[2]))\n")
        out(_DOUBLE_LINE * "\n")
    elseif code == 241
        out(r_sprintf("  § 23 EStG: Verlustvortrag verwendet: %.2f EUR\n", v[1]))
        out(r_sprintf("             Verbleibender Vortrag: %.2f EUR\n", v[2]))
    elseif code == 242
        out("  § 23 EStG Jahresübersicht $(Int(v[1])):\n")
        out(r_sprintf("    Bruttogewinne (< 1 Jahr):    %10.2f EUR\n", v[2]))
        out(r_sprintf("    Bruttoverluste (< 1 Jahr):   %10.2f EUR\n", v[3]))
        out(r_sprintf("    Interne Verrechnung:         %10.2f EUR\n", v[4]))
        out(r_sprintf("    Verlustvortrag-Verrechnung:  %10.2f EUR\n", v[5]))
        out("    " * "─"^41 * "\n")
        out(r_sprintf("    Netto-Ergebnis:              %10.2f EUR\n", v[6]))
    elseif code == 243
        out("\n  ⚠ FREIGRENZE ERREICHT!\n")
        out(r_sprintf("    Jahressaldo %.2f EUR >= Freigrenze %.2f EUR\n", v[1], v[2]))
        out(r_sprintf("    → GESAMTER Gewinn nach Verlustvortrag steuerpflichtig: %.2f EUR (Freigrenze, kein Freibetrag!)\n", v[3]))
        if aux == 1
            out("    → Steuer nach dem Einkommensteuertarif (ESt + Soli + KiSt des § 23-Zuwachses): siehe Jahresveranlagung unten (Zeile § 23)\n")
        else
            out(r_sprintf("    → Steuersatz: %.1f%%%s%s\n", v[4] * 100,
                          v[5] > 1 ? r_sprintf(" + %.1f%%%% Soli", (v[5] - 1) * 100) : "",
                          v[6] > 0 ? r_sprintf(" + %.1f%% KiSt", v[6] * 100) : ""))
            out(r_sprintf("    → Steuerlast: %.2f EUR\n", v[7]))
        end
    elseif code == 244
        out(r_sprintf("\n  Nettoverlust %.2f EUR → Vortrag ins nächste Jahr\n", v[1]))
        out(r_sprintf("  Gesamter Verlustvortrag: %.2f EUR\n", v[2]))
    elseif code == 245
        out(r_sprintf("\n  ✓ Jahressaldo %.2f EUR < Freigrenze %.2f EUR → STEUERFREI (Verlustvortrag unverändert)\n", v[1], v[2]))
    elseif code == 246
        out("\n  Keine steuerpflichtigen § 23 Vorgänge in $(Int(v[1]))\n")
    elseif code == 247
        out("\n  Sparerpauschbetrag $(Int(v[1])):\n")
        out(r_sprintf("    Jahresbetrag:    %10.2f EUR\n", v[2]))
        out(r_sprintf("    Verwendet:       %10.2f EUR\n", v[3]))
        out(r_sprintf("    Verfallen:       %10.2f EUR\n", v[4]))
    elseif code == 248
        out(r_sprintf("  § 20 EStG: Unterjährige Verlustverrechnung -> Erstattung %.2f EUR in den Geldbestand\n", v[1]))
    elseif code == 249
        out(r_sprintf("  § 20 EStG: Verlust gibt Sparer-Pauschbetrag frei: %.2f EUR (genutzt %d: %.2f EUR, Verlusttopf %.2f EUR)\n",
                      v[1], Int(v[2]), v[3], v[4]))
    elseif code == 250   # Jahreszeile in der Reihenfolge TR_* (tariff_core_impl.h)
        year, X1, D = Int(v[1]), v[21], v[23]
        out(r_sprintf("  Tarif %d: zvE %.2f EUR - KiSt-Sonderausgaben %.2f EUR (gezahlt %.2f, erstattet %.2f) = %.2f EUR (Wirkung %.2f EUR)\n",
                      year, v[2], v[5], v[3], v[4], v[6], v[7]))
        aux & 2 != 0 && out(r_sprintf("    § 23: Gewinn %.2f EUR -> Steuerlast ESt %.2f + Soli %.2f + KiSt %.2f = %.2f EUR\n",
                                      v[8], v[9], v[10], v[11], v[12]))
        aux & 1 != 0 && out(r_sprintf("    Günstigerprüfung: K %.2f EUR, Abgeltungsteuer %.2f EUR (KiSt %.2f), Tarif auf K %.2f EUR (ESt %.2f + Soli %.2f + KiSt %.2f); Belastung ohne %.2f / mit %s EUR -> %s\n",
                                      v[13], v[14], v[15], v[19], v[16], v[17], v[18], v[20], isnan(X1) ? "-" : r_sprintf("%.2f", X1),
                                      v[22] != 0 ? "Tarif" : "Abgeltungsteuer bleibt"))
        out(r_sprintf("    Abrechnung: %s %.2f EUR; KiSt-Bescheid %+.2f EUR (Sonderausgabe %d)\n",
                      D >= 0 ? "Nachzahlung" : "Erstattung", abs(D), v[25], year + 1))
    elseif code == 251
        out("\n  Tracker zurückgesetzt für Jahr $(Int(v[1]))\n")
        out(_DOUBLE_LINE * "\n\n")
    else
        error("simulation: interner Fehler: unbekannter Ereigniscode $code der Tagesengine.")
    end
    return nothing
end
