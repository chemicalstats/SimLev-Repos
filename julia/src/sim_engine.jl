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
    chk_stop("a.m_cabi_layout_check", what, got, n)

_engine_fee(f::Nothing) = (0.0, 0.0, 0.0, 0.0, 0.0)
_engine_fee(f::FeeSpec) = (1.0, f.fixed, f.percent, f.min, f.max)

const _ENGINE_REGIME = Dict("investment_fund" => Int32(1), "capital_gains" => Int32(2), "private_sale" => Int32(3))
const _ENGINE_REGIME_NAME = VALID_REGIMES   # config.jl (eine Liste, seit 1.6.3)
const _ENGINE_ROWS = ("year", "taxable_income", "church_tax_paid_deductible", "church_tax_refunded",
                      "church_tax_net_deduction", "taxable_income_net", "deduction_effect", "gain_p23", "income_tax_p23",
                      "soli_p23", "church_tax_p23", "tax_p23", "capital_income", "abgeltung_burden",
                      "church_tax_withheld_k", "tariff_income_tax_k", "tariff_soli_k", "tariff_church_tax_k",
                      "tariff_burden", "burden_without_gp", "burden_with_gp", "guenstiger", "settlement", "refund",
                      "church_tax_settlement_next_year")

# Zeiger auf eine Signalspalte; leer (keine Spalte, seit 1.6.1) → C_NULL, der Kern liest FALSE an jedem Tag
_sig_ptr(v::Vector{Float64}) = isempty(v) ? Ptr{Float64}(C_NULL) : pointer(v)

"Freibetrag ab harvest_day (\"MM-TT\"): erster Monat * 100 + Tag, den der Zeichenvergleich zulässt (wie R)."
function _harvest_md(harvest_day)
    harvest_day isa AbstractString && occursin(r"^[0-9]{2}-[0-9]{2}$", harvest_day) &&
        return parse(Int, harvest_day[1:2]) * 100 + parse(Int, harvest_day[4:5])
    ok = [m * 100 + d for m in 1:12 for d in 1:31 if string(lpad(m, 2, '0'), "-", lpad(d, 2, '0')) >= harvest_day]
    return isempty(ok) ? 9999 : minimum(ok)
end

"""Eingabe der Tagesengine (seit 1.6.5 eigene Funktion, Paket E: der Studienkern sim_prepared.jl merkt sie sich je
Strategie und tauscht je Pfad nur Kurse und Signale); setzt fl.tax_regimes."""
function _sim_engine_input(R::Run, sim::Sim, fr::_Frame, liquidate, event_weight, split_thresh, balance_dca,
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
    fees = Float64[_engine_fee(cfg.fee_order)..., _engine_fee(cfg.fee_dca)..., _engine_fee(cfg.fee_cust)...]   # seit 1.6.5 15 Werte
    L = _CABI_LAYOUT
    _flat_len(ai, L.AI_N * na, "ai"); _flat_len(ad, L.AD_N * na, "ad"); _flat_len(ci, L.CI_N, "ci")
    _flat_len(cd, L.CD_N, "cd"); _flat_len(tot0, L.TT_N, "tot0"); _flat_len(pint, L.PI_N, "pint")
    _flat_len(pdbl, L.PD_N, "pdbl")
    return (n = n, na = na, person = person, env = env, day = day, ew = ew, ai = ai, ad = ad, ci = ci, cd = cd,
            fees = fees, tot0 = tot0, tariff_par = tariff_par, zve = zve, pint = pint, pdbl = pdbl, starts = starts,
            filled = filled, event = event, has_ew = event_weight !== nothing)
end

"Vorbereitung, Phasen 4 und 5 über den C++-Kern: Termine, Flags, Startgewichte, Tagesschleife und Abschluss des letzten Jahres."
function _sim_engine_run!(R::Run, sim::Sim, fr::_Frame, liquidate, event_weight, split_thresh, balance_dca,
                          harvest_loss_pot, stopp_date::Int, harvest_day)
    @nospecialize
    E = _sim_engine_input(R, sim, fr, liquidate, event_weight, split_thresh, balance_dca, harvest_loss_pot, stopp_date,
                          harvest_day)
    h = ccall((:simlev_c_engine_new, LIBSLC), Ptr{Cvoid}, ())
    h == C_NULL && throw(OutOfMemoryError())
    try
        flags_out = zeros(Int32, E.n)
        rc = _engine_ccall(h, C_NULL, E, sim, R.fl, flags_out, nothing)
        _sim_engine_output!(h, rc, R, sim, E, flags_out)
    finally
        ccall((:simlev_c_engine_free, LIBSLC), Cvoid, (Ptr{Cvoid},), h)
    end
    return nothing
end

"""Aufruf des Kerns mit der Eingabe E und den Zeigern auf Kurse, Signale, Basiszins und Report von sim: ohne ev
`simlev_c_engine_run`, mit ev (Teile der Auswertung, Studienkern seit 1.6.5) `simlev_c_run_prepared` mit dem
Auswertungsobjekt he; Rückgabe des Kerns."""
function _engine_ccall(h::Ptr{Cvoid}, he::Ptr{Cvoid}, E, sim::Sim, fl::Flags, flags_out::Vector{Int32}, ev)
    @nospecialize
    n, na, person = E.n, E.na, E.person
    day, ew, ai, ad, ci, cd, fees, tot0 = E.day, E.ew, E.ai, E.ad, E.ci, E.cd, E.fees, E.tot0
    tariff_par, zve, pint, pdbl, starts, filled, event = E.tariff_par, E.zve, E.pint, E.pdbl, E.starts, E.filled, E.event
    rc = Cint(0)
    GC.@preserve sim day ew ai ad ci cd fees tot0 tariff_par zve pint pdbl starts filled event fl flags_out ev begin
        prices = Ptr{Float64}[pointer(sim.market[a].asset_price) for a in 1:na]
        sb = Ptr{Float64}[_sig_ptr(sim.market[a].signal_buy.v) for a in 1:na]
        ss = Ptr{Float64}[_sig_ptr(sim.market[a].signal_sell.v) for a in 1:na]
        ewp = !E.has_ew ? Ptr{Ptr{Float64}}(C_NULL) :
              Ptr{Float64}[ew[a] === nothing ? Ptr{Float64}(C_NULL) : pointer(ew[a]) for a in 1:na]
        brp = person ? Ptr{Float64}[pointer(sim.market[a].base_rates) for a in 1:na] : Ptr{Ptr{Float64}}(C_NULL)
        reps = Ptr{Float64}[]
        for a in 1:na
            r = sim.report[a]
            append!(reps, (pointer(r.worth), pointer(r.money), pointer(r.flows), pointer(r.total), pointer(r.share)))
        end
        GC.@preserve prices sb ss ewp brp reps begin
            dd, dc, bd, bc = fl.dca[3], fl.dca[4], fl.balance[3], fl.balance[4]
            if ev === nothing
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
            else
                rc = ccall((:simlev_c_run_prepared, LIBSLC), Cint,
                           (Ptr{Cvoid}, Ptr{Cvoid}, Int64, Int64, Ptr{Float64}, Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}},
                            Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}}, Ptr{Int32}, Ptr{Float64},
                            Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Int64, Ptr{Float64},
                            Int64, Ptr{Ptr{Float64}}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32},
                            Int64, Ptr{Float64}, Ptr{Int32}, Int64, Ptr{Float64}, Ptr{Int32}, Ptr{Int32},
                            Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Int64, Int32, Ptr{Int64}),
                           h, he, n, na, day, prices, sb, ss, ewp, brp, ai, ad, ci, cd, fees, tot0, tariff_par,
                           length(tariff_par), zve, length(zve) ÷ 2, reps, pint, pdbl, starts,
                           isempty(filled) ? Ptr{Int32}(C_NULL) : pointer(filled),
                           fl.flag_event === nothing ? Ptr{Int32}(C_NULL) : pointer(event),
                           length(dd), dd, dc, length(bd), bd, bc, flags_out,
                           ev.day, isempty(ev.filled) ? Ptr{Int32}(C_NULL) : pointer(ev.filled), ev.sc,
                           ev.rf_ok ? pointer(ev.rf) : Ptr{Float64}(C_NULL), ev.rf_ok ? length(ev.rf) : 0,
                           Int32(ev.rf_ok), ev.cnt)
            end
        end
    end
    return rc
end

"Ergebnis der Tagesengine (Objekt h nach dem Lauf, Rückgabe rc) in sim, fl, Tarifjahre, Gebühren und Meldungen übernehmen."
function _sim_engine_output!(h::Ptr{Cvoid}, rc, R::Run, sim::Sim, E, flags_out::Vector{Int32})
    @nospecialize
    fl, n, na, T = R.fl, E.n, E.na, sim.totals
    env = E.person ? R.cfg.tariff_env : nothing   # Tarifzustand dieses Laufs (Studienkern: eigene Kopie)
    rc == 0 || rc == 6 || CAbi.check(rc)
    fl.flag_harvest = BitVector((flags_out .& Int32(128)) .!= 0)
    status = zeros(8na); tv = zeros(13); nlots = zeros(Int64, na); nsells = zeros(Int64, na)
    ntaxes = zeros(Int64, na); pxc = zeros(Int32, na); cnt = zeros(Int64, 5); scal = zeros(2)
    err = zeros(Int32, 1); err_d0 = Ref{Float64}(0.0)
    ccall((:simlev_c_engine_counts, LIBSLC), Cvoid,
          (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Ptr{Int64}, Ptr{Int64}, Ptr{Int64}, Ptr{Int32}, Ptr{Int64},
           Ptr{Float64}, Ptr{Int32}, Ref{Float64}),
          h, status, tv, nlots, nsells, ntaxes, pxc, cnt, scal, err, err_d0)
    for a in 1:na
        o = 8 * (a - 1)
        sim.status[a].money = status[o+4]   # Status je Asset: gelesen wird nur money (wie R seit 1.6.3)
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
    T.private_sale_gains_ytd, T.private_sale_losses_ytd = tv[4], tv[5]   # gelesen: tax_report next_year private_sale_net
    T.sparer_pauschbetrag_annual, T.sparer_pauschbetrag_remaining, T.sparer_pauschbetrag_used_total = tv[6], tv[7], tv[8]
    T.current_year = Int(tv[9])
    T.cgt_base_taxed_ytd, T.cgt_loss_added_ytd, T.cgt_loss_used_ytd, T.cgt_pool_start_ytd = tv[10], tv[11], tv[12], tv[13]
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
    end
    nev = Int(cnt[1])
    evi = zeros(Int32, 9 * nev); evd = zeros(2 * nev); evy = zeros(Int32, Int(cnt[2])); evv = zeros(Int(cnt[5]))
    ccall((:simlev_c_engine_events, LIBSLC), Cvoid, (Ptr{Cvoid}, Ptr{Int32}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}),
          h, evi, evd, evy, evv)
    R.fee_paid = scal[1]
    R.tax_unpaid_total = scal[2]
    _sim_engine_signal(R, fl, evi, evd, evy, evv, rc == 6, Int(err[1]), err_d0[])
    return nothing
end

# Texte aus core/meldungen.tsv (meldungen.jl); Anlass der Käufe und Verkäufe (enum Reason in engine_core_impl.h)
const _ENGINE_REASONS = Tuple(_MELD_ENGINE_REASON[string(k)] for k in 0:length(_MELD_ENGINE_REASON)-1)

"Bezeichnung einer Steuerzahlung (.pay_tax label): Vorabpauschale, § 23-Steuer oder Veranlagung der Jahre."
_engine_label(aux::Int, ints) = aux == 3 ? chk_msg("a.label_depot") :   # 3 (Depotgebühr) seit 1.6.5
                                aux < 2 ? _MELD_ENGINE_LABEL[string(aux)] :
                                r_sprintf(_MELD_ENGINE_LABEL["2"], join(string.(ints), "/"))

"Warnungen, details-Ausgaben und Abbruch des Kerns mit den Texten von R 1.3.0 auslösen (Reihenfolge des Protokolls);
Texte aus `_MELD_ENGINE_SIGNAL`."
function _sim_engine_signal(R::Run, fl::Flags, evi::Vector{Int32}, evd::Vector{Float64}, evy::Vector{Int32},
                            evv::Vector{Float64}, failed::Bool, err_code::Int, err_d0::Float64)
    m = _MELD_ENGINE_SIGNAL
    for k in 0:(length(evd) ÷ 2 - 1)
        code, day, asset = evi[9k+1], Int(evi[9k+3]), Int(evi[9k+4])
        aux, y_off, ny, v_off, nv = Int(evi[9k+5]), Int(evi[9k+6]), Int(evi[9k+7]), Int(evi[9k+8]), Int(evi[9k+9])
        d0, d1 = evd[2k+1], evd[2k+2]
        nm = asset >= 0 ? fl.flag_assets[asset+1] : ""
        ints = @view evy[y_off+1:y_off+ny]
        if code >= 200
            _sim_engine_detail(R, fl, Int(code), nm, aux, @view(evv[v_off+1:v_off+nv]), ints, fmt_date(fl.flag_date[day]))
        elseif code == 1
            @warn r_sprintf(m["1"], d0, nm, fmt_date(fl.flag_date[day]))
        elseif code == 2
            @warn r_sprintf(m["2"], d0, d1, nm)
        elseif code == 3
            @warn r_sprintf(m["3"], nm, d0)
        elseif code == 4
            @warn m["4"]
        elseif code == 5 && aux == 3   # seit 1.6.5 (Paket E): nicht gedeckte Depotgebühr als offene Gebühr
            @warn chk_msg("e.gebuehr_ungedeckt", _engine_label(aux, ints), r_sprintf("%.2f", d0), fmt_date(fl.flag_date[day]),
                          r_sprintf("%.2f", d1), nm)
        elseif code == 5
            @warn r_sprintf(m["5"], _engine_label(aux, ints), d0, fmt_date(fl.flag_date[day]), d1, nm)
        elseif code == 6
            @warn r_sprintf(m["6"], d0, d1) * m["6.rest"]
        elseif code == 7   # seit 1.6.5 (CR2-G-6, K36): Hinweis zu unbrauchbaren event_weight an Ereignistagen
            _message(chk_msg("a.event_gewicht", string(Int(d0)), fmt_date(fl.flag_date[day])))
        else
            error(r_sprintf(m["unbekannt"], Int(code)))
        end
    end
    if failed
        err_code == 101 && error(r_sprintf(m["101"], r_format1(err_d0)))
        err_code == 102 && chk_stop("fa.nicht_endlich")      # seit 1.6.4 (A-005, Entscheidung 103)
        err_code == 103 && chk_stop("ut1.unterlauf")         # seit 1.6.4 (K43 T1-R9)
        error(m["na"])
    end
    return nothing
end

"details-Ausgabe eines Ereignisses (DT_* in engine_core_impl.h), wortgleich zu R 1.3.0; Texte aus `_MELD_ENGINE_DETAIL`."
function _sim_engine_detail(R::Run, fl::Flags, code::Int, name::AbstractString, aux::Int, v, ints, ds::String)
    out(s) = _cat(R, s)
    anames(ix) = join((fl.flag_assets[k+1] for k in ix), ", ")
    m = _MELD_ENGINE_DETAIL
    sp = r_sprintf
    if code == 201
        out(sp(m["201"], _ENGINE_REASONS[aux+1], v[1], name, v[2], ds))
    elseif code == 202
        out(sp(m["202"], v[1]))
    elseif code == 203
        out(sp(m["203"], v[1], v[2]))
    elseif code == 204
        out(sp(m["204"], v[1]))
    elseif code == 205
        out(sp(m["205"], v[1]))
    elseif code == 206
        out(sp(m["206"], v[1], v[2]))
    elseif code == 207
        out(sp(m["207"], v[1], v[2]))
    elseif code == 208
        out(sp(m["208"], _ENGINE_REASONS[aux+1], v[1], name, v[2], ds))
    elseif code == 209   # ifelse(gain < 0, ...) mit NA: "NA" wie R
        out(sp(m["209"], isnan(v[1]) ? "NA" : v[1] < 0 ? m["209.verlust"] : m["209.gewinn"], v[1], v[2]))
    elseif code == 210
        out(sp(m["210"], v[1], v[2], name, v[3]))
    elseif code == 211
        desc = sp(aux == 1 ? m["211.v1"] : m["211.v2"], r_format1(v[1]; digits = 5))
        out(sp(m["211"], aux == 1 ? m["211.split"] : m["211.reverse"], name, desc, ds))
    elseif code == 212
        out(sp(m["212"], name, aux == 1 ? m["212.v1"] : m["212.v2"], r_format1(v[1]; digits = 5), ds))
    elseif code == 213
        out(sp(m["213"], anames(ints)))
    elseif code == 214
        parts = join((sp(m["214.teil"], fl.flag_assets[k+1], v[j+1]) for (j, k) in enumerate(ints)), "; ")
        out(sp(m["214"], v[1], ds) * parts * "\n")
    elseif code == 215
        out(sp(m["215"], ds, anames(ints)))
    elseif code == 216
        out(sp(m["216"], ds, v[1], v[2]))
    elseif code == 217
        out(sp(m["217"], name, v[1], v[2], v[3]))
    elseif code == 218
        out(sp(m["218"], ds, v[1], v[2]))
    elseif code == 219
        out(sp(m["219"], v[1], name))
    elseif code == 220
        out(sp(m["220"], v[1], name))
    elseif code == 221
        out(sp(m["221"], name, v[1]))
    elseif code == 222
        out(sp(m["222"], v[1]))
    elseif code == 223
        out(sp(m["223"], v[1], name))
    elseif code == 224
        out(sp(m["224"], name, v[1], ds))
    elseif code == 225 && Int(aux) == 3   # seit 1.6.5 (Entscheidung 194): Depotgebühr mit Präfix „Depotgebühr:“
        out(chk_msg("a.dt_gebuehr_zahlung", sp("%.2f", v[1]), name, ds))
    elseif code == 226 && Int(aux) == 3
        out(chk_msg("a.dt_gebuehr_teil", sp("%.2f", v[1]), ds))
    elseif code == 225
        out(sp(m["225"], _engine_label(aux, ints), v[1], name, ds))
    elseif code == 226
        out(sp(m["226"], _engine_label(aux, ints), v[1], ds))
    elseif code == 227
        out(sp(m["227"], v[1], _engine_label(aux, ints)))
    elseif code == 228
        out(sp(m["228"], Int(v[1]), v[2], v[3], v[4], aux & 1 != 0 ? sp(m["228.guenstiger"], v[5]) : "", ds,
               aux & 2 != 0 ? m["228.asset"] : m["228.gleich"]))
    elseif code == 229
        out(sp(m["229"], name, v[1]))
    elseif code == 230
        out(sp(m["230"], v[1], name, ds))
    elseif code == 231
        out(sp(m["231"], v[1], ds))
    elseif code == 232
        out(sp(m["232"], name, fmt_date(Int(v[1])), v[2], v[3], v[4], v[5], ds))
    elseif code == 233   # seit 1.6.5: Zahlung aus dem Geld eines anderen Assets (MA1-2)
        out(Int(aux) == 3 ? chk_msg("a.dt_gebuehr_anderes", sp("%.2f", v[1]), fl.flag_assets[Int(v[2])+1], name, ds) :
            chk_msg("a.dt_zahlung_anderes", _engine_label(aux, ints), sp("%.2f", v[1]), fl.flag_assets[Int(v[2])+1], name, ds))
    elseif code == 234   # seit 1.6.5: Depotgebühr (Entscheidung 150)
        out(chk_msg("a.dt_depot", sp("%.2f", v[1]), sp("%.2f", v[2]), sp("%.4f", v[3]), ds))
    elseif code == 240
        out(m["240.1"])
        out(sp(m["240.2"], Int(v[1]), Int(v[2])))
        out(m["240.3"])
    elseif code == 241
        out(sp(m["241.1"], v[1]))
        out(sp(m["241.2"], v[2]))
    elseif code == 242
        out(sp(m["242.1"], Int(v[1])))
        out(sp(m["242.2"], v[2]))
        out(sp(m["242.3"], v[3]))
        out(sp(m["242.4"], v[4]))
        out(sp(m["242.5"], v[5]))
        out(m["242.6"])
        out(sp(m["242.7"], v[6]))
    elseif code == 243
        out(m["243.1"])
        out(sp(m["243.2"], v[1], v[2]))
        out(sp(m["243.3"], v[3]))
        if aux == 1
            out(m["243.tarif"])
        else
            out(sp(m["243.satz"], v[4] * 100, v[5] > 1 ? sp(m["243.soli"], (v[5] - 1) * 100) : "",
                   v[6] > 0 ? sp(m["243.kist"], v[6] * 100) : ""))
            out(sp(m["243.last"], v[7]))
        end
    elseif code == 244
        out(sp(m["244.1"], v[1]))
        out(sp(m["244.2"], v[2]))
    elseif code == 245
        out(sp(m["245"], v[1], v[2]))
    elseif code == 246
        out(sp(m["246"], Int(v[1])))
    elseif code == 247
        out(sp(m["247.1"], Int(v[1])))
        out(sp(m["247.2"], v[2]))
        out(sp(m["247.3"], v[3]))
        out(sp(m["247.4"], v[4]))
    elseif code == 248
        out(sp(m["248"], v[1]))
    elseif code == 249
        out(sp(m["249"], v[1], Int(v[2]), v[3], v[4]))
    elseif code == 250   # Jahreszeile in der Reihenfolge TR_* (tariff_core_impl.h)
        year, X1, D = Int(v[1]), v[21], v[23]
        out(sp(m["250.1"], year, v[2], v[5], v[3], v[4], v[6], v[7]))
        aux & 2 != 0 && out(sp(m["250.p23"], v[8], v[9], v[10], v[11], v[12]))
        aux & 1 != 0 && out(sp(m["250.guenstiger"], v[13], v[14], v[15], v[19], v[16], v[17], v[18], v[20],
                               isnan(X1) ? "-" : sp(m["250.x1"], X1), v[22] != 0 ? m["250.tarif"] : m["250.bleibt"]))
        out(sp(m["250.abrechnung"], D >= 0 ? m["250.nach"] : m["250.erst"], abs(D), v[25], year + 1))
    elseif code == 251
        out(sp(m["251.1"], Int(v[1])))
        out(m["251.2"])
    else
        error(sp(_MELD_ENGINE_SIGNAL["unbekannt"], code))
    end
    return nothing
end
