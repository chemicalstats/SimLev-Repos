# ─────────────────────────────────────────────────────────────────────────────
# Studienkern: vorbereiteter Kernlauf je Pfad bzw. Punkt (seit 1.6.5, Paket E, Entscheidung 176; FB-12; R:
# r/R/sim_prepared.R, Python: python/simlev/_sim_prepared.py)
#
# Studien (bootstrap_study, param_search, sensitivity_*, planning_lumpsum_vs_dca) rufen simulation() über _sim_call
# vielfach mit derselben Strategie und denselben Argumenten auf; je Pfad bzw. Punkt ändern sich oft nur Kurse (Pfade,
# Hebelreihen) oder Signale (Signalparameter einer Suche). Innerhalb einer Studie merkt sich _sim_call_study ab dem
# zweiten Aufruf mit derselben Strategie und Argumentliste einen vollständigen Lauf als Vorlage (_prep_capture:
# Eingabe der Tagesengine, Zustand vor der Engine, Kalender, Bausteine, Teile der Auswertung ohne den Lauf). Spätere
# Aufrufe tauschen nur die Kurs- und Signalspalten (aufgefüllt wie in _sim_prepare_data) und rechnen Engine und
# Auswertung in einem Kernaufruf (simlev_c_run_prepared, core/evaluate_core_impl.h simlev_run::run_prepared);
# Meldungen der Engine und der Auswertung, Ergebnis und Fehler entstehen mit denselben Funktionen wie in simulation().
#
# Bitgleich zu simulation(): dieselben Kernaufrufe in derselben Reihenfolge. Eine Vorlage entsteht nur, wenn die
# Phasen 1 und 2 still blieben (_prep_probe: ohne Hinweis, Warnung, Ausgabe und Fehler), ohne details, ohne
# Fonds-Wrapper, mit einer RFrame ohne Attribut filled und einer Datumsspalte. Ein Lauf nutzt sie nur, wenn Spalten,
# Datumsspalte und die übrigen gelesenen Spalten (risk_free, Basiszins, Ereignis- und Gewichtsspalten) gleich sind und
# die neuen Kurse und Signale die Prüfungen still bestehen (Kurse: Zahlen ohne NA in [1e-100, 1e100]; Signale: dieselbe
# Art, logisch oder 0/1); sonst rechnet simulation() vollständig. Ändern sich Spalten, Datum oder die übrigen Spalten
# bei derselben Strategie (z. B. Zeitfenster), merkt sich die Studie für sie keine Vorlage mehr. Vorlagen sind nach dem
# Anlegen unveränderlich; jeder Lauf baut eigene Zustände (Aufgaben mit cores > 1 teilen die Liste unter _STUDY_LOCK).
# ─────────────────────────────────────────────────────────────────────────────

const _PREP_MAX = 16                      # gemerkte Vorlagen bzw. Schlüssel je Studie (älteste fällt heraus)
const _PREP_CAP = :SimLev_prep_cap        # Merker "nächster Lauf wird Vorlage" (je Aufgabe)
const _PREP_OUT = :SimLev_prep_out        # gemerkte Vorlage dieses Laufs (je Aufgabe)

"Merker \"dieser Lauf wird Vorlage\" lesen und löschen (`_simulation_flat` am Anfang)."
function _prep_cap_take()
    _STUDY_ON[] || return false
    tls = task_local_storage()
    get(tls, _PREP_CAP, false) === true || return false
    tls[_PREP_CAP] = false
    return true
end

"Logger, der jede Meldung nur zählt (stille Probe der Phasen 1 und 2)."
struct _ProbeLogger <: Base.CoreLogging.AbstractLogger
    n::Base.RefValue{Int}
end
Base.CoreLogging.min_enabled_level(::_ProbeLogger) = Base.CoreLogging.BelowMinLevel
Base.CoreLogging.shouldlog(::_ProbeLogger, args...) = true
Base.CoreLogging.catch_exceptions(::_ProbeLogger) = false
Base.CoreLogging.handle_message(l::_ProbeLogger, args...; kwargs...) = (l.n[] += 1; nothing)

"""Phasen 1 und 2 still rechnen: ihr Ergebnis, wenn sie ohne Hinweis, Warnung, Ausgabe und Fehler blieben, sonst
`nothing` (dann rechnet `_simulation_flat` sie noch einmal mit allen Meldungen)."""
function _prep_probe(phases)
    lg = _ProbeLogger(Ref(0)); msg = IOBuffer(); pio = IOBuffer()
    got = try
        task_local_storage(SimLev.RParallel._MUTE_KEY, false) do
            Base.CoreLogging.with_logger(lg) do
                SimLev.RParallel.with_message_stream(() -> phases(pio), msg)
            end
        end
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    (lg.n[] == 0 && position(msg) == 0 && position(pio) == 0) || return nothing
    return got
end

"Flache Kopie eines Objekts mit allen Feldern (Flags, Cfg, TariffEnv)."
_prep_shallow(x::T) where {T} = T((getfield(x, f) for f in fieldnames(T))...)

function _prep_env_copy(e)
    e === nothing && return nothing
    c = _prep_shallow(e)
    c.ks = copy(e.ks); c.rows = copy(e.rows)
    return c
end

"Spalten einer RFrame als Namen und Werte; nothing, wenn keine Vorlage möglich ist."
function _prep_shape(data)
    data isa RFrame || return nothing
    get(attrs(data), "filled", nothing) === nothing || return nothing
    nms, vals, _ = _raw_columns(data)
    i = findfirst(==("date"), nms)
    i === nothing && return nothing
    return (names = nms, vals = vals, date = vals[i])
end

_prep_col(shp, c) = _column(shp.vals[findfirst(==(c), shp.names)])

"""Vorlage aus einem Lauf von `simulation()` (vor der Tagesengine): legt sie in der laufenden Aufgabe ab; Rückgabe
`_sim_eval_static` für die Auswertung dieses Laufs."""
function _prep_capture(data, R::Run, sim::Sim, fr::_Frame, fill_src, E, start_date::Int, stopp_date::Int, details,
                       base_rate_flex, base_rate_data, event_weight)
    @nospecialize
    es = _sim_eval_static(R, start_date, stopp_date, fr)
    cfg, fl = R.cfg, R.fl
    shp = _prep_shape(data)
    (details == true || R.details || !isempty(cfg.no_split) || es.rf_err !== nothing || shp === nothing) && return es
    kd, dd = _column(shp.date)
    kd == :date || return es
    nm = copy(fl.flag_assets)
    strat = Dict(cfg.strategy)
    sb = Union{Nothing,String}[]; ss = Union{Nothing,String}[]
    for a in nm
        for (f, lst) in (("signal_buy", sb), ("signal_sell", ss))
            c = get(strat[a], f, nothing)
            c === nothing || (c isa AbstractString && String(c) in shp.names) || return es
            push!(lst, c === nothing ? nothing : String(c))
        end
    end
    sig = String[]
    for c in vcat(sb, ss)
        (c === nothing || c in sig) || push!(sig, c)
    end
    swap = vcat(nm, [c for c in sig if !(c in nm)])
    fixed = String[]
    cfg.risk_free isa AbstractString && push!(fixed, String(cfg.risk_free))
    _is_true(base_rate_flex) && base_rate_data isa AbstractString && push!(fixed, String(base_rate_data))
    if cfg.event_col !== nothing
        push!(fixed, String(cfg.event_col))
        if event_weight !== nothing
            for p in event_weight
                p.second isa AbstractString && push!(fixed, String(p.second))
            end
        end
    end
    fixed = [c for c in unique(fixed) if c in shp.names]
    any(c -> c in swap, fixed) && return es
    (all(a -> get(fr.kinds, a, :none) == :numeric, nm) && all(c -> get(fr.kinds, c, :none) in (:numeric, :logical), sig)) ||
        return es
    P = (names = copy(shp.names), date = dd, fixed = [(c, _prep_col(shp, c)) for c in fixed], price = nm,
         sig = [(c, fr.kinds[c]) for c in sig], sb = sb, ss = ss, src = fill_src, E = E,
         sim = _prep_sim(sim, Market[Market(m.base_rates, m.asset_price, m.signal_buy, m.signal_sell, m.spread_rate) for m in sim.market]),
         fl = _prep_shallow(fl), cfg = cfg, env0 = _prep_env_copy(cfg.tariff_env),
         io = R.io, ev = (day = es.day, filled = es.filled, sc = es.sc, rf = es.rf, rf_ok = true))
    task_local_storage(_PREP_OUT, P)
    return es
end

"Zustand für einen Lauf: Markt (Kurse, Signale), Status, Trades, Report und Töpfe neu (die Engine schreibt sie)."
function _prep_sim(s::Sim, market::Vector{Market})
    n = length(s.report) == 0 ? 0 : length(s.report[1].worth)
    return Sim(s.names, s.assets, Status[Status(x.money) for x in s.status], market,
               Trades[Trades(Lot[], SellEntry[], TaxEntry[]) for _ in s.trades],
               Report[Report(zeros(n), zeros(n), zeros(n), zeros(n), zeros(n)) for _ in s.report], deepcopy(s.totals))
end

"""Lauf mit einer Vorlage: nur Kurse und Signale aus data; `nothing` (Kurse/Signale passen nicht) bzw. `:anders`
(Spalten, Datum oder übrige Spalten anders), dann rechnet `simulation()`."""
function _prep_run(P, data)
    @nospecialize
    shp = _prep_shape(data)
    (shp === nothing || shp.names != P.names) && return :anders
    kd, dd = _column(shp.date)
    (kd == :date && _same_bits(dd, P.date)) || return :anders
    for (c, col) in P.fixed
        _deep_same(_prep_col(shp, c), col) || return :anders
    end
    # Kurse und Signale, die die Prüfungen von simulation() still bestehen (_sim_check_inputs, chk_col_signal)
    cols = Dict{String,Tuple{Symbol,AbstractVector}}()
    for a in P.price
        k, v = _prep_col(shp, a)
        (k == :numeric && !isempty(v) && !any(isnan, v)) || return nothing
        lo, hi = minimum(v), maximum(v)
        (isfinite(lo) && isfinite(hi) && lo >= 1e-100 && hi <= 1e100) || return nothing
        cols[a] = (k, v)
    end
    for (c, kind) in P.sig
        k, v = _prep_col(shp, c)
        k == kind || return nothing
        k == :numeric && !all(x -> isnan(x) || x == 0 || x == 1, v) && return nothing
        cols[c] = (k, v)
    end
    if P.src !== nothing   # wie _sim_prepare_data: Spalten auf das Kalenderraster
        src = Int[s + 1 for s in P.src]
        for (c, (k, v)) in collect(cols)
            cols[c] = (k, _fill_column(P.src, src, v, k))
        end
    end
    tmpl = P.sim
    market = Market[]
    for (j, a) in enumerate(P.price)
        m = tmpl.market[j]
        sbj, ssj = P.sb[j], P.ss[j]
        b = sbj === nothing ? m.signal_buy : _prep_signal(cols[sbj])
        s = ssj === nothing ? m.signal_sell : _prep_signal(cols[ssj])
        (b.logical == m.signal_buy.logical && s.logical == m.signal_sell.logical) || return nothing
        push!(market, Market(m.base_rates, copy(cols[a][2]::Vector{Float64}), b, s, m.spread_rate))
    end
    sim = _prep_sim(tmpl, market)
    cfg = _prep_shallow(P.cfg)
    cfg.tariff_env = _prep_env_copy(P.env0)
    R = Run(cfg, _prep_shallow(P.fl), false, P.io, 0.0, 0.0)
    E = P.E
    h = ccall((:simlev_c_engine_new, LIBSLC), Ptr{Cvoid}, ())
    h == C_NULL && throw(OutOfMemoryError())
    he = ccall((:simlev_c_eval_new, LIBSLC), Ptr{Cvoid}, ())
    if he == C_NULL
        ccall((:simlev_c_engine_free, LIBSLC), Cvoid, (Ptr{Cvoid},), h)
        throw(OutOfMemoryError())
    end
    local res
    try
        flags_out = zeros(Int32, E.n)
        ev = (day = P.ev.day, filled = P.ev.filled, sc = P.ev.sc, rf = P.ev.rf, rf_ok = P.ev.rf_ok, cnt = zeros(Int64, 2))
        rc = _engine_ccall(h, he, E, sim, R.fl, flags_out, ev)
        _sim_engine_output!(h, rc, R, sim, E, flags_out)
        ret, statistics, um, buys, sells = _sim_eval_output(he, E.n, E.na, ev.cnt, nothing, sim.names)
        res = _sim_result(R, sim, ret, statistics, um, buys, sells)
    finally
        ccall((:simlev_c_eval_free, LIBSLC), Cvoid, (Ptr{Cvoid},), he)
        ccall((:simlev_c_engine_free, LIBSLC), Cvoid, (Ptr{Cvoid},), h)
    end
    return res
end

"Signal wie `_signal_col` aus einer (aufgefüllten) Spalte (Art, Werte)."
function _prep_signal(col)
    k, v = col
    k == :numeric && return Signal(false, copy(v))
    return Signal(true, _signal_logical(v))
end

"""Schlüssel (Strategie, Argumente): die Objekte selbst; der Vergleich `_deep_same` prüft zuerst `===` (eine Studie
gibt je Strategie dieselben Objekte weiter) und sonst den Inhalt. Studien ändern Strategie und Argumente nicht an Ort und
Stelle (`_sim_args_set` baut neue Listen und Bausteine); ein Abzug (deepcopy) kostete je Pfad den vollen Vergleich."""
_prep_key(strategy, args) = (strategy, args)

function _prep_find(lst::Vector{Any}, strategy, args)
    for (i, e) in enumerate(lst)
        (_deep_same(e[1], strategy) && _deep_same(e[2], args)) && return i
    end
    return 0
end

function _prep_push!(lst::Vector{Any}, e)
    push!(lst, e)
    length(lst) > _PREP_MAX && popfirst!(lst)
    return nothing
end

"""`simulation()` in einer Studie: Vorlage nutzen, sonst vollständig rechnen (ab dem zweiten Aufruf mit derselben
Strategie und denselben Argumenten als Vorlage merken)."""
function _sim_call_study(data, strategy, args)
    @nospecialize
    call() = simulation(data, strategy; (Symbol(k) => v for (k, v) in args)...)
    P = lock(_STUDY_LOCK) do
        i = _prep_find(_PREP, strategy, args)
        i > 0 ? _PREP[i][3] : nothing
    end
    if P !== nothing
        r = _prep_run(P, data)
        r === nothing || r === :anders || return r
        if r === :anders
            lock(_STUDY_LOCK) do
                i = _prep_find(_PREP, strategy, args)
                i > 0 && deleteat!(_PREP, i)
                _prep_find(_NEVER, strategy, args) > 0 || _prep_push!(_NEVER, _prep_key(strategy, args))
            end
        end
        return call()
    end
    cap = lock(_STUDY_LOCK) do
        _prep_find(_NEVER, strategy, args) > 0 && return false
        j = _prep_find(_SEEN, strategy, args)
        j == 0 && (_prep_push!(_SEEN, _prep_key(strategy, args)); return false)
        deleteat!(_SEEN, j)
        return true
    end
    cap || return call()
    tls = task_local_storage()
    tls[_PREP_CAP] = true; tls[_PREP_OUT] = nothing
    local res, Q
    try
        res = call()
        Q = get(tls, _PREP_OUT, nothing)
    finally
        tls[_PREP_CAP] = false; tls[_PREP_OUT] = nothing
    end
    Q === nothing || lock(_STUDY_LOCK) do
        _STUDY_ON[] && _prep_find(_PREP, strategy, args) == 0 && _prep_push!(_PREP, (_prep_key(strategy, args)..., Q))
    end
    return res
end
