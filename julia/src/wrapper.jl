# ─────────────────────────────────────────────────────────────────────────────
# Fonds-Wrapper (Port von r/R/wrapper.R, Etappe 6.5c): Anteilswert (NAV) aus einer
# inneren Strategie. Vorlage: python/simlev/wrapper.py.
#
#   wrapper_config(strategy; rebalance, costs, order_fee, volume)  → RList der Klasse SimLevWrapperConfig
#   asset_config(...; wrapper = wrapper_config(...))                Wrapper als ein Asset der Strategie
#   wrapper_nav(data, wrapper; splits)                              → RFrame der Klasse SimLevWrapperNav
#
# simulation() rechnet je Wrapper-Asset den Anteilswert (`_wrapper_nav_calc`) und hängt ihn als
# Kursspalte mit dem Asset-Namen an die Daten an (`_sim_check_inputs`, nach der Prüfung der
# Datumsspalte); danach ist das Asset ein gewöhnliches Asset ohne `wrapper`. Für die NAV-Spalte
# gibt es keine Splits (`cfg.no_split`).
#
# Rechenregeln (wörtlich wie im Kopf von r/R/wrapper.R; Reihenfolge der Operationen wie dort):
#   1. Innere Bruttorechnung simulation(d, strategy; start_value = S, costs = sim_costs(order_fee),
#      rebalance, splits, tax = nothing, fractions = true), S = volume bzw. 100; d = Daten ab der
#      ersten Zeile mit mindestens einem inneren Kurs; G = worth an den NAV-Tagen (Datenzeilen, die
#      in result.filled nicht als aufgefüllt gelten).
#   2. Start U = 100, H = 100, G_prev = S, d_prev = erster Tag von d.
#   3. Je NAV-Tag: a = U * (G_t / G_prev); k = fee / 100 * dd / D (D = 366 im Schaltjahr von t);
#      fee_t = a * k; U = a - fee_t; acc_t = pf / 100 * max(0, U - H); nav_t = U - acc_t; am letzten
#      NAV-Tag eines Kalenderjahres (nicht am letzten insgesamt) paid_t = acc_t, U = nav_t,
#      H = max(H, U); gross_t = 100 * G_t / S; hwm_t = H.
#
# Paketzustand: Die Ordergebühren (R: `.fee_env`) hält Julia je Lauf im Feld `Run.fee_current`
# bzw. `Run.fee_paid` (engine.jl), nicht im Paket; die innere Rechnung ist ein eigener Lauf und
# lässt den äußeren daher unverändert (nichts zu sichern). Meldungen der inneren Rechnung
# erscheinen als "Hinweis: <tag> (innere Rechnung): …" (`RParallel.with_message_stream`),
# Warnungen und Fehler als "<who> (innere Rechnung): …" (Logger `_WrapperWarnLogger`).
# ─────────────────────────────────────────────────────────────────────────────

using Base.CoreLogging: AbstractLogger, current_logger, with_logger

# ── wrapper_config ────────────────────────────────────────────────────────────

"""
    wrapper_config(strategy; rebalance = nothing, costs = funds_costs(), order_fee = nothing, volume = nothing)

Fonds-Wrapper konfigurieren (R: `wrapper_config()`, Etappe 6.5c). `strategy`: innere Strategie aus
`create_strategy()` oder eine benannte Liste, die `create_strategy(; assets = )` annimmt (Gewichte mit
Summe 1, ohne verschachtelte Wrapper; innere Signale erlaubt). `rebalance`: `nothing` oder
`rebalance_plan()` (Umschichten innen). `costs`: `funds_costs()` (Verwaltungsgebühr in % p. a., täglich je
Kalendertag; Performancegebühr in % über dem Höchststand, täglich abgegrenzt, am 31.12. festgeschrieben).
`order_fee`: Ordergebühr der inneren Käufe wie in `sim_costs()`; feste Beträge, `min` und `max` brauchen das
Fondsvolumen `volume` (EUR, Start der inneren Rechnung; sonst 100). Innere Assets mit Spread > 0 ergeben
einen Hinweis. Ergebnis: `RList` der Klasse `SimLevWrapperConfig` (`strategy`, `rebalance`, `costs`,
`order_fee`, `volume`).
"""
function wrapper_config(strategy; rebalance = nothing, costs = funds_costs(), order_fee = nothing, volume = nothing)
    @nospecialize
    strategy === nothing &&
        error("wrapper_config: strategy fehlt (innere Strategie aus create_strategy() oder eine Liste, die create_strategy() annimmt).")
    if !inherits(strategy, "strategy")
        (_is_mapping(strategy) || strategy isa Union{AbstractVector,Tuple}) ||
            error("wrapper_config: strategy muss ein Objekt aus create_strategy() oder eine benannte Liste von Asset-Konfigurationen sein, nicht $(_r_class1(strategy)).")
        strategy = create_strategy(; assets = strategy)
    end
    strategy_validate(strategy)
    nested = _strategy_wrappers(strategy)
    isempty(nested) ||
        error("wrapper_config: Asset '$(nested[1])' der inneren Strategie hat selbst einen Wrapper; verschachtelte Wrapper sind nicht möglich.")
    total = r_sum(Float64[Float64(a["share"]) for (_, a) in strategy])
    abs(total - 1) > 1e-6 &&
        error(r_sprintf("wrapper_config: Gewichte (share) der inneren Strategie summieren sich auf %.4f, müssen aber 1 ergeben.", total))
    (rebalance === nothing || inherits(rebalance, "SimLevRebalancePlan")) ||
        error("wrapper_config: rebalance muss NULL oder ein Objekt aus rebalance_plan() sein, nicht $(_blk_cls(rebalance)).")
    inherits(costs, "SimLevFundsCosts") ||
        error("wrapper_config: costs muss ein Objekt aus funds_costs() sein, nicht $(costs === nothing ? "NULL" : _blk_cls(costs)).")
    fs = _fee_spec(order_fee)
    if volume !== nothing && (!_blk_one(volume) || volume <= 0)
        error("wrapper_config: 'volume' muss NULL oder eine einzelne endliche Zahl > 0 sein (Fondsvolumen in EUR), nicht $(_blk_show(volume)).")
    end
    if fs !== nothing && volume === nothing && (fs.fixed > 0 || fs.min > 0 || isfinite(fs.max))
        error("wrapper_config: order_fee enthält feste Beträge in EUR (fixed, min oder max); dafür ist das Fondsvolumen " *
              "'volume' in EUR nötig (die innere Rechnung startet dann mit diesem Volumen). Ohne volume gehen nur " *
              "Prozentgebühren (order_fee = list(percent = ...)).")
    end
    spr = [nm => (get(a, "spread", nothing) === nothing ? 0.0 : Float64(a["spread"])) for (nm, a) in strategy]
    if any(p -> p.second > 0, spr)
        _message("Hinweis: wrapper_config: innere Assets mit Spread > 0: " *
                 join(("'$(p.first)' ($(_blk_fmt(p.second)) %)" for p in spr if p.second > 0), ", ") *
                 "; der Spread gilt in der inneren Rechnung (Kauf und Umschichten).")
    end
    return RList("strategy" => strategy, "rebalance" => rebalance, "costs" => costs, "order_fee" => order_fee,
                 "volume" => volume === nothing ? nothing : Float64(volume); class = ["SimLevWrapperConfig"])
end

function _print_wrapper_config(io::IO, x)
    rb = x["rebalance"]
    umsch = rb === nothing ? "keines" :
            (rb["event_col"] !== nothing && rb["event_mode"] == "replace") ? "an Ereignissen (Spalte '$(rb["event_col"])')" :
            _blk_sched_text(rb["span"], rb["unit"], rb["days"], rb["anchor"])
    _blk_print(io, "Fonds-Wrapper (wrapper_config)",
               ["Innere Assets" => _wrapper_assets_text(x["strategy"]),
                "Umschichten" => umsch,
                "Fondskosten" => "$(_blk_fmt(x["costs"]["fee"])) % p. a. (täglich je Kalendertag)",
                "Performancegebühr" => "$(_blk_fmt(x["costs"]["performance_fee"])) % über dem Höchststand (täglich abgegrenzt, jährlich festgeschrieben)",
                "Ordergebühr innen" => _blk_fee_text(x["order_fee"]),
                "Fondsvolumen" => x["volume"] === nothing ? "nicht angegeben (Start mit 100)" : r_sprintf("%.2f EUR", x["volume"])])
end

# ── Meldungen und Warnungen der inneren Rechnung ──────────────────────────────

"Strom für Meldungen der inneren Rechnung: je Meldung (bis Zeilenende) mit Präfix an `target`."
mutable struct _WrapperMsgIO <: IO
    target::IO
    tag::String
    buf::Vector{UInt8}
end
function _wmsg_add!(s::_WrapperMsgIO, bytes)
    append!(s.buf, bytes)
    !isempty(s.buf) && s.buf[end] == UInt8('\n') && _wmsg_emit!(s)
    nothing
end
function _wmsg_emit!(s::_WrapperMsgIO)
    m = String(copy(s.buf)); empty!(s.buf)
    startswith(m, "Hinweis: ") && (m = m[length("Hinweis: ")+1:end])
    write(s.target, "Hinweis: $(s.tag) (innere Rechnung): $m")
    nothing
end
Base.unsafe_write(s::_WrapperMsgIO, p::Ptr{UInt8}, n::UInt) = (_wmsg_add!(s, copy(unsafe_wrap(Array, p, n))); Int(n))
Base.write(s::_WrapperMsgIO, b::UInt8) = (_wmsg_add!(s, UInt8[b]); 1)
Base.isopen(::_WrapperMsgIO) = true
Base.iswritable(::_WrapperMsgIO) = true
Base.flush(s::_WrapperMsgIO) = (isempty(s.buf) || _wmsg_emit!(s); flush(s.target); nothing)

"Logger der inneren Rechnung: Warnungen mit Präfix `who` an den äußeren Logger (R: `warning(…)` im Handler)."
struct _WrapperWarnLogger <: AbstractLogger
    parent::AbstractLogger
    who::String
end
Base.CoreLogging.min_enabled_level(l::_WrapperWarnLogger) = Base.CoreLogging.min_enabled_level(l.parent)
Base.CoreLogging.shouldlog(l::_WrapperWarnLogger, args...) = Base.CoreLogging.shouldlog(l.parent, args...)
Base.CoreLogging.catch_exceptions(l::_WrapperWarnLogger) = Base.CoreLogging.catch_exceptions(l.parent)
function Base.CoreLogging.handle_message(l::_WrapperWarnLogger, level, message, args...; kw...)
    msg = (level >= Base.CoreLogging.Warn && level < Base.CoreLogging.Error) ? "$(l.who) (innere Rechnung): $(message)" : message
    Base.CoreLogging.handle_message(l.parent, level, msg, args...; kw...)
end

_wrapper_errmsg(e) = e isa ErrorException ? e.msg : e isa KeyError ? string(e.key) :
                     hasproperty(e, :msg) ? string(getproperty(e, :msg)) : sprint(showerror, e)

# ── Anteilswert ───────────────────────────────────────────────────────────────

"Zeilen `i0:end` von `fr` (ohne Attribut filled)."
_frame_rows(fr::_Frame, i0::Int) = _Frame(copy(fr.names), Dict{String,AbstractVector}(nm => fr.cols[nm][i0:end] for nm in fr.names),
                                          copy(fr.kinds), nothing)

"""
    _wrapper_nav_calc(data::_Frame, wrapper, splits, tag, who)

Anteilswert eines Wrappers (R: `.wrapper_nav_calc`); Rechenregeln im Kopf der Datei. `data`: Spaltendaten
mit `date` (Tage, aufsteigend, ohne Doppelte) und den inneren Kursspalten (`filled_attr` geht an die innere
Rechnung); `splits`: `nothing` oder `split_rule()`; `tag`/`who`: Kennung für Meldungen bzw. Warnungen und
Fehler. Ergebnis: RFrame der Klasse `SimLevWrapperNav` mit Attributen `inner` und `wrapper`.
"""
function _wrapper_nav_calc(data::_Frame, wrapper, splits, tag::String, who::String)
    @nospecialize
    st = wrapper["strategy"]
    cols = _strategy_columns(st)
    miss = [c for c in cols if !haskey(data, c)]
    if !isempty(miss)
        error("$who: $(length(miss) == 1 ? "Kursspalte" : "Kursspalten") $(join(("'$m'" for m in miss), ", ")) der inneren Strategie " *
              "$(length(miss) == 1 ? "fehlt" : "fehlen") in data (vorhanden: $(join((nm for nm in data.names if nm != "date"), ", "))).")
    end
    n0 = _fnrow(data)
    has = falses(n0)
    for cc in cols
        has .|= .!_isna_vec(data.cols[cc])
    end
    any(has) || error("$who: die inneren Kursspalten ($(join(cols, ", "))) enthalten nur NA.")
    r0 = findfirst(has)
    d = data
    if r0 > 1
        fa = data.filled_attr
        d = _frame_rows(data, r0)
        fa_m, fa_cols, fa_n = _filled_matrix(fa)
        if fa_m !== nothing && fa_n == n0
            sub = fa_m[r0:end, :]
            d.filled_attr = fa_cols === nothing ? Matrix{Bool}(sub) :
                            RFrame((String(c) => Vector{Bool}(sub[:, j]) for (j, c) in enumerate(fa_cols))...)
        end
    end
    S = wrapper["volume"] === nothing ? 100.0 : Float64(wrapper["volume"])
    # Ordergebühren: Zustand je Lauf (Run), die innere Rechnung ist ein eigener Lauf (siehe Kopf)
    msg = _WrapperMsgIO(SimLev.RParallel.r_stderr(), tag, UInt8[])
    res = try
        with_logger(_WrapperWarnLogger(current_logger(), who)) do
            SimLev.RParallel.with_message_stream(msg) do
                try
                    simulation(d, st; start_value = S, costs = sim_costs(; order_fee = wrapper["order_fee"]),
                               rebalance = wrapper["rebalance"], splits = splits, tax = nothing, fractions = true)
                finally
                    flush(msg)
                end
            end
        end
    catch e
        e isa InterruptException && rethrow()
        error("$who (innere Rechnung): $(_wrapper_errmsg(e))")
    end
    rdays = Int[to_days(z) for z in res["dates"]]
    rfilled = res["filled"]
    pos = Dict{Int,Int}(z => i for (i, z) in enumerate(rdays))
    idx = Int[pos[Int(z)] for z in d.cols["date"]]
    idx = idx[.!rfilled[idx]]
    isempty(idx) && error("$who: keine Handelstage in der inneren Rechnung (alle Tage aufgefüllt).")
    day = rdays[idx]
    G = Float64.(res["worth"])[idx]
    yr = Int[year_of(z) for z in day]
    fee = Float64(wrapper["costs"]["fee"]); pf = Float64(wrapper["costs"]["performance_fee"])
    n = length(idx)
    nav = zeros(n); gross = zeros(n); fee_t = zeros(n); acc_t = zeros(n); paid_t = zeros(n); hwm = zeros(n)
    U = 100.0; H = 100.0; G_prev = S; d_prev = Float64(rdays[1])
    for t in 1:n
        g = G[t]
        if !(G_prev > 0) || !isfinite(g) || !(g > 0)
            error("$who: innerer Wert am $(fmt_date(day[t])) ist $(r_format1(g)) (vorher $(r_format1(G_prev))); der Anteilswert ist dann nicht definiert.")
        end
        D = is_leap(yr[t]) ? 366.0 : 365.0
        a = U * (g / G_prev)
        k = fee / 100 * (Float64(day[t]) - d_prev) / D
        fee_t[t] = a * k
        U = a - fee_t[t]
        acc_t[t] = pf / 100 * _wrapper_max0(U - H)
        nav[t] = U - acc_t[t]
        if t < n && yr[t+1] != yr[t]      # letzter NAV-Tag des Kalenderjahres (nicht der letzte insgesamt)
            paid_t[t] = acc_t[t]
            U = nav[t]
            H = U > H ? U : H             # R: max(H, U)
        end
        gross[t] = 100 * g / S
        hwm[t] = H
        G_prev = g; d_prev = Float64(day[t])
    end
    return RFrame("date" => Date[from_days(z) for z in day], "nav" => nav, "gross" => gross, "fee" => fee_t,
                  "perf_fee" => acc_t, "perf_paid" => paid_t, "hwm" => hwm;
                  class = ["SimLevWrapperNav", "data.frame"], attrs = Dict{String,Any}("inner" => res, "wrapper" => wrapper))
end

"R: `max(0, x)` (x endlich): 0 bleibt +0."
_wrapper_max0(x::Float64) = x > 0.0 ? x : 0.0

"""
    wrapper_nav(data, wrapper; splits = nothing)

Anteilswert eines Fonds-Wrappers (R: `wrapper_nav()`, Etappe 6.5c). `data`: data.frame-artig mit `date` und
den Kursspalten der inneren Strategie (unsortiert wird nach Datum sortiert; das Attribut `filled` aus
`series_align()` geht an die innere Rechnung); `wrapper`: Ergebnis von `wrapper_config()`; `splits`:
`nothing` oder `split_rule()` (für die inneren Spalten). Ergebnis: RFrame der Klasse `SimLevWrapperNav`
(`date`, `nav`, `gross`, `fee`, `perf_fee`, `perf_paid`, `hwm`; Start 100) mit Attributen `inner`
(inneres `SimLevResult`) und `wrapper`. Eine Zeilenauswahl (`rows(x, i)`) ist eine gewöhnliche Tabelle
(`RFrame`) ohne Klasse und Attribute (R: `x[i, ]` ergibt einen data.frame); `withdrawal_simulation` nimmt
nur das ganze Objekt.
"""
function wrapper_nav(data, wrapper; splits = nothing)
    @nospecialize
    inherits(wrapper, "SimLevWrapperConfig") ||
        error("wrapper_nav: wrapper muss ein Objekt aus wrapper_config() sein, nicht $(wrapper === nothing ? "NULL" : _blk_cls(wrapper)).")
    (splits === nothing || inherits(splits, "SimLevSplitRule")) ||
        error("wrapper_nav: splits muss NULL oder ein Objekt aus split_rule() sein, nicht $(_blk_cls(splits)).")
    data = as_rframe(data)
    (data isa RFrame && haskey(data, "date")) ||
        error("wrapper_nav: data muss ein data.frame mit Spalte 'date' und den Kursspalten der inneren Strategie sein.")
    fa = get(attrs(data), "filled", nothing)
    dates = SimLev.DataPrep._to_date(data["date"], "wrapper_nav: data\$date")
    i_na = findfirst(ismissing, dates)
    i_na === nothing || error("wrapper_nav: Spalte 'date' enthält NA (erstmals in Zeile $i_na).")
    data = copy(data)
    data["date"] = Date[z for z in dates]
    zd = Int[to_days(z) for z in data["date"]]
    fr_filled = fa
    if any(i -> zd[i+1] < zd[i], 1:length(zd)-1)        # nach Datum sortieren (wie simulation())
        o = sortperm(zd; alg = MergeSort)
        data = rows(data, o)
        fa_m, fa_cols, fa_n = _filled_matrix(fa)
        fr_filled = nothing
        if fa_m !== nothing && fa_n == length(o)
            sub = fa_m[o, :]
            fr_filled = fa_cols === nothing ? Matrix{Bool}(sub) :
                        RFrame((String(c) => Vector{Bool}(sub[:, j]) for (j, c) in enumerate(fa_cols))...)
        end
    end
    empty!(attrs(data))
    fr = _to_frame(data)
    fr.filled_attr = fr_filled
    return _wrapper_nav_calc(fr, wrapper, splits, "wrapper_nav", "wrapper_nav")
end

function _print_wrapper_nav(io::IO, x)
    w = get(attrs(x), "wrapper", nothing)
    if !inherits(w, "SimLevWrapperConfig") || nrow(x) == 0 || !all(c -> haskey(x, c), ("date", "nav", "gross"))
        y = copy(x); empty!(getfield(y, :class)); empty!(attrs(y))
        return _default_print(io, y)
    end
    n = nrow(x)
    _blk_print(io, "Anteilswert (wrapper_nav)",
               ["Zeitraum" => "$(Dates.format(x["date"][1], dateformat"yyyy-mm-dd")) bis $(Dates.format(x["date"][n], dateformat"yyyy-mm-dd")) ($n $(n == 1 ? "Datentag" : "Datentage"))",
                "Fondskosten" => "$(_blk_fmt(w["costs"]["fee"])) % p. a.",
                "Performancegebühr" => "$(_blk_fmt(w["costs"]["performance_fee"])) % über dem Höchststand",
                "Endwert" => r_sprintf("%.4f (brutto %.4f, Start 100)", x["nav"][n], x["gross"][n])])
end

register_print!("SimLevWrapperConfig", _print_wrapper_config)
register_print!("SimLevWrapperNav", _print_wrapper_nav)
# Jede Zeilenauswahl (rows) ist eine gewöhnliche Tabelle ohne Klasse und Attribute (R: `[.SimLevWrapperNav`, Etappe 8.0)
register_plain_rows!("SimLevWrapperNav")
