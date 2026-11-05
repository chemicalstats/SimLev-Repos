# Bootstrap – Gegenstück zu r/R/bootstrap.R und python/simlev/bootstrap.py
#
# Bootstrap-Pfade für Indizes, Hebelprodukte und Signale:
#   bootstrap_config  Spezifikation (Indizes, Hebelprodukte, Zusatzreihen)
#   bootstrap                         Preis-Pfade im Speicher (Klasse bootstrap_result)
#   bootstrap_validate, bootstrap_data, bootstrap_study_metrics, bootstrap_study,
#   bootstrap_probability, block_length
#
# Datenstrukturen wie in R: Pfade sind Matrizen mit Spaltennamen (NamedMat),
# die Niveau-Variante der Zusatzreihen steht im Attribut `aux_level`
# (`attrs(P)["aux_level"]`). Konfigurationen und Ergebnisse sind RList mit
# S3-Klasse; Ausgabe über register_print!/register_summary!.
#
# Bedingungen in bootstrap_probability(): Zeichenketten in R-Syntax (z. B.
# "cagr > 0 & max_drawdown <= 0.3"), ausgewertet vom gemeinsamen Auswerter
# `SimLev.RExpr` (Vorrang, NA-Logik und Funktionen wie in R). Spaltennamen der
# Ergebnistabelle sind Variablen; freie Variablen kommen aus `env` (Modul,
# NamedTuple oder Dict, Voreinstellung `Main`). Alternativ eine Julia-Funktion
# `RFrame -> Vektor`.
module Bootstrap

import ..SimLev
using ..SimLev: _match_arg   # util.jl (seit 1.6.1 eine Fassung)
using Dates
using Printf

export bootstrap_config, bootstrap_block_length, bootstrap, bootstrap_validate, bootstrap_data,
       bootstrap_study_metrics, bootstrap_study, bootstrap_probability

const RList = SimLev.RList
const RFrame = SimLev.RFrame
const RVector = SimLev.RVector
const NamedMat = SimLev.NamedMat
const NA = SimLev.NA

# ═══════════════════════════════════════════════════════════════════════════
# Kleine R-Hilfen
# ═══════════════════════════════════════════════════════════════════════════

"Platzhalter für ein nicht angegebenes Argument (R's `missing()`)."
struct _Missing end
const _MISSING = _Missing()

_stop(msg) = error(msg)
_warn(msg) = (@warn String(msg); nothing)
function _message(msg)
    println(SimLev.RParallel.r_stderr(), msg)
    nothing
end

_sp(fmt::AbstractString, args...) = SimLev.RFmt.sprintf(fmt, args...)
function _fmtstrs(x; kw...)
    r = SimLev.RFmt.format(x; kw...)
    r isa AbstractString && return [String(r)]
    return String[string(s) for s in r]
end
"R-`format(x)` als ein Text (bei Vektoren `paste(format(x), collapse = \", \")`)."
_fmt1(x; kw...) = join(_fmtstrs(x; kw...), ", ")
"`paste(format(x), collapse = \", \")` (NULL → \"\")."
_show(x) = x === nothing ? "" : _fmt1(_showable(x))
_showable(x) = x isa RVector ? x.values : x isa Tuple ? collect(x) : x
"`as.character` einer Zahl (15 signifikante Stellen)."
function _as_char(x)
    r = SimLev.RFmt.as_character(x)
    r isa AbstractString ? String(r) : String(first(r))
end
_round0(x::Real) = Float64(SimLev.RFmt.r_round(Float64(x), 0))

_isnum(x) = x isa Real && !(x isa Bool)
function _numvec(x)
    x === nothing && return nothing
    x isa Bool && return nothing
    x isa Real && return [Float64(x)]
    x isa RVector && return _numvec(x.values)
    x isa NamedMat && return _numvec(vec(x.data))
    if x isa AbstractArray
        T = Base.nonmissingtype(eltype(x))
        if T <: Real && !(T <: Bool)
            return Float64[v === missing ? NA : Float64(v) for v in vec(x)]
        end
        isempty(x) && return (eltype(x) <: Union{Real,Missing} && !(Base.nonmissingtype(eltype(x)) <: Bool)) ? Float64[] : nothing
        all(v -> (v isa Real && !(v isa Bool)) || v === missing, x) || return nothing
        return Float64[v === missing ? NA : Float64(v) for v in vec(x)]
    end
    return nothing
end
"`is.numeric(v) && length(v) == 1L && is.finite(v)`."
function _num1(v)
    a = _numvec(v)
    a !== nothing && length(a) == 1 && isfinite(a[1])
end
_f1(v) = _numvec(v)[1]

"Gleitkommavektor aus beliebigen numerischen Eingaben (immer eine neue Kopie)."
_dvec(x::Vector{Float64}) = copy(x)   # seit 1.6.3 eine Kopie (bis 1.6.2 collect und Umwandlung je Wert, gleiche Bits)
_dvec(x) = x === nothing ? Float64[] : x isa Real ? [Float64(x)] : x isa RVector ? Float64.(x.values) :
           x isa NamedMat ? Float64.(vec(x.data)) : Float64[v === missing ? NA : Float64(v) for v in vec(collect(x))]
_ivec(x) = x === nothing ? Int[] : x isa Real ? [Int(x)] : Int[Int(v) for v in vec(collect(x))]

"Matrix (Float64) aus Matrix/NamedMat/Vektor."
function _mat(x)
    x isa NamedMat && return Matrix{Float64}(x.data)
    x isa AbstractMatrix && return Matrix{Float64}(x)
    v = _dvec(x)
    return reshape(v, length(v), 1)
end
_colnames(x) = x isa NamedMat ? x.colnames : x isa RFrame ? names(x) : nothing

"Zahlen wie R-Literale als Double (Int → Float64), sonst unverändert."
_rval(v::Integer) = v isa Bool ? v : Float64(v)
_rval(v::AbstractVector{<:Integer}) = eltype(v) <: Bool ? v : Float64.(v)
_rval(v) = v

# ── benannte Vektoren / Listen ────────────────────────────────────────────

"`names(x)` für benannte Vektoren und Listen (oder `nothing`)."
function _names(x)
    x === nothing && return nothing
    x isa RVector && return x.names
    x isa RList && return keys(x)
    x isa NamedTuple && return String[string(k) for k in keys(x)]
    x isa AbstractDict && return String[string(k) for k in keys(x)]
    x isa Pair && return [string(x.first)]
    if x isa AbstractVector && !isempty(x) && all(p -> p isa Pair, x)
        return String[string(p.first) for p in x]
    end
    x isa RFrame && return names(x)
    return nothing
end
function _values(x)
    x === nothing && return Any[]
    x isa RVector && return Any[v for v in x.values]
    x isa RList && return values(x)
    x isa NamedTuple && return Any[v for v in values(x)]
    x isa AbstractDict && return Any[v for v in values(x)]
    x isa Pair && return Any[x.second]
    if x isa AbstractVector && !isempty(x) && all(p -> p isa Pair, x)
        return Any[p.second for p in x]
    end
    x isa AbstractVector && return Any[v for v in x]
    x isa Tuple && return Any[v for v in x]
    return Any[x]
end
_len(x) = x === nothing ? 0 : x isa AbstractString ? 1 : x isa Union{AbstractArray,Tuple,NamedTuple,AbstractDict} ? length(x) : 1

"`x\$name` für Listen, NamedTuple, Dict, Strukturen (fehlend/NULL → default)."
function _get(x, name::AbstractString, default = nothing)
    x === nothing && return default
    v = if x isa RList || x isa AbstractDict
        haskey(x, name) ? x[name] : (x isa AbstractDict && haskey(x, Symbol(name)) ? x[Symbol(name)] : nothing)
    elseif x isa NamedTuple
        haskey(x, Symbol(name)) ? getfield(x, Symbol(name)) : nothing
    elseif x isa RFrame
        haskey(x, name) ? x[name] : nothing
    elseif x isa AbstractVector && !isempty(x) && all(p -> p isa Pair, x)
        i = findfirst(p -> string(p.first) == name, x)
        i === nothing ? nothing : x[i].second
    elseif x isa Union{AbstractArray,Number,AbstractString,Function}
        nothing
    else
        s = Symbol(name)
        try
            hasproperty(x, s) ? getproperty(x, s) : nothing
        catch
            nothing
        end
    end
    return v === nothing ? default : v
end

"Geordnete Liste (RList) aus NamedTuple/Dict/Pairs/RList/nothing."
function _as_rlist(x)
    x === nothing && return RList()
    x isa RList && return copy(x)
    out = RList()
    nms = _names(x)
    nms === nothing && (x isa AbstractVector && isempty(x)) && return out
    nms === nothing && _stop("Liste mit Namen erwartet")
    for (k, v) in zip(nms, _values(x))
        v === nothing || (out[k] = _rval(v))
    end
    return out
end
"`utils::modifyList(base, val)` (flach)."
function _modify_list(base::RList, val)
    out = copy(base)
    val === nothing && return out
    for (k, v) in zip(_names(val), _values(val))
        if v === nothing
            delete!(out, k)
        else
            out[k] = v
        end
    end
    return out
end

function _duplicated(seq)
    seen = Set{Any}()
    out = Bool[]
    for s in seq
        push!(out, s in seen)
        push!(seen, s)
    end
    return out
end
function _setdiff(a, b)
    out = String[]
    for v in a
        (v in b || v in out) || push!(out, v)
    end
    return out
end
function _uniq(seq)
    out = eltype(seq)[]
    for s in seq
        s in out || push!(out, s)
    end
    return out
end

function _todate(x, what)
    d = SimLev.DataPrep._to_date(x, what)
    d isa Date && return [d]
    return d isa AbstractVector ? collect(d) : [d]
end
_seq_dates(start::Date, n::Integer) = Date[start + Day(i) for i in 0:n-1]
_days(d::Date) = Dates.value(d - Date(1970, 1, 1))

# ── numerische R-Bausteine ────────────────────────────────────────────────

_rsum(x) = SimLev.r_sum(x)
_rmean(x) = SimLev.r_mean(x)
_rvar(x) = SimLev.r_var(x)
_rsd(x) = SimLev.r_sd(x)
_rprod(x) = SimLev.r_prod(x)
_rpow(x, y) = SimLev.r_pow(Float64(x), Float64(y))
_rlog(x::Real) = SimLev.RLibm.log(Float64(x))

"`cumprod(x)` wie in R (long double)."
function _cumprod(x)
    return SimLev._rb_cumprod(Float64[Float64(v) for v in x])   # C-Kern
end
"`cumsum(x)` wie in R (long double)."
_cumsum(x) = SimLev.r_cumsum(x)

"`stats::median(x)` (Doubles, NA → NA; R's Teilsortierung über `RStats.median`)."
_median(x) = Float64(SimLev.RStats.median(_dvec(x)))

"`stats::quantile(x, probs, names = FALSE, type = 7)`."
function _quantile7(x, probs)
    r = SimLev.RStats.quantile(_dvec(x), _dvec(probs); names = false, type = 7)
    return _dvec(r)
end

using ..SimLev: _pmax, _pmin   # util.jl (seit 1.6.3 eine Fassung)

"R's `order(x)` für Doubles ohne NA (stabil, -0 == 0)."
_order(x) = sortperm(collect(Float64, x); alg = MergeSort, lt = (a, b) -> a < b)

"`stats::weighted.mean(x, w, na.rm)` (Standardmethode)."
function _weighted_mean(x, w; na_rm = false)
    x = _dvec(x); w = _dvec(w)
    length(w) != length(x) && _stop("'x' and 'w' must have the same length")
    if na_rm
        i = .!isnan.(x)
        w = w[i]; x = x[i]
    end
    xw = x .* w
    return _rsum(xw[w .!= 0]) / _rsum(w)
end

# ── Warnungen sammeln / unterdrücken ──────────────────────────────────────

"Logger, der Warnungen sammelt (wie `withCallingHandlers(..., warning = ...)`)."
struct _CollectLogger <: Base.CoreLogging.AbstractLogger
    msgs::Vector{String}
end
Base.CoreLogging.min_enabled_level(::_CollectLogger) = Base.CoreLogging.Warn
Base.CoreLogging.shouldlog(::_CollectLogger, args...) = true
Base.CoreLogging.catch_exceptions(::_CollectLogger) = false
function Base.CoreLogging.handle_message(l::_CollectLogger, level, message, args...; kw...)
    level >= Base.CoreLogging.Warn && level < Base.CoreLogging.Error && push!(l.msgs, string(message))
    nothing
end
"`f()` mit gesammelten Warnungen (an `msgs` angehängt)."
_collect_warnings(f, msgs::Vector{String}) = Base.CoreLogging.with_logger(f, _CollectLogger(msgs))
"`suppressWarnings(f())`."
_quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
"`suppressMessages(f())`: Meldungen verwerfen (nur die laufende Aufgabe, siehe `RParallel`)."
_no_messages(f) = SimLev.RParallel.suppress_messages(f)

_errmsg(e) = e isa ErrorException ? e.msg : e isa ArgumentError ? e.msg :
             (hasproperty(e, :msg) ? string(getproperty(e, :msg)) : sprint(showerror, e))

# ═══════════════════════════════════════════════════════════════════════════
# Zufall: Ströme aus SimLev.SLib; .par_lapply in RParallel
# ═══════════════════════════════════════════════════════════════════════════

_SL() = SimLev.SLib

"`.par_lapply(X, FUN, cores)`: steht in Schicht 0 (`SimLev.RParallel.par_lapply`)."
_par_lapply(X, FUN, cores = 1) = SimLev.RParallel.par_lapply(X, FUN, cores)

# ═══════════════════════════════════════════════════════════════════════════
# Konfiguration
# ═══════════════════════════════════════════════════════════════════════════

_is_config(x) = x isa RList && SimLev.inherits(x, "bootstrap_config")

"aux_type[[nm]] (oder nothing)."
function _aux_type_of(at, nm)
    at === nothing && return nothing
    if at isa RVector
        (at.names === nothing || !(nm in at.names)) && return nothing
        return at.values[findfirst(==(nm), at.names)]
    end
    return _get(at, nm)
end

"""
    bootstrap_config(indices; letfs = [], regime_index = nothing, aux = nothing,
                     aux_type = nothing, cross = "ratio", input = "returns")

Bootstrap-Konfiguration erstellen.

Beschreibt, welche Spalten eines Datensatzes gebootstrappt werden, welche Hebelprodukte (LETFs) daraus je Pfad
abgeleitet werden und welche Zusatzreihen (Zinsen, Inflation, Kalendertage, ...) jeweils aus derselben
historischen Zeile mitgezogen werden. Das Ergebnis ist die Eingabe `config` von `bootstrap()` und
`bootstrap_study()`.

# Argumente
- `indices`: Benannter Zeichenvektor oder benannte Liste: Pfadname -> Spaltenname in `data`, z. B. `(us =
  "us_index_l1_return", eu = "eu_index_l1_return")`. Die Pfadnamen werden zu Spaltennamen der erzeugten Pfade.
- `letfs`: Liste von Hebelprodukten (Standard: keine). Jedes Element ist eine Liste mit

  - base: Name des Basisindex (Pfadname aus `indices`), Pflicht.
  - leverage: Hebel L als Zahl ungleich 0 (Standard 2; negativ für Short-Produkte).
  - finance: Finanzierungszins in Prozent p. a. (3.5 = 3,5 Prozent) als Skalar oder Name einer Zusatzreihe aus
    `aux`, deren Werte ebenfalls in Prozent p. a. vorliegen (Standard 3.5).
  - expense: TER in Prozent p. a. (Standard 0.5; muss >= 0 sein).
  - spread: Spread auf den finanzierten bzw. leerverkauften Anteil m(L) in Prozent p. a. (Standard 0).
  - days: Kalendertage je Zeile: Skalar (Standard 1, passend für Kalendertagsdaten) oder Name einer
    Zusatzreihe (z. B. Datumsabstand bei Handelstagsdaten).
  - rate_basis, ter_basis: Tagesbasis für Zins und Spread bzw. TER (Standard 360 bzw. 365).
  - name: Spaltenname im Pfad (Standard `<base>_l<L>`, z. B. "eu_l2", bei negativem Hebel `<base>_inv<|L|>`,
    z. B. "us_inv1").

  Zahlen sind einzelne endliche Zahlen, `base` und `name` ein einzelner Text, `finance` und `days` eine Zahl oder
  ein Name aus `aux`; andere Werte (Vektoren, `Bool`, `missing`, NaN) ergeben einen Fehler (seit 1.6.3).

  Tagesrendite (MSCI Daily Leveraged/Short, plus Fondskosten): r = 1 + L (R - 1) + (1 - L) i · d / 360 - TER ·
  d / 365
  - s · m(L) · d / 360 mit Brutto-Indexrendite R, Tagen je Zeile d, i, TER und s als Anteil (Prozentangabe /
    100) und m(L) = max(L-1,0) + max(-L,0); 360 und 365 stehen für `rate_basis` und `ter_basis`. Fällt r auf 0
    oder darunter, bleibt das Produkt ab diesem Tag bei 0 (Totalverlust). Für L = 2 und konstantem Zins
    entspricht das dem Original (Finanzierung auf L - 1); für Short-Produkte wird - anders als im Original -
    der Zinsertrag auf Kapital und Leerverkaufserlös gutgeschrieben (MSCI-Methodik: -R + 2i).
- `regime_index`: Pfadname des Referenzindex für die Verfahren "regime", "evt", "tails" und die GARCH-Familie
  (Standard `nothing` = erster Index).
- `aux`: Optional (Standard `nothing` = keine) benannter Zeichenvektor Zusatzreihen: Pfadname -> Spaltenname,
  z. B. `(rate = "eu_rate", cpi = "eu_cpi")`. Zusatzreihen werden nicht simuliert, sondern aus denselben
  historischen Zeilen gezogen wie die Renditen; wie sie in den Pfad und in die Weiterverarbeitung eingehen,
  legt `aux_type` fest.
- `aux_type`: Optional (Standard `nothing` = keine Angabe) benannter Zeichenvektor: Art je Zusatzreihe, Name
  aus `aux` -> `"level"` oder `"rate"`. Ein leerer Vektor (`character(0)`) gilt wie `nothing`. Nicht genannte
  Reihen stehen wie `"rate"` mit ihren Originalwerten im Pfad, behalten aber in der Weiterverarbeitung das
  bisherige Verhalten (siehe unten).

  - "level": Niveau, z. B. ein Preisindex (CPI). Die Reihe wird in Zeilenverhältnisse zerlegt (Wert je Zeile /
    Wert der Vorzeile); der Pfad enthält das Niveau, das sich durch Kumulieren der Verhältnisse der gezogenen
    Zeilen ergibt. Startwert (Pfadzeile 1) ist der Wert der ersten verwendeten Historienzeile, bei `input =
    "prices"` der Wert der Zeile davor (Startzeile der Kurse). So entstehen keine Sprünge an Blockgrenzen. Bei
    `input = "returns"` hat die erste Historienzeile mangels Vorzeile das Verhältnis 1. Die Werte müssen
    positiv und endlich sein.
  - "rate": Rate in Prozent pro Jahr (2 = 2 % p. a.; nicht je Datenperiode, kein Anteil wie 0.02), z. B. ein
    Zins oder eine Inflationsrate: Werte der gezogenen Zeilen unverändert (keine Normierung auf 100; Pfadzeile
    1 wiederholt den Wert der ersten gezogenen Zeile). Als Inflation wird die Rate je Pfadzeile über die
    Kalendertage seit der Vorzeile aufgezinst, Π (1 + r/100)^Tage/365.25; eine konstante Rate 2 ergibt damit
    je Jahr 1.02^Tage/365.25 (1,02 bei 365,25 Tagen), bei Kalender- wie Handelstagsdaten.

  Eine ausdrückliche Angabe gilt einheitlich in allen Funktionen, die die Reihe weiterverarbeiten: `keep_aux`
  in `bootstrap_study()`, `inflation` in `withdrawal_paths()` und `withdrawal_simulation()` (`"level"` =
  Preisindex, `"rate"` = Inflationsrate in Prozent p. a.; `inflation_type` muss nicht erneut angegeben werden)
  und `withdrawal_cohorts()` mit einer Tabelle aus `bootstrap_data()`. Widersprechende Angaben dort (z. B.
  `inflation_type = "level"` bei `"rate"`) sind ein Fehler. Ohne Angabe gilt das bisherige Verhalten:
  Originalwerte im Pfad; als Inflation (`keep_aux`, `withdrawal_paths()` mit `inflation_type = "level"`) dient
  die Niveau-Variante (Attribut `aux_level`, siehe `bootstrap()`), also die kumulierten Zeilenverhältnisse,
  als wäre die Reihe ein Preisindex; eine Rate in Prozent p. a. muss dann mit `inflation_type = "rate_pa"` in
  `withdrawal_paths()` angegeben werden. Der Finanzierungszins von Hebelprodukten (`finance`) ist ebenfalls in
  Prozent p. a. (einfache Verzinsung je Zeile über `rate_basis`) und darf nicht `"level"` sein; ebenso die
  Tage je Zeile (`days`, Werte unverändert verwendet, am besten ohne Angabe).
- `cross`: Kopplung der Nicht-Referenzindizes bei den Verfahren "garch", "gjr_garch", "ms_garch",
  "ms_ar_garch_m" und "tvtp_ms_garch": `"ratio"` (Standard, wie Original: GARCH(1,1) auf das Verhältnis zur
  Referenz, z. B. EUR-Index = USD-Index x Wechselkurs) oder `"joint"` (eigene GARCH(1,1)-Dynamik je Reihe,
  Kopplung nur über das gemeinsame Residuendatum). Bei den übrigen Verfahren ohne Wirkung.
- `input`: `"returns"` (Standard; Brutto-Renditen > 0 je Zeile, wie im Original) oder `"prices"` (Kursniveaus;
  Renditen werden intern als Verhältnis aufeinanderfolgender Zeilen gebildet, die erste Zeile entfällt).

# Rückgabe
Objekt der Klasse `bootstrap_config` (Liste mit `indices`, `letfs` (mit allen Standardwerten ergänzt),
`regime_index`, `aux`, `aux_type` (Art je Zusatzreihe, vollständig), `aux_type_set` (Namen der ausdrücklich
angegebenen Arten), `cross`, `input`, `n_indices`, `n_letfs`, `n_aux`, `index_names`, `letf_names`,
`aux_names`).

# Details
Eingabedaten (`data` in `bootstrap()`): ein Tabelle (RFrame) oder eine Matrix mit einer Zeile je Beobachtung
(z. B. Kalendertage oder Handelstage) und den hier genannten Spalten. Mit `input = "returns"` enthalten die
Index-Spalten Brutto-Renditen je Zeile (z. B. 1.002 für +0,2 Prozent), mit `input = "prices"` Kursniveaus.
Eine Datumsspalte wird nicht benötigt und nicht ausgewertet; Zeilen mit fehlenden Werten in den verwendeten
Spalten werden entfernt.

# Beispiel
```julia
using SimLev
cfg = bootstrap_config((us = "us_ret", eu = "eu_ret"); regime_index = "us",
                       letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5)], aux = (rate = "eu_rate",))
println(cfg["letf_names"])
```
"""
function bootstrap_config(indices; letfs = Any[], regime_index = nothing, aux = nothing, aux_type = nothing,
                          cross = nothing, input = nothing)
    @nospecialize   # seit 1.6.3: ein Rumpf für alle Typen der Schlüsselwörter (Übersetzung je Aufrufform entfällt)
    cross = _match_arg(cross, ("ratio", "joint"))
    input = _match_arg(input, ("returns", "prices"))
    inames = _names(indices)
    (inames === nothing || any(==(""), inames)) && _stop("indices muss vollständig benannt sein: c(name1 = 'spalte1', ...)")
    index_names = collect(String, inames)
    icols = String[string(v) for v in _values(indices)]
    dup = _duplicated(index_names)
    any(dup) && _stop("Doppelte Index-Namen: " * join(index_names[dup], ", "))
    if aux !== nothing && (_names(aux) === nothing || any(==(""), _names(aux)))
        _stop("aux muss benannt sein.")
    end
    aux_names = aux === nothing ? String[] : collect(String, _names(aux))
    if aux_type !== nothing && _len(aux_type) == 0
        aux_type = nothing
    end
    at_names = String[]
    at_vals = String[]
    if aux_type !== nothing
        nm = _names(aux_type)
        vals = _values(aux_type)
        if nm === nothing || any(==(""), nm) || !all(v -> v isa AbstractString, vals)
            _stop("aux_type muss ein benannter Zeichenvektor sein: c(<Name aus aux> = 'level' oder 'rate'), z. B. c(cpi = 'level', zins = 'rate').")
        end
        at_names = collect(String, nm); at_vals = String[String(v) for v in vals]
        bad = _setdiff(at_names, aux_names)
        if !isempty(bad)
            _stop(@sprintf("aux_type: '%s' ist keine Zusatzreihe aus aux (verfügbar: %s).", join(bad, "', '"),
                           isempty(aux_names) ? "keine" : join(aux_names, ", ")))
        end
        d = _duplicated(at_names)
        any(d) && _stop(@sprintf("aux_type: Name '%s' doppelt angegeben.", at_names[d][1]))
        badi = findall(v -> !(v in ("level", "rate")), at_vals)
        if !isempty(badi)
            _stop(@sprintf("aux_type['%s'] = '%s': erlaubt sind nur 'level' (Niveau, z. B. Preisindex) und 'rate' (Rate, z. B. Zins in Prozent).",
                           at_names[badi[1]], at_vals[badi[1]]))
        end
    end
    full = Dict{String,String}(nm => "rate" for nm in aux_names)
    for (k, v) in zip(at_names, at_vals)
        full[k] = v
    end
    aux_type_full = RVector(String[full[n] for n in aux_names]; names = aux_names)
    is_level(nm) = nm isa AbstractString && get(full, nm, "") == "level"

    # LETF-Felder (seit 1.6.3 mit Typ und Länge wie in R): Zahlen einzeln und endlich, base und name einzelner Text,
    # finance und days Zahl oder Name einer Zusatzreihe
    num1(v) = _isnum(v) && isfinite(v)
    chk_num(i, v, nm) = num1(v) || _stop(@sprintf("LETF %d: %s muss eine einzelne endliche Zahl sein", i, nm))
    chk_col(i, v, nm) = num1(v) || v isa AbstractString ||
        _stop(@sprintf("LETF %d: %s muss eine einzelne endliche Zahl oder der Name einer Zusatzreihe aus aux sein", i, nm))
    letf_list = Any[]
    for (i, lt0) in enumerate(collect(letfs === nothing ? Any[] : letfs))
        lt = lt0 isa Union{RList,NamedTuple,AbstractDict} ? lt0 : RList()
        base = _get(lt, "base")
        base === nothing && _stop(@sprintf("LETF %d: 'base' muss angegeben werden", i))
        base isa AbstractString || _stop(@sprintf("LETF %d: base muss ein einzelner Name (Text) sein", i))
        base in index_names || _stop(@sprintf("LETF %d: base '%s' nicht in indices. Verfügbar: %s", i, base, join(index_names, ", ")))
        lev = _rval(_get(lt, "leverage", 2.0))
        chk_num(i, lev, "leverage")
        lev == 0 && _stop(@sprintf("LETF %d: leverage darf nicht 0 sein", i))
        fin = _rval(_get(lt, "finance", 3.5))
        chk_col(i, fin, "finance")
        fin isa AbstractString && !(fin in aux_names) && _stop(@sprintf("LETF %d: finance-Reihe '%s' nicht in aux.", i, fin))
        is_level(fin) && _stop(@sprintf("LETF %d: finance-Reihe '%s' ist in aux_type als 'level' gekennzeichnet; der Finanzierungszins muss eine Rate (Prozent p. a.) sein.", i, fin))
        _isnum(fin) && fin < 0 && _warn(@sprintf("LETF %d: negativer Finanzierungszins.", i))
        exp_ = _rval(_get(lt, "expense", 0.5))
        chk_num(i, exp_, "expense")
        exp_ < 0 && _stop(@sprintf("LETF %d: expense muss >= 0 sein", i))
        days = _rval(_get(lt, "days", 1.0))
        chk_col(i, days, "days")
        days isa AbstractString && !(days in aux_names) && _stop(@sprintf("LETF %d: days-Reihe '%s' nicht in aux.", i, days))
        is_level(days) && _stop(@sprintf("LETF %d: days-Reihe '%s' ist in aux_type als 'level' gekennzeichnet; Tage je Zeile werden unverändert gebraucht ('rate').", i, days))
        sp = _rval(_get(lt, "spread", 0.0)); rb = _rval(_get(lt, "rate_basis", 360.0)); tb = _rval(_get(lt, "ter_basis", 365.0))
        chk_num(i, sp, "spread"); chk_num(i, rb, "rate_basis"); chk_num(i, tb, "ter_basis")
        name = _get(lt, "name")
        name === nothing || name isa AbstractString || _stop(@sprintf("LETF %d: name muss ein einzelner Name (Text) sein", i))
        if name === nothing
            name = lev > 0 ? string(base, "_l", _as_char(lev)) : string(base, "_inv", _as_char(abs(lev)))
        end
        push!(letf_list, RList("name" => String(name), "base" => String(base), "leverage" => lev, "finance" => fin,
                               "expense" => exp_, "spread" => sp, "days" => days, "rate_basis" => rb, "ter_basis" => tb))
    end
    letf_names = String[l["name"] for l in letf_list]
    any(_duplicated(vcat(index_names, letf_names, aux_names))) && _stop("Namen von Indizes, LETFs und aux müssen eindeutig sein.")
    if regime_index === nothing
        regime_index = index_names[1]
    elseif !(regime_index in index_names)
        _stop(@sprintf("regime_index '%s' nicht in indices", regime_index))
    end
    aux_out = aux === nothing ? nothing : RVector(String[string(v) for v in _values(aux)]; names = aux_names)
    return RList("indices" => Any[RList("name" => nm, "col" => c) for (nm, c) in zip(index_names, icols)],
                 "letfs" => letf_list, "regime_index" => String(regime_index), "aux" => aux_out,
                 "aux_type" => aux_type_full, "aux_type_set" => at_names, "cross" => cross, "input" => input,
                 "n_indices" => length(index_names), "n_letfs" => length(letf_list), "n_aux" => length(aux_names),
                 "index_names" => index_names, "letf_names" => letf_names, "aux_names" => aux_names;
                 class = "bootstrap_config")
end

_cfg_list(x, k) = (v = _get(x, k); v === nothing ? String[] : v isa AbstractString ? [String(v)] : collect(String, _values(v)))

function _print_config(io::IO, x)
    print(io, "SimLev Bootstrap-Konfiguration\n------------------------------\n")
    inames = _cfg_list(x, "index_names")
    cols = String[string(ix["col"]) for ix in x["indices"]]
    print(io, _sp("  Indizes:      %s\n", join([string(n, "=", c) for (n, c) in zip(inames, cols)], ", ")))
    print(io, _sp("  Referenz:     %s (Kopplung: %s, Eingabe: %s)\n", x["regime_index"], x["cross"], x["input"]))
    if _get(x, "n_aux", 0) != 0
        sets = _cfg_list(x, "aux_type_set")
        at = _get(x, "aux_type")
        anames = _cfg_list(x, "aux_names")
        parts = String[]
        for (nm, col) in zip(anames, _values(x["aux"]))
            typ = nm in sets ? string(" (", _aux_type_of(at, nm), ")") : ""
            push!(parts, string(nm, "=", col, typ))
        end
        print(io, _sp("  Zusatzreihen: %s\n", join(parts, ", ")))
    end
    for lt in x["letfs"]
        fin = lt["finance"]
        print(io, _sp("  Produkt %-8s Basis %s, L = %g, Zins = %s, TER = %g %%, Spread = %g %%\n",
                      lt["name"], lt["base"], lt["leverage"], fin isa AbstractString ? fin : _fmt1(fin),
                      lt["expense"], lt["spread"]))
    end
    nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# Interne Daten- und Parameterhelfer
# ═══════════════════════════════════════════════════════════════════════════

const _BOOT_METHODS = ("raw", "block", "circular", "stationary", "wild", "regime", "evt",
                       "tails", "reset", "garch", "gjr_garch", "ms_garch",
                       "ms_ar_garch_m", "tvtp_ms_garch")

function _as_numeric_col(v)
    v isa RVector && (v = v.values)
    T = Base.nonmissingtype(eltype(v))
    if T <: Real
        return Float64[x === missing ? NA : Float64(x) for x in v]
    end
    return Float64[x === missing || x === nothing ? NA : x isa Real ? Float64(x) :
                   (x isa AbstractString ? something(tryparse(Float64, strip(x)), NA) : NA) for x in v]
end

_complete_rows(m::Matrix{Float64}) = Bool[!any(isnan, view(m, i, :)) for i in 1:size(m, 1)]

"Renditematrix und Zusatzreihen extrahieren (R: `.extract_returns`)."
function _extract_returns(data, config)
    is_df = data isa RFrame
    is_mat = data isa AbstractMatrix
    (is_df || is_mat) || _stop("data muss ein data.frame oder eine Matrix sein")
    nr = is_df ? SimLev.nrow(data) : size(data, 1)
    nr == 0 && _stop("data darf nicht leer sein")
    nms = is_df ? names(data) : (data isa NamedMat && data.colnames !== nothing ? data.colnames : String[])
    function get_col(col)
        col in nms || _stop(@sprintf("Spalte '%s' nicht gefunden. Verfügbar: %s", col, join(nms, ", ")))
        is_df && return _as_numeric_col(data[col])
        j = findfirst(==(col), nms)
        return _as_numeric_col(data[:, j])
    end
    inames = _cfg_list(config, "index_names")
    ret = isempty(config["indices"]) ? zeros(nr, 0) : reduce(hcat, [get_col(string(ix["col"])) for ix in config["indices"]])
    ret = reshape(ret, nr, length(config["indices"]))
    aux = aux0 = aux_ratio = aux_start = nothing
    anames = _cfg_list(config, "aux_names")
    aux_cols = config["n_aux"] != 0 ? String[string(v) for v in _values(config["aux"])] : String[]
    if config["n_aux"] != 0
        aux = reshape(reduce(hcat, [get_col(c) for c in aux_cols]), nr, length(aux_cols))
        aux0 = aux
    end
    prices = config["input"] == "prices"
    if prices
        ret = ret[2:end, :] ./ ret[1:end-1, :]
        aux !== nothing && (aux = aux[2:end, :])
    end
    ok = _complete_rows(ret)
    aux !== nothing && (ok = ok .& _complete_rows(aux))
    if !all(ok)
        _message(@sprintf("Hinweis: %d unvollständige Zeilen entfernt.", count(!, ok)))
        ret = ret[ok, :]
        aux !== nothing && (aux = aux[ok, :])
    end
    size(ret, 1) == 0 && _stop("data enthält keine vollständige Zeile in den verwendeten Spalten.")
    bad = findfirst(!isfinite, vec(ret))
    if bad !== nothing
        r0 = (bad - 1) % size(ret, 1) + 1; c0 = (bad - 1) ÷ size(ret, 1) + 1
        _stop(@sprintf("Renditen enthalten nicht endliche Werte (Inf), erste in Spalte '%s', Zeile %d der verwendeten Daten.",
                       inames[c0], r0))
    end
    if aux !== nothing
        okw = findall(ok)
        prev1 = prices ? aux0[okw[1], :] : aux[1, :]
        prev1 = copy(prev1)
        rows = prices ? vcat(okw[1], okw .+ 1) : vcat(okw[1], okw)
        at = _get(config, "aux_type")
        lvl = String[]
        if at !== nothing
            for (n, v) in zip(something(_names(at), String[]), _values(at))
                v == "level" && push!(lvl, n)
            end
        end
        for a in lvl
            j = findfirst(==(a), anames)
            v = vcat(prev1[j], aux[:, j])
            b = findfirst(z -> !isfinite(z) || z <= 0, v)
            if b !== nothing
                _stop(@sprintf("aux_type: Zusatzreihe '%s' (Spalte '%s') ist als 'level' gekennzeichnet und muss positiv und endlich sein; Zeile %d von data hat den Wert %s.",
                               a, aux_cols[j], rows[b], _fmt1(v[b])))
            end
        end
        for j in eachindex(prev1)
            isfinite(prev1[j]) || (prev1[j] = aux[1, j])
        end
        den = vcat(reshape(prev1, 1, :), aux[1:end-1, :])
        aux_ratio = NamedMat(aux ./ den; colnames = anames)
        aux_start = RVector(prev1; names = anames)
        aux = NamedMat(aux; colnames = anames)
    end
    any(<=(0), ret) && _stop("Renditen <= 0 gefunden (erwartet: Brutto-Renditen > 0, z. B. 1.002).")
    _median(abs.(vec(ret) .- 1)) > 0.5 &&
        _warn("Renditen sehen nicht wie Brutto-Tagesrenditen aus (Median |R - 1| > 0.5). input = 'prices' vergessen?")
    return RList("ret" => NamedMat(ret; colnames = inames), "aux" => aux, "aux_ratio" => aux_ratio, "aux_start" => aux_start)
end

const _PARAM_DEFAULTS = (
    "L" => 20.0, "block_length" => 20.0, "wild_type" => 0.0, "n_regimes" => 2.0, "vol_window" => 20.0,
    "tail_prob" => 0.05, "both_tails" => true, "p_break" => 0.02, "garch_order" => [1.0, 1.0],
    "ms_n_regimes" => 2.0, "ms_garch_model" => "gjrGARCH", "ms_ar_n_regimes" => 2.0,
    "ms_ar_garch_model" => "gjrGARCH", "tvtp_n_regimes" => 2.0, "tvtp_garch_model" => "gjrGARCH")

"Standardparameter je Verfahren (R: `.get_base_params`)."
function _get_base_params(params)
    p = _as_rlist(params)
    for (nm, dv) in _PARAM_DEFAULTS
        haskey(p, nm) || (p[nm] = dv isa Vector ? copy(dv) : dv)
    end
    return p
end

const _ESS_GRIDS = Dict{String,Any}(
    "raw" => nothing, "stationary" => ["L" => [5, 10, 20, 30, 50, 75, 100.0]],
    "block" => ["block_length" => [5, 10, 20, 30, 50, 75, 100.0]],
    "circular" => ["block_length" => [5, 10, 20, 30, 50, 75, 100.0]],
    "wild" => ["wild_type" => [0, 1, 2.0]], "regime" => ["n_regimes" => [2, 3, 4.0]],
    "evt" => ["tail_prob" => [0.01, 0.025, 0.05, 0.10]],
    "tails" => ["tail_prob" => [0.01, 0.025, 0.05, 0.10]],
    "reset" => ["p_break" => [0.01, 0.02, 0.05, 0.10]], "garch" => nothing, "gjr_garch" => nothing,
    "ms_garch" => ["ms_n_regimes" => [2, 3.0]], "ms_ar_garch_m" => ["ms_ar_n_regimes" => [2, 3.0]],
    "tvtp_ms_garch" => ["tvtp_n_regimes" => [2, 3.0]])

"Standard-ESS-Gitter je Verfahren (R: `.get_ess_grid`)."
function _get_ess_grid(method, n)
    g = get(_ESS_GRIDS, method, nothing)
    g === nothing && return nothing
    out = RList()
    for (k, v) in g
        vv = copy(v)
        if k in ("L", "block_length")
            vv = vv[vv .<= n / 2]
            isempty(vv) && (vv = [min(5.0, floor(n / 4))])
        end
        out[k] = vv
    end
    return out
end

_pget(params, nm, default) = (v = _get(params, nm); v === nothing ? default : Float64(_f1(v)))

"Effektive Stichprobengröße je Konfiguration (R: `.calculate_ess`)."
function _calculate_ess(n, method, params, info = nothing)
    n = Float64(n)
    ess = if method in ("raw", "wild", "reset", "garch", "gjr_garch")
        n
    elseif method == "stationary"
        n / _pget(params, "L", 20.0)
    elseif method in ("block", "circular")
        n / _pget(params, "block_length", 20.0)
    elseif method == "regime"
        K = _pget(params, "n_regimes", 2.0)
        ms = 1.0
        tr = _get(info, "trans")
        if tr !== nothing
            T = _mat(tr)
            d = Float64[T[i, i] for i in 1:min(size(T)...)]
            ms = _rmean(Float64[1.0 / _pmax(1e-6, 1.0 - v) for v in d])
        end
        n / (K * ms)
    elseif method in ("evt", "tails")
        n * (1 - 2 * _pget(params, "tail_prob", 0.05))
    elseif method == "ms_garch"
        n / (_pget(params, "ms_n_regimes", 2.0) * 2)
    elseif method == "ms_ar_garch_m"
        n / (_pget(params, "ms_ar_n_regimes", 2.0) * 2)
    elseif method == "tvtp_ms_garch"
        n / (_pget(params, "tvtp_n_regimes", 2.0) * 2)
    else
        n
    end
    return max(1.0, ess)
end

# ═══════════════════════════════════════════════════════════════════════════
# Automatische Blocklänge
# ═══════════════════════════════════════════════════════════════════════════

_pw_one() = RVector([1.0, 1.0]; names = ["stationary", "circular"])

"Optimale Blocklänge nach Politis & White (2004), R: `.pw_block`."
function _pw_block(x)
    x = _dvec(x)
    n = length(x)
    n < 20 && return _pw_one()
    l10 = SimLev.RLibm.log10(Float64(n))
    KN = max(5.0, sqrt(l10))
    mmax = ceil(sqrt(n)) + KN
    bmax = ceil(min(3 * sqrt(n), n / 3))
    crit = 2 * sqrt(l10 / n)
    m = _rmean(x)
    xc = x .- m
    acov(k) = _rsum(Float64[xc[i] * xc[i+k] for i in 1:n-k]) / n
    r0 = acov(0)
    r0 <= 0 && return _pw_one()
    nlag = Int(floor(mmax))
    rho = Float64[acov(k) for k in 1:nlag] ./ r0
    insig = abs.(rho) .< crit
    KNi = Int(ceil(KN))
    mhat = nothing
    for k in 1:max(0, length(insig) - KNi + 1)
        if all(insig[k:k+KNi-1])
            mhat = k
            break
        end
    end
    if mhat === nothing
        sig = findall(!, insig)
        mhat = isempty(sig) ? 1 : maximum(sig)
    end
    M = min(2 * mhat, nlag)
    kk = Float64.(1:M)
    t = abs.(kk ./ M)
    lam = Float64[v <= 0.5 ? 1.0 : (v <= 1 ? 2 * (1 - v) : 0.0) for v in t]
    Rk = Float64[acov(Int(k)) for k in kk]
    G = 2 * _rsum(lam .* kk .* Rk)
    g0 = r0 + 2 * _rsum(lam .* Rk)
    g0 <= 0 && return _pw_one()
    n13 = _rpow(Float64(n), 1 / 3)
    b_sb = _rpow(2 * (G * G) / (2 * (g0 * g0)), 1 / 3) * n13
    b_cb = _rpow(2 * (G * G) / ((4 / 3) * (g0 * g0)), 1 / 3) * n13
    return RVector([min(max(1.0, b_sb), bmax), min(max(1.0, b_cb), bmax)]; names = ["stationary", "circular"])
end

"""
    bootstrap_block_length(x; transform = "none")

Optimale Blocklänge nach Politis & White (2004) mit Korrektur von Patton et al. (2009).

Schätzt die optimale (erwartete) Blocklänge für den stationären und den zirkulären Block-Bootstrap nach
Politis & White (2004) mit der Korrektur von Patton, Politis & White (2009) (Flat-Top-Lagfenster, c = 2, K_N =
max(5, √log_10 n)).

# Argumente
- `x`: Numerischer Vektor oder Matrix (Spalten = Reihen), z. B. (Log-)Renditen je Zeile. Nicht-endliche Werte
  werden je Spalte entfernt.
- `transform`: Transformation vor der Schätzung: `"none"` (Standard, Reihe selbst), `"abs"` (|x - bar x|) oder
  `"squared"` ((x - bar x)^2).

# Rückgabe
Matrix mit Spalten `stationary` (erwartete Blocklänge für den stationären Bootstrap, Parameter `L`) und
`circular` (feste Blocklänge für den zirkulären Block-Bootstrap, Parameter `block_length`), eine Zeile je
Reihe (Zeilennamen = Spaltennamen von `x` bzw. V1, V2, ...). Einheit: Zeilen (Beobachtungen) von `x`; Werte
sind nicht gerundet, mindestens 1 und höchstens ⌈min(3√(n), n/3)⌉; bei weniger als 20 Beobachtungen 1.

# Details
Hinweis: Das Verfahren optimiert die Varianzschätzung des Mittelwerts. Für tägliche Aktienrenditen ergeben
sich oft sehr kurze Blöcke, weil die Renditen kaum autokorreliert sind. Für Pfad-Simulationen mit
Trendfolge-Signalen ist daher `transform = "abs"` (Volatilitäts- Clustering) und eine Sensitivitätsanalyse
über mehrere Blocklängen zu empfehlen; die Blocklänge sollte die Signal-Lookback-Länge nicht weit
unterschreiten.

Mit `params = (L = "auto",)` bzw. `(block_length = "auto",)` verwenden `bootstrap()` und `bootstrap_study()`
diese Schätzung (Maximum über alle Indizes, jeweils für Log-Renditen und deren Beträge).

# Literatur
Politis, D.N. & White, H. (2004), Econometric Reviews 23(1); Patton, A., Politis, D.N. & White, H. (2009),
Econometric Reviews 28(4).

# Beispiel
```julia
using SimLev, Random
e = randn(MersenneTwister(1), 2000); x = similar(e); x[1] = e[1]
for t in 2:2000; x[t] = 0.5 * x[t-1] + e[t]; end   # AR(1)
println(bootstrap_block_length(x))
```
"""
function bootstrap_block_length(x, transform_ = nothing; transform = nothing)
    transform = _match_arg(transform === nothing ? transform_ : transform, ("none", "abs", "squared"))
    if x isa RFrame
        cols = names(x)
        M = reduce(hcat, [_as_numeric_col(x[c]) for c in cols])
        M = reshape(M, SimLev.nrow(x), length(cols))
    else
        cols = x isa NamedMat ? x.colnames : nothing
        M = _mat(x)
    end
    res = zeros(size(M, 2), 2)
    for j in 1:size(M, 2)
        v = M[:, j]
        v = v[isfinite.(v)]
        if transform == "abs"
            mv = _rmean(v); v = abs.(v .- mv)
        elseif transform == "squared"
            mv = _rmean(v); d = v .- mv; v = d .* d
        end
        res[j, :] = _pw_block(v).values
    end
    rn = cols !== nothing ? cols : ["V$j" for j in 1:size(M, 2)]
    return NamedMat(res; rownames = rn, colnames = ["stationary", "circular"])
end

"\"auto\"-Parameter auflösen (R: `.resolve_auto`)."
function _resolve_auto(params, returns)
    params = _as_rlist(params)
    for nm in ("L", "block_length")
        v = _get(params, nm)
        if v isa AbstractString && v == "auto"
            R = _mat(returns)
            lr = NamedMat(map(z -> _rlog(z), R); colnames = _colnames(returns))
            b1 = bootstrap_block_length(lr); b2 = bootstrap_block_length(lr, "abs")
            col = nm == "L" ? 1 : 2
            mx = max(maximum(b1.data[:, col]), maximum(b2.data[:, col]))
            params[nm] = max(1.0, _round0(mx))
            _message(@sprintf("Automatische Blocklänge (%s, Politis-White, max. über Reihen und |r|): %d", nm, Int(params[nm])))
        end
    end
    return params
end

# ═══════════════════════════════════════════════════════════════════════════
# Modellanpassung (GARCH-Familie, Regime, EVT)
# ═══════════════════════════════════════════════════════════════════════════

"""
GARCH(1,1) / GJR-GARCH(1,1) schätzen (ML → Momente), R: `.fit_garch11`.
Seit 1.0.0 wie R über die C-Bibliothek slc (`SLib.fit_garch11`):
ML-Punktschätzer unter Normalverteilung (Raster-Starts, BFGS; GJR mit α + γ ≥ 0, also auch
γ < 0, und BFGS von allen sieben Rasterpunkten), bei Fehlschlag die Momente
mit Warnung; Methodenlabel "konstant", "ml" oder "momente". Der frühere Weg über die
rugarch-Nachbildung (mit gosolnp und Uhrzeit-Seed) und Nelder-Mead entfällt.
"""
_fit_garch11(e; gjr = false, quiet = false) = _SL().fit_garch11(_dvec(e); gjr = gjr, quiet = quiet)

"Nicht-Referenzreihen als GARCH(1,1) modellieren (R: `.fit_cross`); `base` 1-basiert."
function _fit_cross(returns, config, base)
    R = _mat(returns)
    n, k = size(R)
    others = [j for j in 1:k if j != base]
    if isempty(others)
        return RList("cols" => Int[], "mu" => Float64[], "om" => Float64[], "al" => Float64[], "be" => Float64[],
                     "ratio" => Bool[], "s2" => Float64[], "z" => zeros(n, 0))
    end
    ratio = config["cross"] == "ratio"
    inames = _cfg_list(config, "index_names")
    fits = RList[]
    for j in others
        e = ratio ? R[:, j] ./ R[:, base] .- 1 : R[:, j] .- 1
        f = _fit_garch11(e; gjr = false, quiet = true)
        _message(_sp("  Kopplung %s (%s): mu=%.2e, omega=%.2e, alpha=%.4f, beta=%.4f [%s]",
                     inames[j], config["cross"], f["mu"], f["omega"], f["alpha"], f["beta"], f["method"]))
        push!(fits, f)
    end
    return RList("cols" => Int[j - 1 for j in others],
                 "mu" => Float64[f["mu"] for f in fits], "om" => Float64[f["omega"] for f in fits],
                 "al" => Float64[f["alpha"] for f in fits], "be" => Float64[f["beta"] for f in fits],
                 "ratio" => fill(ratio, length(others)), "s2" => Float64[f["s2_init"] for f in fits],
                 "z" => reduce(hcat, [f["z"] for f in fits]))
end

"""
Tail-Schätzung (GPD-ML → Momente → empirisch → Default), R: `.fit_tail`.

Den GPD-Fit (`SLib.gpd_fit`, C-Bibliothek slc) nimmt R bei mindestens
30 Überschreitungen; Fehler darin (z. B. Suche an der Grenze ξ = -0,999) führen wie
das `tryCatch` in R zum Momenten-Schätzer.
"""
function _fit_tail(base_ret, prob, side)
    base_ret = _dvec(base_ret)
    prob = Float64(prob)
    thr = _quantile7(base_ret, side == "left" ? prob : 1 - prob)[1]
    mask = side == "left" ? base_ret .< thr : base_ret .> thr
    exc = side == "left" ? thr .- base_ret[mask] : base_ret[mask] .- thr
    ne = length(exc)
    scale = shape = nothing
    method = "none"
    if ne >= 30
        try
            f = _SL().gpd_fit(exc)
            sc = Float64(f["scale"]); sh = Float64(f["shape"])
            if isfinite(sc) && sc > 0 && isfinite(sh)
                scale = sc; shape = sh; method = "MLE"
            end
        catch e
            e isa InterruptException && rethrow()      # tryCatch(..., error = function(e) NULL)
        end
    end
    if scale === nothing && ne >= 20
        m = _rmean(exc); v = _rvar(exc)
        if v > 0 && m > 0
            ratio = m * m / v
            shape = max(-0.5, min(1.0, 0.5 * (1 - ratio)))
            scale = max(1e-3, 0.5 * m * (1 + ratio))
            method = "Momente"
        end
    end
    if scale === nothing && ne >= 5
        scale = max(1e-3, _rsd(exc)); shape = 0.1; method = "empirisch"
    end
    if scale === nothing
        scale = max(0.005, 2 * _rsd(base_ret .- 1)); shape = 0.1; method = "Default"
        _warn(@sprintf("Tail-Fit: Default-Parameter (nur %d Tail-Beobachtungen)", ne))
    end
    shape >= 0.5 && _warn(_sp("GPD shape = %.3f (%s): unendliche Varianz", shape, side))
    return RList("prob" => prob, "thresh" => thr, "scale" => scale, "shape" => shape,
                 "pool" => findall(mask), "method" => method)
end

"`seq(0, 1, length.out = n_out)`."
function _seq_len_out(n_out)
    n_out = Int(n_out)
    if n_out > 2
        n1 = n_out - 1.0
        return vcat(0.0, Float64[0.0 + i * (1.0 / n1) for i in 1:n_out-2], 1.0)
    end
    return [0.0, 1.0][1:n_out]
end

"Regime aus rollierender Volatilität (R: `.prepare_regime_info`)."
function _prepare_regime_info(base_ret, vol_window, n_regimes)
    vol = _SL().rolling_vol(base_ret, Int(trunc(Float64(vol_window))))
    th = _quantile7(vol, _seq_len_out(Float64(n_regimes) + 1))
    th[end] = th[end] + 1e-10
    reg = _SL().assign_regimes(vol, th)
    return RList("regimes" => reg, "trans" => _SL().estimate_trans_mat(reg, Int(trunc(Float64(n_regimes)))), "vol" => vol)
end

"""
MS-GARCH-Familie vorbereiten (R: `.prepare_ms_info`; eigene ML-Schätzung
`SimLev.MsGarch._ms_garch_fit`); `base` 1-basiert.
"""
function _prepare_ms_info(returns, config, base, K, garch_model, ar_gm, tvtp, cores = 1)
    MG = SimLev.MsGarch
    MG._ms_garch_check(K, garch_model)
    R = _mat(returns)
    ex = R[:, base] .- 1; n = length(ex)
    Ki = Int(Float64(K isa AbstractVector || K isa Tuple ? first(K) : K))
    gm = String(garch_model isa AbstractVector || garch_model isa Tuple ? first(garch_model) : garch_model)
    fit = try
        MG._ms_garch_fit(ex, K, garch_model; cores = cores)   # cores Threads für die Starts
    catch e
        e isa InterruptException && rethrow()
        _stop(_sp("MS-GARCH(%d, %s) Fit fehlgeschlagen: %s", Ki, gm, _errmsg(e)))
    end
    K = Ki
    om = fit["omega"]; al = fit["alpha"]; be = fit["beta"]; ga = fit["gamma"]
    P = fit["P"]
    reg = Int.(fit["regimes"])
    idx = [findall(==(r), reg) for r in 1:K]
    mu = Float64[length(i) >= 10 ? SimLev.r_mean(ex[i]) : SimLev.r_mean(ex) for i in idx]
    s2 = fit["s2"]
    sig = Float64[sqrt(isnan(v) ? v : max(v, 1e-14)) for v in s2]
    phi = zeros(K); lam = zeros(K)
    lag_ex = vcat(0.0, ex[1:n-1])
    if ar_gm
        for r in 1:K
            i = idx[r]
            length(i) < 30 && continue
            b = try
                Float64(_SL().lsfit(hcat(ones(length(i)), lag_ex[i]), ex[i])["coefficients"][2])
            catch e
                e isa InterruptException && rethrow()
                NA
            end
            isfinite(b) && (phi[r] = max(-0.5, min(0.5, b)))
            l = try
                Float64(_SL().lsfit(reshape(sig[i], :, 1), ex[i] .- mu[r] .- phi[r] .* lag_ex[i])["coefficients"][1])
            catch e
                e isa InterruptException && rethrow()
                NA
            end
            isfinite(l) && (lam[r] = max(-5.0, min(5.0, l)))
        end
    end
    unc = zeros(K)
    for r in 1:K
        p = al[r] + be[r] + ga[r] / 2
        if p < 0.9999 && om[r] > 0
            unc[r] = om[r] / (1 - p)
        else
            i = idx[r]
            unc[r] = length(i) >= 10 ? SimLev.r_var(ex[i]) : SimLev.r_var(ex)
        end
    end
    delta = zeros(K, K)
    if tvtp
        for i in 1:K
            from = findall(==(i), reg[1:n-1])
            length(from) < 50 && continue
            x = s2[from] ./ unc[i] .- 1; to = reg[from .+ 1]
            for j in 1:K
                if j != i && count(==(j), to) >= 5
                    d = try
                        g = _SL().logit_irls(hcat(ones(length(x)), x), Float64.(to .== j))   # Logit-IRLS
                        Float64(g["coefficients"][2])
                    catch e
                        e isa InterruptException && rethrow()
                        NA
                    end
                    isfinite(d) && (delta[i, j] = max(-3.0, min(3.0, d)))
                end
            end
        end
    end
    cm = Float64[mu[reg[t]] + phi[reg[t]] * lag_ex[t] + lam[reg[t]] * sig[t] for t in 1:n]
    z = Float64[(ex[t] - cm[t]) / sig[t] for t in 1:n]
    for t in 1:n
        isfinite(z[t]) || (z[t] = 0.0)
    end
    pools = [length(i) < 10 ? collect(1:n) : i for i in idx]
    for r in 1:K
        i = pools[r]
        sv = SimLev.r_sd(z[i])
        if isfinite(sv) && sv > 0
            mz = SimLev.r_mean(z[i])
            z[i] = (z[i] .- mz) ./ sv
        end
    end
    pi_ = MG._ms_garch_stat(P)
    _message(_sp("MS-GARCH(%d, %s%s%s): P(stay) = %s", K, gm, ar_gm ? ", AR-M" : "", tvtp ? ", TVTP" : "",
                 join([_sp("%.3f", P[r, r]) for r in 1:K], "/")))
    sp = SimLev.r_sum(pi_)
    return RList("K" => K, "mu" => mu, "omega" => om, "alpha" => al, "beta" => be, "gamma" => ga, "phi" => phi,
                 "lambda" => lam, "trans" => P, "delta" => delta, "unc" => unc, "stat" => pi_ ./ sp,
                 "pools" => [Int.(p) for p in pools], "z" => z, "regimes" => reg, "cross" => _fit_cross(R, config, base))
end

_istrue(x) = x === true || (x isa AbstractVector && length(x) == 1 && x[1] === true)

"Verfahrensspezifische Vorberechnung (R: `.prepare_method_info`)."
function _prepare_method_info(returns, config, method, params, cores = 1)
    R = _mat(returns)
    p = _get_base_params(params)
    base = findfirst(==(config["regime_index"]), _cfg_list(config, "index_names"))
    br = R[:, base]
    info = RList("base" => base)
    if method == "regime"
        ri = _prepare_regime_info(br, p["vol_window"], p["n_regimes"])
        for (k, v) in ri
            info[k] = v
        end
    end
    if method == "evt"
        info["left"] = _fit_tail(br, _f1(p["tail_prob"]), "left")
        right = _istrue(p["both_tails"]) ? _fit_tail(br, _f1(p["tail_prob"]), "right") : nothing
        right === nothing || (info["right"] = right)
        bulk = br .>= info["left"]["thresh"]
        right === nothing || (bulk = bulk .& (br .<= right["thresh"]))
        info["bulk"] = findall(bulk)
        isempty(info["bulk"]) && (info["bulk"] = collect(1:length(br)))
    end
    if method == "tails"
        tp = _f1(p["tail_prob"])
        lt = _quantile7(br, tp)[1]
        rt = _quantile7(br, 1 - tp)[1]
        info["left"] = findall(br .< lt)
        info["right"] = findall(br .> rt)
        info["bulk"] = findall((br .>= lt) .& (br .<= rt))
        isempty(info["bulk"]) && (info["bulk"] = collect(1:length(br)))
        info["p"] = tp
    end
    if method in ("garch", "gjr_garch")
        f = _fit_garch11(br .- 1; gjr = method == "gjr_garch")
        haskey(f, "persistence") || _stop("argument is of length zero")
        _message(_sp("%s(1,1) [%s]: mu=%.2e, omega=%.2e, alpha=%.4f, beta=%.4f, gamma=%.4f, Persistenz=%.4f",
                     uppercase(method), f["method"], f["mu"], f["omega"], f["alpha"], f["beta"], f["gamma"], f["persistence"]))
        f["persistence"] >= 0.999 && _warn(_sp("GARCH: Persistenz %.4f (nahe IGARCH)", f["persistence"]))
        info["garch"] = f
        info["cross"] = _fit_cross(R, config, base)
    end
    method == "ms_garch" && (info["ms"] = _prepare_ms_info(R, config, base, p["ms_n_regimes"], p["ms_garch_model"], false, false, cores))
    method == "ms_ar_garch_m" && (info["ms"] = _prepare_ms_info(R, config, base, p["ms_ar_n_regimes"], p["ms_ar_garch_model"], true, false, cores))
    method == "tvtp_ms_garch" && (info["ms"] = _prepare_ms_info(R, config, base, p["tvtp_n_regimes"], p["tvtp_garch_model"], true, true, cores))
    return info
end

# ═══════════════════════════════════════════════════════════════════════════
# Pfaderzeugung
# ═══════════════════════════════════════════════════════════════════════════

"`as.integer` (Abschneiden)."
_as_int(x) = x isa Integer ? Int(x) : Int(trunc(Float64(_f1(x))))

"""Eine Renditematrix samt Quellzeilen erzeugen (R: `.generate_returns`); Ziehungen aus dem
Strom des Pfads (Kerne slc_boot per `ccall`)."""
function _generate_returns(returns, method, p, info, n_out, stream; src_ok::Bool = false)
    # seit 1.6.3: die einmal je Lauf umgewandelte Renditematrix ohne Kopie (die Kerne lesen nur, SLib kopiert selbst);
    # src_ok (alle Zeilen endlich und > 0): Zeilenverfahren ohne die Kopie R[idx, :], der Pfad entsteht im Kern aus
    # den Zeilen der Quelle (_build_path, sl_boot_path_src)
    R = returns isa Matrix{Float64} ? returns : _mat(returns)
    n, k = size(R)
    from_idx(idx32) = (idx = Vector{Int}(idx32); src_ok ? RList("src" => R, "idx" => idx) : RList("ret" => R[idx, :], "idx" => idx))
    C = _SL()
    g = if method == "raw"
        from_idx(C.boot_idx_iid(n, n_out; stream = stream))
    elseif method == "block"
        from_idx(C.boot_idx_block(n, n_out, _as_int(p["block_length"]), false; stream = stream))
    elseif method == "circular"
        from_idx(C.boot_idx_block(n, n_out, _as_int(p["block_length"]), true; stream = stream))
    elseif method == "stationary"
        from_idx(C.boot_idx_stationary(n, n_out, Float64(_f1(p["L"])); stream = stream))
    elseif method == "regime"
        from_idx(C.boot_idx_regime(info["regimes"], info["trans"], n_out; stream = stream))
    elseif method == "tails"
        from_idx(C.boot_idx_tails(n_out, info["p"], info["p"], info["bulk"], info["left"], info["right"]; stream = stream))
    elseif method == "wild"
        RList("ret" => C.boot_wild(R, _as_int(p["wild_type"]); stream = stream), "idx" => collect(1:n))
    elseif method == "reset"
        RList("ret" => C.boot_reset(R, _f1(p["p_break"]); stream = stream), "idx" => collect(1:n))
    elseif method == "evt"
        lt = info["left"]; rt = _get(info, "right")
        C.boot_evt(R, info["base"] - 1, n_out, lt["prob"], lt["thresh"], lt["scale"], lt["shape"], lt["pool"],
                   rt === nothing ? 0.0 : rt["prob"], rt === nothing ? Inf : rt["thresh"],
                   rt === nothing ? 0.0 : rt["scale"], rt === nothing ? 0.0 : rt["shape"],
                   rt === nothing ? Int[] : rt["pool"], info["bulk"]; stream = stream)
    elseif method in ("garch", "gjr_garch")
        f = info["garch"]; cr = info["cross"]
        C.boot_garch(n_out, info["base"] - 1, k, f["mu"], f["omega"], f["alpha"], f["beta"], f["gamma"],
                     f["s2_init"], f["z"], collect(1:n), cr["cols"], cr["mu"], cr["om"], cr["al"],
                     cr["be"], cr["ratio"], cr["s2"], cr["z"]; stream = stream)
    elseif method in ("ms_garch", "ms_ar_garch_m", "tvtp_ms_garch")
        m = info["ms"]; cr = m["cross"]
        C.boot_ms_garch(n_out, info["base"] - 1, k, Int(m["K"]), m["mu"], m["omega"], m["alpha"], m["beta"], m["gamma"],
                        m["phi"], m["lambda"], m["trans"], m["delta"], m["unc"], m["stat"], m["pools"], m["z"],
                        cr["cols"], cr["mu"], cr["om"], cr["al"], cr["be"], cr["ratio"], cr["s2"], cr["z"]; stream = stream)
    else
        _stop(@sprintf("Unbekannte Methode: %s", method))
    end
    return g
end

"""Angaben für den Kern `sl_boot_path` (seit 1.6.0; wie `.boot_path_spec` in R) oder `nothing` (seit 1.6.3 ein
interner Fehler in `_build_path`): Zusatzreihen als Matrix, Merker der Niveau-Reihen, Hebelprodukte (`SLib.Letf`)."""
function _boot_path_spec(aux, config, aux_ratio, aux_start)
    try
        inames = _cfg_list(config, "index_names")
        anames = aux === nothing ? String[] : _cfg_list(config, "aux_names")
        lnames = config["n_letfs"] != 0 ? _cfg_list(config, "letf_names") : String[]
        allnames = vcat(inames, lnames, anames)
        length(unique(allnames)) == length(allnames) || return nothing
        A = aux === nothing ? nothing : _mat(aux)
        A === nothing || size(A, 2) == length(anames) || return nothing
        AR = aux === nothing || aux_ratio === nothing ? nothing : _mat(aux_ratio)
        AR === nothing || size(AR) == size(A) || return nothing
        s0 = AR === nothing || aux_start === nothing ? nothing : _dvec(aux_start)
        s0 === nothing || length(s0) == length(anames) || return nothing
        at = _get(config, "aux_type")
        level = Cint[_aux_type_of(at, a) == "level" for a in anames]
        cv(v) = v isa AbstractString ? (j = findfirst(==(v), anames); j === nothing ? error("Spalte") : (Cint(j - 1), 0.0)) :
                (Cint(-1), Float64(_f1(v)))
        letf = SimLev.SLib.Letf[]
        for lt in (isempty(lnames) ? Any[] : config["letfs"])
            b = findfirst(==(lt["base"]), inames)
            b === nothing && return nothing
            rc, rv = cv(_get(lt, "finance")); dc, dv = cv(_get(lt, "days"))
            push!(letf, SimLev.SLib.Letf(Cint(b - 1), Float64(_f1(_get(lt, "leverage"))), rc, rv, dc, dv,
                                         Float64(_f1(_get(lt, "rate_basis"))), Float64(_f1(_get(lt, "ter_basis"))),
                                         Float64(_f1(_get(lt, "expense"))), Float64(_f1(_get(lt, "spread")))))
        end
        return (aux = A, ratio = AR, start = s0, level = level, letf = letf, inames = inames, cols = allnames, anames = anames)
    catch e
        (e isa UndefVarError || e isa MethodError) && rethrow()
        return nothing
    end
end

"""Preis-Pfad aus Renditen bauen (R: `.build_path`); NamedMat oder `nothing` (seit 1.6.0 mit `spec` im Kern; seit
1.6.3 ohne Rückfall in Julia: unerreichbar, `bootstrap_config` prüft die LETF-Felder)."""
function _build_path(g, aux, config; start = 100.0, aux_ratio = nothing, aux_start = nothing, spec = nothing)
    if haskey(g, "src")   # Zeilen der geprüften Quelle (seit 1.6.3): gleiche Prüfungen, Kern sl_boot_path_src
        src = g["src"]::Matrix{Float64}
        idx = Vector{Int64}(g["idx"])
        (spec !== nothing && length(idx) >= 1 && size(src, 2) == length(spec.inames) &&
         (spec.aux === nothing || all(i -> 1 <= i <= size(spec.aux, 1), idx))) ||
            _stop("bootstrap: interner Fehler: Angaben für den Pfadkern unvollständig (.boot_path_spec)")
        r = SimLev.SLib.boot_path_src(src, idx, spec.aux, spec.ratio, spec.start, spec.level, spec.letf, Float64(start))
        r === nothing && return nothing
        out = NamedMat(r[1]; colnames = copy(spec.cols))
        r[2] === nothing || (out.attrs["aux_level"] = NamedMat(r[2]; colnames = copy(spec.anames)))
        return out
    end
    ret = g["ret"]
    idx = _ivec(g["idx"])
    ret isa AbstractMatrix || return nothing
    ret = _mat(ret)
    (any(!isfinite, ret) || any(<=(0), ret)) && return nothing
    # seit 1.6.0 im Kern (sl_boot_path: Kurspfade, Hebelprodukte, Zusatzreihen und Niveau-Variante in einem Aufruf)
    (spec !== nothing && size(ret, 1) >= 1 && length(idx) == size(ret, 1) && size(ret, 2) == length(spec.inames) &&
     (spec.aux === nothing || all(i -> 1 <= i <= size(spec.aux, 1), idx))) ||
        _stop("bootstrap: interner Fehler: Angaben für den Pfadkern unvollständig (.boot_path_spec)")
    r = SimLev.SLib.boot_path(ret, Int64.(idx), spec.aux, spec.ratio, spec.start, spec.level, spec.letf, Float64(start))
    r === nothing && return nothing
    out = NamedMat(r[1]; colnames = copy(spec.cols))
    r[2] === nothing || (out.attrs["aux_level"] = NamedMat(r[2]; colnames = copy(spec.anames)))
    return out
end

"ESS-Design (R: `.ess_design`): RFrame oder `nothing`."
function _ess_design(method, grid, budget, n_obs)
    grid === nothing && (grid = _get_ess_grid(method, n_obs))
    (grid === nothing || _len(grid) == 0) && return nothing
    ess_params = ("L", "block_length", "n_regimes", "tail_prob", "ms_n_regimes", "ms_ar_n_regimes", "tvtp_n_regimes")
    non_ess = ("vol_window", "wild_type", "both_tails", "p_break", "garch_order", "ms_garch_model")
    nm = collect(String, _names(grid))
    vals = [_dvec(v) for v in _values(grid)]
    # expand.grid: erster Faktor läuft am schnellsten
    rows = [Float64[]]
    for v in vals
        rows = [vcat(r, x) for x in v for r in rows]
    end
    nr = length(rows)
    cols = Pair{String,Any}[k => Float64[r[i] for r in rows] for (i, k) in enumerate(nm)]
    ess = Float64[_calculate_ess(n_obs, method, RList((k => rows[i][j] for (j, k) in enumerate(nm))...)) for i in 1:nr]
    push!(cols, "ess_per_boot" => ess)
    if any(k -> k in non_ess, nm)
        ec = [k for k in nm if k in ess_params]
        grp = isempty(ec) ? fill("all", nr) :
              String[join([_as_char(rows[i][findfirst(==(k), nm)]) for k in ec], "_") for i in 1:nr]
        cnt = Dict{String,Int}()
        for gname in grp
            cnt[gname] = get(cnt, gname, 0) + 1
        end
        nv = Float64[cnt[gname] for gname in grp]
        push!(cols, "ess_group" => grp)
        push!(cols, "n_variants" => nv)
        wa = (1 ./ ess) ./ nv
        push!(cols, "weight_alloc" => wa)
    else
        push!(cols, "n_variants" => fill(1.0, nr))
        wa = 1 ./ ess
        push!(cols, "weight_alloc" => wa)
    end
    sw = _rsum(wa)
    ns = Float64[max(1.0, _round0(budget * w / sw)) for w in wa]
    while _rsum(ns) > budget
        i = argmax(ns)
        ns[i] -= 1
    end
    push!(cols, "n_sims" => ns)
    tot = ess .* ns
    push!(cols, "total_ESS" => tot)
    target = _median(tot[tot .> 0])
    push!(cols, "weight" => Float64[t > 0 ? target / t : 0.0 for t in tot])
    design = RFrame(cols...)
    SimLev.attrs(design)["param_names"] = nm
    return design
end

"Verfahrensparameter vor dem Ziehen prüfen (R: `.check_boot_params`)."
function _check_boot_params(method, p, n_obs)
    if method == "stationary" && (!_num1(_get(p, "L")) || _f1(_get(p, "L")) < 1)
        _stop(@sprintf("params\$L (erwartete Blocklänge) muss eine Zahl >= 1 sein (erhalten: %s).", _show(_get(p, "L"))))
    end
    if method in ("block", "circular")
        b = _get(p, "block_length")
        hi = method == "block" ? n_obs - 1 : n_obs
        bv = _num1(b) ? _f1(b) : nothing
        if bv === nothing || bv != _round0(bv) || bv < 1 || bv > hi
            _stop(@sprintf("params\$block_length muss eine ganze Zahl von 1 bis %d sein (%d Zeilen Historie%s; erhalten: %s).",
                           hi, n_obs, method == "block" ? ", sonst gäbe es nur einen Blockstart" : "", _show(b)))
        end
    end
    if method == "wild"
        w = _get(p, "wild_type")
        if !_num1(w) || !(_f1(w) in (0.0, 1.0, 2.0))
            _stop(@sprintf("params\$wild_type muss 0 (Rademacher), 1 (Mammen) oder 2 (Normal) sein (erhalten: %s).", _show(w)))
        end
    end
    if method == "reset"
        pb = _get(p, "p_break")
        if !_num1(pb) || _f1(pb) < 0 || _f1(pb) > 1
            _stop(@sprintf("params\$p_break muss ein Anteil zwischen 0 und 1 sein (erhalten: %s).", _show(pb)))
        end
    end
    return true
end

"Gemeinsame Vorbereitung für bootstrap() und bootstrap_study() (R: `.boot_setup`)."
function _boot_setup(data, config, method, n, params, ess, ess_grid, path_length, cores = 1)
    _is_config(config) || _stop("config muss mit bootstrap_config() erstellt werden")
    method in _BOOT_METHODS || _stop("Unbekannte Methode '" * string(method) * "'. Verfügbar: " * join(_BOOT_METHODS, ", "))
    (!_isnum(n) || n < 1) && _stop("n muss eine positive Zahl sein")
    if path_length !== nothing && (!_num1(path_length) || _f1(path_length) < 1 || _f1(path_length) != _round0(_f1(path_length)))
        _stop(@sprintf("path_length muss eine ganze Zahl >= 1 sein (erhalten: %s).", _show(path_length)))
    end
    ex = _extract_returns(data, config)
    ex["_path_spec"] = _boot_path_spec(ex["aux"], config, ex["aux_ratio"], ex["aux_start"])   # Kern sl_boot_path (seit 1.6.0)
    # seit 1.6.3: Renditematrix einmal je Lauf (bis 1.6.2 je Pfad und Versuch kopiert) und ob alle Zeilen gültig sind
    ex["_ret_m"] = _mat(ex["ret"])
    ex["_src_ok"] = all(v -> isfinite(v) && v > 0, ex["_ret_m"])
    n_obs = size(ex["ret"], 1)
    n_out = _as_int(path_length !== nothing ? path_length : n_obs)
    if method in ("wild", "reset") && n_out != n_obs
        _stop(@sprintf("Verfahren '%s' erhält die Chronologie; path_length muss %d sein.", method, n_obs))
    end
    params = _resolve_auto(params, ex["ret"])
    design = ess ? _ess_design(method, ess_grid, _as_int(n), n_obs) : nothing
    ess && design === nothing && _message("Keine Hyperparameter für ESS - nutze Standard-Bootstrap")
    if design === nothing
        combos = RList[params]
        combo_of_path = ones(Int, Int(floor(Float64(n))))
    else
        pn = SimLev.attrs(design)["param_names"]
        combos = RList[_modify_list(params, RList((k => design[k][i] for k in pn)...)) for i in 1:SimLev.nrow(design)]
        combo_of_path = reduce(vcat, [fill(i, Int(design["n_sims"][i])) for i in 1:SimLev.nrow(design)]; init = Int[])
    end
    n_paths = length(combo_of_path)
    infos = RList[]
    for cp in combos
        info = try
            _prepare_method_info(ex["ret"], config, method, cp, cores)
        catch err
            (err isa UndefVarError || err isa MethodError) && rethrow()
            _stop(@sprintf("Vorberechnung fehlgeschlagen: %s", _errmsg(err)))
        end
        push!(infos, info)
    end
    base_p = RList[_get_base_params(cp) for cp in combos]
    for bp in base_p
        _check_boot_params(method, bp, n_obs)
    end
    weights = design === nothing ? ones(n_paths) : design["weight"][combo_of_path]
    weights = weights ./ _rsum(weights) .* length(weights)
    return RList("ex" => ex, "n_obs" => n_obs, "n_out" => n_out, "design" => design, "combos" => combos, "base_p" => base_p,
                 "infos" => infos, "combo_of_path" => combo_of_path, "n_paths" => n_paths, "weights" => weights)
end

"""Einen gültigen Pfad mit eigenem Zufallsstrom erzeugen (R: `.draw_path`); `i` 1-basiert.
`stream` ist der SimLev-Strom des Pfads; Wiederholungen ziehen daraus weiter."""
function _draw_path(setup, i, stream, config, method, max_tries)
    c_id = setup["combo_of_path"][i]
    err = "Pfad ungültig (Indexrendite <= 0 oder nicht endlich)"
    ex = setup["ex"]
    for tr in 1:Int(max_tries)
        g = try
            _generate_returns(ex["_ret_m"], method, setup["base_p"][c_id], setup["infos"][c_id], setup["n_out"], stream;
                              src_ok = ex["_src_ok"]::Bool)
        catch e
            (e isa UndefVarError || e isa MethodError) && rethrow()
            err = _errmsg(e)
            nothing
        end
        if g !== nothing
            P = _build_path(g, ex["aux"], config; aux_ratio = ex["aux_ratio"], aux_start = ex["aux_start"],
                            spec = _get(ex, "_path_spec"))
            P === nothing || return (path = P, tries = tr, err = nothing)
        end
    end
    return (path = nothing, tries = Int(max_tries), err = err)
end

# ═══════════════════════════════════════════════════════════════════════════
# bootstrap()
# ═══════════════════════════════════════════════════════════════════════════

"`nothing` -> einmal k aus G, sonst geprüft (Wert bleibt)."
_seed_or_draw(seed) = seed === nothing ? _SL().next_seed() : (_SL().check_seed(seed); seed)

"""
    bootstrap(data, config; method = "raw", n = 1000, params = RList(), ess = false,
              ess_grid = nothing, path_length = nothing, max_tries = 10, seed = nothing,
              cores = 1, progress = true)

Bootstrap-Pfade erzeugen.

Erzeugt `n` simulierte Preis-Pfade für alle Indizes der Konfiguration, leitet daraus die Hebelprodukte ab und
zieht Zusatzreihen mit. Eingabe ist ein Datensatz mit historischen Renditen oder Kursen (Format siehe
`bootstrap_config()`); Ergebnis sind Pfadmatrizen im Speicher. Einen einzelnen Pfad macht `bootstrap_data()`
zum Tabelle (RFrame) für `simulation()`; `withdrawal_paths()` wandelt alle Pfade in Periodenrenditen für
`withdrawal_simulation()` um. Für Strategievergleiche über viele Pfade ohne Speicherung der Pfade dient
`bootstrap_study()`.

# Argumente
- `data`: Tabelle (RFrame) oder Matrix mit den in `config` genannten Spalten (Index-Spalten als
  Brutto-Renditen je Zeile oder, bei `input = "prices"`, als Kursniveaus; Zusatzreihen beliebig). Jede Zeile
  ist ein Simulationsschritt ("Tag"); eine Datumsspalte wird nicht ausgewertet.
- `config`: Objekt aus `bootstrap_config()`.
- `method`: Verfahren (Standard in `bootstrap()`: `"raw"`, in `bootstrap_study()`: `"stationary"`). In
  Klammern die Einträge von `params`, die das Verfahren verwendet:

  - "raw": IID-Zeilen-Bootstrap (Efron 1979); zerstört Zeitabhängigkeit (Nullmodell). Keine Parameter.
  - "block": Moving Block Bootstrap (Künsch 1989) (`block_length`)
  - "circular": Circular Block Bootstrap (Politis & Romano 1992) (`block_length`)
  - "stationary": Stationärer Bootstrap (Politis & Romano 1994), geometrisch verteilte Blöcke (`L`)
  - "wild": Wild Bootstrap mit gemeinsamem Gewicht je Zeile für alle Reihen (`wild_type`); erhält die
    Chronologie
  - "regime": Volatilitätsregime-Markov-Bootstrap: Regime aus Quantilen der rollierenden Volatilität des
    Referenzindex (`n_regimes`, `vol_window`)
  - "evt": GPD-Tails des Referenzindex plus empirischer Bulk (`tail_prob`, `both_tails`); übrige Indizes über
    das historische Verhältnis zum Referenzindex gekoppelt
  - "tails": Empirische Tail-Schichtung des Referenzindex (`tail_prob`)
  - "reset": Chronologie mit zufällig gespiegelten Segmenten (`p_break`); erhält die Chronologie
  - "garch", "gjr_garch": (GJR-)GARCH(1,1) mit Filtered Historical Simulation (keine Parameter; Kopplung über
    `cross` in `bootstrap_config()`). Geschätzt per Maximum Likelihood unter Normalverteilung mit der
    C-Bibliothek von SimLev (GJR mit α + γ ≥ 0, also auch γ < 0; bis Version 1.0.0 γ ≥ 0; BFGS von sieben
    Rasterpunkten), notfalls mit Momentschätzern; die Meldungen nennen den Weg "ml" bzw. "momente" (bis 0.10.0
    "rugarch"/"optim")
  - "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch": Markov-Switching-GARCH-Familie: eigene ML-Schätzung des
    MS-GARCH-Modells nach Haas, Mittnik und Paolella (2004), Normalverteilung, Varianzmodell "sGARCH" oder
    "gjrGARCH" je Regime (GJR mit α + γ ≥ 0, also auch γ < 0; BFGS mit analytischem Gradienten von 12 bzw. bei
    "gjrGARCH" 20 Startpunkten); "ms_ar_garch_m" zusätzlich mit AR- und GARCH-in-Mean-Termen je Regime,
    "tvtp_ms_garch" mit zeitvariablen Uebergangswahrscheinlichkeiten (`ms_n_regimes`/`ms_garch_model`,
    `ms_ar_n_regimes`/`ms_ar_garch_model` bzw. `tvtp_n_regimes`/`tvtp_garch_model`)

  Bei "wild" und "reset" muss `path_length` der Länge der Historie entsprechen.
- `n`: Anzahl Pfade (Standard 1000); bei `ess = true` das Gesamtbudget, das auf die Parameterkombinationen
  verteilt wird. Pfade, die nach `max_tries` Versuchen ungültig bleiben, fehlen im Ergebnis.
- `params`: Benannte Liste von Verfahrensparametern; nicht angegebene Einträge erhalten den Standardwert
  (Standard `()` = alle Standardwerte). Je Verfahren werden nur die oben genannten Einträge verwendet:

  - L: Erwartete Blocklänge in Zeilen für "stationary" (Zahl >= 1, Standard 20) oder `"auto"`
    (`bootstrap_block_length()`, Spalte `stationary`).
  - block_length: Feste Blocklänge in Zeilen für "block" und "circular" (ganze Zahl, Standard 20; bei "block"
    höchstens Zeilen der Historie minus 1, bei "circular" höchstens Zeilen der Historie) oder `"auto"`
    (`bootstrap_block_length()`, Spalte `circular`).
  - wild_type: Gewichte beim Wild Bootstrap: 0 = Rademacher (Standard), 1 = Mammen, 2 = Standardnormal; andere
    Werte sind ein Fehler.
  - n_regimes: Anzahl Volatilitätsregime für "regime" (Standard 2).
  - vol_window: Fensterlänge der rollierenden Volatilität in Zeilen für "regime" (Standard 20).
  - tail_prob: Tail-Wahrscheinlichkeit je Seite als Anteil für "evt" und "tails" (Standard 0.05 = 5 Prozent).
  - both_tails: Logisch, nur "evt": auch den rechten Tail mit einer GPD modellieren (Standard `true`).
  - p_break: Wahrscheinlichkeit je Zeile als Anteil (0 bis 1), dass bei "reset" ein neues Segment beginnt
    (Standard 0.02).
  - ms_n_regimes, ms_ar_n_regimes, tvtp_n_regimes: Anzahl Regime für "ms_garch", "ms_ar_garch_m" bzw.
    "tvtp_ms_garch" (Standard je 2). Hat die Reihe weniger deutlich getrennte Regime als angefordert (z. B.
    drei Regime auf einer Reihe mit nur einem oder zwei Volatilitätszuständen), kann ein Regime entarten:
    Verweilwahrscheinlichkeit nahe 0 (Meldung "P(stay)"), kaum oder keine Tage im Regimepfad, mitunter
    Persistenz nahe 1 mit unplausibel hoher unbedingter Varianz; die Log-Likelihood liegt dann kaum über der
    mit einem Regime weniger. In diesem Fall die Anzahl Regime verkleinern.
  - ms_garch_model, ms_ar_garch_model, tvtp_garch_model: Varianzmodell je Regime: "sGARCH" (GARCH(1,1)) oder
    "gjrGARCH" (GJR-GARCH(1,1), Standard je "gjrGARCH"); andere Werte sind ein Fehler.

  Der Eintrag `garch_order` (Standard `[1, 1]`) ist vorhanden, ändert aber nichts: die GARCH-Verfahren
  schätzen immer GARCH(1,1).
- `ess`: Logisch (Standard `false`): ESS-gewichtete Gittersuche über Hyperparameter (wie im Original). Das
  Budget `n` wird invers zur effektiven Stichprobengröße (ESS) je Kombination verteilt; die Pfade erhalten
  Gewichte (Mittel 1), mit denen `bootstrap_probability()` und `summary()` rechnen. Für "raw", "garch" und
  "gjr_garch" gibt es kein Standardgitter (dann normaler Bootstrap).
- `ess_grid`: Benannte Liste von Wertevektoren je Hyperparameter (z. B. `(L = [20, 50, 100],)`); `nothing`
  (Standard) = Standardgitter des Verfahrens (z. B. `L` bzw. `block_length` 5, 10, 20, 30, 50, 75, 100 Zeilen,
  begrenzt auf die halbe Historienlänge). Nur bei `ess = true` verwendet.
- `path_length`: Pfadlänge in Zeilen (simulierte Schritte, ganze Zahl, mindestens 1); `nothing` (Standard) =
  Anzahl verwendbarer Zeilen der Historie. Damit lassen sich z. B. 50-jährige Pfade aus 30 Jahren Historie
  erzeugen. Jeder Pfad hat `path_length + 1` Zeilen (Startzeile plus Schritte).
- `max_tries`: Versuche je Pfad (Standard 10), falls ein Pfad ungültig ist (Indexrendite <= 0 oder nicht
  endlich). Ein Totalverlust eines Hebelprodukts macht den Pfad nicht ungültig.
- `seed`: Ganzzahliger Startwert (|seed| < 2^53); `nothing` (Standard) = genau einmal aus dem Zufallszustand
  von SimLev gezogen (siehe `simlev_seed()`; ganze Zahl von 0 bis 2^31 - 1, im Ergebnis unter `seed`
  gespeichert, damit reproduzierbar). Jeder Pfad i erhält einen eigenen Strom (Sprung um 2^128 Schritte je
  Pfad), so dass Pfad i unabhängig von `cores` (und bei `bootstrap_study()` von `chunk_size`) ist und
  `bootstrap()` und `bootstrap_study()` mit gleichem Seed (und gleichen Daten, Verfahren, `params`, `ess` und
  `path_length`) dieselben Pfade erzeugen. Mit angegebenem Seed bleibt der Zufallszustand von SimLev
  unverändert; mit `seed = nothing` liefern wiederholte Aufrufe verschiedene Pfade. `set.seed()` wirkt nicht.
- `cores`: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK-Cluster auf Windows). Bei den MS-GARCH-Verfahren
  (`ms_garch`, `ms_ar_garch_m`, `tvtp_ms_garch`) rechnet der Fit seine Startpunkte zudem auf so vielen
  Threads; das Ergebnis hängt davon nicht ab.
- `progress`: Logisch: Fortschritts- und Abschlussmeldung per `message()` ausgeben (Standard `true`).

# Rückgabe
Objekt der Klasse `bootstrap_result`, eine Liste mit

- paths: Liste von Matrizen, eine je gültigem Pfad, mit `path_length + 1` Zeilen: Zeile 1 = Startwert 100 für
  Indizes und Hebelprodukte, danach je Simulationsschritt. Spalten: Indizes, Hebelprodukte, Zusatzreihen in
  dieser Reihenfolge. Keine Datumsspalte. Zusatzreihen mit `aux_type = "rate"` (Prozent p. a.) und ohne Angabe
  in `aux_type` enthalten die Originalwerte der gezogenen Zeilen, solche mit `"level"` das kumulierte Niveau
  (Startwert = erste verwendete Historienzeile bzw. Startzeile der Kurse, danach die historischen
  Zeilenverhältnisse der gezogenen Zeilen kumuliert; keine Sprünge an Blockgrenzen). Bei Zusatzreihen trägt
  jede Matrix zusätzlich das Attribut `aux_level`: diese Niveau-Variante für alle Zusatzreihen (für
  `"level"`-Reihen identisch mit der Pfadspalte). Ihr Startwert (Zeile 1) ist die erste Historienzeile (bzw.
  Startzeile der Kurse) und damit für alle Pfade gleich; früher war es der Wert der Historienzeile vor dem
  ersten gezogenen Schritt (je Pfad verschieden). Die Zeilenverhältnisse sind unverändert die historischen
  Verhältnisse der gezogenen Zeilen, können aber durch die andere Startskalierung um 1 ulp von früheren Läufen
  abweichen (beabsichtigt; betrifft z. B. `withdrawal_paths()` mit `inflation_type = "level"` und `keep_aux`).
  Es dient als Inflation für Reihen ohne Angabe in `aux_type` (`withdrawal_paths()` mit `inflation_type =
  "level"`, `keep_aux` in `bootstrap_study()`); für Reihen mit `aux_type = "rate"` wird es dort nicht
  verwendet.
- weights: Pfadgewichte (Mittel 1; ohne ESS alle 1).
- method, config, seed: Verfahren, Konfiguration und verwendeter Seed.
- params: Vollständige Parameterliste (bei ESS: der ersten Kombination).
- ess, ess_design: Logisch, ob ESS verwendet wurde, und das ESS-Design (Tabelle (RFrame) je Kombination mit
  Parametern, `ess_per_boot`, `n_sims`, `weight` u. a.) bzw. `nothing`.
- param_values: Bei ESS: Parameterliste je Pfad, sonst `nothing`.
- knockout_rate: Anteil der ungültigen Versuche an allen Versuchen in Prozent (`100 *
  stats["knockout_rate"]`).
- stats: Liste mit `attempts` (Versuche gesamt), `success` (gültige Pfade), `null` (Versuche ohne gültigen
  Pfad) und `knockout_rate` (`null / attempts`, als Anteil).

# Literatur
Haas, M., Mittnik, S. & Paolella, M.S. (2004), A New Approach to Markov-Switching GARCH Models, Journal of
Financial Econometrics 2(4) (Verfahren "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"); Hamilton, J.D. (1989),
Econometrica 57(2) (Filter).

# Beispiel
```julia
using SimLev, Random
rng = MersenneTwister(2)
us = 1 .+ 3e-4 .+ 0.01 .* randn(rng, 1500)
d = RFrame("us" => us, "eu" => us .* (1 .+ 0.004 .* randn(rng, 1500)))
d["rate"] = fill(2.0, 1500)
cfg = bootstrap_config((us = "us", eu = "eu"); aux = (rate = "rate",),
                       letfs = [(base = "eu", leverage = 2, finance = "rate")])
b = bootstrap(d, cfg; method = "stationary", n = 5, params = (L = 50,), seed = 1, progress = false)
println(size(b["paths"][1]))
```
"""
function bootstrap(data, config, method_pos = nothing; method = "raw", n = 1000, params = RList(), ess = false,
                   ess_grid = nothing, path_length = nothing, max_tries = 10, seed = nothing, cores = 1, progress = true)
    data = SimLev.as_rframe(data)
    method_pos === nothing || (method = method_pos)
    t0 = time()
    setup = _boot_setup(data, config, method, n, params, ess, ess_grid, path_length, cores)
    seed = _seed_or_draw(seed)
    streams = _SL().streams(seed, setup["n_paths"])            # U_i = J^i(S_0)
    res = _par_lapply(1:setup["n_paths"],
        i -> _draw_path(setup, i, streams[i], config, method, max_tries), cores)
    ok = Bool[r.path !== nothing for r in res]
    tries = Float64[r.tries for r in res]
    if !any(ok)
        last = isempty(res) ? nothing : res[end].err
        _stop(@sprintf("Keine gültigen Pfade erzeugt (%d Versuche; letzte Ursache: %s).",
                       Int(_rsum(tries)), last === nothing ? "unbekannt" : last))
    end
    st = _rsum(tries)
    nok = count(ok)
    ko = (st - nok) / st
    w = setup["weights"][ok]
    w = w ./ _rsum(w) .* length(w)
    progress && _message(_sp("Bootstrap '%s': %d Pfade x %d Tage in %.1f s (Knockout-Rate %.2f %%).",
                             method, nok, setup["n_out"], time() - t0, 100 * ko))
    design = setup["design"]
    return RList("paths" => Any[r.path for (r, o) in zip(res, ok) if o], "weights" => w, "method" => method,
                 "config" => config, "params" => setup["base_p"][1], "ess" => design !== nothing, "ess_design" => design,
                 "param_values" => design === nothing ? nothing : Any[setup["combos"][c] for (c, o) in zip(setup["combo_of_path"], ok) if o],
                 "seed" => seed, "knockout_rate" => 100 * ko,
                 "stats" => RList("attempts" => st, "success" => nok, "null" => st - nok, "knockout_rate" => ko);
                 class = "bootstrap_result")
end

_is_boot_result(x) = x isa RList && SimLev.inherits(x, "bootstrap_result")
_nrow(p) = p isa RFrame ? SimLev.nrow(p) : p isa AbstractMatrix ? size(p, 1) : 0
_ncol(p) = p isa RFrame ? SimLev.ncol(p) : p isa AbstractMatrix ? size(p, 2) : 0

function _print_boot_result(io::IO, x)
    P = x["paths"][1]
    ess = _istrue(_get(x, "ess")) ? _sp(", ESS-gewichtet (%d Kombinationen)", SimLev.nrow(x["ess_design"])) : ""
    cn = _colnames(P)
    print(io, _sp("SimLev Bootstrap '%s': %d Pfade, je %d Zeilen x %d Spalten (%s)%s\n",
                  x["method"], length(x["paths"]), _nrow(P), _ncol(P), join(cn === nothing ? String[] : cn, ", "), ess))
end

"""
    bootstrap_validate(result; min_rows = nothing, verbose = true)

Bootstrap-Ergebnis validieren und bereinigen.

Entfernt leere, unvollständige (`NA`) oder nicht endliche Pfade sowie Pfade, deren Zeilenzahl von der
häufigsten Zeilenzahl abweicht, und normiert die Gewichte neu auf Mittel 1 (wie im Original). Nützlich vor der
Weiterverarbeitung von `bootstrap()`-Ergebnissen, die z. B. von Hand verändert oder aus mehreren Läufen
zusammengesetzt wurden.

# Argumente
- `result`: Objekt der Klasse `bootstrap_result` aus `bootstrap()`.
- `min_rows`: Mindestzeilenzahl je Pfad; `nothing` (Standard) = keine Mindestlänge.
- `verbose`: Logisch: Anzahl entfernter und gültiger Pfade ausgeben (Standard `true`).

# Rückgabe
Das bereinigte `bootstrap_result` (`paths`, `weights` und `param_values` gekürzt). Bleibt kein Pfad übrig,
bricht die Funktion mit einem Fehler ab.

# Beispiel
```julia
using SimLev, Random
d = RFrame("r" => 1 .+ 3e-4 .+ 0.01 .* randn(MersenneTwister(1), 500))
b = bootstrap(d, bootstrap_config((idx = "r",)); method = "stationary", n = 3, params = (L = 20,), seed = 1,
              progress = false)
b["paths"][2][10, 1] = NaN       # einen Pfad beschädigen
b = bootstrap_validate(b)
println(length(b["paths"]))
```
"""
function bootstrap_validate(result; min_rows = nothing, verbose = true)
    _is_boot_result(result) || _stop("result muss ein bootstrap_result-Objekt sein")
    P = collect(Any, something(_get(result, "paths"), Any[]))
    isempty(P) && _stop("Keine Pfade im Ergebnis vorhanden")
    function valid(p)
        (p === nothing || !(p isa AbstractMatrix || p isa RFrame) || _nrow(p) == 0) && return false
        a = p isa RFrame ? reduce(vcat, [_as_numeric_col(c) for c in p.cols]) : vec(_mat(p))
        return !any(isnan, a) && all(isfinite, a)
    end
    ok = Bool[valid(p) for p in P]
    if any(ok)
        ln = [p === nothing ? nothing : _nrow(p) for p in P]
        cnt = Dict{Int,Int}()
        for (v, o) in zip(ln, ok)
            o && (cnt[v] = get(cnt, v, 0) + 1)
        end
        ks = sort(collect(keys(cnt)))
        best = ks[1]
        for k in ks
            cnt[k] > cnt[best] && (best = k)
        end
        ok = ok .& Bool[v == best for v in ln]
        min_rows === nothing || (ok = ok .& Bool[v !== nothing && v >= min_rows for v in ln])
    end
    any(ok) || _stop("Keine gültigen Pfade nach Validierung übrig")
    verbose && any(!, ok) && print(stdout, @sprintf("%d von %d Pfaden entfernt\n", count(!, ok), length(ok)))
    out = copy(result)
    out["paths"] = P[ok]
    if _get(result, "weights") !== nothing
        w = _dvec(result["weights"])[ok]
        out["weights"] = w ./ _rsum(w) .* length(w)
    end
    pv = _get(result, "param_values")
    pv === nothing || (out["param_values"] = collect(Any, pv)[ok])
    verbose && print(stdout, @sprintf("%d valide Pfade, je %d Zeilen\n", length(out["paths"]), _nrow(out["paths"][1])))
    return out
end

"Matrix/RFrame-Pfad als RFrame mit führender Datumsspalte."
function _path_frame(dates, P)
    cols = Pair{String,Any}["date" => dates]
    if P isa RFrame
        for c in names(P)
            push!(cols, c => P[c])
        end
    else
        M = _mat(P)
        cn = _colnames(P)
        cn === nothing && (cn = ["V$j" for j in 1:size(M, 2)])
        for (j, c) in enumerate(cn)
            push!(cols, c => M[:, j])
        end
    end
    return RFrame(cols...)
end

"""
    bootstrap_data(result, i = 1; dates = nothing, start = "2000-01-01")

Bootstrap-Pfad als `RFrame` für `simulation`.

Wandelt einen Pfad aus `bootstrap()` in einen Tabelle (RFrame) mit Datumsspalte um, der direkt an
`simulation()` übergeben werden kann. Die Spaltennamen sind die Pfadnamen aus `bootstrap_config()` (Indizes,
Hebelprodukte, Zusatzreihen); die Strategie muss Assets mit diesen Namen verwenden.

# Argumente
- `result`: `bootstrap_result` aus `bootstrap()` oder eine einzelne Pfadmatrix (z. B. `result["paths"][[i]]`).
- `i`: Pfadnummer (Standard 1); nur bei `bootstrap_result` verwendet.
- `dates`: Datumsvektor mit genau so vielen Elementen wie der Pfad Zeilen hat (`path_length + 1`), z. B. ein
  Handelstagskalender; `nothing` (Standard) = aufeinanderfolgende Kalendertage ab `start`.
- `start`: Startdatum für `dates = nothing` (Zeichenkette oder Date, Standard "2000-01-01").

# Rückgabe
Tabelle (RFrame) mit Spalte `date` (Klasse Date) und allen Pfadspalten (Kursniveaus mit Startwert 100;
Zusatzreihen mit `aux_type = "rate"` (Prozent p. a.) und ohne Angabe als Originalwerte der gezogenen Zeilen,
mit `"level"` als kumuliertes Niveau, z. B. ein durchgehender CPI ohne Sprünge an Blockgrenzen; siehe
`bootstrap_config()`). Bei einem `bootstrap_result`, dessen Konfiguration Reihen ausdrücklich als `aux_type =
"rate"` kennzeichnet, trägt der Tabelle (RFrame) das Attribut `aux_type` mit diesen Reihen (z. B. `(infl =
"rate",)`); `withdrawal_cohorts()` behandelt sie als Inflationsrate in Prozent p. a. Ohne solche Angabe
entfällt das Attribut (Ergebnis wie bisher). Umformungen wie `transform()`, `merge()`, `cbind()` oder
CSV-Export entfernen das Attribut; dann in `withdrawal_cohorts()` `inflation_type = "rate_pa"` angeben.

# Beispiel
```julia
using SimLev, Random
d = RFrame("r" => 1 .+ 3e-4 .+ 0.01 .* randn(MersenneTwister(1), 800))
cfg = bootstrap_config((idx = "r",); letfs = [(base = "idx", leverage = 2)])
b = bootstrap(d, cfg; method = "stationary", n = 2, params = (L = 20,), path_length = 400, seed = 1, progress = false)
x = bootstrap_data(b, 2; start = "2030-01-01")
res = simulation(x, create_strategy(idx_l2 = asset_config("etf")))
println(res["cagr"])
```
"""
function bootstrap_data(result, i_pos = 1; i = i_pos, dates = nothing, start = "2000-01-01")
    is_res = _is_boot_result(result)
    P = is_res ? result["paths"][Int(i)] : result
    nr = _nrow(P)
    dates === nothing && (dates = _seq_dates(_todate(start, "start")[1], nr))
    _len(dates) != nr && _stop(@sprintf("dates hat Länge %d, Pfad hat %d Zeilen.", _len(dates), nr))
    d = _todate(dates, "dates")
    out = _path_frame(d, P)
    if is_res
        cfg = result["config"]
        sets = _cfg_list(cfg, "aux_type_set")
        at = _get(cfg, "aux_type")
        keep = [s for s in sets if _aux_type_of(at, s) == "rate"]
        isempty(keep) || (SimLev.attrs(out)["aux_type"] = RVector(fill("rate", length(keep)); names = keep))
    elseif !(P isa RFrame || P isa AbstractDict || P isa NamedTuple)
        _stop("\$ operator is invalid for atomic vectors")
    end
    return out
end

# Kennzahlen, bei denen ein kleinerer Wert günstiger ist (Drawdowns)
const _LOWER_BETTER = ("max_drawdown", "avg_drawdown", "dd_q50", "dd_q90", "ulcer_index", "longest_drawdown")

_is_result(x) = x isa SimLev.SimLevResult || (x isa RList && SimLev.inherits(x, "SimLevResult"))

"Summe aller Werte eines benannten Vektors/einer Liste (NULL → 0)."
function _tot(v)
    v === nothing && return 0.0
    if v isa AbstractDict || v isa NamedTuple
        vals = Float64[]
        for x in values(v)
            x === nothing || append!(vals, _dvec(x))
        end
        return _rsum(vals)
    end
    return _rsum(_dvec(v))
end

"""
    bootstrap_study_metrics(res)

Standard-Kennzahlen für `bootstrap_study` (benannter Vektor).

Fasst ein Ergebnis von `simulation()` zu einem benannten Kennzahlenvektor zusammen. Standardwert des Arguments
`metrics` von `bootstrap_study()`, `sensitivity_grid()`, `sensitivity_rebalancing()` und
`sensitivity_leverage()`; eigene Kennzahlfunktionen müssen ebenfalls ein `SimLevResult` entgegennehmen und
einen benannten numerischen Vektor liefern.

# Argumente
- `res`: `SimLevResult` aus `simulation()`.

# Rückgabe
Benannter numerischer Vektor mit

- cagr, ttwror: CAGR und annualisierte TTWROR als Anteil (0.05 = 5 Prozent). Mit Sparplan (Einzahlungen nach
  dem Starttag, `res["external_flows"]`) ist `cagr` die geldgewichtete Jahresrendite (XIRR, siehe
  `simulation()`), `ttwror` die zeitgewichtete.
- final_value: Endwert des Depots (Währungseinheiten).
- max_drawdown, avg_drawdown: Maximaler und mittlerer Drawdown (Mittel über Zeilen mit Drawdown > 0), als
  positiver Anteil.
- dd_q50, dd_q90: Median und 90-Prozent-Quantil der Drawdowns über alle Zeilen, als Anteil.
- ulcer_index: Ulcer Index (Drawdowns als Anteil).
- longest_drawdown: Längste Drawdown-Phase in Zeilen der Daten.
- sharpe, sortino, calmar, omega: Kennzahlen aus `res["statistics"]`, wie in `simulation()` berechnet.
- mean, sd, skewness, kurtosis, lpm, hpm: Momente und partielle Momente der Renditen je Zeile aus
  `res["statistics"]`.
- taxes: Gezahlte Steuern gesamt (Währungseinheiten; 0 ohne Steuerbericht).
- trades: Käufe plus Verkäufe je Jahr, summiert über alle Assets.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1095
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
res = simulation(d, create_strategy(aktien = asset_config("etf")))
println(bootstrap_study_metrics(res))
```
"""
function bootstrap_study_metrics(res)
    s = _get(res, "statistics", RList())
    dq = _quantile7(_dvec(_get(res, "drawdowns")), [0.5, 0.9])
    worth = _dvec(_get(res, "worth"))
    tr = _get(res, "tax_report")
    taxes = _get(tr, "total_taxes_paid")
    items = Pair{String,Any}["cagr" => _get(res, "cagr"), "ttwror" => _get(res, "ttwror"), "final_value" => worth[end],
             "max_drawdown" => _get(s, "max_drawdown"), "avg_drawdown" => _get(s, "average_drawdown"),
             "dd_q50" => dq[1], "dd_q90" => dq[2], "ulcer_index" => _get(s, "ulcer_index"),
             "longest_drawdown" => _get(s, "longest_drawdown"), "sharpe" => _get(s, "sharpe"),
             "sortino" => _get(s, "sortino"), "calmar" => _get(s, "calmar"), "omega" => _get(s, "omega"),
             "mean" => _get(s, "mean"), "sd" => _get(s, "sd"), "skewness" => _get(s, "skewness"),
             "kurtosis" => _get(s, "kurtosis"), "lpm" => _get(s, "lpm"), "hpm" => _get(s, "hpm"),
             "taxes" => taxes === nothing ? 0.0 : taxes,
             "trades" => _tot(_get(res, "buys")) + _tot(_get(res, "sells"))]
    nm = String[]; vals = Float64[]
    for (k, v) in items
        v === nothing && continue
        for z in _dvec(v)
            push!(nm, k); push!(vals, z)
        end
    end
    return RVector(vals; names = nm)
end

# ═══════════════════════════════════════════════════════════════════════════
# bootstrap_study()
# ═══════════════════════════════════════════════════════════════════════════

_is_study(x) = x isa RList && SimLev.inherits(x, "SimLevBootstrapStudy")
_is_strategy(s) = s isa SimLev.Strategy || (s isa RList && SimLev.inherits(s, "strategy"))

"Einfaches `deparse()` für Argumentwerte in Fehlermeldungen."
function _deparse(v)
    v === nothing && return "NULL"
    v isa Bool && return v ? "TRUE" : "FALSE"
    v isa AbstractString && return "\"" * escape_string(v) * "\""
    v isa Real && return _as_char(v)
    if v isa AbstractVector
        isempty(v) && return "NULL"
        length(v) == 1 && return _deparse(v[1])
        return "c(" * join([_deparse(x) for x in v], ", ") * ")"
    end
    return string(v)
end

"`simulation()` mit den aufgelösten sim_args (R: `.sim_call`)."
_sim_call(df, strategy, args) = SimLev._sim_call(df, strategy, args)

"Logische Spalten: `NA` → `FALSE`."
function _logical_fill(v)
    v isa RVector && (v = v.values)
    v isa AbstractVector || return v
    T = eltype(v)
    if T <: Union{Missing,Bool} && T !== Missing
        return Bool[x === missing ? false : x for x in v]
    end
    if !isempty(v) && all(x -> x === missing || x isa Bool, v)
        return Bool[x === missing ? false : x for x in v]
    end
    return v
end

function _set_col!(df::RFrame, k::AbstractString, v)
    v = _logical_fill(v)
    df[String(k)] = v isa AbstractVector ? collect(v) : v
    df
end

_sim_rows(df::RFrame, rows) = SimLev.rows(df, rows)

# ── Zwischenspeicher der Chunks (chunk_dir) ───────────────────────────────
# Seit 1.6.3 eigenes Binärformat (bis 1.6.2 Julia-Quelltext, gelesen mit Meta.parse und Core.eval): Kopf
# _CHUNK_KOPF (8 Byte) und Fassung (UInt32), dann der Wert als Baum aus Kennbyte und Inhalt. Zahlen mit ihren rohen
# Bits (Float64 bitgleich, auch die NaN-Nutzlast), Längen und ganze Zahlen als Int64, Text als UTF-8 mit Länge, alles
# little-endian. Gelesen wird nur dieses Format, kein Code. Gespeichert werden dieselben Typen wie bis 1.6.2:
# nothing, Bool, ganze Zahl (als Int), Float64, Text, Date, RVector (Werte, Namen), NamedMat (Werte, Größe, Zeilen- und
# Spaltennamen, Attribute), RList (Einträge, Klasse), NamedTuple, AbstractDict (Schlüssel als Text), Matrix und Vektor
# (Elementtyp Float64, Bool, Int, String, Date oder Any wie bis 1.6.2).
# Dateiname (seit 1.6.3 je Sprache, R: .chunk_stem, .chunk_pruefen): <Stamm>_jl.bin, Stamm
# chunk_<Nr>_seed<Seed>[_<keep_returns>][_keep<k>]; R schreibt <Stamm>_r.rds, Python <Stamm>_py.pkl, bis 1.6.2 alle
# drei <Stamm>.rds. Liegt zu einem Chunk ohne eigene Datei eine fremde oder alte vor (oder hat die eigene einen anderen
# Kopf): Fehler mit derselben Meldung wie in R und Python.

const _CHUNK_KOPF = collect(codeunits("SLVCHNK\0"))   # 8 Byte
const _CHUNK_FASSUNG = UInt32(1)
const _CHUNK_KENNUNG = (".rds", "_r.rds", "_py.pkl", "_jl.bin")
_chunk_stem(ci, seed, keep_returns, keep_paths) =
    @sprintf("chunk_%05d_seed%d%s%s", ci, Int(seed), keep_returns != "none" ? "_" * keep_returns : "",
             keep_paths > 0 ? @sprintf("_keep%d", Int(keep_paths)) : "")
_chunk_meldung(datei) = "chunk_dir: '$datei' stammt von einer anderen Sprache oder einer älteren Fassung von SimLev " *
                        "(bis 1.6.2) und wird nicht gelesen; je Sprache ein eigenes Verzeichnis verwenden."
function _chunk_pruefen(d, n_chunks, seed, keep_returns, keep_paths, eigen)
    for ci in 1:n_chunks
        st = _chunk_stem(ci, seed, keep_returns, keep_paths)
        isfile(joinpath(d, st * eigen)) && continue
        for k in _CHUNK_KENNUNG
            k != eigen && isfile(joinpath(d, st * k)) && _stop(_chunk_meldung(st * k))
        end
    end
    nothing
end

# Kennbytes der Werte und Elementtypen der Vektoren
const _CK_NOTHING, _CK_BOOL, _CK_INT, _CK_F64, _CK_STR, _CK_DATE = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05
const _CK_RV, _CK_NM, _CK_RL, _CK_NT, _CK_DICT, _CK_MAT, _CK_VEC = 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c
const _CE_ANY, _CE_F64, _CE_BOOL, _CE_INT, _CE_STR, _CE_DATE = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05

_cw_i64(io, v) = write(io, htol(Int64(v)))
_cw_str(io, x) = (b = codeunits(String(x)); _cw_i64(io, length(b)); write(io, b))
function _cw_pairs(io, ps)
    _cw_i64(io, length(ps))
    for (k, v) in ps
        _cw_str(io, string(k)); _chunk_write(io, v)
    end
end
function _chunk_write(io::IO, x)
    if x === nothing
        write(io, _CK_NOTHING)
    elseif x isa Bool
        write(io, _CK_BOOL, UInt8(x))
    elseif x isa Integer
        write(io, _CK_INT); _cw_i64(io, Int(x))
    elseif x isa Float64
        write(io, _CK_F64, htol(reinterpret(UInt64, x)))
    elseif x isa AbstractString
        write(io, _CK_STR); _cw_str(io, x)
    elseif x isa Date
        write(io, _CK_DATE); _cw_i64(io, Dates.value(x))
    elseif x isa RVector
        write(io, _CK_RV); _chunk_write(io, x.values); _chunk_write(io, x.names)
    elseif x isa NamedMat
        write(io, _CK_NM); _chunk_write(io, vec(x.data)); _cw_i64(io, size(x, 1)); _cw_i64(io, size(x, 2))
        _chunk_write(io, x.rownames); _chunk_write(io, x.colnames); _cw_pairs(io, collect(x.attrs))
    elseif x isa RList
        write(io, _CK_RL); _cw_pairs(io, collect(x)); _chunk_write(io, collect(String, x.class))
    elseif x isa NamedTuple
        write(io, _CK_NT); _cw_pairs(io, collect(pairs(x)))
    elseif x isa AbstractDict
        write(io, _CK_DICT); _cw_pairs(io, collect(x))
    elseif x isa AbstractMatrix
        write(io, _CK_MAT); _chunk_write(io, vec(collect(x))); _cw_i64(io, size(x, 1)); _cw_i64(io, size(x, 2))
    elseif x isa AbstractVector
        T = eltype(x)
        e = T <: Float64 ? _CE_F64 : T <: Bool ? _CE_BOOL : T <: Integer ? _CE_INT : T <: AbstractString ? _CE_STR :
            T <: Date ? _CE_DATE : _CE_ANY
        write(io, _CK_VEC, e); _cw_i64(io, length(x))
        if e == _CE_F64
            for v in x
                write(io, htol(reinterpret(UInt64, Float64(v))))
            end
        elseif e == _CE_BOOL
            for v in x
                write(io, UInt8(v))
            end
        elseif e == _CE_INT
            for v in x
                _cw_i64(io, Int(v))
            end
        elseif e == _CE_STR
            for v in x
                _cw_str(io, v)
            end
        elseif e == _CE_DATE
            for v in x
                _cw_i64(io, Dates.value(v))
            end
        else
            for v in x
                _chunk_write(io, v)
            end
        end
    else
        error("chunk_dir: Wert vom Typ $(typeof(x)) nicht speicherbar")
    end
    nothing
end

_cr_i64(io) = Int(ltoh(read(io, Int64)))
_cr_str(io) = String(read(io, _cr_i64(io)))
_cr_pairs(io) = [(_cr_str(io) => _chunk_read(io)) for _ in 1:_cr_i64(io)]
function _chunk_read(io::IO)
    t = read(io, UInt8)
    t == _CK_NOTHING && return nothing
    t == _CK_BOOL && return read(io, UInt8) != 0x00
    t == _CK_INT && return _cr_i64(io)
    t == _CK_F64 && return reinterpret(Float64, ltoh(read(io, UInt64)))
    t == _CK_STR && return _cr_str(io)
    t == _CK_DATE && return Date(Dates.UTD(_cr_i64(io)))
    if t == _CK_RV
        v = _chunk_read(io)
        return RVector(v; names = _chunk_read(io))
    elseif t == _CK_NM
        v = _chunk_read(io); r = _cr_i64(io); c = _cr_i64(io)
        rn = _chunk_read(io); cn = _chunk_read(io)
        m = NamedMat(reshape(v, r, c); rownames = rn, colnames = cn)
        for (k, a) in _cr_pairs(io)
            m.attrs[k] = a
        end
        return m
    elseif t == _CK_RL
        ps = _cr_pairs(io)
        return RList(ps...; class = _chunk_read(io))
    elseif t == _CK_NT
        ps = _cr_pairs(io)
        return NamedTuple{Tuple(Symbol(p.first) for p in ps)}(Tuple(p.second for p in ps))
    elseif t == _CK_DICT
        return Dict{String,Any}(_cr_pairs(io))
    elseif t == _CK_MAT
        v = _chunk_read(io); r = _cr_i64(io); c = _cr_i64(io)
        return reshape(v, r, c)
    elseif t == _CK_VEC
        e = read(io, UInt8); n = _cr_i64(io)
        e == _CE_F64 && return Float64[reinterpret(Float64, ltoh(read(io, UInt64))) for _ in 1:n]
        e == _CE_BOOL && return Bool[read(io, UInt8) != 0x00 for _ in 1:n]
        e == _CE_INT && return Int[_cr_i64(io) for _ in 1:n]
        e == _CE_STR && return String[_cr_str(io) for _ in 1:n]
        e == _CE_DATE && return Date[Date(Dates.UTD(_cr_i64(io))) for _ in 1:n]
        e == _CE_ANY && return Any[_chunk_read(io) for _ in 1:n]
    end
    error("chunk_dir: unbekannter Eintrag $(t) im Binärformat")
end

function _save_chunk(f, x)
    io = IOBuffer()
    write(io, _CHUNK_KOPF, htol(_CHUNK_FASSUNG))
    _chunk_write(io, x)
    write(f, take!(io))
    nothing
end
function _load_chunk(f)
    io = IOBuffer(read(f))
    k = length(_CHUNK_KOPF)
    (bytesavailable(io) >= k + 4 && read(io, k) == _CHUNK_KOPF && ltoh(read(io, UInt32)) == _CHUNK_FASSUNG) ||
        _stop(_chunk_meldung(basename(f)))
    return _chunk_read(io)
end

"""
    _keep_count(x, n, who)

Anzahl behaltener Pfade aus `keep_paths` (R: `.keep_count`): `true` = alle Pfade, `false` oder 0 =
keine, ganze Zahl k ≥ 1 = die ersten k Pfade (k > n: still alle). Logisch wird vor der Ganzzahl geprüft (`Bool` ist
in Julia eine Ganzzahl). Fehler bei NA, Text, Vektor, negativen oder nicht ganzen Zahlen. Ergebnis: Anzahl in `0..n`
(Float64; `n` darf `Inf` sein).
"""
function _keep_count(x, n, who)
    x isa Bool && return x ? Float64(n) : 0.0
    ok = x isa Real && !(x isa Bool) && isfinite(Float64(x)) && Float64(x) >= 0 && Float64(x) == _round0(Float64(x))
    ok || _stop(@sprintf("%s: keep_paths muss TRUE (alle Pfade), FALSE/0 (keine) oder eine ganze Zahl k >= 1 (die ersten k Pfade) sein, nicht %s.",
                         who, _show(x)))
    return min(Float64(x), Float64(n))
end

"""
    bootstrap_study(data, config; method = "stationary", n = 1000, strategies, params = RList(),
                    ess = false, ess_grid = nothing, path_length = nothing, dates = nothing,
                    start = "2000-01-01", burn_in = 0, sim_args = RList(), metrics = bootstrap_study_metrics,
                    benchmark = nothing, chunk_dir = nothing, keep_paths = 0, keep_returns = "none",
                    keep_aux = nothing, max_tries = 10, chunk_size = 25, seed = nothing, cores = 1, progress = true)

Strategien auf Bootstrap-Pfaden auswerten.

Erzeugt Bootstrap-Pfade wie `bootstrap()`, berechnet je Pfad die Signale, simuliert alle Strategien mit
`simulation()` auf DEMSELBEN Pfad (Common Random Numbers, gepaarter Vergleich) und speichert nur Kennzahlen.
Pfade werden nach der Auswertung verworfen; der Speicherbedarf ist daher unabhängig von `n`. Entspricht der
Pipeline aus '06 Bootstraps' (Chunks, Parallelisierung), ohne die Pfade zwischenzuspeichern.

# Argumente
- `data`: Tabelle (RFrame) oder Matrix mit den in `config` genannten Spalten (Index-Spalten als
  Brutto-Renditen je Zeile oder, bei `input = "prices"`, als Kursniveaus; Zusatzreihen beliebig). Jede Zeile
  ist ein Simulationsschritt ("Tag"); eine Datumsspalte wird nicht ausgewertet.
- `config`: Objekt aus `bootstrap_config()`.
- `method`: Verfahren (Standard in `bootstrap()`: `"raw"`, in `bootstrap_study()`: `"stationary"`). In
  Klammern die Einträge von `params`, die das Verfahren verwendet:

  - "raw": IID-Zeilen-Bootstrap (Efron 1979); zerstört Zeitabhängigkeit (Nullmodell). Keine Parameter.
  - "block": Moving Block Bootstrap (Künsch 1989) (`block_length`)
  - "circular": Circular Block Bootstrap (Politis & Romano 1992) (`block_length`)
  - "stationary": Stationärer Bootstrap (Politis & Romano 1994), geometrisch verteilte Blöcke (`L`)
  - "wild": Wild Bootstrap mit gemeinsamem Gewicht je Zeile für alle Reihen (`wild_type`); erhält die
    Chronologie
  - "regime": Volatilitätsregime-Markov-Bootstrap: Regime aus Quantilen der rollierenden Volatilität des
    Referenzindex (`n_regimes`, `vol_window`)
  - "evt": GPD-Tails des Referenzindex plus empirischer Bulk (`tail_prob`, `both_tails`); übrige Indizes über
    das historische Verhältnis zum Referenzindex gekoppelt
  - "tails": Empirische Tail-Schichtung des Referenzindex (`tail_prob`)
  - "reset": Chronologie mit zufällig gespiegelten Segmenten (`p_break`); erhält die Chronologie
  - "garch", "gjr_garch": (GJR-)GARCH(1,1) mit Filtered Historical Simulation (keine Parameter; Kopplung über
    `cross` in `bootstrap_config()`). Geschätzt per Maximum Likelihood unter Normalverteilung mit der
    C-Bibliothek von SimLev (GJR mit α + γ ≥ 0, also auch γ < 0; bis Version 1.0.0 γ ≥ 0; BFGS von sieben
    Rasterpunkten), notfalls mit Momentschätzern; die Meldungen nennen den Weg "ml" bzw. "momente" (bis 0.10.0
    "rugarch"/"optim")
  - "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch": Markov-Switching-GARCH-Familie: eigene ML-Schätzung des
    MS-GARCH-Modells nach Haas, Mittnik und Paolella (2004), Normalverteilung, Varianzmodell "sGARCH" oder
    "gjrGARCH" je Regime (GJR mit α + γ ≥ 0, also auch γ < 0; BFGS mit analytischem Gradienten von 12 bzw. bei
    "gjrGARCH" 20 Startpunkten); "ms_ar_garch_m" zusätzlich mit AR- und GARCH-in-Mean-Termen je Regime,
    "tvtp_ms_garch" mit zeitvariablen Uebergangswahrscheinlichkeiten (`ms_n_regimes`/`ms_garch_model`,
    `ms_ar_n_regimes`/`ms_ar_garch_model` bzw. `tvtp_n_regimes`/`tvtp_garch_model`)

  Bei "wild" und "reset" muss `path_length` der Länge der Historie entsprechen.
- `n`: Anzahl Pfade (Standard 1000); bei `ess = true` das Gesamtbudget, das auf die Parameterkombinationen
  verteilt wird. Pfade, die nach `max_tries` Versuchen ungültig bleiben, fehlen im Ergebnis.
- `strategies`: Benannte, nicht leere Liste. Jedes Element ist entweder direkt eine Strategie
  (`create_strategy()`) oder eine Liste mit

  - strategy: Strategie (Pflicht).
  - signal: Optional Funktion, die den Pfad-Tabelle (RFrame) (alle Zeilen einschließlich `burn_in`) erhält und
    entweder einen Tabelle (RFrame) (ersetzt den Pfad-Tabelle (RFrame)) oder eine benannte Liste von Spalten
    gleicher Länge zurückgibt, z. B. `(buy = ..., sell = ...)`; `NA` in logischen Spalten wird zu `false`.
  - args: Liste von Argumenten für `simulation()`, die `sim_args` für diese Strategie überschreiben.
  - map: Spalten-Aliase als benannter Zeichenvektor Alias -> Pfadspalte, z. B. `(letf = "eu_l2",)`.

  Die Asset-Namen der Strategien müssen Spaltennamen des Pfads (bzw. Aliase aus `map`) sein. Schlägt Signal,
  Simulation oder Kennzahlberechnung für einen Pfad fehl, fehlt diese Zeile im Ergebnis; die Funktion warnt
  mit der Anzahl und der häufigsten Fehlermeldung (alle in `errors`). Schlagen alle Kombinationen fehl, bricht
  sie mit dieser Meldung ab. Warnungen aus Signal, Simulation und Kennzahlen werden je Pfad gesammelt,
  dedupliziert und am Ende als eine Warnung ausgegeben (mit Anzahl der betroffenen Pfade; alle in `warnings`);
  bei `cores > 1` ebenso.
- `params`: Benannte Liste von Verfahrensparametern; nicht angegebene Einträge erhalten den Standardwert
  (Standard `()` = alle Standardwerte). Je Verfahren werden nur die oben genannten Einträge verwendet:

  - L: Erwartete Blocklänge in Zeilen für "stationary" (Zahl >= 1, Standard 20) oder `"auto"`
    (`bootstrap_block_length()`, Spalte `stationary`).
  - block_length: Feste Blocklänge in Zeilen für "block" und "circular" (ganze Zahl, Standard 20; bei "block"
    höchstens Zeilen der Historie minus 1, bei "circular" höchstens Zeilen der Historie) oder `"auto"`
    (`bootstrap_block_length()`, Spalte `circular`).
  - wild_type: Gewichte beim Wild Bootstrap: 0 = Rademacher (Standard), 1 = Mammen, 2 = Standardnormal; andere
    Werte sind ein Fehler.
  - n_regimes: Anzahl Volatilitätsregime für "regime" (Standard 2).
  - vol_window: Fensterlänge der rollierenden Volatilität in Zeilen für "regime" (Standard 20).
  - tail_prob: Tail-Wahrscheinlichkeit je Seite als Anteil für "evt" und "tails" (Standard 0.05 = 5 Prozent).
  - both_tails: Logisch, nur "evt": auch den rechten Tail mit einer GPD modellieren (Standard `true`).
  - p_break: Wahrscheinlichkeit je Zeile als Anteil (0 bis 1), dass bei "reset" ein neues Segment beginnt
    (Standard 0.02).
  - ms_n_regimes, ms_ar_n_regimes, tvtp_n_regimes: Anzahl Regime für "ms_garch", "ms_ar_garch_m" bzw.
    "tvtp_ms_garch" (Standard je 2). Hat die Reihe weniger deutlich getrennte Regime als angefordert (z. B.
    drei Regime auf einer Reihe mit nur einem oder zwei Volatilitätszuständen), kann ein Regime entarten:
    Verweilwahrscheinlichkeit nahe 0 (Meldung "P(stay)"), kaum oder keine Tage im Regimepfad, mitunter
    Persistenz nahe 1 mit unplausibel hoher unbedingter Varianz; die Log-Likelihood liegt dann kaum über der
    mit einem Regime weniger. In diesem Fall die Anzahl Regime verkleinern.
  - ms_garch_model, ms_ar_garch_model, tvtp_garch_model: Varianzmodell je Regime: "sGARCH" (GARCH(1,1)) oder
    "gjrGARCH" (GJR-GARCH(1,1), Standard je "gjrGARCH"); andere Werte sind ein Fehler.

  Der Eintrag `garch_order` (Standard `[1, 1]`) ist vorhanden, ändert aber nichts: die GARCH-Verfahren
  schätzen immer GARCH(1,1).
- `ess`: Logisch (Standard `false`): ESS-gewichtete Gittersuche über Hyperparameter (wie im Original). Das
  Budget `n` wird invers zur effektiven Stichprobengröße (ESS) je Kombination verteilt; die Pfade erhalten
  Gewichte (Mittel 1), mit denen `bootstrap_probability()` und `summary()` rechnen. Für "raw", "garch" und
  "gjr_garch" gibt es kein Standardgitter (dann normaler Bootstrap).
- `ess_grid`: Benannte Liste von Wertevektoren je Hyperparameter (z. B. `(L = [20, 50, 100],)`); `nothing`
  (Standard) = Standardgitter des Verfahrens (z. B. `L` bzw. `block_length` 5, 10, 20, 30, 50, 75, 100 Zeilen,
  begrenzt auf die halbe Historienlänge). Nur bei `ess = true` verwendet.
- `path_length`: Pfadlänge in Zeilen (simulierte Schritte, ganze Zahl, mindestens 1); `nothing` (Standard) =
  Anzahl verwendbarer Zeilen der Historie. Damit lassen sich z. B. 50-jährige Pfade aus 30 Jahren Historie
  erzeugen. Jeder Pfad hat `path_length + 1` Zeilen (Startzeile plus Schritte).
- `dates`, `start`: Kalender der Pfade: `dates` ist ein Datumsvektor der Länge `path_length + 1`; `nothing`
  (Standard) = aufeinanderfolgende Kalendertage ab `start` (Standard "2000-01-01"), siehe `bootstrap_data()`.
- `burn_in`: Anzahl Anfangszeilen des Pfads, die nach der Signalberechnung verworfen werden (Signal-Vorlauf,
  z. B. 730 Tage für eine 430-Tage-SMA; Standard 0). Muss kleiner als `path_length` sein.
- `sim_args`: Benannte Liste gemeinsamer Argumente für `simulation()` (Standard `()`), z. B. `(start_value =
  1000, tax = tax_profile())`: Argumente von `simulation()` außer `data` und `strategy`, also auch Bausteine
  (z. B. `dca = dca_plan(100, 1)`, `tax = tax_profile()`) und Pfade zu Parametern der Bausteine
  (`"dca.value"`, siehe `sensitivity_grid`). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B.
  `dca_value`) ergeben einen Fehler, der den Baustein nennt.
- `metrics`: Funktion `SimLevResult -> benannter numerischer Vektor` (Standard `bootstrap_study_metrics()`);
  die Namen werden zu Spalten von `results`.
- `benchmark`: Name einer Strategie aus `strategies` als Vergleich für die gepaarte Auswertung in `summary()`;
  `nothing` (Standard) = keine.
- `chunk_dir`: Optional (Standard `nothing`) Verzeichnis für Zwischenergebnisse je Chunk (Dateien
  `chunk_<Nr>_seed<Seed>_jl.bin` im Binärformat von SimLev, bei `keep_returns` mit Frequenz-Suffix, bei
  `keep_paths` > 0 mit Suffix `_keep<k>`, jeweils vor `_jl.bin`; R schreibt `_r.rds`, Python `_py.pkl`). Liegt zu
  einem Chunk nur eine Datei einer anderen Sprache oder der Form bis 1.6.2 (`chunk_<Nr>_seed<Seed>.rds`, in Julia
  Quelltext), bricht die Studie mit einer Meldung ab. Vorhandene Dateien werden gelesen statt neu gerechnet; so wird ein abgebrochener Lauf mit
  gleichem Seed fortgesetzt. Die Dateien werden nur über Chunk-Nummer, Seed, `keep_returns` und `keep_paths`
  zugeordnet: bei geänderten Strategien, Daten oder Parametern ein neues Verzeichnis verwenden.
- `keep_paths`: Pfadmatrizen zusätzlich zurückgeben (Diagnose): `true` = alle Pfade, `false` oder 0 (Standard)
  = keine, ganze Zahl k >= 1 = die ersten k Pfade (k größer als die Pfadzahl: alle); `NA`, Text, Vektoren,
  negative oder nicht ganze Zahlen ergeben einen Fehler. Speicherbedarf: Alle behaltenen Pfadmatrizen bleiben
  im Ergebnis und gehen bei `cores > 1` auch durch die Prozessgrenze, ungefähr Pfade x (Pfadlänge + 1) x
  Reihen x 8 Byte (z. B. 10 000 Pfade x 7 300 Tage x 3 Reihen x 8 Byte = 1,75 GB).
- `keep_returns`: `"none"` (Standard) oder `"year"`, `"quarter"`, `"month"`: speichert je Strategie und Pfad
  die zeitgewichteten Brutto-Periodenrenditen (aus `result_index()`, Perioden ab dem ersten Tag nach
  `burn_in`). Die Studie kann dann direkt an `withdrawal_simulation()` bzw. `withdrawal_paths()` übergeben
  werden.
- `keep_aux`: Zeichenvektor mit Namen von Zusatzreihen aus `config`, deren Brutto-Inflation je Periode
  ebenfalls gespeichert wird (Inflation für die Entnahmephase, Argument `inflation` von `withdrawal_paths()`);
  nur zusammen mit `keep_returns` wirksam. Die Behandlung folgt `aux_type` in `bootstrap_config()`: `"level"`
  (Preisindex) = Periodenverhältnisse des kumulierten Niveaus in der Pfadspalte; ausdrücklich `"rate"` =
  Inflationsrate in Prozent pro Jahr (2 = 2 % p. a.; nicht je Datenperiode, kein Anteil), je Pfadzeile über
  die Kalendertage aus `dates` aufgezinst, Π (1 + r/100)^Tage/365.25 über die Zeilen der Periode (wie
  `inflation_type = "rate_pa"` in `withdrawal_paths()`, das dann nicht erneut angegeben werden muss). Ohne
  Angabe in `aux_type` gilt die Reihe wie bisher als Niveau (Niveau-Variante des Pfads, Attribut `aux_level`,
  siehe `bootstrap()`: Verhältnis der kumulierten Zeilenverhältnisse an den Periodenenden), so dass jede
  Periode die Inflation der gezogenen Zeilen eines Preisindex enthält; eine Ratenspalte ergibt so keine
  Inflation in Prozent p. a. Sind gespeicherte Faktoren nicht endlich oder <= 0 (z. B. eine nicht
  gekennzeichnete Zinsreihe mit Vorzeichenwechsel), warnt die Funktion, und `withdrawal_paths()` bricht mit
  dieser Reihe als Inflation ab. Standard `nothing`.
- `max_tries`: Versuche je Pfad (Standard 10), falls ein Pfad ungültig ist (Indexrendite <= 0 oder nicht
  endlich). Ein Totalverlust eines Hebelprodukts macht den Pfad nicht ungültig.
- `chunk_size`: Pfade je Arbeitspaket (Standard 25); Einheit der Parallelisierung und der Zwischenspeicherung.
- `seed`: Ganzzahliger Startwert (|seed| < 2^53); `nothing` (Standard) = genau einmal aus dem Zufallszustand
  von SimLev gezogen (siehe `simlev_seed()`; ganze Zahl von 0 bis 2^31 - 1, im Ergebnis unter `seed`
  gespeichert, damit reproduzierbar). Jeder Pfad i erhält einen eigenen Strom (Sprung um 2^128 Schritte je
  Pfad), so dass Pfad i unabhängig von `cores` (und bei `bootstrap_study()` von `chunk_size`) ist und
  `bootstrap()` und `bootstrap_study()` mit gleichem Seed (und gleichen Daten, Verfahren, `params`, `ess` und
  `path_length`) dieselben Pfade erzeugen. Mit angegebenem Seed bleibt der Zufallszustand von SimLev
  unverändert; mit `seed = nothing` liefern wiederholte Aufrufe verschiedene Pfade. `set.seed()` wirkt nicht.
- `cores`: Anzahl Prozesse (Standard 1); parallelisiert wird über Chunks. Der MS-GARCH-Fit der Vorberechnung
  nutzt ebenso viele Threads (Ergebnis unabhängig davon).
- `progress`: Logisch: Fortschrittsmeldungen per `message()` (Standard `true`; Meldung je Chunk nur bei `cores
  = 1`).

# Rückgabe
Objekt der Klasse `SimLevBootstrapStudy`, eine Liste mit

- results: Tabelle (RFrame) mit einer Zeile je Pfad und Strategie: `strategy`, `path` (Pfadnummer), `weight`
  (Pfadgewicht), `combo` (ESS-Kombination), `tries` (Versuche) und den Kennzahlen aus `metrics` (bei
  `bootstrap_study_metrics()` z. B. `cagr` und `max_drawdown` als Anteil).
- method, n_paths, strategies, benchmark, config, params, seed, burn_in, path_length, elapsed: Metadaten
  (`elapsed` in Sekunden).
- ess_design, path_weights: ESS-Design (oder `nothing`) und Gewichte aller Pfade.
- paths: Liste der mit `keep_paths` behaltenen Pfadmatrizen.
- returns, aux_returns: Bei `keep_returns`: je Strategie bzw. Zusatzreihe eine Matrix (Perioden x Pfade) von
  Brutto-Periodenrenditen bzw. Brutto-Inflation (z. B. 1.05 bzw. 1.02), sonst `nothing`.
- returns_frequency, returns_dates: Frequenz und Periodenenden (Datum) der gespeicherten Renditen.
- errors: Tabelle (RFrame) der Fehler der Einzelsimulationen (`strategy`, `stage` = "Signal", "Simulation"
  oder "Kennzahlen", `message`, `n` = Anzahl Pfade, `first_path`), nach Häufigkeit sortiert; `nothing`, wenn
  keine.
- warnings: Tabelle (RFrame) der deduplizierten Warnungen (`strategy`, `message`, `n` = Anzahl Pfade mit
  dieser Warnung, `first_path`); `nothing`, wenn keine.

# Details
Ablauf je Pfad: Pfadmatrix erzeugen, mit `dates` zu einem Tabelle (RFrame) wie in `bootstrap_data()` machen
(Spalte `date` plus Pfadspalten aus `bootstrap_config()`), je Strategie optional `signal` und `map` anwenden,
die ersten `burn_in` Zeilen verwerfen, `simulation()` mit `sim_args` aufrufen und `metrics` auswerten.
Weiterverarbeitung: `summary()` und `plot()` (siehe SimLevBootstrap-methods), `bootstrap_probability()`; mit
`keep_returns` zusätzlich `withdrawal_paths()` bzw. `withdrawal_simulation()` (Entnahmephase auf den
simulierten Strategiepfaden).

# Literatur
Haas, M., Mittnik, S. & Paolella, M.S. (2004), A New Approach to Markov-Switching GARCH Models, Journal of
Financial Econometrics 2(4) (Verfahren "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"); Hamilton, J.D. (1989),
Econometrica 57(2) (Filter).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1095
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
cfg = bootstrap_config((akt = "aktien",); input = "prices", letfs = [(base = "akt", leverage = 2, finance = 2)])
st = bootstrap_study(d, cfg; method = "stationary", n = 5, params = (L = 30,), path_length = 500, seed = 1,
                     progress = false,
                     strategies = (etf = create_strategy(akt = asset_config("etf")),
                                   letf = create_strategy(akt_l2 = asset_config("etf"))))
println(st["results"])
```
"""
SimLev.@study function bootstrap_study(data, config, method_pos = nothing; method = "stationary", n = 1000, strategies = nothing,
                         params = RList(), ess = false, ess_grid = nothing, path_length = nothing, dates = nothing,
                         start = "2000-01-01", burn_in = 0, sim_args = RList(), metrics = bootstrap_study_metrics,
                         benchmark = nothing, chunk_dir = nothing, keep_paths = 0, keep_returns = nothing,
                         keep_aux = nothing, max_tries = 10, chunk_size = 25, seed = nothing, cores = 1, progress = true)
    @nospecialize   # seit 1.6.3: ein Rumpf für alle Typen der Schlüsselwörter (Übersetzung je Aufrufform entfällt)
    data = SimLev.as_rframe(data)
    method_pos === nothing || (method = method_pos)
    keep_returns = _match_arg(keep_returns, ("none", "year", "quarter", "month"))
    if keep_aux !== nothing
        keep_aux = keep_aux isa AbstractString ? [String(keep_aux)] : String[string(a) for a in keep_aux]
        all(a -> a in _cfg_list(config, "aux_names"), keep_aux) || _stop("keep_aux muss Namen aus config\$aux enthalten.")
    end
    t0 = time()
    snm = strategies === nothing ? nothing : _names(strategies)
    if strategies === nothing || _len(strategies) == 0 || snm === nothing || any(==(""), snm)
        _stop("'strategies' muss eine benannte, nicht-leere Liste sein.")
    end
    snames = collect(String, snm)
    specs = Dict{String,Any}()
    for (k, s) in zip(snames, _values(strategies))
        if !_is_strategy(s) && (s isa Union{RList,NamedTuple,AbstractDict}) && _get(s, "strategy") !== nothing
            specs[k] = s
        else
            specs[k] = (strategy = s,)
        end
    end
    benchmark !== nothing && !(benchmark in snames) && _stop("benchmark muss einer der Strategienamen sein.")
    # Argumente für simulation() je Strategie einmal auflösen (Bausteine, Pfade; alte flache Namen: Fehler)
    sim_args = SimLev._sim_args_set(RList(), sim_args, "bootstrap_study")
    spec_sim = Dict{String,Any}(k => SimLev._sim_args_set(sim_args, _get(specs[k], "args"), "bootstrap_study") for k in snames)
    setup = _boot_setup(data, config, method, n, params, ess, ess_grid, path_length, cores)
    keep_paths = _keep_count(keep_paths, setup["n_paths"], "bootstrap_study")   # true = alle Pfade
    n_out = setup["n_out"]
    dates === nothing && (dates = _seq_dates(_todate(start, "start")[1], n_out + 1))
    _len(dates) != n_out + 1 && _stop(@sprintf("dates braucht Länge %d (Pfadlänge + 1).", n_out + 1))
    dates = _todate(dates, "dates")
    burn_in >= n_out && _stop("burn_in ist länger als der Pfad.")
    seed = _seed_or_draw(seed)
    n_paths = setup["n_paths"]
    streams = _SL().streams(seed, n_paths)                     # U_i = J^i(S_0)
    cs = Float64(chunk_size)
    keyv = Float64[ceil(i / cs) for i in 1:n_paths]
    chunks = [findall(==(k), keyv) for k in sort(unique(keyv))]
    if chunk_dir !== nothing
        mkpath(chunk_dir)
        _chunk_pruefen(chunk_dir, length(chunks), seed, keep_returns, keep_paths, "_jl.bin")
    end
    bi = Int(burn_in)
    sim_rows = collect(bi+1:n_out+1)
    dsim = dates[sim_rows]
    ret_ends = keep_returns != "none" ? SimLev.Withdrawal._anniv_ends(dsim, keep_returns) : nothing
    ret_ends !== nothing && length(ret_ends) < 2 && _stop("Pfad nach burn_in zu kurz für eine volle Periode in keep_returns.")
    per_ret(v) = (w = _dvec(v)[ret_ends]; w[2:end] ./ w[1:end-1])
    at = _get(config, "aux_type")
    sets = _cfg_list(config, "aux_type_set")
    rate_set = [s for s in sets if _aux_type_of(at, s) == "rate"]
    rate_aux = _uniq(String[a for a in something(keep_aux, String[]) if a in rate_set])
    dt_sim = Float64[_days(dsim[i+1]) - _days(dsim[i]) for i in 1:length(dsim)-1] ./ 365.25
    function aux_level_of(P, a)
        if a in rate_aux
            v = P[:, a][sim_rows[2:end]]
            return _cumprod(vcat(1.0, Float64[_rpow(1 + v[i] / 100, dt_sim[i]) for i in eachindex(v)]))
        end
        _aux_type_of(at, a) == "level" && return P[:, a][sim_rows]
        return P.attrs["aux_level"][:, a][sim_rows]
    end
    function eval_path(i)
        dp = _draw_path(setup, i, streams[i], config, method, max_tries)
        dp.path === nothing && return nothing
        P = dp.path
        df0 = _path_frame(dates, P)
        rows = Dict{String,Any}()
        df_cut = nothing   # seit 1.6.3: Ausschnitt nach burn_in einmal je Pfad für Strategien ohne signal und map
        for nm in snames
            sp = specs[nm]
            plain = _get(sp, "signal") === nothing && _get(sp, "map") === nothing
            # Kopie nur, wenn signal oder map den Rahmen verändern können (simulation() liest ihn nur)
            df = plain ? df0 : copy(df0)
            wr = String[]
            fail(stage, msg) = (row = nothing, ret = nothing, err = (stage = stage, message = msg), warn = _uniq(wr))
            run(f) = _collect_warnings(f, wr)
            sig = _get(sp, "signal")
            if sig !== nothing
                sg = try
                    run(() -> sig(df))
                catch e
                    e isa UndefVarError && rethrow()
                    rows[nm] = fail("Signal", _errmsg(e)); continue
                end
                if sg === nothing
                    rows[nm] = fail("Signal", "Signal-Funktion lieferte NULL"); continue
                end
                if sg isa RFrame
                    df = sg
                else
                    for (k2, v) in zip(_names(sg), _values(sg))
                        _set_col!(df, k2, v)
                    end
                end
            end
            mp = _get(sp, "map")
            if mp !== nothing
                for (a2, col) in zip(_names(mp), _values(mp))
                    df[String(a2)] = df[String(col)]
                end
            end
            if bi > 0
                if plain
                    df_cut === nothing && (df_cut = _sim_rows(df0, bi+1:SimLev.nrow(df0)))
                    df = df_cut
                else
                    df = _sim_rows(df, bi+1:SimLev.nrow(df))
                end
            end
            args = spec_sim[nm]
            res = try
                _no_messages(() -> run(() -> _sim_call(df, _get(sp, "strategy"), args)))
            catch e
                e isa UndefVarError && rethrow()
                rows[nm] = fail("Simulation", _errmsg(e)); continue
            end
            m = try
                run(() -> metrics(res))
            catch e
                e isa UndefVarError && rethrow()
                rows[nm] = fail("Kennzahlen", _errmsg(e)); continue
            end
            if m === nothing
                rows[nm] = fail("Kennzahlen", "metrics() lieferte NULL"); continue
            end
            mn = _names(m); mv = Float64[Float64(v) for v in Iterators.flatten(_dvec.(_values(m)))]
            mn === nothing && (mn = fill("", length(mv)))
            row = RVector(vcat(Float64(i), Float64(setup["weights"][i]), Float64(setup["combo_of_path"][i]), Float64(dp.tries), mv);
                          names = vcat(["path", "weight", "combo", "tries"], collect(String, mn)))
            rows[nm] = (row = row, ret = ret_ends !== nothing ? per_ret(SimLev.Withdrawal.result_index(res)["value"]) : nothing,
                        err = nothing, warn = _uniq(wr))
        end
        aux_ret = nothing
        if ret_ends !== nothing && keep_aux !== nothing && !isempty(keep_aux)
            aux_ret = Dict{String,Any}(a => per_ret(aux_level_of(P, a)) for a in keep_aux)
        end
        return (id = i, rows = rows, aux = aux_ret, path = i <= keep_paths ? P : nothing)
    end
    function run_chunk(ci)
        f = nothing
        if chunk_dir !== nothing
            f = joinpath(chunk_dir, _chunk_stem(ci, seed, keep_returns, keep_paths) * "_jl.bin")
        end
        f !== nothing && isfile(f) && return _load_chunk(f)
        out = Any[eval_path(i) for i in chunks[ci]]
        f !== nothing && _save_chunk(f, out)
        progress && cores <= 1 && _message(@sprintf("  Chunk %d/%d fertig (%.0f s)", ci, length(chunks), time() - t0))
        return out
    end
    progress && _message(@sprintf("Bootstrap-Studie '%s': %d Pfade x %d Strategien, %d Chunks, %d Kern(e)",
                                  method, n_paths, length(specs), length(chunks), Int(cores)))
    resc = _par_lapply(1:length(chunks), run_chunk, cores)
    res = Any[r for ch in resc for r in ch]
    # Ergebnistabelle
    tcols = nothing
    strat_col = String[]
    mats = Vector{Float64}[]
    for nm in snames
        rws = [r.rows[nm].row for r in res if r !== nothing && r.rows[nm].row !== nothing]
        isempty(rws) && continue
        if tcols === nothing
            tcols = rws[1].names
        end
        for rw in rws
            push!(strat_col, nm)
            push!(mats, Float64[rw.values[findfirst(==(c), rw.names)] for c in tcols])
        end
    end
    tab = nothing
    if tcols !== nothing
        cols = Pair{String,Any}["strategy" => strat_col]
        for (j, c) in enumerate(tcols)
            push!(cols, c => Float64[m[j] for m in mats])
        end
        tab = RFrame(cols...)
    end
    function cond_tab(field)
        st = String[]; sg = Union{Missing,String}[]; ms = String[]; pa = Int[]
        for r in res
            r === nothing && continue
            for nm in snames
                v = getfield(r.rows[nm], field)
                (v === nothing || (v isa AbstractVector && isempty(v))) && continue
                if field === :err
                    push!(sg, v.stage); vv = [v.message]
                else
                    vv = collect(String, v); append!(sg, fill(missing, length(vv)))
                end
                append!(st, fill(nm, length(vv))); append!(ms, vv); append!(pa, fill(Int(r.id), length(vv)))
            end
        end
        isempty(st) && return nothing
        key = String[string(a, "\r", b === missing ? "NA" : b, "\r", c) for (a, b, c) in zip(st, sg, ms)]
        cnt = Dict{String,Int}()
        for k in key
            cnt[k] = get(cnt, k, 0) + 1
        end
        idx = findall(.!_duplicated(key))
        nvals = Int[cnt[key[i]] for i in idx]
        o = sortperm(-nvals; alg = MergeSort)
        idx = idx[o]
        cols = Pair{String,Any}["strategy" => st[idx]]
        field === :err && push!(cols, "stage" => String[x for x in sg[idx]])
        push!(cols, "message" => ms[idx]); push!(cols, "n" => Int[cnt[key[i]] for i in idx]); push!(cols, "first_path" => pa[idx])
        return RFrame(cols...)
    end
    errs = cond_tab(:err)
    warns = cond_tab(:warn)
    first_err = errs === nothing ? nothing :
                @sprintf("Strategie '%s', %s, %d-mal: %s", errs["strategy"][1], errs["stage"][1], errs["n"][1], errs["message"][1])
    if tab === nothing
        first_err === nothing && _stop("Keine Strategie-Ergebnisse - Strategie, Signale und sim_args prüfen.")
        _stop(@sprintf("Keine Strategie-Ergebnisse: alle %d Pfad-Strategie-Kombinationen fehlgeschlagen (%d verschiedene Fehlermeldung(en)). Häufigster Fehler (%s) - Strategie, Signale und sim_args prüfen.",
                       n_paths * length(specs), SimLev.nrow(errs), first_err))
    end
    n_fail = n_paths * length(specs) - SimLev.nrow(tab)
    if n_fail > 0
        _warn(@sprintf("%d Pfad-Strategie-Kombinationen ohne Ergebnis (Simulation/Signal fehlgeschlagen)%s.", n_fail,
                       first_err === nothing ? "" : @sprintf("; häufigster Fehler (%s); alle Fehler in \$errors", first_err)))
    end
    if warns !== nothing
        k = min(3, SimLev.nrow(warns))
        txt = join([@sprintf("[Strategie '%s', %d von %d Pfaden] %s", warns["strategy"][j], warns["n"][j], n_paths, warns["message"][j]) for j in 1:k], "; ")
        _warn(@sprintf("Warnungen der Einzelsimulationen (%d verschiedene, zusammengefasst; alle in \$warnings): %s%s",
                       SimLev.nrow(warns), txt, SimLev.nrow(warns) > k ? @sprintf("; ... und %d weitere", SimLev.nrow(warns) - k) : ""))
    end
    returns = aux_returns = nothing
    if ret_ends !== nothing
        n_per = length(ret_ends) - 1
        function fill_mat(get)
            M = fill(NA, n_per, n_paths)
            for r in res
                r === nothing && continue
                v = get(r)
                v === nothing || (M[:, Int(r.id)] = v)
            end
            return M
        end
        returns = RList((nm => fill_mat(r -> r.rows[nm].ret) for nm in snames)...)
        if keep_aux !== nothing && !isempty(keep_aux)
            aux_returns = RList((a => fill_mat(r -> r.aux === nothing ? nothing : get(r.aux, a, nothing)) for a in keep_aux)...)
        end
        for a in something(keep_aux, String[])
            r = vec(aux_returns[a]); r = r[.!isnan.(r)]
            badv = r[.!isfinite.(r) .| (r .<= 0)]
            if !isempty(badv)
                msg = a in rate_aux ?
                    "keep_aux: Zusatzreihe '%s' (aux_type 'rate') ergibt nicht endliche oder nicht positive Periodenfaktoren (z. B. %s; Rate <= -100 %%?); als Inflation in withdrawal_paths()/withdrawal_simulation() nicht verwendbar." :
                    "keep_aux: Zusatzreihe '%s' ist kein positives Niveau (Periodenverhältnisse nicht endlich oder <= 0, z. B. %s); als Inflation in withdrawal_paths()/withdrawal_simulation() nicht verwendbar. Für eine Rate aux_type = c(<Name> = 'rate') in bootstrap_config() angeben."
                _warn(_sp(msg, a, _fmt1(badv[1]; digits = 4)))
            end
        end
    end
    elapsed = time() - t0
    progress && _message(@sprintf("Fertig: %d Ergebniszeilen in %.1f s.", SimLev.nrow(tab), elapsed))
    return RList("results" => tab, "method" => method, "n_paths" => n_paths, "strategies" => snames,
                 "benchmark" => benchmark, "config" => config, "params" => setup["base_p"][1],
                 "ess_design" => setup["design"], "seed" => seed, "burn_in" => burn_in, "path_length" => n_out,
                 "elapsed" => elapsed, "paths" => Any[r.path for r in res if r !== nothing && r.path !== nothing],
                 "returns" => returns, "aux_returns" => aux_returns,
                 "returns_frequency" => keep_returns != "none" ? keep_returns : nothing,
                 "returns_dates" => ret_ends !== nothing ? dsim[ret_ends] : nothing,
                 "path_weights" => setup["weights"], "errors" => errs, "warnings" => warns;
                 class = "SimLevBootstrapStudy")
end

# ═══════════════════════════════════════════════════════════════════════════
# Gewichtete Quantile, Wahrscheinlichkeiten, Zusammenfassung
# ═══════════════════════════════════════════════════════════════════════════

"Gewichtete Quantile (gewichteter Typ 7, Akinshin 2023), R: `.wquantile`."
function _wquantile(x, w, probs)
    x = _dvec(x); w = _dvec(w); probs = _dvec(probs)
    length(w) == 1 && length(x) != 1 && (w = fill(w[1], length(x)))
    ok = isfinite.(x) .& isfinite.(w)
    x = x[ok]; w = w[ok]
    isempty(x) && return fill(NA, length(probs))
    length(unique(w .+ 0.0)) == 1 && return _quantile7(x, probs)
    sw = _rsum(w)
    sw > 0 || return fill(NA, length(probs))
    o = _order(x)
    x = x[o]
    w = w[o] ./ sw
    r = _cumsum(w)
    r[end] = 1.0
    l = vcat(0.0, r[1:end-1])
    ne = 1 / _rsum(w .* w)
    out = Vector{Float64}(undef, length(probs))
    for (i, p) in enumerate(probs)
        a = (ne - 1) * p / ne
        Fu(u) = _pmin(_pmax((u - a) * ne, 0.0), 1.0)
        out[i] = _rsum(Float64[(Fu(r[j]) - Fu(l[j])) * x[j] for j in eachindex(x)])
    end
    return out
end

# ── Bedingungen in R-Syntax (gemeinsamer Auswerter SimLev.RExpr) ─────────

const _LGL = Vector{Union{Missing,Bool}}

_as_lgl(v::_LGL) = v
_as_lgl(v::AbstractVector{Bool}) = _LGL(v)
_as_lgl(v::AbstractVector{<:Real}) = _LGL([isnan(Float64(x)) ? missing : Float64(x) != 0 for x in v])
_as_lgl(v::AbstractVector) = _LGL([x === missing ? missing : x isa Bool ? x : x isa Real ? (isnan(Float64(x)) ? missing : x != 0) :
                                   x isa AbstractString ? (x in ("TRUE", "true", "T", "True") ? true : x in ("FALSE", "false", "F", "False") ? false : missing) : missing
                                   for x in v])

"""
Bedingung in `d` auswerten wie `as.logical(eval(cond, d, env))`; Ergebnis
`Vector{Union{Missing,Bool}}`. Text in R-Syntax über `SimLev.RExpr` (Länge wie
in R), Julia-Funktionen `RFrame -> Vektor` (Skalar wird auf `nrow(d)` erweitert).
"""
function _eval_condition(cond, d::RFrame, env)
    cond isa Function || return SimLev.RExpr.as_logical(SimLev.RExpr.eval_r(string(cond), d; env = env))
    v = cond(d)
    v isa AbstractVector || (v = [v])
    l = _as_lgl(collect(v))
    nr = SimLev.nrow(d)
    length(l) == 1 && nr != 1 && (l = _LGL(fill(l[1], nr)))
    return l
end

"""
    bootstrap_probability(study, conds...; thresholds = nothing, env = Main, named...)

Wahrscheinlichkeiten aus einer Bootstrap-Studie.

Wertet beliebige logische Bedingungen je Strategie über alle Pfade einer `bootstrap_study()` aus (mit den
Pfadgewichten, also ESS-gewichtet), z. B. die gemeinsame Wahrscheinlichkeit, eine Mindestrendite zu erreichen
und einen maximalen Drawdown nicht zu überschreiten (wie `calc_metrics` in '06 Bootstraps').

# Argumente
- `study`: Objekt der Klasse `SimLevBootstrapStudy` aus `bootstrap_study()`.
- `conds...`: Benannte oder unbenannte Bedingungen in Kennzahlnamen, z. B. `ttwror >= 0.13`, `joint = ttwror
  >= 0.13 & max_drawdown <= 0.95`. Unbenannte Bedingungen werden nach ihrem Ausdruck benannt.
- `thresholds`: Optional (Standard `nothing`) benannte Liste je Strategiename mit einer benannten Liste von
  Ausdrücken (`quote()`), z. B. `(sma = (ziel = quote(cagr >= 0.08),),)`. Für eine hier genannte Strategie
  ersetzen diese Bedingungen die Bedingungen aus `...` (strategiespezifische Schwellen).
- `env`: Modul, in dem freie Variablen und Funktionen der Bedingungen gesucht werden (Standard `Main`).
- `named...`: Benannte oder unbenannte Bedingungen in Kennzahlnamen, z. B. `ttwror >= 0.13`, `joint = ttwror
  >= 0.13 & max_drawdown <= 0.95`. Unbenannte Bedingungen werden nach ihrem Ausdruck benannt.

# Rückgabe
Tabelle (RFrame) mit einer Zeile je Strategie und Bedingung: `strategy`, `condition` (Name), `probability`
(gewichtete Wahrscheinlichkeit als Anteil), `se` (Monte-Carlo-Standardfehler √p(1-p)/n_eff mit effektiver
Pfadzahl n_eff = (Σ w)^2 / Σ w^2) und `n` (Anzahl ausgewerteter Pfade).

# Details
Die Bedingungen werden zeilenweise in `study["results"]` ausgewertet; verwendbar sind dort alle Spalten, also
die Kennzahlen aus `metrics` (bei `bootstrap_study_metrics()` z. B. `cagr`, `ttwror`, `max_drawdown` als
Anteil) sowie `path`, `weight`, `combo` und `tries`. Zeilen mit `NA`-Ergebnis zählen nicht. Freie Variablen in
den Bedingungen (z. B. eine Schwelle `thr`) werden in der Umgebung des Aufrufs gesucht (auch lokale Variablen
einer aufrufenden Funktion), Spalten von `study["results"]` haben Vorrang.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1095
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
cfg = bootstrap_config((akt = "aktien",); input = "prices", letfs = [(base = "akt", leverage = 2, finance = 2)])
st = bootstrap_study(d, cfg; method = "stationary", n = 5, params = (L = 30,), path_length = 500, seed = 1,
                     progress = false,
                     strategies = (etf = create_strategy(akt = asset_config("etf")),
                                   letf = create_strategy(akt_l2 = asset_config("etf"))))
println(bootstrap_probability(st, "cagr > 0"; joint = "cagr > 0.05 & max_drawdown <= 0.3"))
```
"""
function bootstrap_probability(study, conds...; thresholds = nothing, env = Main, named...)
    _is_study(study) || _stop("study muss ein SimLevBootstrapStudy-Objekt sein.")
    cl0 = Pair{String,Any}[]
    for c in conds
        push!(cl0, (c isa Function ? string(nameof(c)) : string(c)) => c)
    end
    for (k, c) in named
        push!(cl0, string(k) => c)
    end
    tab = study["results"]
    s_out = String[]; c_out = String[]; p_out = Float64[]; se_out = Float64[]; n_out = Int[]
    for s in _uniq(collect(String, tab["strategy"]))
        d = SimLev.rows(tab, tab["strategy"] .== s)
        th = thresholds === nothing ? nothing : _get(thresholds, s)
        cl = th !== nothing ? collect(zip(_names(th), _values(th))) : [(p.first, p.second) for p in cl0]
        for (cn, ce) in cl
            v = _eval_condition(ce, d, env)
            w = _dvec(d["weight"])
            if length(v) != length(w)
                # andere Länge als nrow(d): R's Recycling in w[ok] * v[ok]
                r = SimLev.RExpr.eval_r("ok <- !is.na(v); sw <- sum(w[ok]); c(sum(w[ok] * v[ok]) / sw, sw^2 / sum(w[ok]^2), sum(ok))",
                                        (v = v, w = w))
                p = r[1]; q = p * (1 - p) / r[2]
                push!(s_out, s); push!(c_out, string(cn)); push!(p_out, p)
                push!(se_out, q < 0 ? NaN : sqrt(q)); push!(n_out, Int(r[3]))
                continue
            end
            ok = Bool[z !== missing for z in v]
            vv = Float64[z === true ? 1.0 : 0.0 for z in v]
            p = _rsum(w[ok] .* vv[ok]) / _rsum(w[ok])
            swk = _rsum(w[ok])
            neff = swk * swk / _rsum(w[ok] .* w[ok])
            q = p * (1 - p) / neff
            push!(s_out, s); push!(c_out, string(cn)); push!(p_out, p)
            push!(se_out, q < 0 ? NaN : sqrt(q)); push!(n_out, count(ok))
        end
    end
    return RFrame("strategy" => s_out, "condition" => c_out, "probability" => p_out, "se" => se_out, "n" => n_out)
end

function _rbind_frames(fs::Vector{RFrame})
    isempty(fs) && return nothing
    nms = names(fs[1])
    cols = Pair{String,Any}[]
    for (j, k) in enumerate(nms)
        push!(cols, k => reduce(vcat, [collect(f[k]) for f in fs]))
    end
    return RFrame(cols...)
end

"""Paare (Zeile Strategie, Zeile Benchmark) mit gleichem Pfad wie `merge(d, b, by = "path")`: Pfade aufsteigend, je
Pfad alle Zeilen von d mal alle von b in Zeilenfolge. Seit 1.6.3 über ein Verzeichnis je Pfad (O(n)); bis 1.6.2
`findall` je Pfadwert (O(n²)). Nur endliche Pfadnummern ohne −0 (wie aus `bootstrap_study`), sonst der bisherige Weg."""
function _study_pairs(dpath::Vector{Float64}, bpath::Vector{Float64}, dsel, bsel)
    pairs_ = Tuple{Int,Int}[]
    if all(v -> isfinite(v) && !(v == 0 && signbit(v)), dpath) && all(v -> isfinite(v) && !(v == 0 && signbit(v)), bpath)
        gd = Dict{Float64,Vector{Int}}(); gb = Dict{Float64,Vector{Int}}()
        for (i, v) in enumerate(dpath); push!(get!(Vector{Int}, gd, v), i); end
        for (j, v) in enumerate(bpath); push!(get!(Vector{Int}, gb, v), j); end
        for pv in sort(unique(vcat(dpath, bpath)); lt = (a, b) -> a < b)
            ii = get(gd, pv, nothing); jj = get(gb, pv, nothing)
            (ii === nothing || jj === nothing) && continue
            for i in ii, j in jj
                push!(pairs_, (dsel[i], bsel[j]))
            end
        end
        return pairs_
    end
    for pv in sort(unique(vcat(dpath, bpath)); lt = (a, b) -> a < b)
        for i in findall(==(pv), dpath), j in findall(==(pv), bpath)
            push!(pairs_, (dsel[i], bsel[j]))
        end
    end
    return pairs_
end

"Zusammenfassung einer Bootstrap-Studie (R: `summary.SimLevBootstrapStudy`)."
function _summary_study(obj; metrics = ["cagr", "ttwror", "max_drawdown", "sharpe", "ulcer_index", "final_value"],
                        probs = [0.05, 0.25, 0.5, 0.75, 0.95])
    tab = obj["results"]
    metrics = metrics isa AbstractString ? [metrics] : collect(String, metrics)
    metrics = [m for m in _uniq(metrics) if haskey(tab, m)]
    probs = _dvec(probs)
    qn = String[_sp("q%02d", _round0(100 * p)) for p in probs]
    rows = RFrame[]
    # Spalten einmal umgewandelt (seit 1.6.3; bis 1.6.2 je Strategie, Metrik und Paar, gleiche Werte)
    # (erst beim ersten Gebrauch, damit Fehler wie bisher nur bei Bedarf entstehen)
    wref = Ref{Union{Nothing,Vector{Float64}}}(nothing); mcol = Dict{String,Vector{Float64}}()
    wcol() = (wref[] === nothing && (wref[] = _dvec(tab["weight"])); wref[]::Vector{Float64})
    mc(m) = get!(() -> _dvec(tab[m]), mcol, m)
    for s in collect(String, _values(obj["strategies"]))
        sel = tab["strategy"] .== s
        for m in metrics
            x = mc(m)[sel]; w = wcol()[sel]
            q = _wquantile(x, w, probs)
            cols = Pair{String,Any}["strategy" => [s], "metric" => [m], "mean" => [_weighted_mean(x, w; na_rm = true)]]
            for (k, v) in zip(qn, q)
                push!(cols, k => [v])
            end
            push!(rows, RFrame(cols...))
        end
    end
    dist = _rbind_frames(rows)
    paired = nothing
    bm = _get(obj, "benchmark")
    if bm !== nothing
        bsel = findall(tab["strategy"] .== bm)
        bpath = _dvec(tab["path"])[bsel]
        prow = RFrame[]
        for s in [x for x in collect(String, _values(obj["strategies"])) if x != bm]
            dsel = findall(tab["strategy"] .== s)
            dpath = _dvec(tab["path"])[dsel]
            # merge(d, b, by = "path"): innerer Join, nach path sortiert
            pairs_ = _study_pairs(dpath, bpath, dsel, bsel)
            for m in metrics
                col = mc(m)
                dif = Float64[col[i] - col[j] for (i, j) in pairs_]
                better = m in _LOWER_BETTER ? dif .< 0 : dif .> 0
                wc = wcol()
                w = Float64[wc[i] for (i, _) in pairs_]
                ok = isfinite.(dif)
                p = _rsum(w[ok] .* better[ok]) / _rsum(w[ok])
                q = _wquantile(dif, w, [0.05, 0.5, 0.95])
                swk = _rsum(w[ok])
                v = p * (1 - p) / (swk * swk / _rsum(w[ok] .* w[ok]))
                push!(prow, RFrame("strategy" => [s], "metric" => [m], "p_better" => [p], "se" => [v < 0 ? NaN : sqrt(v)],
                                   "diff_q05" => [q[1]], "diff_median" => [q[2]], "diff_q95" => [q[3]]))
            end
        end
        paired = _rbind_frames(prow)
    end
    return RList("distribution" => dist, "paired" => paired, "n_paths" => obj["n_paths"], "method" => obj["method"],
                 "benchmark" => bm, "path_length" => obj["path_length"]; class = "summary.SimLevBootstrapStudy")
end

const _LINE = repeat("═", 62)

function _print_summary_study(io::IO, x)
    function fv(v, m)
        m in ("cagr", "ttwror", "max_drawdown", "avg_drawdown", "dd_q50", "dd_q90", "p_better") && return _sp("%8.2f%%", 100 * v)
        m in ("final_value", "taxes") && return _sp("%10.0f", v)
        return _sp("%9.3f", v)
    end
    print(io, "\n", _LINE, "\n")
    print(io, "                 SimLev Bootstrap-Studie                       \n")
    print(io, _LINE, "\n")
    print(io, _sp("  Verfahren: %s | Pfade: %d | Pfadlänge: %d Tage\n", x["method"], x["n_paths"], x["path_length"]))
    d = x["distribution"]
    if d !== nothing
        qc = [c for c in names(d) if length(c) > 1 && c[1] == 'q' && isdigit(c[2])]
        for m in _uniq(collect(String, d["metric"]))
            sel = findall(d["metric"] .== m)
            lab = m == "cagr" ? "cagr (mit Sparplan geldgewichtet, XIRR)" : m
            print(io, _sp("\n  %s\n  %-14s %10s %s\n", lab, "Strategie", "Mittel", join([_sp("%10s", q) for q in qc])))
            for i in sel
                print(io, _sp("  %-14s %10s %s\n", d["strategy"][i], fv(d["mean"][i], m),
                              join([_sp("%10s", fv(d[q][i], m)) for q in qc])))
            end
        end
    end
    p = _get(x, "paired")
    if p !== nothing
        print(io, _sp("\n  Gepaarter Vergleich gegen '%s' (gleiche Pfade)\n", x["benchmark"]))
        print(io, _sp("  %-14s %-14s %10s %8s %11s %11s %11s\n", "Strategie", "Kennzahl", "P(besser)", "SE",
                      "Diff q05", "Diff Median", "Diff q95"))
        for i in 1:SimLev.nrow(p)
            m = p["metric"][i]
            print(io, _sp("  %-14s %-14s %9.1f%% %7.1f%% %11s %11s %11s\n", p["strategy"][i], m,
                          100 * p["p_better"][i], 100 * p["se"][i],
                          fv(p["diff_q05"][i], m), fv(p["diff_median"][i], m), fv(p["diff_q95"][i], m)))
        end
    end
    print(io, _LINE)   # ohne abschließenden Zeilenumbruch (wie capture.output)
end

function _print_study(io::IO, x)
    print(io, _sp("SimLev Bootstrap-Studie '%s': %d Pfade, Strategien: %s, %d Ergebniszeilen, %.1f s\n",
                  x["method"], x["n_paths"], join(collect(String, _values(x["strategies"])), ", "),
                  SimLev.nrow(x["results"]), x["elapsed"]))
    _print_summary_study(io, _summary_study(x))
end

# ── Grafik (SVG) ──────────────────────────────────────────────────────────

const _DARK3 = ["#E16A86", "#50A315", "#009ADE", "#B88A00", "#00AD9A", "#C86DD7"]
_svgnum(v) = @sprintf("%.2f", v)

"""
Ungewichtete Dichten einer Kennzahl je Strategie als SVG (R: `plot.SimLevBootstrapStudy`).

Liefert `(svg, data)`; `data`: `density` (`strategy`, `x`, `density`: die gezeichneten Punkte von
der Kerndichte `.sl_kde` je Strategie im Wertebereich der Kennzahl).
"""
function _plot_study(x; metric = "cagr", width = 640, height = 420)
    tab = x["results"]
    strats = collect(String, _values(x["strategies"]))
    dl = [_dvec(tab[metric])[tab["strategy"] .== s] for s in strats]
    allv = filter(isfinite, reduce(vcat, dl; init = Float64[]))
    dens = Any[]
    for v in dl
        v = filter(isfinite, v)
        dd = _SL().kde(v)   # Gauß-Kerndichte wie .sl_kde in R (slc; nur Grafik)
        push!(dens, (_dvec(dd["x"]), _dvec(dd["y"])))
    end
    x0, x1 = isempty(allv) ? (0.0, 1.0) : (minimum(allv), maximum(allv))
    x1 == x0 && (x1 = x0 + 1)
    y1 = maximum([isempty(d[2]) ? 0.0 : maximum(d[2]) for d in dens]; init = 1e-12)
    ml, mr, mt, mb = 60, 20, 40, 50
    pw, ph = width - ml - mr, height - mt - mb
    sx(v) = ml + (v - x0) / (x1 - x0) * pw
    sy(v) = mt + ph - v / y1 * ph
    io = IOBuffer()
    print(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\" font-family=\"sans-serif\" font-size=\"12\">\n")
    print(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n")
    print(io, "<text x=\"", width / 2, "\" y=\"22\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"bold\">",
          @sprintf("Verteilung %s (%s, %d Pfade)", metric, x["method"], x["n_paths"]), "</text>\n")
    print(io, "<rect x=\"$ml\" y=\"$mt\" width=\"$pw\" height=\"$ph\" fill=\"none\" stroke=\"black\"/>\n")
    print(io, "<text x=\"", ml + pw / 2, "\" y=\"", height - 12, "\" text-anchor=\"middle\">", metric, "</text>\n")
    print(io, "<text x=\"16\" y=\"", mt + ph / 2, "\" text-anchor=\"middle\" transform=\"rotate(-90 16 ", mt + ph / 2, ")\">Dichte</text>\n")
    rs = String[]; rx = Float64[]; ry = Float64[]
    for (i, (gx, gy)) in enumerate(dens)
        col = _DARK3[(i-1)%length(_DARK3)+1]
        keep = [(a, b) for (a, b) in zip(gx, gy) if x0 <= a <= x1]
        pts = join([string(_svgnum(sx(a)), ",", _svgnum(sy(b))) for (a, b) in keep], " ")
        append!(rs, fill(strats[i], length(keep))); append!(rx, first.(keep)); append!(ry, last.(keep))
        print(io, "<polyline fill=\"none\" stroke=\"$col\" stroke-width=\"1.5\" points=\"$pts\"/>\n")
        print(io, "<line x1=\"", width - mr - 120, "\" y1=\"", mt + 16 * i, "\" x2=\"", width - mr - 100, "\" y2=\"", mt + 16 * i,
              "\" stroke=\"$col\" stroke-width=\"1.5\"/><text x=\"", width - mr - 95, "\" y=\"", mt + 16 * i + 4, "\">", strats[i], "</text>\n")
    end
    print(io, "</svg>\n")
    svg = String(take!(io))
    return (svg, SimLev.RList("density" => SimLev.RFrame("strategy" => rs, "x" => rx, "density" => ry)))
end

# ── Registrierung der S3-Methoden ─────────────────────────────────────────

function __init__()
    SimLev.register_print!("bootstrap_config", _print_config)
    SimLev.register_print!("bootstrap_result", _print_boot_result)
    SimLev.register_print!("SimLevBootstrapStudy", _print_study)
    SimLev.register_print!("summary.SimLevBootstrapStudy", _print_summary_study)
    SimLev.register_summary!("SimLevBootstrapStudy", (x, args...; kw...) -> _summary_study(x; kw...))
    SimLev.register_plot!("SimLevBootstrapStudy", SimLev._plot_method(_plot_study, "SimLevBootstrapStudy"))
end

end # module
