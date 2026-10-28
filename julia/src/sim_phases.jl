# ─────────────────────────────────────────────────────────────────────────────
# simulation(), Phasen 1–2: Eingabeprüfung (sim_validate.R), Datenvorbereitung,
# Zentralstruktur, Termine und Ablaufplan (sim_prepare.R)
# ─────────────────────────────────────────────────────────────────────────────

"`given` aus simulation(): welche Argumente ausdrücklich angegeben wurden."
struct _Given
    d::Dict{String,Bool}
end
_g(g::_Given, k::String) = g.d[k]

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

function _sim_check_inputs(data, strategy, start_value, spread, details, dca_mode, dca_value, dca_span, dca_days,
                           balance_mode, balance_days, balance_thresh, balance_thresh_type, tax_mode, tax_rate,
                           marginal_tax_rate, use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                           use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax, base_rate,
                           funds_fee, bonus_fee, fractions, risk_free, split_mode, split_thresh, event_col, church_tax,
                           order_fee, dca_fee, harvest_mode, harvest_day, taxable_income, tariff, given::_Given,
                           io::IO, blocks::Bool = false)
    @nospecialize
    tax_mode = match_arg(tax_mode, ("none", "person", "funds"), "tax_mode")
    if !(data isa RFrame || data isa NamedTuple || data isa AbstractDict || data isa AbstractVector{<:Pair})
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
            error("simulation: tax_regime $(r_deparse(tr_)) von Asset '$nm' ist ungültig; erlaubt sind investment_fund, capital_gains, private_sale (oder weglassen: aus asset_class abgeleitet). Ohne Steuern $(blocks ? "tax = NULL" : "tax_mode = \"none\"") verwenden.")
        end
        at = get(a, "trading", nothing)
        if !(at isa AbstractString) || !(at in ("bnh", "signal"))
            error("simulation: trading $(_show_arg(at)) von Asset '$nm' ist ungültig; erlaubt sind \"bnh\" und \"signal\".")
        end
    end
    haskey(fr, "date") || error("simulation: Spalte 'date' fehlt in 'data'.")
    miss = [nm for (nm, _) in strat if !haskey(fr, nm)]
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
    if any(i -> dvals[i+1] < dvals[i], 1:length(dvals)-1)
        o = sortperm(dvals; alg = MergeSort)
        _ftake!(fr, o)
        fa_m !== nothing && size(fa_m, 1) == length(o) && (fa_m = fa_m[o, :])
        _message("Hinweis: 'data' war nicht aufsteigend nach Datum sortiert und wurde sortiert.")
    end
    dvals = fr.cols["date"]::Vector{Float64}
    seen = Set{Float64}()
    dup_first = nothing
    n_dup = 0
    for z in dvals
        if z in seen
            n_dup += 1
            dup_first === nothing && (dup_first = z)
        end
        push!(seen, z)
    end
    dup_first === nothing || error("simulation: Datum $(fmt_date(Int(dup_first))) kommt in 'data' mehrfach vor ($n_dup doppelte Zeilen); je Tag genau eine Zeile.")
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
    if !blocks && (!_is_num(tax_rate) || isnan(Float64(tax_rate)) || tax_rate < 0 || tax_rate > 100)
        error("simulation: tax_rate muss eine einzelne Zahl in Prozent zwischen 0 und 100 sein (z. B. 26.375 für 26,375 %), nicht $(r_deparse(tax_rate)).")
    end
    tax_rate = Float64(tax_rate)
    !blocks && 0 < tax_rate < 1 && @warn "simulation: tax_rate = $(r_format1(tax_rate)) wird als $(r_format1(tax_rate)) % gelesen (Prozent-Konvention); gemeint war vermutlich $(r_format1(tax_rate * 100))."
    if church_tax !== nothing
        if !blocks && (!_is_num(church_tax) || isnan(Float64(church_tax)) || church_tax < 0 || church_tax > 100)
            error("simulation: church_tax muss eine Zahl in Prozent zwischen 0 und 100 sein (in Deutschland 8 oder 9), nicht $(join(r_format(church_tax), ", ")).")
        end
        church_tax = Float64(church_tax)
        if blocks
        elseif 0 < church_tax < 1
            @warn "simulation: church_tax = $(r_format1(church_tax)) wird als $(r_format1(church_tax)) % gelesen (Prozent-Konvention); gemeint war vermutlich $(r_format1(church_tax * 100))."
        elseif church_tax > 9
            @warn "simulation: church_tax = $(r_format1(church_tax)) % ist ungewöhnlich hoch (Kirchensteuer in Deutschland: 8 oder 9 %)."
        end
    end
    !blocks && _is_true(harvest_mode) && tax_mode != "person" && @warn "simulation: harvest_mode wirkt nur mit tax_mode = \"person\" und wird hier ignoriert."
    # Fondsmodus mit tax_profile(harvest = ...)
    blocks && _is_true(harvest_mode) && tax_mode != "person" && @warn "simulation: harvest (tax_profile(harvest = harvest_rule())) wirkt nicht im Fondsmodus (funds = funds_costs()) und wird hier ignoriert."
    function chk_num(x, arg, what; mn = 0.0, null_ok = false)
        (x === nothing && null_ok || blocks) && return
        if !_is_num(x) || !isfinite(Float64(x)) || (mn !== nothing && x < mn)
            error("simulation: '$arg' muss $what sein, nicht $(_show_arg(x)).")
        end
    end
    chk_num(sparer_pauschbetrag, "sparer_pauschbetrag", "eine einzelne endliche Zahl >= 0 (EUR je Jahr, z. B. 1000)")
    chk_num(private_sale_threshold, "private_sale_threshold", "eine einzelne endliche Zahl >= 0 (Freigrenze in EUR, z. B. 1000)")
    chk_num(base_rate, "base_rate", "NULL oder eine einzelne endliche Zahl (Basiszins in Prozent, z. B. 2.29; negativ erlaubt)";
            mn = nothing, null_ok = true)
    chk_num(marginal_tax_rate, "marginal_tax_rate", "NULL oder eine einzelne Zahl in Prozent von 0 bis 50 (z. B. 42)"; null_ok = true)
    chk_num(balance_thresh, "balance_thresh", "NULL oder eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5)"; null_ok = true)
    for (a, x) in (("use_guenstigerpruefung", use_guenstigerpruefung), ("include_soli_on_income_tax", include_soli_on_income_tax),
                   ("fractions", fractions), ("use_sparer_pauschbetrag", use_sparer_pauschbetrag))
        (!blocks || a == "fractions") && !(x isa Bool) && error("simulation: '$a' muss TRUE oder FALSE sein, nicht $(_show_arg(x)).")
    end
    sparer_pauschbetrag = Float64(sparer_pauschbetrag)
    private_sale_threshold = Float64(private_sale_threshold)
    function frac_warn(x, arg, hi = 1.0)
        blocks && arg != "risk_free" && return
        if _is_num(x) && isfinite(Float64(x)) && 0 < x < hi
            @warn "simulation: $arg = $(r_format1(x)) wird als $(r_format1(x)) % gelesen (Prozent-Konvention); gemeint war vermutlich $(r_format1(x * 100))."
        end
    end
    frac_warn(base_rate, "base_rate", 0.05)
    frac_warn(marginal_tax_rate, "marginal_tax_rate")
    frac_warn(balance_thresh, "balance_thresh", 0.2)
    frac_warn(risk_free, "risk_free", 0.05)
    risk_free isa AbstractString && haskey(fr, risk_free) && _frac_warn_col(fr, String(risk_free), "risk_free", 0.05)
    !blocks && !_is_true(dca_mode) && dca_value !== nothing && @warn "simulation: dca_value wirkt nur mit dca_mode = TRUE und wird ignoriert."
    if !blocks && !_is_true(balance_mode) && event_col === nothing && balance_thresh !== nothing
        @warn "simulation: balance_thresh wirkt nur mit balance_mode = TRUE oder event_col (Rebalancing) und wird ignoriert."
    end
    event_col === nothing && _g(given, "event_mode") && @warn "simulation: event_mode wirkt nur zusammen mit event_col und wird ignoriert."
    function check_days(x, arg)
        (x === nothing || blocks) && return
        v = _num_vec(x)
        if v === nothing || any(isnan, v) || any(d -> d < 1 || d > 31 || d != r_round(d), v)
            shown = r_format(x isa Union{AbstractVector,Tuple} ? collect(Any, x) : x)
            error("simulation: $arg muss ganze Zahlen von 1 bis 31 enthalten, nicht $(join(shown, ", ")).")
        end
    end
    check_days(dca_days, "dca_days")
    check_days(balance_days, "balance_days")
    days_out = Dict{String,Any}()
    for (a, x) in (("dca_days", dca_days), ("balance_days", balance_days))
        if x !== nothing && !blocks
            v = _num_vec(x)
            u = unique(v)
            if length(u) < length(v)
                @warn "simulation: $a enthält doppelte Tage ($(join(r_format(v), ", "))); jeder Tag ergibt nur einen Termin, verwendet wird $a = $(r_deparse(u))."
                x = u
            end
        end
        days_out[a] = x
    end
    dca_days, balance_days = days_out["dca_days"], days_out["balance_days"]
    if !blocks && _is_true(split_mode) && split_thresh !== nothing
        st_v = _num_vec(split_thresh)
        if st_v === nothing || length(st_v) != 2 || any(isnan, st_v)
            shown = r_format(split_thresh isa Union{AbstractVector,Tuple} ? collect(Any, split_thresh) : split_thresh)
            error("simulation: split_thresh muss ein Zahlenvektor c(untere, obere) der Länge 2 sein, nicht $(join(shown, ", ")).")
        end
        if !(st_v[1] < 100 < st_v[2])
            @warn "simulation: split_thresh = c($(r_format1(st_v[1])), $(r_format1(st_v[2]))) schließt den Zielkurs 100 nicht ein (erwartet untere < 100 < obere). Ein Split setzt den Kurs auf 100; liegt 100 außerhalb der Schwellen, folgt danach an jedem Tag ein weiterer Split (mit fractions = FALSE jeweils mit Spitzenausgleich)."
        end
    end
    if tax_mode != "funds" && (_g(given, "funds_fee") || _g(given, "bonus_fee"))
        gv = [a for a in ("funds_fee", "bonus_fee") if given.d[a]]
        @warn "simulation: $(join(gv, " und ")) wirkt nur bei tax_mode = \"funds\" (hier tax_mode = \"$tax_mode\") und wird ignoriert."
    end
    if tax_mode == "funds" && !blocks
        for (a, x) in (("funds_fee", funds_fee), ("bonus_fee", bonus_fee))
            if !_is_num(x) || isnan(Float64(x)) || x < 0 || x > 100
                error("simulation: $a muss eine Zahl in Prozent zwischen 0 und 100 sein (z. B. " *
                      (a == "funds_fee" ? "0.95 für 0,95 % p. a." : "5 für 5 %") * "), nicht " *
                      (x !== nothing ? join(r_format(x), ", ") : "NULL") * ".")
            end
        end
    end
    tariff_on = taxable_income !== nothing && tax_mode == "person"
    taxable_income !== nothing && tax_mode != "person" && @warn(blocks ? "simulation: income_tariff() (tax_profile(income =)) wirkt nicht im Fondsmodus (funds = funds_costs()) und wird ignoriert." :
        "simulation: taxable_income wirkt nur bei tax_mode = \"person\" (hier \"$tax_mode\") und wird ignoriert.")
    taxable_income === nothing && tariff !== nothing && @warn "simulation: tax_tariff wirkt nur zusammen mit taxable_income (zu versteuerndes Einkommen je Jahr) und wird ignoriert."
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
        ign = [a for (a, g) in (("marginal_tax_rate", _g(given, "marginal_tax_rate") && marginal_tax_rate !== nothing),
                                ("include_soli_on_income_tax", _g(given, "include_soli_on_income_tax")),
                                ("soli_rate_income_tax", _g(given, "soli_rate_income_tax"))) if g]
        isempty(ign) || @warn "simulation: Mit taxable_income gilt der Einkommensteuertarif der Tarifdatei (ESt und Soli); $(join(ign, ", ")) wirkt dann nicht."
    end
    is_private(a) = get(a, "tax_regime", nothing) == "private_sale" || get(a, "asset_class", nothing) == "etn_deliverable" ||
                    (get(a, "asset_class", nothing) in ("etn", "etc") && _is_true(get(a, "deliverable", nothing)))
    has_private_sale = any(p -> is_private(p.second), strat)
    if has_private_sale && marginal_tax_rate === nothing && tax_mode == "person" && !tariff_on && blocks
        @warn "simulation: Der Grenzsteuersatz ist nicht gesetzt (tax_profile(income = income_rate(marginal_rate))), die Strategie enthält aber Assets mit tax_regime = \"private_sale\"; Gewinne nach Paragraf 23 EStG werden dann möglicherweise nicht korrekt besteuert. income_rate(marginal_rate) in Prozent angeben (z. B. 42)."
    elseif has_private_sale && marginal_tax_rate === nothing && tax_mode == "person" && !tariff_on
        @warn "simulation: marginal_tax_rate ist nicht gesetzt, die Strategie enthält aber Assets mit tax_regime = \"private_sale\"; Gewinne nach Paragraf 23 EStG werden dann möglicherweise nicht korrekt besteuert. marginal_tax_rate in Prozent angeben (z. B. 42)."
    end
    if !blocks && marginal_tax_rate !== nothing && (marginal_tax_rate < 0 || marginal_tax_rate > 50)
        error("simulation: marginal_tax_rate muss ein Grenzsteuersatz in Prozent zwischen 0 und 50 sein (z. B. 42 für 42 %), nicht $(r_deparse(marginal_tax_rate)).")
    end
    if church_tax !== nothing && church_tax > 0
        _g(given, "tax_rate") && abs(tax_rate - 26.375) > 1e-9 && @warn "church_tax überschreibt das angegebene tax_rate."
        k = church_tax / 100
        tax_rate = 100 * 0.25 / (1 + 0.25 * k) * (1 + 0.055 + k)
    end
    church_k = (church_tax !== nothing && church_tax > 0) ? church_tax / 100 : 0.0
    tax_rate = tax_rate / 100
    mtr = marginal_tax_rate === nothing ? nothing : Float64(marginal_tax_rate) / 100
    soli_rate = Float64(soli_rate_income_tax) / 100
    bth = balance_thresh === nothing ? nothing : Float64(balance_thresh) / 100
    balance_thresh_type = match_arg(balance_thresh_type, ("absolute", "relative"), "balance_thresh_type")
    fee_order = _fee_spec(order_fee)
    fee_dca = dca_fee === nothing ? fee_order : _fee_spec(dca_fee)
    fees_on = fee_order !== nothing || fee_dca !== nothing
    if _is_true(harvest_mode) && !blocks
        if !(harvest_day isa AbstractString) || !occursin(r"^\d{2}-\d{2}$", harvest_day) || harvest_day >= "12-31"
            error("harvest_day im Format 'MM-TT' und vor dem 31.12. angeben (z. B. '12-15').")
        end
    end
    if _truthy_mode(dca_mode)
        one_num(x) = _is_num(x) && isfinite(Float64(x))
        !blocks && (!one_num(dca_value) || dca_value <= 0) &&
            error("simulation: 'dca_value' muss bei dca_mode = TRUE eine einzelne endliche Zahl > 0 sein (Betrag je Sparplan-Termin in EUR), nicht $(_show_arg(dca_value)).")
        !blocks && (!one_num(dca_span) || dca_span < 1 || dca_span != r_round(Float64(dca_span))) &&
            error("simulation: 'dca_span' muss bei dca_mode = TRUE eine einzelne ganze Zahl >= 1 sein (Perioden zwischen zwei Terminen), nicht $(_show_arg(dca_span)).")
        dca_value = Float64(dca_value)
    end
    shares = Float64[(s = get(a, "share", nothing); s === nothing ? NA : Float64(s)) for (_, a) in strat]
    total_weight = r_sum(shares; na_rm = true)
    if abs(total_weight - 1.0) > 1e-6
        error(r_sprintf("simulation: Asset-Gewichte (share) summieren sich auf %.4f, müssen aber exakt 1.0 ergeben (Anteile, z. B. 0.6 und 0.4).\n  Aktuelle Gewichte: %s",
                        total_weight, join((r_sprintf("%s=%.3f", k, (s = get(v, "share", nothing); s === nothing ? NA : Float64(s))) for (k, v) in strat), ", ")))
    end
    effective_tax_rate = tax_rate
    if use_guenstigerpruefung && !tariff_on
        if mtr === nothing && blocks
            @warn "simulation: Günstigerprüfung aktiviert (tax_profile(guenstigerpruefung = TRUE)), aber der Grenzsteuersatz (income_rate(marginal_rate)) ist nicht gesetzt.\nVerwendet wird die Abgeltungsteuer (" *
                  r_as_character(r_round(tax_rate * 100, 2)) * " %).\nFür eine korrekte Günstigerprüfung tax_profile(income = income_rate(marginal_rate)) in Prozent angeben (z. B. 42)."
        elseif mtr === nothing
            @warn "simulation: Günstigerprüfung aktiviert (use_guenstigerpruefung = TRUE), aber 'marginal_tax_rate' ist nicht gesetzt.\nVerwendet wird die Abgeltungsteuer (" *
                  r_as_character(r_round(tax_rate * 100, 2)) * " %).\nFür eine korrekte Günstigerprüfung marginal_tax_rate in Prozent angeben (z. B. 42)."
        else
            personal_rate = mtr * ((include_soli_on_income_tax ? (1 + soli_rate) : 1.0) + church_k)
            if personal_rate < tax_rate
                effective_tax_rate = personal_rate
                details == true && print(io, r_sprintf("═══ Günstigerprüfung aktiv ═══\n  Persönlicher Steuersatz: %.2f%%\n  Effektiver Steuersatz: %.2f%% (statt %.2f%% Abgeltungsteuer)\n  Ersparnis: %.2f Prozentpunkte\n\n",
                                                       mtr * 100, effective_tax_rate * 100, tax_rate * 100, (tax_rate - effective_tax_rate) * 100))
            else
                details == true && print(io, r_sprintf("═══ Günstigerprüfung geprüft ═══\n  Persönlicher Steuersatz: %.2f%%\n  Abgeltungsteuer: %.2f%% → bleibt günstiger\n\n",
                                                       personal_rate * 100, tax_rate * 100))
            end
        end
    end
    soli_factor_income = include_soli_on_income_tax ? (1 + soli_rate) : 1.0
    cfg = Cfg(tax_mode, start_value, tax_rate, mtr, effective_tax_rate, soli_factor_income, church_k, tariff_env,
              private_sale_threshold, sparer_pauschbetrag, use_sparer_pauschbetrag, fractions, fee_order, fee_dca, fees_on,
              order_fee, dca_mode, dca_value, dca_days, balance_mode, balance_days, bth, balance_thresh_type, base_rate,
              risk_free, harvest_mode, split_mode, event_col, BitVector(pre_filled), strat)
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

function _sim_prepare_data(fr::_Frame, pre_filled::BitVector, base_rate_flex, base_rate_data, blocks::Bool = false)
    @nospecialize
    dates = fr.cols["date"]::Vector{Float64}
    start_date = Int(dates[1])
    stopp_date = Int(dates[end])
    flex = _is_true(base_rate_flex) && base_rate_data isa AbstractString && haskey(fr, base_rate_data)
    flex && _frac_warn_col(fr, String(base_rate_data), blocks ? "base_rate" : "base_rate_data", 0.05)
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
        src = zeros(Int, n)
        for (i, z) in enumerate(dates)
            src[Int(z) - start_date + 1] = i
        end
        new_cols = Dict{String,AbstractVector}("date" => Float64.(start_date:stopp_date))
        new_kinds = Dict{String,Symbol}("date" => :date)
        nms = ["date"; [nm for nm in fr.names if nm != "date"]]
        for nm in nms[2:end]
            v = fr.cols[nm]; k = fr.kinds[nm]
            if k in (:numeric, :date, :posixct)
                out = fill(NA, n)
                for j in 1:n
                    src[j] > 0 && (out[j] = v[src[j]])
                end
                k == :numeric && (out = _locf_fill(out))
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
    if k == :logical
        return Signal(true, Float64[x === missing ? NA : (x ? 1.0 : 0.0) for x in v])
    end
    # andere Spaltenarten: wahr, wenn ein Wert vorliegt und nicht FALSE/0 ist
    return Signal(false, Float64[_isna_val(x) ? NA : ((x === false || x == 0) ? 0.0 : 1.0) for x in v])
end

function _sim_build_state(fr::_Frame, strategy, start_value::Float64, start_date::Int, stopp_date::Int,
                          sparer_pauschbetrag::Float64, use_spb::Bool, base_rate, base_rate_flex, base_rate_data,
                          blocks::Bool = false)
    @nospecialize
    n = _fnrow(fr)
    totals = Totals(start_value, 0.0, 0.0, 0.0, 0.0, 0.0, sparer_pauschbetrag, use_spb ? sparer_pauschbetrag : 0.0,
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
        share = Float64(a["share"])
        push!(status, Status(0.0, 0.0, 0.0, share * start_value, share * start_value, share, share, 0.0))
        local br::Vector{Float64}
        if _truthy_mode(base_rate_flex)
            if base_rate_data === nothing || !haskey(fr, base_rate_data)
                base_rate_data === nothing && error("simulation: base_rate_flex = TRUE braucht base_rate_data (Name der Basiszins-Spalte in data, Prozent p. a.); base_rate_data fehlt.")
                blocks && error("simulation: base_rate-Spalte '$base_rate_data' fehlt in data (tax_profile(base_rate = \"$base_rate_data\") braucht eine Basiszins-Spalte in Prozent p. a.; vorhanden: $(join(fr.names, ", "))).")
                error("simulation: base_rate_data-Spalte '$base_rate_data' fehlt in data (base_rate_flex = TRUE braucht eine Basiszins-Spalte in Prozent p. a.; vorhanden: $(join(fr.names, ", "))).")
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
        push!(trades, Trades(Lot[], SellEntry[], TaxEntry[], FeeEntry[], 1))
        st = status[end]
        worth0 = zeros(n); money0 = zeros(n); total0 = zeros(n)
        worth0[1], money0[1], total0[1] = st.worth, st.money, st.total
        push!(report, Report(worth0, money0, zeros(n), total0, zeros(n)))
    end
    return Sim(names_, assets, status, market, trades, report, totals)
end

function _sim_build_calendar(fr::_Frame, sim::Sim, strategy, start_date::Int, stopp_date::Int, liquidate,
                             dca_mode, dca_span, dca_unit, dca_days, dca_value, dca_anchor, dca_start, dca_skip,
                             balance_mode, balance_span, balance_unit, balance_days, balance_anchor, balance_start,
                             balance_skip, event_col, event_mode, event_weight, split_mode, split_thresh,
                             blocks::Bool = false)
    @nospecialize
    flag_date = collect(start_date:stopp_date)
    n = length(flag_date)
    flag_filled = haskey(fr, ".filled") ? BitVector(fr.cols[".filled"]) : falses(n)
    _fdrop!(fr, ".filled")
    flag_assets = [p.first for p in strategy]
    liq = liquidate == true
    flag_liquidate = BitVector(liq .& (flag_date .== stopp_date))
    for (a, sd0, mode) in (("dca", dca_start, dca_mode), ("balance", balance_start, balance_mode))
        (!_is_true(mode) || sd0 === nothing) && continue
        sd1 = _as_date(sd0)
        sd1 === nothing && error("simulation: $(a)_start = '$(sd0 isa AbstractString ? sd0 : r_format1(sd0))' ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\").")
        sd1 > stopp_date && error("simulation: $(blocks ? "start von " * (a == "dca" ? "dca_plan()" : "rebalance_plan()") : a * "_start") ($(fmt_date(sd1))) liegt nach dem letzten Datentag ($(fmt_date(stopp_date))); es gäbe keine Termine.")
    end
    flag_rebalance = _calculate_dates_flags(balance_mode, balance_span, balance_unit, balance_days, flag_date, nothing,
                                            balance_anchor, balance_start, balance_skip, liq)
    flag_dca = _calculate_dates_flags(dca_mode, dca_span, dca_unit, dca_days, flag_date, dca_value, dca_anchor,
                                      dca_start, dca_skip, liq)
    flag_taxes = BitVector([(md = Dates.monthday(from_days(z)); md == (12, 31)) for z in flag_date])
    event_mode = match_arg(event_mode, ("additional", "replace"), "event_mode")
    flag_event = falses(n)
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
        guard = (flag_date .!= flag_date[1]) .& ((!liq) .| (flag_date .!= stopp_date))
        flag_event = BitVector(flag_event .& guard)
        flag_rebalance = event_mode == "additional" ? BitVector(flag_rebalance .| flag_event) : copy(flag_event)
    end
    flag_trade = BitVector(.!flag_rebalance .& (flag_date .!= stopp_date) .& .!flag_filled)
    flag_split = _calculate_split_flags(sim, 100.0, split_mode, n, split_thresh)
    flag_dca_n = Float64.(flag_dca)
    if any(flag_filled)
        mon = [ym_key(z) for z in flag_date]
        flag_rebalance = _shift_off_filled(flag_rebalance, flag_filled, mon)
        flag_dca_n = _shift_off_filled(flag_dca_n, flag_filled, mon)
        flag_dca = BitVector(flag_dca_n .> 0)
        flag_split = _shift_off_filled(flag_split, flag_filled, mon)
        flag_liquidate = _shift_off_filled(flag_liquidate, flag_filled, mon)
        if any(flag_liquidate)
            flag_rebalance = BitVector(flag_rebalance .& .!flag_liquidate)
            flag_dca_n = [flag_liquidate[i] ? 0.0 : flag_dca_n[i] for i in 1:n]
            flag_dca = BitVector(flag_dca_n .> 0)
        end
        flag_trade = BitVector(.!flag_rebalance .& (flag_date .!= stopp_date) .& .!flag_filled)
    end
    for (a, name) in enumerate(flag_assets)
        st_a = sim.assets[a].start
        st_a > stopp_date && error("simulation: start von '$name' ($(fmt_date(st_a))) liegt nach dem letzten Datentag ($(fmt_date(stopp_date))); das Asset wäre nie handelbar. start auf ein Datum im Datenzeitraum setzen oder das Asset aus der Strategie entfernen.")
    end
    fl = Flags(flag_date, flag_filled, flag_assets, BitVector(flag_liquidate), BitVector(flag_rebalance), BitVector(flag_dca),
               flag_dca_n, flag_taxes, flag_event, flag_trade, BitVector(flag_split), Int[], Int[], falses(n), Int[],
               falses(n), falses(n), String[], String[], Float64[], falses(n), falses(n), falses(n), Int[], n)
    return fl, ew
end

function _sim_init_weights!(sim::Sim, fl::Flags, start_value::Float64)
    initial = [a for a in eachindex(fl.flag_assets) if sim.assets[a].start <= fl.flag_date[1]]
    isempty(initial) && error("simulation: Kein Asset ist am ersten Datentag ($(fmt_date(fl.flag_date[1]))) handelbar (start bzw. erste Kurse später); mindestens ein Asset muss ab Beginn handelbar sein.")
    initial_weights_sum = r_sum([sim.status[a].actual for a in initial])
    all_weights_sum = r_sum([sim.status[a].actual for a in eachindex(fl.flag_assets)])
    for a in eachindex(fl.flag_assets)
        st = sim.status[a]
        target_weight = st.actual / all_weights_sum
        if a in initial
            normalized_weight = st.actual / initial_weights_sum
            st.actual = target_weight
            st.money = start_value * normalized_weight
            st.total = start_value * normalized_weight
        else
            st.actual = target_weight
            st.differ = 0.0
            st.money = 0.0
            st.total = 0.0
        end
    end
    fl.initial_assets = initial
    return nothing
end

function _sim_build_schedule!(sim::Sim, fl::Flags, stopp_date::Int, tax_mode::String, harvest_mode, harvest_day)
    @nospecialize
    flag_date, flag_filled = fl.flag_date, fl.flag_filled
    n = length(flag_date)
    na = length(fl.flag_assets)
    asset_starts = Int[sim.assets[a].start for a in 1:na]
    d0 = flag_date[1]
    if any(flag_filled)
        mon = [ym_key(z) for z in flag_date]
        shifted = Int[]
        for dz in asset_starts
            i = dz - d0 + 1
            if !(1 <= i <= n) || !flag_filled[i]
                push!(shifted, dz); continue
            end
            j = _shift_target(i, flag_filled, mon, n)
            push!(shifted, flag_date[max(min(j, n), 1)])
        end
        asset_starts = shifted
    end
    start_set = Set(asset_starts)
    flag_active = BitVector([z in start_set for z in flag_date])
    asset_start_indices = Int[(1 <= z - d0 + 1 <= n) ? z - d0 + 1 : 1 for z in asset_starts]
    flag_harvest = falses(n)
    if _is_true(harvest_mode) && tax_mode == "person"
        yrs = [year_of(z) for z in flag_date]
        md_s = [(d = from_days(z); string(lpad(Dates.month(d), 2, '0'), "-", lpad(Dates.day(d), 2, '0'))) for z in flag_date]
        for y in unique(yrs)
            j = findfirst(i -> yrs[i] == y && md_s[i] >= harvest_day && md_s[i] < "12-31" && !flag_filled[i], 1:n)
            j === nothing || (flag_harvest[j] = true)
        end
    end
    flag_fund_fee = BitVector((tax_mode == "funds") .& (fl.flag_taxes .| (flag_date .== stopp_date)))
    flag_liquidate = fl.flag_liquidate
    if tax_mode == "funds" && any(flag_liquidate) && !flag_liquidate[n]
        liq_i = findlast(flag_liquidate)
        flag_fund_fee[liq_i+1:end] .= false
        flag_fund_fee[liq_i] = true
    end
    flag_definite = flag_active .| fl.flag_split .| fl.flag_dca .| fl.flag_rebalance .| fl.flag_taxes .|
                    flag_liquidate .| flag_harvest .| flag_fund_fee
    strategy_types = String[sim.assets[a].style for a in 1:na]
    has_bnh = any(==("bnh"), strategy_types)
    has_signal = any(==("signal"), strategy_types)
    tax_regimes = String[sim.assets[a].tax_regime for a in 1:na]
    spread_rates = Float64[sim.market[a].spread_rate for a in 1:na]
    flag_signal = falses(n)
    if has_signal
        for a in 1:na
            if sim.assets[a].style == "signal"
                b = sim.market[a].signal_buy; s = sim.market[a].signal_sell
                for i in 1:n
                    (_sig_truthy(b, i) | _sig_truthy(s, i)) && (flag_signal[i] = true)
                end
            end
        end
    end
    flag_bnh_potential = falses(n)
    has_bnh && (flag_bnh_potential[1] = true)
    flag_slow_path = flag_definite .| flag_signal .| flag_bnh_potential
    flag_year_change = falses(n)
    flag_vp_settle = falses(n)
    if tax_mode == "person"
        years = [year_of(z) for z in flag_date]
        for i in 2:n
            years[i] > years[i-1] && (flag_year_change[i] = true)
        end
        for ys in findall(flag_year_change)
            j = ys
            while j <= n && flag_filled[j] && years[j] == years[ys]
                j += 1
            end
            (j > n || years[j] != years[ys]) && (j = ys)
            flag_vp_settle[j] = true
        end
    end
    flag_slow_path = flag_slow_path .| flag_vp_settle
    flag_individual = flag_slow_path .| flag_year_change
    fl.asset_starts = asset_starts
    fl.flag_active = flag_active
    fl.asset_start_indices = asset_start_indices
    fl.flag_harvest = flag_harvest
    fl.flag_fund_fee = flag_fund_fee
    fl.strategy_types = strategy_types
    fl.tax_regimes = tax_regimes
    fl.spread_rates = spread_rates
    fl.flag_slow_path = BitVector(flag_slow_path)
    fl.flag_year_change = flag_year_change
    fl.flag_vp_settle = flag_vp_settle
    fl.individual_days = findall(flag_individual)
    fl.n_total_days = n
    return nothing
end
