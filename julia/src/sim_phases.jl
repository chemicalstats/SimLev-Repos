# ─────────────────────────────────────────────────────────────────────────────
# simulation(), Phasen 1–2: Eingabeprüfung (sim_validate.R), Datenvorbereitung,
# Zentralstruktur, Termine und Ablaufplan (sim_prepare.R)
# ─────────────────────────────────────────────────────────────────────────────

function _frac_warn_col(fr::_Frame, col::String, arg::String, hi::Float64)
    @nospecialize
    _fis_numeric(fr, col) || return nothing
    v = [x for x in fr.cols[col] if !isnan(x) && x != 0]
    isempty(v) && return nothing
    m = r_median(v)
    if isfinite(m) && 0 < m < hi
        @warn "simulation: $arg-Spalte '$col' hat den Median $(r_format1(m)) und wird als $(r_format1(m)) % gelesen (Prozent-Konvention); gemeint waren vermutlich Werte x 100 (Median $(r_format1(m * 100)))."
    end
    return nothing
end

_show_arg(x) = x === nothing ? "NULL" : r_deparse(x)

"""
    _tax_rates(rate, church_tax, guenstigerpruefung, marginal_rate, include_soli, soli_rate, who;
               details = false, tariff_on = false, io = stdout)

Steuersätze aus Abgeltungsteuer, Kirchensteuer und Günstigerprüfung (R: `.tax_rates`). Gemeinsamer
Helfer von `simulation()` (`_sim_check_inputs`) und `withdrawal_simulation()`: Satz der Abgeltungsteuer mit
Kirchensteuer (§ 32d Abs. 1 EStG), Prozentangaben als Anteile und effektiver Satz der Günstigerprüfung (einmal
je Lauf mit dem Grenzsteuersatz aus `income_rate()`). Rechenfolge, Warnungen und Druck wie in R; Meldungen
beginnen mit `who`. Ergebnis: NamedTuple `tax_rate`, `marginal_tax_rate`, `soli_rate_income_tax` (Anteile),
`effective_tax_rate`, `church_k`, `soli_factor_income`.
"""
function _tax_rates(rate, church_tax, guenstigerpruefung, marginal_rate, include_soli, soli_rate, who::AbstractString;
                    details::Bool = false, tariff_on::Bool = false, io::IO = stdout)
    tax_rate = Float64(rate)
    church_tax = church_tax === nothing ? nothing : Float64(church_tax)
    marginal_tax_rate = marginal_rate
    use_guenstigerpruefung = guenstigerpruefung === true
    include_soli_on_income_tax = include_soli === true
    soli_rate_income_tax = soli_rate
    if church_tax !== nothing && church_tax > 0
        k = church_tax / 100
        tax_rate = 100 * 0.25 / (1 + 0.25 * k) * (1 + 0.055 + k)
    end
    church_k = (church_tax !== nothing && church_tax > 0) ? church_tax / 100 : 0.0
    tax_rate = tax_rate / 100
    mtr = marginal_tax_rate === nothing ? nothing : Float64(marginal_tax_rate) / 100
    soli_rate = Float64(soli_rate_income_tax) / 100
    effective_tax_rate = tax_rate
    if use_guenstigerpruefung && !tariff_on
        if mtr === nothing
            @warn who * ": Günstigerprüfung aktiviert (tax_profile(guenstigerpruefung = TRUE)), aber der Grenzsteuersatz (income_rate(marginal_rate)) ist nicht gesetzt.\nVerwendet wird die Abgeltungsteuer (" *
                  r_as_character(r_round(tax_rate * 100, 2)) * " %).\nFür eine korrekte Günstigerprüfung tax_profile(income = income_rate(marginal_rate)) in Prozent angeben (z. B. 42)."
        else
            personal_rate = mtr * ((include_soli_on_income_tax ? (1 + soli_rate) : 1.0) + church_k)
            if personal_rate < tax_rate
                effective_tax_rate = personal_rate
                details && print(io, r_sprintf("═══ Günstigerprüfung aktiv ═══\n  Persönlicher Steuersatz: %.2f%%\n  Effektiver Steuersatz: %.2f%% (statt %.2f%% Abgeltungsteuer)\n  Ersparnis: %.2f Prozentpunkte\n\n",
                                                       mtr * 100, effective_tax_rate * 100, tax_rate * 100, (tax_rate - effective_tax_rate) * 100))
            else
                details && print(io, r_sprintf("═══ Günstigerprüfung geprüft ═══\n  Persönlicher Steuersatz: %.2f%%\n  Abgeltungsteuer: %.2f%% → bleibt günstiger\n\n",
                                                       personal_rate * 100, tax_rate * 100))
            end
        end
    end
    soli_factor_income = include_soli_on_income_tax ? (1 + soli_rate) : 1.0
    return (tax_rate = tax_rate, marginal_tax_rate = mtr, soli_rate_income_tax = soli_rate,
            effective_tax_rate = effective_tax_rate, church_k = church_k, soli_factor_income = soli_factor_income)
end

# Prüf-Cache je Studie (seit 1.5.1; R .sim_study_env, Python _StudyCache): Studien (bootstrap_study, param_search,
# sensitivity_*, planning_lumpsum_vs_dca) rufen simulation() vielfach mit denselben Daten auf. Solange eine Studie
# läuft, merkt sich simulation() je Art den zuletzt gesehenen Schlüssel von Prüfungen, die ohne Meldung durchgingen
# (eindeutige Tage); Meldungen und Warnungen entstehen weiter je Lauf, Fehler brechen vor dem Merken ab.
const _STUDY_ON = Ref(false)
const _STUDY_M = Dict{String,Any}()
const _STUDY_LOCK = ReentrantLock()

function _sim_study()
    lock(_STUDY_LOCK) do
        _STUDY_ON[] && return false
        _STUDY_ON[] = true; empty!(_STUDY_M)
        return true
    end
end

function _sim_study_end(own::Bool)
    own || return nothing
    lock(_STUDY_LOCK) do
        _STUDY_ON[] = false; empty!(_STUDY_M)
    end
    nothing
end

function _memo_get(what::String, key::Vector{Float64})
    _STUDY_ON[] || return nothing
    lock(_STUDY_LOCK) do
        e = get(_STUDY_M, what, nothing)
        (e === nothing || !isequal(e[1], key)) && return nothing
        return e[2]
    end
end

function _memo_set(what::String, key::Vector{Float64}, val)
    _STUDY_ON[] || return nothing
    lock(_STUDY_LOCK) do
        _STUDY_M[what] = (copy(key), val)
    end
    nothing
end

"""
    @study function f(...) ... end

Studie mit Prüf-Cache (seit 1.5.1): der Rumpf läuft zwischen `_sim_study()` und `_sim_study_end()` (auch bei
Fehlern); geschachtelte Studien teilen den Cache der äußeren.
"""
macro study(fdef)
    body = fdef.args[2]
    # erste Zeilenangabe des Rumpfs bleibt vorn (Ort der Methode wie ohne Makro, für Stapel und Schnittstellenprüfung)
    ln = body.args[1] isa LineNumberNode ? body.args[1] : LineNumberNode(__source__.line, __source__.file)
    fin = Expr(:block, :($(SimLev)._sim_study_end(own_cache)))
    fdef.args[2] = Expr(:block, ln, :(own_cache = $(SimLev)._sim_study()), Expr(:try, body, false, false, fin))
    return esc(:(Base.@__doc__ $fdef))
end

function _sim_check_inputs(data, strategy, start_value, spread, details, dca_mode, dca_value, dca_days,
                           balance_mode, balance_days, balance_thresh, balance_thresh_type, tax_mode, tax_rate,
                           marginal_tax_rate, use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                           use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax, base_rate,
                           fractions, risk_free, split_mode, split_thresh, event_col, church_tax,
                           order_fee, dca_fee, harvest_mode, taxable_income, tariff, io::IO)
    @nospecialize
    tax_mode = match_arg(tax_mode, ("none", "person"), "tax_mode")
    if !(data isa RFrame || data isa NamedTuple || data isa AbstractDict || data isa AbstractVector{<:Pair} || data isa _Frame)
        error("simulation: data muss ein data.frame mit Spalte 'date' und je Asset einer Kursspalte sein, nicht " *
              (data === nothing ? "fehlend" : _r_class1(data)) * ".")
    end
    if strategy === nothing || length(strategy) == 0
        error("simulation: strategy muss eine nicht leere, benannte Liste von Asset-Konfigurationen sein (z. B. aus create_strategy()), nicht " *
              (strategy === nothing ? "fehlend" : "leer (Länge 0)") * ".")
    end
    spread !== nothing && @warn "simulation: Das Argument 'spread' wird nicht ausgewertet; maßgeblich ist spread je Asset (asset_config())."
    names_d = data isa RFrame ? names(data) : String[]
    dup = [nm for (i, nm) in enumerate(names_d) if nm in names_d[1:i-1]]
    if !_is_mapping(strategy) || any(p -> isempty(p.first), _kvpairs(strategy isa Union{AssetConfig,Strategy} ? collect(strategy) : strategy))
        error("simulation: Alle Assets in 'strategy' müssen benannt sein (Name = Kursspalte in 'data').")
    end
    isempty(dup) || error("simulation: Spaltenname '$(dup[1])' kommt in 'data' mehrfach vor; jede Spalte muss eindeutig benannt sein.")
    fr = _to_frame(data)
    filled_attr = fr.filled_attr
    strat = Pair{String,Dict{String,Any}}[]
    for (nm, a) in _kvpairs(strategy isa Strategy ? collect(strategy) : strategy)
        _is_mapping(a) || error("simulation: Asset '$nm' in 'strategy' muss eine Liste bzw. asset_config() sein.")
        push!(strat, nm => Dict{String,Any}(_kvpairs(a isa AssetConfig ? collect(a) : a)))
    end
    cls_ok = ["etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable"]
    for (nm, a) in strat
        ac = get(a, "asset_class", nothing)
        if !(ac isa AbstractString) || !(ac in cls_ok)
            error("simulation: asset_class $(_show_arg(ac)) von Asset '$nm' ist ungültig; erlaubt sind $(join(cls_ok[1:4], ", ")) (veraltet: etn_standard, etn_deliverable). Strategie am besten mit create_strategy()/asset_config() bauen.")
        end
        tr_ = get(a, "tax_regime", nothing)
        if tr_ !== nothing && (!(tr_ isa AbstractString) || !(tr_ in VALID_REGIMES))
            error("simulation: tax_regime $(r_deparse(tr_)) von Asset '$nm' ist ungültig; erlaubt sind investment_fund, capital_gains, private_sale (oder weglassen: aus asset_class abgeleitet). Ohne Steuern tax = NULL verwenden.")
        end
        at = get(a, "trading", nothing)
        if !(at isa AbstractString) || !(at in ("bnh", "signal"))
            error("simulation: trading $(_show_arg(at)) von Asset '$nm' ist ungültig; erlaubt sind \"bnh\" und \"signal\".")
        end
        w = get(a, "wrapper", nothing)
        if w !== nothing   # Fonds-Wrapper (wrapper.jl)
            _is_wrapper(w) || error("simulation: wrapper von Asset '$nm' muss ein Objekt aus wrapper_config() sein, nicht $(_cls_all(w)).")
            at == "bnh" || error("simulation: Asset '$nm' ist ein Fonds-Wrapper; dafür ist nur trading = \"bnh\" möglich (keine Signale auf den Anteilswert).")
        end
    end
    haskey(fr, "date") || error("simulation: Spalte 'date' fehlt in 'data'.")
    # Fonds-Wrapper: Asset-Name ist keine Kursspalte; gebraucht werden die inneren Spalten (_strategy_columns)
    wraps = _strategy_wrappers(strat)
    coll = [w for w in wraps if w in fr.names]
    isempty(coll) || error("simulation: Asset '$(coll[1])' ist ein Fonds-Wrapper (asset_config(wrapper = )); 'data' darf keine Spalte gleichen Namens enthalten (der Anteilswert wird aus den inneren Spalten gerechnet). Spalte umbenennen oder entfernen.")
    miss = [nm for nm in _strategy_columns(strat) if !haskey(fr, nm)]
    if !isempty(miss)
        error("simulation: " * (length(miss) == 1 ? "Kursspalte" : "Kursspalten") * " " *
              join(("'$m'" for m in miss), ", ") * " " * (length(miss) == 1 ? "fehlt" : "fehlen") *
              " in 'data'; je Asset der Strategie wird eine Spalte gleichen Namens erwartet (vorhanden: " *
              join((nm for nm in fr.names if nm != "date"), ", ") * ").")
    end
    _fnrow(fr) < 1 && error("simulation: 'data' enthält keine Zeilen.")
    kind = fr.kinds["date"]
    kind == :factor && (kind = :character)
    if kind == :character
        raw = fr.cols["date"]
        dd = Float64[v === missing ? NA : (z = _r_strptime_ymd(v); z === nothing ? NA : Float64(z)) for v in raw]
        bad = findfirst(i -> isnan(dd[i]) && raw[i] !== missing, eachindex(raw))
        bad === nothing || error("simulation: Spalte 'date' ist Text und '$(raw[bad])' (Zeile $bad) ist kein Datum im Format JJJJ-MM-TT; vorher mit as.Date(..., format = ...) umwandeln.")
        _fset!(fr, "date", dd, :date)
        _message("Hinweis: Spalte 'date' wurde von Text in Date umgewandelt.")
    elseif kind == :posixct
        fr.kinds["date"] = :date
        _message("Hinweis: Spalte 'date' wurde von Datum-Uhrzeit in Date umgewandelt.")
    end
    fr.kinds["date"] == :date || error("simulation: Spalte 'date' muss die Klasse Date haben (ist: $(_fr_class(fr, "date"))).")
    dvals = fr.cols["date"]::Vector{Float64}
    i_na = findfirst(isnan, dvals)
    i_na === nothing || error("simulation: Spalte 'date' enthält NA (erstmals in Zeile $i_na).")
    fa_m, fa_cols, fa_n = _filled_matrix(filled_attr)
    resorted = false
    if any(i -> dvals[i+1] < dvals[i], 1:length(dvals)-1)
        o = sortperm(dvals; alg = MergeSort)
        _ftake!(fr, o)
        resorted = true
        fa_m !== nothing && size(fa_m, 1) == length(o) && (fa_m = fa_m[o, :])
        _message("Hinweis: 'data' war nicht aufsteigend nach Datum sortiert und wurde sortiert.")
    end
    dvals = fr.cols["date"]::Vector{Float64}
    seen = Set{Float64}()
    dup_first = nothing
    n_dup = 0
    dates_ok = _memo_get("dates", dvals) !== nothing   # Studie: einmal je Datumsspalte ohne Meldung (seit 1.5.1)
    for z in (dates_ok ? Float64[] : dvals)
        if z in seen
            n_dup += 1
            dup_first === nothing && (dup_first = z)
        end
        push!(seen, z)
    end
    dup_first === nothing && !dates_ok && _memo_set("dates", dvals, true)
    dup_first === nothing || error("simulation: Datum $(fmt_date(Int(dup_first))) kommt in 'data' mehrfach vor ($n_dup doppelte Zeilen); je Tag genau eine Zeile.")
    # Fonds-Wrapper: Anteilswert je Wrapper-Asset aus den inneren Spalten (wrapper.jl) als Kursspalte mit dem
    # Asset-Namen anhängen (NA vor dem Beginn und an Tagen ohne inneren Kurs); danach ist das Asset ein
    # gewöhnliches Asset ohne wrapper. splits gelten für die inneren Spalten, nicht für den Anteilswert.
    wrapper_navs = nothing
    if !isempty(wraps)
        d_in = _fcopy(fr)
        if fa_m !== nothing && size(fa_m, 1) == _fnrow(fr)
            d_in.filled_attr = fa_cols === nothing ? Matrix{Bool}(fa_m) :
                               RFrame((String(c) => Vector{Bool}(fa_m[:, j]) for (j, c) in enumerate(fa_cols))...)
        elseif resorted
            d_in.filled_attr = nothing
        end
        sp = _is_true(split_mode) && split_thresh !== nothing ?
             RList("thresh" => _num_vec(split_thresh); class = ["SimLevSplitRule"]) : nothing
        sd = Dict(strat)
        wrapper_navs = RList()
        for nm in wraps
            wrapper_navs[nm] = _wrapper_nav_calc(d_in, sd[nm]["wrapper"], sp, "Wrapper '$nm'", "simulation: Wrapper '$nm'")
        end
        dkey = Dict{Float64,Int}(z => i for (i, z) in enumerate(fr.cols["date"]::Vector{Float64}))
        for nm in wraps
            v = fill(NA, _fnrow(fr))
            nv = wrapper_navs[nm]
            for (z, x) in zip(nv["date"], nv["nav"])
                v[dkey[Float64(to_days(z))]] = x
            end
            _fset!(fr, nm, v, :numeric)
            delete!(sd[nm], "wrapper")
        end
    end
    nrow_ = _fnrow(fr)
    if filled_attr !== nothing && fa_n != nrow_
        @warn "simulation: Attribut 'filled' von 'data' hat $fa_n Zeilen, 'data' aber $nrow_ (z. B. nach Zeilenauswahl einer series_align()-Ausgabe); es wird ignoriert, aufgefüllte Tage gelten dann als Handelstage. Zeitraum besser mit series_align(..., start =, end =) wählen."
        fa_m = nothing
    end
    pre_filled = falses(nrow_)
    if fa_m !== nothing && size(fa_m, 1) == nrow_ && fa_cols !== nothing
        fc = [nm for (nm, _) in strat if nm in fa_cols]
        if !isempty(fc)
            real = zeros(Int, nrow_)
            for nm in fc
                isna = _isna_vec(fr.cols[nm])
                j = findfirst(==(nm), fa_cols)
                for i in 1:nrow_
                    real[i] += (!fa_m[i, j] && !isna[i]) ? 1 : 0
                end
            end
            pre_filled = BitVector(real .== 0)
        end
    end
    all_na = trues(nrow_)
    for (nm, _) in strat
        all_na .&= _isna_vec(fr.cols[nm])
    end
    all_na[1] && error("simulation: In der ersten Zeile von 'data' fehlen alle Kurse (NA); mindestens ein Asset muss am ersten Tag notieren. Daten erst ab dem ersten Kurs übergeben.")
    pre_filled = pre_filled .| all_na
    for (nm, a) in strat
        _fis_numeric(fr, nm) || error("simulation: Kursspalte '$nm' muss numerisch sein (ist: $(_fr_class(fr, nm))).")
        v = fr.cols[nm]::Vector{Float64}
        bad = findfirst(x -> !isnan(x) && !(isfinite(x) && x > 0), v)
        if bad !== nothing
            error("simulation: Kursspalte '$nm' enthält ungültige Kurse (<= 0 oder unendlich), erstmals am $(fmt_date(Int(dvals[bad]))) (Wert $(r_format1(v[bad]))); erwartet werden positive Kursniveaus.")
        end
        ok = findall(!isnan, v)
        isempty(ok) && error("simulation: Kursspalte '$nm' enthält nur NA.")
        if length(ok) < length(v)
            if ok[1] > 1
                st0 = get(a, "start", nothing)
                st_new = max(Int(dvals[ok[1]]), st0 === nothing ? Int(dvals[1]) : _date_or_fail(st0))
                a["start"] = st_new
                _message("Hinweis: '$nm' hat erst ab $(fmt_date(Int(dvals[ok[1]]))) Kurse; das Asset wird wie mit start = $(fmt_date(st_new)) behandelt.")
            end
            n_gap = count(isnan, v) - (ok[1] - 1)
            n_gap > 0 && _message("Hinweis: '$nm': $n_gap fehlende Kurse (NA) per LOCF gefüllt.")
            fr.cols[nm] = _locf_fill(v)
        end
    end
    if start_value === nothing || start_value === missing || (_is_num(start_value) && isnan(Float64(start_value)))
        start_value = 10000.0
        _message("Hinweis: start_value ist NULL oder NA; verwendet wird der Standardwert 10000 EUR.")
    end
    (!_is_num(start_value) || start_value <= 0) &&
        error("simulation: start_value muss eine positive Zahl sein (Anfangskapital in EUR, z. B. 10000), nicht $(r_deparse(start_value)).")
    start_value = Float64(start_value)
    # Steuer-, Kosten-, Termin- und Split-Angaben haben die Bausteine geprüft (die Prüfungen des flachen Wegs
    # sind entfallen); fractions und risk_free prüft simulation() selbst
    tax_rate = Float64(tax_rate)
    church_tax !== nothing && (church_tax = Float64(church_tax))
    !(fractions isa Bool) && error("simulation: 'fractions' muss TRUE oder FALSE sein, nicht $(_show_arg(fractions)).")
    sparer_pauschbetrag = Float64(sparer_pauschbetrag)
    private_sale_threshold = Float64(private_sale_threshold)
    if _is_num(risk_free) && isfinite(Float64(risk_free)) && 0 < risk_free < 0.05
        @warn "simulation: risk_free = $(r_format1(risk_free)) wird als $(r_format1(risk_free)) % gelesen (Prozent-Konvention); gemeint war vermutlich $(r_format1(risk_free * 100))."
    end
    risk_free isa AbstractString && haskey(fr, risk_free) && _frac_warn_col(fr, String(risk_free), "risk_free", 0.05)
    # taxable_income und tax_tariff nur aus income_tariff() in tax_profile(), also nur mit tax_mode = "person"
    tariff_on = taxable_income !== nothing && tax_mode == "person"
    tariff_env = nothing
    if tariff_on
        y0, y1 = year_of(Int(minimum(dvals))), year_of(Int(maximum(dvals)))
        zv = _check_taxable_income(taxable_income, collect(y0:y1))
        tt = if tariff === nothing
            tax_tariff()
        elseif inherits(tariff, "SimLevTaxTariff")
            tariff
        elseif tariff isa AbstractString
            tax_tariff(tariff)
        else
            error("simulation: tax_tariff muss NULL (mitgelieferte Tarifdatei), ein Dateipfad oder ein Objekt aus tax_tariff() sein.")
        end
        tariff_env = TariffEnv()
        tariff_env.tariff = tt
        tariff_env.zve_all = zv.all
        tariff_env.zve = zv.by_year
        tariff_env.church_k = (church_tax !== nothing && church_tax > 0) ? church_tax / 100 : 0.0
        tariff_env.kapest_rate = 0.25 / (1 + 0.25 * tariff_env.church_k)
        tariff_env.use_gp = use_guenstigerpruefung
    end
    is_private(a) = get(a, "tax_regime", nothing) == "private_sale" || get(a, "asset_class", nothing) == "etn_deliverable" ||
                    (get(a, "asset_class", nothing) in ("etn", "etc") && _is_true(get(a, "deliverable", nothing)))
    has_private_sale = any(p -> is_private(p.second), strat)
    if has_private_sale && marginal_tax_rate === nothing && tax_mode == "person" && !tariff_on
        @warn "simulation: Der Grenzsteuersatz ist nicht gesetzt (tax_profile(income = income_rate(marginal_rate))), die Strategie enthält aber Assets mit tax_regime = \"private_sale\"; Gewinne nach Paragraf 23 EStG werden dann möglicherweise nicht korrekt besteuert. income_rate(marginal_rate) in Prozent angeben (z. B. 42)."
    end
    # Kirchensteuer, Prozent-Konvention und Günstigerprüfung: _tax_rates() (unten, nach der Gewichtssumme)
    bth = balance_thresh === nothing ? nothing : Float64(balance_thresh) / 100
    balance_thresh_type = match_arg(balance_thresh_type, ("absolute", "relative"), "balance_thresh_type")
    fee_order = _fee_spec(order_fee)
    fee_dca = dca_fee === nothing ? fee_order : _fee_spec(dca_fee)
    fees_on = fee_order !== nothing || fee_dca !== nothing
    if _truthy_mode(dca_mode)
        dca_value = Float64(dca_value)
    end
    shares = Float64[(s = get(a, "share", nothing); s === nothing ? NA : Float64(s)) for (_, a) in strat]
    total_weight = r_sum(shares; na_rm = true)
    if abs(total_weight - 1.0) > 1e-6
        error(r_sprintf("simulation: Asset-Gewichte (share) summieren sich auf %.4f, müssen aber exakt 1.0 ergeben (Anteile, z. B. 0.6 und 0.4).\n  Aktuelle Gewichte: %s",
                        total_weight, join((r_sprintf("%s=%.3f", k, (s = get(v, "share", nothing); s === nothing ? NA : Float64(s))) for (k, v) in strat), ", ")))
    end
    # Steuersätze (Kirchensteuer, Prozent -> Anteil, Günstigerprüfung) im gemeinsamen Helfer (seit 1.1.0 auch für
    # withdrawal_simulation()); Rechenfolge, Warnungen und Druck wie bisher an dieser Stelle
    tr = _tax_rates(tax_rate, church_tax, use_guenstigerpruefung, marginal_tax_rate, include_soli_on_income_tax,
                    soli_rate_income_tax, "simulation"; details = details == true, tariff_on = tariff_on, io = io)
    tax_rate = tr.tax_rate; mtr = tr.marginal_tax_rate; effective_tax_rate = tr.effective_tax_rate
    soli_factor_income = tr.soli_factor_income; church_k = tr.church_k
    cfg = Cfg(tax_mode, start_value, tax_rate, mtr, effective_tax_rate, soli_factor_income, church_k, tariff_env,
              private_sale_threshold, sparer_pauschbetrag, use_sparer_pauschbetrag, fractions, fee_order, fee_dca, fees_on,
              order_fee, dca_mode, dca_value, dca_days, balance_mode, balance_days, bth, balance_thresh_type, base_rate,
              risk_free, harvest_mode, split_mode, event_col, BitVector(pre_filled), strat,
              String[w for w in wraps], details == true ? wrapper_navs : nothing)
    return cfg, fr
end

function _locf_fill(v::Vector{Float64})
    nonna = findall(!isnan, v)
    isempty(nonna) && return v
    out = similar(v)
    last = nonna[1]
    @inbounds for i in eachindex(v)
        isnan(v[i]) || (last = i)
        out[i] = v[last]
    end
    return out
end

function _sim_prepare_data(fr::_Frame, pre_filled::BitVector, base_rate_flex, base_rate_data)
    @nospecialize
    dates = fr.cols["date"]::Vector{Float64}
    start_date = Int(dates[1])
    stopp_date = Int(dates[end])
    flex = _is_true(base_rate_flex) && base_rate_data isa AbstractString && haskey(fr, base_rate_data)
    flex && _frac_warn_col(fr, String(base_rate_data), "base_rate", 0.05)
    if flex
        col = fr.cols[base_rate_data]
        k = fr.kinds[base_rate_data]
        if k == :numeric && any(isnan, col)
            fr.cols[base_rate_data] = Float64[isnan(x) ? 0.0 : x for x in col]
        elseif k != :numeric && all(_isna_val, col)
            _fset!(fr, String(base_rate_data), zeros(length(col)), :numeric)
        end
    end
    expected_days = (stopp_date - start_date) + 1
    nr = _fnrow(fr)
    if nr != expected_days
        _message("Hinweis: $nr Zeilen, erwartet $expected_days Kalendertage. Fehlende Tage werden aufgefüllt (LOCF; Signale = FALSE).")
        n = expected_days
        # Zeile je Kalendertag und Zahlenspalten mit LOCF seit 1.6.0 im Kern (sl_cal_index, sl_cal_fill_real)
        src0 = SimLev.SLib.cal_index(Float64[Float64(Int(z)) for z in dates], Float64(start_date), n)
        src = Int[s + 1 for s in src0]                     # 1-basiert, 0 = kein Kurs
        new_cols = Dict{String,AbstractVector}("date" => Float64.(start_date:stopp_date))
        new_kinds = Dict{String,Symbol}("date" => :date)
        nms = ["date"; [nm for nm in fr.names if nm != "date"]]
        for nm in nms[2:end]
            v = fr.cols[nm]; k = fr.kinds[nm]
            if k in (:numeric, :date, :posixct)
                out = SimLev.SLib.cal_fill_real(src0, Vector{Float64}(v), k == :numeric)
            elseif k == :logical
                out = Vector{Union{Missing,Bool}}(undef, n)
                for j in 1:n
                    out[j] = src[j] > 0 ? (v[src[j]] === missing ? false : v[src[j]]) : false
                end
            else
                out = Vector{Any}(nothing, n)
                for j in 1:n
                    src[j] > 0 && (out[j] = v[src[j]])
                end
            end
            new_cols[nm] = out; new_kinds[nm] = k
        end
        filled = trues(n)
        for j in 1:n
            src[j] > 0 && (filled[j] = pre_filled[src[j]])
        end
        new_cols[".filled"] = filled; new_kinds[".filled"] = :filled
        push!(nms, ".filled")
        fr.names, fr.cols, fr.kinds = nms, new_cols, new_kinds
    elseif any(pre_filled)
        _fset!(fr, ".filled", BitVector(pre_filled), :filled)
    end
    return start_date, stopp_date
end

function _signal_col(fr::_Frame, col, n::Int)
    @nospecialize
    col === nothing && return Signal(true, zeros(n))
    v = fr.cols[col]
    k = fr.kinds[col]
    k == :numeric && return Signal(false, copy(v))
    k == :logical && return Signal(true, _signal_logical(v))
    return Signal(false, _signal_other(v))
end

# Funktionsgrenze (seit 1.5.2): die Schleifen werden je Spaltentyp übersetzt (fr.cols ist Dict{String,AbstractVector})
_signal_logical(v::AbstractVector) = Float64[x === missing ? NA : (x ? 1.0 : 0.0) for x in v]
# andere Spaltenarten: wahr, wenn ein Wert vorliegt und nicht FALSE/0 ist
_signal_other(v::AbstractVector) = Float64[_isna_val(x) ? NA : ((x === false || x == 0) ? 0.0 : 1.0) for x in v]

function _sim_build_state(fr::_Frame, strategy, start_date::Int, stopp_date::Int,
                          sparer_pauschbetrag::Float64, use_spb::Bool, base_rate, base_rate_flex, base_rate_data)
    @nospecialize
    n = _fnrow(fr)
    totals = Totals(0.0, 0.0, 0.0, 0.0, 0.0, sparer_pauschbetrag, use_spb ? sparer_pauschbetrag : 0.0,
                    0.0, year_of(start_date), 0.0, 0.0, 0.0, 0.0, VPPending[], Pair{Int,Float64}[], Pair{Int,Float64}[])
    names_ = String[]; assets = AssetInfo[]; status = Status[]; market = Market[]; trades = Trades[]; report = Report[]
    days = collect(start_date:stopp_date)
    for (name, a) in strategy
        ac = get(a, "asset_class", nothing)
        deliverable = _is_true(get(a, "deliverable", nothing))
        regime = get(a, "tax_regime", nothing)
        if regime === nothing
            regime = ac == "etf" ? "investment_fund" :
                     ac in ("etn", "etc") ? (deliverable ? "private_sale" : "capital_gains") :
                     ac == "etn_deliverable" ? "private_sale" : "capital_gains"
        end
        st_raw = get(a, "start", nothing)
        bonus = get(a, "partial_exemption", nothing)
        dl = get(a, "deliverable", nothing)
        push!(names_, name)
        push!(assets, AssetInfo(ac, get(a, "trading", ""), st_raw === nothing ? start_date : _date_or_fail(st_raw),
                                regime, (bonus === nothing ? 0.0 : Float64(bonus)) / 100, dl === nothing ? false : dl))
        if get(a, "trading", nothing) == "signal"
            sb, ss = get(a, "signal_buy", nothing), get(a, "signal_sell", nothing)
            (sb === nothing || !haskey(fr, sb)) &&
                error("simulation: signal_buy-Spalte '$(sb === nothing ? "NULL" : sb)' fehlt im Datensatz (Asset '$name').")
            (ss === nothing || !haskey(fr, ss)) &&
                error("simulation: signal_sell-Spalte '$(ss === nothing ? "NULL" : ss)' fehlt im Datensatz (Asset '$name').")
        end
        push!(status, Status(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0))   # setzt der Kern
        local br::Vector{Float64}
        if _truthy_mode(base_rate_flex)
            if base_rate_data === nothing || !haskey(fr, base_rate_data)
                base_rate_data === nothing && error("simulation: base_rate_flex = TRUE braucht base_rate_data (Name der Basiszins-Spalte in data, Prozent p. a.); base_rate_data fehlt.")
                error("simulation: base_rate-Spalte '$base_rate_data' fehlt in data (tax_profile(base_rate = \"$base_rate_data\") braucht eine Basiszins-Spalte in Prozent p. a.; vorhanden: $(join(fr.names, ", "))).")
            end
            col = fr.cols[base_rate_data]
            br = Float64[_isna_val(x) ? 0.0 : Float64(x) for x in col]
        else
            br = fill(base_rate === nothing ? 0.0 : Float64(base_rate), n)
        end
        spread_a = get(a, "spread", nothing)
        push!(market, Market(days, br, copy(fr.cols[name]::Vector{Float64}), _signal_col(fr, get(a, "signal_buy", nothing), n),
                             _signal_col(fr, get(a, "signal_sell", nothing), n),
                             (spread_a === nothing ? 0.0 : Float64(spread_a)) / 100))
        push!(trades, Trades(Lot[], SellEntry[], TaxEntry[], 1))
        push!(report, Report(zeros(n), zeros(n), zeros(n), zeros(n), zeros(n)))
    end
    return Sim(names_, assets, status, market, trades, report, totals)
end

"""Angaben der Termine und Tages-Flags (wie `.sim_build_calendar` in R): Kalender, Terminpläne (`_sched_spec`),
Ereignis-Spalte und die Prüfungen; Termine, Splits, Flags, Aktivierung, Freibetrag und Startgewichte rechnet
der Kern (core/prepare_core_impl.h, über `_sim_engine_run!`)."""
function _sim_build_calendar(fr::_Frame, sim::Sim, strategy, start_date::Int, stopp_date::Int,
                             dca_mode, dca_span, dca_unit, dca_days, dca_value, dca_anchor, dca_start, dca_skip,
                             balance_mode, balance_span, balance_unit, balance_days, balance_anchor, balance_start,
                             balance_skip, event_col, event_mode, event_weight)
    @nospecialize
    flag_date = collect(start_date:stopp_date)
    n = length(flag_date)
    flag_filled = haskey(fr, ".filled") ? BitVector(fr.cols[".filled"]) : falses(n)
    _fdrop!(fr, ".filled")
    flag_assets = [p.first for p in strategy]
    for (a, sd0, mode) in (("dca", dca_start, dca_mode), ("balance", balance_start, balance_mode))
        (!_is_true(mode) || sd0 === nothing) && continue
        sd1 = _as_date(sd0)
        sd1 === nothing && error("simulation: $(a)_start = '$(sd0 isa AbstractString ? sd0 : r_format1(sd0))' ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\").")
        sd1 > stopp_date && error("simulation: $("start von " * (a == "dca" ? "dca_plan()" : "rebalance_plan()")) ($(fmt_date(sd1))) liegt nach dem letzten Datentag ($(fmt_date(stopp_date))); es gäbe keine Termine.")
    end
    balance = _sched_spec(balance_mode, balance_span, balance_unit, balance_days, flag_date, nothing, balance_anchor,
                         balance_start, balance_skip)
    dca = _sched_spec(dca_mode, dca_span, dca_unit, dca_days, flag_date, dca_value, dca_anchor, dca_start, dca_skip)
    event_mode = match_arg(event_mode, ("additional", "replace"), "event_mode")
    flag_event = nothing
    ew = nothing
    if event_col !== nothing
        haskey(fr, event_col) || error("simulation: event_col '$event_col' nicht im Datensatz gefunden.")
        flag_event = _as_logical_col(fr, String(event_col))
        if event_weight !== nothing
            (_is_mapping(event_weight) && !any(p -> isempty(p.first), _kvpairs(event_weight))) ||
                error("simulation: event_weight muss benannt sein (Asset = Spaltenname), z. B. c(A = \"wA\", B = \"wB\").")
            ew = _kvpairs(event_weight isa RVector ? [n_ => v for (n_, v) in zip(event_weight.names, event_weight.values)] : event_weight)
            unk = [k for (k, _) in ew if !(k in flag_assets)]
            isempty(unk) || error("simulation: event_weight nennt unbekannte Assets: $(join(unk, ", ")).")
            for (nm, col) in ew
                if !(col isa AbstractString) || !haskey(fr, col)
                    error("simulation: event_weight-Spalte '$(col isa Union{AbstractVector,Tuple} ? join(string.(col), ",") : string(col))' (Asset '$nm') fehlt in 'data'.")
                end
                _fis_numeric(fr, col) || error("simulation: event_weight-Spalte '$col' muss nicht negative Zahlen enthalten.")
                wv = fr.cols[col][flag_event]
                any(x -> !isnan(x) && x < 0, wv) && error("simulation: event_weight-Spalte '$col' muss nicht negative Zahlen enthalten.")
            end
            fehlt = [nm for nm in flag_assets if !any(p -> p.first == nm, ew)]
            isempty(fehlt) || @warn "simulation: event_weight nennt nicht alle Assets (es fehlt: $(join(fehlt, ", "))); an Event-Tagen gelten dann die Strategie-Gewichte."
        end
    end
    for (a, name) in enumerate(flag_assets)
        st_a = sim.assets[a].start
        st_a > stopp_date && error("simulation: start von '$name' ($(fmt_date(st_a))) liegt nach dem letzten Datentag ($(fmt_date(stopp_date))); das Asset wäre nie handelbar. start auf ein Datum im Datenzeitraum setzen oder das Asset aus der Strategie entfernen.")
    end
    # bis 1.3.0 _sim_init_weights!: mindestens ein Asset ab dem ersten Tag handelbar
    any(a -> sim.assets[a].start <= flag_date[1], eachindex(flag_assets)) ||
        error("simulation: Kein Asset ist am ersten Datentag ($(fmt_date(flag_date[1]))) handelbar (start bzw. erste Kurse später); mindestens ein Asset muss ab Beginn handelbar sein.")
    fl = Flags(flag_date, flag_filled, flag_assets, dca, balance, flag_event, event_mode == "replace", falses(n), String[])
    return fl, ew
end
