# ─────────────────────────────────────────────────────────────────────────────
# Fonds-Wrapper (Gegenstück zu r/R/wrapper.R): Anteilswert (NAV) aus einer
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
# Paketzustand: Die gezahlten Ordergebühren (R: `.fee_env$paid`) hält Julia je Lauf im Feld
# `Run.fee_paid` (engine.jl), nicht im Paket; die innere Rechnung ist ein eigener Lauf und
# lässt den äußeren daher unverändert (nichts zu sichern). Meldungen der inneren Rechnung
# erscheinen als "Hinweis: <tag> (innere Rechnung): …" (`RParallel.with_message_stream`),
# Warnungen und Fehler als "<who> (innere Rechnung): …" (Logger `_WrapperWarnLogger`).
# ─────────────────────────────────────────────────────────────────────────────

using Base.CoreLogging: AbstractLogger, current_logger, with_logger

# ── wrapper_config ────────────────────────────────────────────────────────────

"""
    wrapper_config(strategy; rebalance = nothing, costs = funds_costs(), order_fee = nothing, volume = nothing)

Fonds-Wrapper konfigurieren.

Beschreibt einen Fonds-Wrapper: Innen handelt eine eigene Strategie (mit Umschichten, Signalen und
Ordergebühren), es fallen Verwaltungs- und Performancegebühr an. Außen ist der Wrapper **ein** Asset der
Strategie: `asset_config(..., wrapper = wrapper_config(...))`. Der Anleger kauft und verkauft Anteile mit
eigenem Spread und eigenen Order- und Sparplangebühren und zahlt Steuern wie auf ein Einzelpapier (nach
`asset_class` bzw. `tax_regime`). `simulation` rechnet dafür je Lauf den Anteilswert mit `wrapper_nav`.

# Argumente
- `strategy`: Innere Strategie: Objekt aus `create_strategy` oder eine benannte Liste, die
  `create_strategy(assets = )` annimmt. Die Namen sind Kursspalten in `data`. Kein inneres Asset darf selbst
  einen Wrapper haben (Fehler). Innere Signale (`trading = "signal"`) sind erlaubt und beziehen sich auf
  Spalten in `data`. Die Gewichte (`share`) müssen sich auf 1 summieren. Innere Spreads gelten wie angegeben
  (Standard 0); Werte > 0 ergeben beim Erzeugen einen Hinweis mit der Liste der Assets.
- `rebalance`: `nothing` (kein Umschichten) oder ein Objekt aus `rebalance_plan`: Umschichten innerhalb des
  Wrappers.
- `costs`: Objekt aus `funds_costs`: Verwaltungsgebühr `fee` in Prozent p. a. und Performancegebühr
  `performance_fee` in Prozent (Rechnung siehe `wrapper_nav`). Standard: `funds_costs()` (0,95 % p. a., 5 %).
- `order_fee`: Ordergebühr der inneren Käufe und Verkäufe (beim Start und beim Umschichten), im Format von
  `sim_costs`: Zahl (EUR je Order) oder `RList("fixed" => …, "percent" => …, "min" => …, "max" => …)`.
  `nothing` = keine.
- `volume`: `nothing` oder Fondsvolumen in EUR (eine Zahl > 0). Pflicht, sobald `order_fee` feste Beträge
  enthält (`fixed` oder `min` > 0 bzw. `max` < ∞), sonst Fehler; reine Prozentgebühren gehen ohne `volume`.
  Die innere Rechnung startet mit `volume`, ohne Angabe mit 100. Einzahlungen der Anleger ändern das
  Fondsvolumen nicht.

# Rückgabe
Objekt der Klasse `SimLevWrapperConfig`: Liste mit `strategy` (geprüft, Klasse `strategy`), `rebalance`,
`costs`, `order_fee` (wie übergeben) und `volume`. `print` zeigt innere Assets, Umschichten, Kosten,
Ordergebühr und Volumen und liefert `x` unsichtbar zurück.

# Details
**Steuerliche Einordnung.** Ob ein konkreter Wrapper steuerlich ein Investmentfonds (`tax_regime =
"investment_fund"` mit `partial_exemption`, Vorabpauschale) oder eine Kapitalforderung ist (`asset_class =
"certificate"`: Besteuerung erst beim Verkauf, ohne Vorabpauschale und Teilfreistellung), entscheidet der
Nutzer über `asset_class`/`tax_regime` des äußeren Assets; der Code legt das nicht fest.

**Performancegebühr.** Die Rechnung folgt den Leitlinien der ESMA zu Performancegebühren (tägliche Abgrenzung
bei jeder Berechnung des Anteilswerts, Festschreibung höchstens einmal jährlich, High-Water-Mark über die
ganze Laufzeit). Diese Leitlinien gelten für OGAW. Bei Zertifikaten gelten die Emissionsbedingungen des
Produkts; der Nutzer prüft, ob die Rechnung dazu passt.

**Kleines Volumen.** Mindestbeträge der Engine (z. B. entfallen Umschichtungen unter 0,01 EUR) beziehen sich
innen auf das Volumen (ohne `volume` 100). Für eine genaue Übereinstimmung mit der direkt gehaltenen Strategie
`volume` in der Größe des Depots angeben.

Mit Wrapper-Assets sind keine äußeren Signale möglich (`trading = "bnh"`).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 730
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["Welt"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["Gold"] = 50 .* cumprod(1 .+ 1e-4 .+ 0.008 .* randn(rng, n))
w = wrapper_config(create_strategy(Welt = asset_config("etf"; share = 0.7), Gold = asset_config("etc"; share = 0.3));
                   rebalance = rebalance_plan(; unit = "quarter"), costs = funds_costs(0.95, 10))
s = create_strategy(Zertifikat = asset_config("certificate"; spread = 0.5, wrapper = w))
r = simulation(d, s; tax = tax_profile(; church_tax = 8), liquidate = true)
println(r["tax_report"]["total_taxes_paid"])
```
"""
function wrapper_config(strategy; rebalance = nothing, costs = funds_costs(), order_fee = nothing, volume = nothing)
    @nospecialize
    strategy === nothing &&
        chk_stop("a.m_wrapper_config")
    if !inherits(strategy, "strategy")
        (_is_mapping(strategy) || strategy isa Union{AbstractVector,Tuple}) ||
            chk_stop("a.m_wrapper_config_2")   # seit 1.6.4 ohne Klasse
        strategy = create_strategy(; assets = strategy)
    end
    strategy_validate(strategy)
    nested = _strategy_wrappers(strategy)
    isempty(nested) ||
        chk_stop("a.m_wrapper_config_3", nested[1])
    total = r_sum(Float64[Float64(a["share"]) for (_, a) in strategy])
    abs(total - 1) > 1e-6 &&
        error(r_sprintf("wrapper_config: Gewichte (share) der inneren Strategie summieren sich auf %.8g, müssen aber 1 ergeben.", total))
    (rebalance === nothing || inherits(rebalance, "SimLevRebalancePlan")) ||
        chk_stop("a.m_wrapper_config_4")
    inherits(costs, "SimLevFundsCosts") ||
        chk_stop("a.m_wrapper_config_5")
    order_fee = _blk_fee_check(order_fee, "wrapper_config", "order_fee")   # seit 1.6.4 (A-046)
    fs = _fee_spec(order_fee, "wrapper_config", "order_fee")
    volume = chk_scalar(volume)   # Länge 1 wie Einzelwert (Entscheidung 4)
    if volume !== nothing && (!_blk_one(volume) || volume <= 0)
        chk_stop("a.m_wrapper_config_6")
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
    used::Bool          # seit 1.6.3: etwas geschrieben (dann merkt die Studie den Anteilswert nicht)
end
_WrapperMsgIO(target::IO, tag::String, buf::Vector{UInt8}) = _WrapperMsgIO(target, tag, buf, false)
function _wmsg_add!(s::_WrapperMsgIO, bytes)
    isempty(bytes) || (s.used = true)
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
# ohne Kopie bzw. Vektor je Byte (seit 1.6.3): _wmsg_add! hängt an s.buf an
Base.unsafe_write(s::_WrapperMsgIO, p::Ptr{UInt8}, n::UInt) = (_wmsg_add!(s, unsafe_wrap(Array, p, n)); Int(n))
Base.write(s::_WrapperMsgIO, b::UInt8) = (_wmsg_add!(s, (b,)); 1)
Base.isopen(::_WrapperMsgIO) = true
Base.iswritable(::_WrapperMsgIO) = true
Base.flush(s::_WrapperMsgIO) = (isempty(s.buf) || _wmsg_emit!(s); flush(s.target); nothing)

"Logger der inneren Rechnung: Warnungen mit Präfix `who` an den äußeren Logger (R: `warning(…)` im Handler)."
struct _WrapperWarnLogger <: AbstractLogger
    parent::AbstractLogger
    who::String
    seen::Base.RefValue{Bool}   # seit 1.6.3: eine Meldung wurde angefragt (auch wenn der äußere Logger sie verwirft)
end
_WrapperWarnLogger(parent::AbstractLogger, who::String) = _WrapperWarnLogger(parent, who, Ref(false))
# Jede Anfrage kommt hier an (BelowMinLevel), damit `seen` sie zählt; durchgelassen wird wie vom äußeren Logger.
Base.CoreLogging.min_enabled_level(l::_WrapperWarnLogger) = Base.CoreLogging.BelowMinLevel
function Base.CoreLogging.shouldlog(l::_WrapperWarnLogger, level, args...)
    l.seen[] = true
    return level >= Base.CoreLogging.min_enabled_level(l.parent) && Base.CoreLogging.shouldlog(l.parent, level, args...)
end
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
_wrapper_nav_calc(data::_Frame, wrapper, splits, tag::String, who::String) =
    _wrapper_nav_calc_q(data, wrapper, splits, tag, who)[1]

"""Wie `_wrapper_nav_calc`, dazu ob die innere Rechnung ohne Meldung und ohne Warnung blieb: `(nav, still)`."""
function _wrapper_nav_calc_q(data::_Frame, wrapper, splits, tag::String, who::String)
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
    wlog = _WrapperWarnLogger(current_logger(), who)
    res = try
        with_logger(wlog) do
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
    # seit 1.6.5 (CR2-D-8): Datumsumrechnung und Zeilenzuordnung in typisierten Hilfen (Funktionsgrenze), Zuordnung über
    # searchsortedfirst auf den aufsteigenden Tagen wie in Python (bis 1.6.4 Dict und Schleifen über untypisierte Spalten,
    # mehr Zeit als die innere Rechnung); gleiche Stellen
    rdays = _wn_days(res["dates"])
    rfilled = res["filled"]
    idx = _wn_index(rdays, d.cols["date"])
    idx = idx[.!rfilled[idx]]
    isempty(idx) && chk_stop("a.m_wrapper_nav_calc", who)
    day = rdays[idx]
    G = Float64.(res["worth"])[idx]
    yr = _wn_years(day)
    fee = Float64(wrapper["costs"]["fee"]); pf = Float64(wrapper["costs"]["performance_fee"])
    n = length(idx)
    # Tagesschleife im Kern (core/wrapper_core_impl.h, wrapper_nav_core; bis 1.5.0 hier in Julia)
    nav = zeros(n); gross = zeros(n); fee_t = zeros(n); acc_t = zeros(n); paid_t = zeros(n); hwm = zeros(n)
    bad = Ref{Int64}(-1)
    CAbi.check(ccall((:simlev_c_wrapper_nav, LIBSLC), Cint,
                     (Int64, Ptr{Float64}, Ptr{Float64}, Ptr{Int64}, Float64, Float64, Float64, Float64, Ptr{Float64},
                      Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ref{Int64}),
                     n, G, Float64.(day), Int64.(yr), fee, pf, Float64(S), Float64(rdays[1]), nav, gross, fee_t, acc_t,
                     paid_t, hwm, bad))
    if bad[] >= 0
        t = Int(bad[]) + 1
        G_prev = t == 1 ? Float64(S) : G[t-1]
        chk_stop("a.m_wrapper_nav_calc_2", who, fmt_date(day[t]), r_format1(G[t]), r_format1(G_prev))
    end
    out = RFrame("date" => _wn_dates(day), "nav" => nav, "gross" => gross, "fee" => fee_t,
                 "perf_fee" => acc_t, "perf_paid" => paid_t, "hwm" => hwm;
                 class = ["SimLevWrapperNav", "data.frame"], attrs = Dict{String,Any}("inner" => res, "wrapper" => wrapper))
    return out, !msg.used && !wlog.seen[]
end

# typisierte Hilfen von _wrapper_nav_calc_q (seit 1.6.5, CR2-D-8)
_wn_days(v) = _wn_days_t(collect(v))
_wn_days_t(v::Vector{Date}) = Int[to_days(z) for z in v]
_wn_days_t(v::AbstractVector) = Int[to_days(z) for z in v]
function _wn_index(rdays::Vector{Int}, dd::AbstractVector)
    n = length(rdays)
    sorted = all(i -> rdays[i+1] > rdays[i], 1:n-1)
    out = Vector{Int}(undef, length(dd))
    if sorted
        @inbounds for k in eachindex(dd)
            z = Int(dd[k])
            j = searchsortedfirst(rdays, z)
            if j > n || rdays[j] != z
                sorted = false
                break
            end
            out[k] = j
        end
        sorted && return out
    end
    pos = Dict{Int,Int}(z => i for (i, z) in enumerate(rdays))   # wie bis 1.6.4 (fehlender Tag: KeyError)
    return Int[pos[Int(z)] for z in dd]
end
_wn_years(day::Vector{Int}) = Int[year_of(z) for z in day]
_wn_dates(day::Vector{Int}) = Date[from_days(z) for z in day]

"""
    wrapper_nav(data, wrapper; splits = nothing)

Anteilswert eines Fonds-Wrappers.

Rechnet den täglichen Anteilswert eines Wrappers aus `wrapper_config`: innere Bruttorechnung mit `simulation`,
dann Verwaltungsgebühr je Kalendertag und Performancegebühr gegen die High-Water-Mark. `simulation()`
verwendet dieselbe Rechnung für Wrapper-Assets; `wrapper_nav()` dient für eigene Auswertungen und Grafiken,
als Renditequelle für `withdrawal_simulation` (`x = wrapper_nav(...)`) und zur Prüfung.

# Argumente
- `data`: `RFrame` (nur Tabelle) mit Spalte `date` und den Kursspalten (und ggf. Signal- und Ereignisspalten) der
  inneren Strategie. `date` wird wie in `simulation()` als Datum gelesen; unsortierte Zeilen werden nach Datum
  sortiert.
- `wrapper`: Objekt aus `wrapper_config`.
- `splits`: `nothing` oder Objekt aus `split_rule` für die inneren Spalten (in `simulation()` die `splits` des
  Aufrufs).

# Rückgabe
Objekt der Klasse `["SimLevWrapperNav", "data.frame"]` mit einer Zeile je NAV-Tag:

- date: Datum.
- nav: Anteilswert NAV_t (Start 100).
- groß: Bruttowert 100 · G_t / G_0 ohne Fondskosten.
- fee: Verwaltungsgebühr des Tages je Anteil f_t.
- perf_fee: Abgegrenzte (aufgelaufene, noch nicht festgeschriebene) Performancegebühr je Anteil A_t am Tag t.
- perf_paid: Am Tag festgeschriebene Performancegebühr je Anteil (am letzten NAV-Tag eines Kalenderjahres A_t,
  sonst 0).
- hwm: High-Water-Mark H nach dem Tag (nach einer Festschreibung).

Attribute: `inner` (das innere `SimLevResult`) und `wrapper` (das `SimLevWrapperConfig`). `print` zeigt
Zeitraum, Kosten p. a. und Endwert (mit Brutto) und liefert `x` unsichtbar zurück.

**Auswahl.** Jede Auswahl von Zeilen oder Spalten (`x[i, ]`, `x[j]`, `x[i, j]`, `x[]`, `head()`, `tail()`,
`subset()`) liefert einen gewöhnlichen `data.frame` ohne Klasse `SimLevWrapperNav` und ohne die Attribute
`inner` und `wrapper`, weil das innere Ergebnis nicht mehr zum Ausschnitt passt (Python: `pandas.DataFrame`
ohne `attrs`, Julia: `rows()` ohne Klasse und Attribute). Für `withdrawal_simulation` ist ein Ausschnitt keine
Renditequelle mehr: `withdrawal_simulation(withdrawal_cohorts(x[i, ], price = "nav", inflation = 2))`.

# Details
**1. Innere Bruttorechnung.** `simulation(d, strategy, start_value = S, costs = sim_costs(order_fee =
order_fee), rebalance = rebalance, splits = splits, tax = nothing, fractions = true)` mit S = `volume`, ohne
`volume` S = 100. `d` ist `data` ab der ersten Zeile, in der mindestens eine innere Kursspalte einen Wert hat.
NAV-Tage sind die Zeilen von `d`, die die innere Rechnung nicht als aufgefüllt führt; an Tagen, an denen alle
inneren Kurse `NA` sind (oder die das Attribut `filled` als aufgefüllt kennzeichnet), gibt es keinen
Anteilswert. G_t ist der Gesamtwert der inneren Rechnung am NAV-Tag t; vor dem ersten NAV-Tag gilt G_0 = S.
Der Paketzustand der Ordergebühren wird gesichert und, auch bei Fehlern, wiederhergestellt.

**2. Verwaltungsgebühr täglich je Kalendertag.** Mit U_0 = 100: a_t = U_t-1 · G_t / G_t-1, f_t = a_t · (fee /
100 · Δ d_t / D_t), U_t = a_t - f_t. Δ d_t = Kalendertage seit dem vorigen NAV-Tag (am ersten NAV-Tag seit dem
ersten Tag von `d`, in der Regel 0), D_t = 366 im Schaltjahr des Datums t, sonst 365. Ein Zeitraum über den
Jahreswechsel zählt mit D_t des Jahres von t. Rechenfolge: ((fee / 100) · Δ d_t) / D_t, dann mal a_t.

**3. Performancegebühr (High-Water-Mark über die ganze Laufzeit).** Mit H = 100: A_t = pf / 100 * max(0, U_t -
H), NAV_t = U_t - A_t mit pf = `performance_fee`. Am letzten NAV-Tag jedes Kalenderjahres wird
festgeschrieben: U_t := NAV_t, danach H := max(H, U_t). Am letzten NAV-Tag insgesamt wird nicht
festgeschrieben; die Abgrenzung steckt bereits im Anteilswert. Die Verwaltungsgebühr bemisst sich an U (vor
der Abgrenzung).

**Näherungen.** Die Kosten werden auf die Bruttorechnung angewandt; feste Ordergebühren beziehen sich damit
auf das Volumen ohne abgezogene Fondskosten. Einzahlungen der Anleger ändern das Fondsvolumen nicht. Eine
Ordergebühr beim Start und ein innerer Spread senken schon den ersten Anteilswert (100 · G_1 / S).

**Randfälle.** Ein einziger Datentag ergibt einen Anteilswert ohne Gebühr (die innere Rechnung warnt dann wie
`simulation()` vor nicht definierten Kennzahlen). Sind alle inneren Kurse `NA`, fehlt eine innere Spalte oder
ist G_t-1 ≤ 0 bzw. G_t nicht endlich und positiv, folgt ein Fehler. Meldungen der inneren Rechnung erscheinen
als „Hinweis: wrapper_nav (innere Rechnung): ...“, Warnungen und Fehler als „wrapper_nav (innere Rechnung):
...“. Rechtliche Einordnung der Performancegebühr: siehe `wrapper_config`.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 730
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["Welt"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["Gold"] = 50 .* cumprod(1 .+ 1e-4 .+ 0.008 .* randn(rng, n))
w = wrapper_config(create_strategy(Welt = asset_config("etf"; share = 0.7), Gold = asset_config("etc"; share = 0.3));
                   costs = funds_costs(0.95, 10))
nv = wrapper_nav(d, w)
println(nv["nav"][end] / nv["gross"][end] - 1)   # Kosten über die Laufzeit
```
"""
function wrapper_nav(data, wrapper; splits = nothing)
    @nospecialize
    # seit 1.6.4 Meldungen ohne Klasse (Entscheidung 8); data nur als RFrame, die Meldung nennt die Umwandlung
    # (Entscheidung 6, wie simulation(); bis 1.6.3 auch NamedTuple, Dict und Paare)
    inherits(wrapper, "SimLevWrapperConfig") ||
        chk_stop("a.m_wrapper_nav")
    (splits === nothing || inherits(splits, "SimLevSplitRule")) ||
        chk_stop("a.m_wrapper_nav_2")
    (data isa RFrame && haskey(data, "date")) || chk_stop("e1.tabelle_spalten", "wrapper_nav", chk_msg("tabelle.formen"))
    data["date"] isa SimLev.RFmt.RFactor && chk_stop("spalte_faktor", "wrapper_nav", "date")   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
    fa = get(attrs(data), "filled", nothing)
    dates = SimLev.DataPrep._to_date(data["date"], "wrapper_nav: data\$date")
    i_na = findfirst(ismissing, dates)
    i_na === nothing || chk_stop("a.m_wrapper_nav_3", i_na)
    data = copy(data)
    data["date"] = Date[z for z in dates]
    zd = _wn_days(data["date"])   # seit 1.6.5 typisiert (CR2-D-8)
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
# Jede Zeilenauswahl (rows) ist eine gewöhnliche Tabelle ohne Klasse und Attribute (R: `[.SimLevWrapperNav`)
register_plain_rows!("SimLevWrapperNav")
