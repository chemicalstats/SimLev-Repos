# Bootstrap – r/R/bootstrap.R (Vorlage python/simlev/bootstrap.py)
#
# Bootstrap-Pfade für Indizes, Hebelprodukte und Signale:
#   bootstrap_config  Spezifikation (Indizes, Hebelprodukte, Zusatzreihen)
#   bootstrap                         Preis-Pfade im Speicher (Klasse bootstrap_result)
#   validate_bootstrap, bootstrap_data, study_metrics, bootstrap_study,
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
using Dates
using Printf

export bootstrap_config, block_length, bootstrap, validate_bootstrap, bootstrap_data,
       study_metrics, bootstrap_study, bootstrap_probability

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
    println(stderr, msg)
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

"Gleitkommavektor aus beliebigen numerischen Eingaben."
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
_has(x, name) = _get(x, name) !== nothing

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

_match_arg(arg, choices) = SimLev.DataPrep._match_arg(arg, choices)

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
_rexp(x::Real) = SimLev.RLibm.exp(Float64(x))

"`cumprod(x)` wie in R (long double)."
function _cumprod(x)
    out = Vector{Float64}(undef, length(x))
    s = SimLev.F80(1.0)
    for (i, v) in enumerate(x)
        s = s * SimLev._ldq(Float64(v))
        out[i] = Float64(s)
    end
    return out
end
"`cumsum(x)` wie in R (long double)."
_cumsum(x) = SimLev.r_cumsum(x)
"`cummax(x)` wie in R."
_cummax(x) = SimLev.r_cummax(collect(Float64, x))

"`stats::median(x)` (Doubles, NA → NA; R's Teilsortierung über `RStats.median`)."
_median(x) = Float64(SimLev.RStats.median(_dvec(x)))

"`stats::quantile(x, probs, names = FALSE, type = 7)`."
function _quantile7(x, probs)
    r = SimLev.RStats.quantile(_dvec(x), _dvec(probs); names = false, type = 7)
    return _dvec(r)
end

"R's `pmax(a, b)` für Skalare (erstes Argument bleibt bei Gleichstand)."
_pmax(a::Float64, b::Float64) = isnan(a) ? a : isnan(b) ? b : (b > a ? b : a)
_pmin(a::Float64, b::Float64) = isnan(a) ? a : isnan(b) ? b : (b < a ? b : a)

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
"`suppressMessages(f())`: stderr verwerfen."
function _no_messages(f)
    return redirect_stderr(f, devnull)
end

_errmsg(e) = e isa ErrorException ? e.msg : e isa ArgumentError ? e.msg :
             (hasproperty(e, :msg) ? string(getproperty(e, :msg)) : sprint(showerror, e))

# ═══════════════════════════════════════════════════════════════════════════
# RNG-Hilfen (.with_rng_restore, .make_streams, .par_lapply)
# ═══════════════════════════════════════════════════════════════════════════

_R() = SimLev.RRng
_rng_kind_get() = collect(String, _R().rng_kind())
_rng_kind_set(k) = _R().rng_kind(k[1], k[2], k[3])

"""
    _with_rng_restore(f; seed = <fehlt>)

Zufallszustand sichern und wiederherstellen (Port von `.with_rng_restore`).
Ohne `seed` wird der Zustand vor dem Aufruf wiederhergestellt; mit einer Zahl
wird `set_seed(seed)` gesetzt und danach der vorherige Zustand
wiederhergestellt; `seed = nothing`: nichts setzen, nichts wiederherstellen.
"""
function _with_rng_restore(f::Function; seed = _MISSING)
    seed === nothing && return f()
    has = _R().has_random_seed()
    old = has ? _R().get_random_seed() : nothing
    kind = _rng_kind_get()
    try
        seed === _MISSING || _R().set_seed(seed)
        return f()
    finally
        if has
            _R().set_random_seed(old)
        else
            _rng_kind_set(kind)
            _R().has_random_seed() && _R().rm_random_seed()
        end
    end
end

"Zufallsströme je Pfad (L'Ecuyer-CMRG), Port von `.make_streams`."
function _make_streams(seed, n)
    has = _R().has_random_seed()
    old = has ? _R().get_random_seed() : nothing
    old_kind = has ? nothing : _rng_kind_get()
    try
        _R().rng_kind("L'Ecuyer-CMRG")
        _R().set_seed(seed)
        s = _R().get_random_seed()
        out = Any[]
        for _ in 1:Int(n)
            push!(out, s)
            s = _R().next_rng_stream(s)
        end
        return out
    finally
        if has
            _R().set_random_seed(old)
        else
            _rng_kind_set(old_kind)
            _R().has_random_seed() && _R().rm_random_seed()
        end
    end
end

function _rng_snapshot()
    has = _R().has_random_seed()
    seed = has ? _R().get_random_seed() : nothing
    kind = _rng_kind_get()
    has || (_R().has_random_seed() && _R().rm_random_seed())
    return (has, seed, kind)
end
function _rng_reset(snap)
    has, seed, kind = snap
    if has
        _R().set_random_seed(seed)
    else
        _rng_kind_set(kind)
        _R().has_random_seed() && _R().rm_random_seed()
    end
end

"""
    _par_lapply(X, FUN, cores = 1)

Port von `.par_lapply`: sequentiell, mit der Fork-Semantik von `mclapply`.
Bei `cores > 1` und mehr als einem Element startet jedes Element mit dem
Zufallszustand des Aufrufers (`mc.set.seed = FALSE`); danach ist der Zustand
des Aufrufers unverändert. Warnungen aus den Elementen gehen wie in
Kindprozessen verloren.
"""
function _par_lapply(X, FUN, cores = 1)
    xs = collect(X)
    (cores === nothing || cores <= 1 || length(xs) <= 1) && return Any[FUN(x) for x in xs]
    snap = _rng_snapshot()
    out = Any[]
    try
        for x in xs
            _rng_reset(snap)
            push!(out, _quiet(() -> FUN(x)))
        end
    finally
        _rng_reset(snap)
    end
    return out
end

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

Bootstrap-Konfiguration erstellen. `indices`: benannter Vektor Pfadname →
Spaltenname (`(us = "us_ret",)`, `["us" => "us_ret"]` oder `RVector`);
`letfs`: Vektor von Hebelprodukten (NamedTuple/Dict/RList mit `base` und
optional `leverage`, `finance`, `expense`, `spread`, `days`, `rate_basis`,
`ter_basis`, `name`); `aux`/`aux_type` benannte Vektoren.
"""
function bootstrap_config(indices; letfs = Any[], regime_index = nothing, aux = nothing, aux_type = nothing,
                          cross = nothing, input = nothing)
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

    letf_list = Any[]
    for (i, lt0) in enumerate(collect(letfs === nothing ? Any[] : letfs))
        lt = lt0 isa Union{RList,NamedTuple,AbstractDict} ? lt0 : RList()
        base = _get(lt, "base")
        base === nothing && _stop(@sprintf("LETF %d: 'base' muss angegeben werden", i))
        base in index_names || _stop(@sprintf("LETF %d: base '%s' nicht in indices. Verfügbar: %s", i, base, join(index_names, ", ")))
        lev = _rval(_get(lt, "leverage", 2.0))
        lev == 0 && _stop(@sprintf("LETF %d: leverage darf nicht 0 sein", i))
        fin = _rval(_get(lt, "finance", 3.5))
        fin isa AbstractString && !(fin in aux_names) && _stop(@sprintf("LETF %d: finance-Reihe '%s' nicht in aux.", i, fin))
        is_level(fin) && _stop(@sprintf("LETF %d: finance-Reihe '%s' ist in aux_type als 'level' gekennzeichnet; der Finanzierungszins muss eine Rate (Prozent p. a.) sein.", i, fin))
        _isnum(fin) && fin < 0 && _warn(@sprintf("LETF %d: negativer Finanzierungszins.", i))
        exp_ = _rval(_get(lt, "expense", 0.5))
        exp_ < 0 && _stop(@sprintf("LETF %d: expense muss >= 0 sein", i))
        days = _rval(_get(lt, "days", 1.0))
        days isa AbstractString && !(days in aux_names) && _stop(@sprintf("LETF %d: days-Reihe '%s' nicht in aux.", i, days))
        is_level(days) && _stop(@sprintf("LETF %d: days-Reihe '%s' ist in aux_type als 'level' gekennzeichnet; Tage je Zeile werden unverändert gebraucht ('rate').", i, days))
        name = _get(lt, "name")
        if name === nothing
            name = lev > 0 ? string(base, "_l", _as_char(lev)) : string(base, "_inv", _as_char(abs(lev)))
        end
        push!(letf_list, RList("name" => String(name), "base" => String(base), "leverage" => lev, "finance" => fin,
                               "expense" => exp_, "spread" => _rval(_get(lt, "spread", 0.0)), "days" => days,
                               "rate_basis" => _rval(_get(lt, "rate_basis", 360.0)),
                               "ter_basis" => _rval(_get(lt, "ter_basis", 365.0))))
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

"Renditematrix und Zusatzreihen extrahieren (Port von `.extract_returns`)."
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

"Standardparameter je Verfahren (Port von `.get_base_params`)."
function _get_base_params(method, params, n)
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

"Standard-ESS-Gitter je Verfahren (Port von `.get_ess_grid`)."
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

"Effektive Stichprobengröße je Konfiguration (Port von `.calculate_ess`)."
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

"Optimale Blocklänge nach Politis & White (2004), Port von `.pw_block`."
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
    block_length(x; transform = "none")

Optimale Blocklänge nach Politis & White (2004) mit Korrektur von Patton et
al. (2009). `x`: Vektor, Matrix (auch `NamedMat`) oder `RFrame`; `transform`:
"none", "abs" (`|x - mean|`) oder "squared". Ergebnis: Matrix (eine Zeile je
Reihe) mit Spalten `stationary` und `circular`.
"""
function block_length(x, transform_ = nothing; transform = nothing)
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

"\"auto\"-Parameter auflösen (Port von `.resolve_auto`)."
function _resolve_auto(params, returns, config, method)
    params = _as_rlist(params)
    for nm in ("L", "block_length")
        v = _get(params, nm)
        if v isa AbstractString && v == "auto"
            R = _mat(returns)
            lr = NamedMat(map(z -> _rlog(z), R); colnames = _colnames(returns))
            b1 = block_length(lr); b2 = block_length(lr, "abs")
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

_core() = SimLev.BootstrapCore

"""
GARCH(1,1) / GJR-GARCH(1,1) schätzen (rugarch → optim → Momente), Port von `.fit_garch11`.
Schätzt wie R (das rugarch übernommen hat, `.rugarch_ugarchfit`) zuerst mit der
Nachbildung von `rugarch::ugarchfit` (`SimLev.RRugarch`, Solver "hybrid");
scheitert sie mit einem R-Fehler, folgen wie in R der optim-Pfad (Nelder-Mead)
und die Momente. Warnungen von rugarch erscheinen wie in R auch bei
`quiet = true`. Erreicht rugarch den Solver gosolnp, setzt dieser wie in R
den globalen Zufallszustand neu (Startwert aus der Uhrzeit).
"""
function _fit_garch11(e; gjr = false, quiet = false)
    e = _dvec(e)
    n = length(e)
    mu = _rmean(e)
    if _rvar(e) < 1e-16
        return RList("mu" => mu, "omega" => 1e-20, "alpha" => 0.0, "beta" => 0.0, "gamma" => 0.0,
                     "s2" => fill(1e-20, n), "z" => zeros(n), "method" => "konstant", "s2_init" => 1e-20)
    end
    omega = alpha = beta = nothing
    gamma = 0.0
    method = "none"
    ok = nothing
    cf = nothing
    try
        fit = SimLev.RRugarch.ugarchfit(e; model = gjr ? "gjrGARCH" : "sGARCH", solver = "hybrid")
        cf = SimLev.RRugarch.coef(fit)
        ok = cf !== nothing
    catch err
        err isa UndefVarError && rethrow()       # sonst: tryCatch(..., error = function(err) NULL)
        err isa MethodError && rethrow()
    end
    # coef(fit) ist NULL (keine Konvergenz): in R werden mu, omega, ... NULL, der optim-Weg
    # filtert eine leere Reihe und `if (stats::sd(z) > 0)` bricht ab (in R mit erzwungener
    # Nicht-Konvergenz geprüft)
    ok === false && error("missing value where TRUE/FALSE needed")
    if ok === true
        cv = Dict(zip(cf.names, Float64.(cf.values)))
        mu = cv["mu"]; omega = cv["omega"]; alpha = cv["alpha1"]; beta = cv["beta1"]
        gjr && (gamma = cv["gamma1"])
        method = "rugarch"
    end
    filt(om, al, be, ga, m) = _core().garch_filter(e .- m, om, al, be, ga, om / max(1e-6, 1 - al - be - ga / 2))
    omega === nothing && try
        sv = _rvar(e)
        ep = e .- mu
        ep2 = ep .* ep
        function nll(th)
            om = _rexp(th[1])
            al = 0.5 / (1 + _rexp(-th[2]))
            be = 0.999 / (1 + _rexp(-th[3]))
            ga = gjr ? 0.5 / (1 + _rexp(-th[4])) : 0.0
            al + be + ga / 2 >= 0.9999 && return 1e10
            s2 = filt(om, al, be, ga, mu)
            return 0.5 * _rsum(Float64[_rlog(s2[i]) + ep2[i] / s2[i] for i in eachindex(s2)])
        end
        lg(p) = _rlog(p / (1 - p))
        st = [_rlog(sv * 0.05), lg(0.05 / 0.5), lg(0.90 / 0.999)]
        gjr && push!(st, lg(0.04 / 0.5))
        gjr && (st[2] = lg(0.02 / 0.5))
        o = SimLev.RStats.optim(st, nll; method = "Nelder-Mead", control = Dict("maxit" => 4000))
        par = _dvec(_get(o, "par"))
        val = Float64(_f1(_get(o, "value")))
        om = _rexp(par[1])
        al = 0.5 / (1 + _rexp(-par[2]))
        be = 0.999 / (1 + _rexp(-par[3]))
        ga = gjr ? 0.5 / (1 + _rexp(-par[4])) : 0.0
        if val < 1e9 && al + be + ga / 2 < 0.9999
            omega, alpha, beta, gamma, method = om, al, be, ga, "optim"
        end
    catch err
        err isa UndefVarError && rethrow()
        err isa MethodError && rethrow()
    end
    if omega === nothing
        sv = _rvar(e)
        alpha, beta = 0.08, 0.88
        gamma = gjr ? 0.04 : 0.0
        omega = sv * (1 - alpha - beta - gamma / 2)
        method = "momente"
        quiet || _warn("GARCH: rugarch und optim fehlgeschlagen, verwende Moment-Schätzer")
    end
    s2 = filt(omega, alpha, beta, gamma, mu)
    z = Float64[(e[i] - mu) / sqrt(s2[i]) for i in 1:n]
    for i in 1:n
        isfinite(z[i]) || (z[i] = 0.0)
    end
    sdz = _rsd(z)
    if sdz > 0
        mz = _rmean(z); sz = _rsd(z)
        z = (z .- mz) ./ sz
    end
    pers = alpha + beta + gamma / 2
    return RList("mu" => mu, "omega" => omega, "alpha" => alpha, "beta" => beta, "gamma" => gamma, "s2" => s2, "z" => z,
                 "method" => method, "persistence" => pers,
                 "s2_init" => pers < 0.9999 ? omega / (1 - pers) : _rvar(e))
end

"Nicht-Referenzreihen als GARCH(1,1) modellieren (Port von `.fit_cross`); `base` 1-basiert."
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
Tail-Schätzung (GPD via evd → Momente → empirisch → Default), Port von `.fit_tail`.

Den GPD-Fit (`.evd_fpot(exc, threshold = 0, std.err = FALSE)`, aus evd 2.3-7.1
ins R-Paket übernommen, nachgebildet in `SimLev.REvd.fpot`) nimmt R bei
mindestens 30 Überschreitungen; Fehler darin führen wie das `tryCatch` in R
zum Momenten-Schätzer.
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
            f = SimLev.REvd.fpot(exc, 0; std_err = false)
            sc = f["estimate"]["scale"]; sh = f["estimate"]["shape"]
            scale = sc; shape = sh; method = "MLE"
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

"Regime aus rollierender Volatilität (Port von `.prepare_regime_info`)."
function _prepare_regime_info(base_ret, vol_window, n_regimes)
    vol = _core().rolling_vol(base_ret, Int(trunc(Float64(vol_window))))
    th = _quantile7(vol, _seq_len_out(Float64(n_regimes) + 1))
    th[end] = th[end] + 1e-10
    reg = _core().assign_regimes(vol, th)
    return RList("regimes" => reg, "trans" => _core().estimate_trans_mat(reg, Int(trunc(Float64(n_regimes)))), "vol" => vol)
end

"""
MS-GARCH-Familie vorbereiten (Port von `.prepare_ms_info`; eigene ML-Schätzung
`SimLev.MsGarch._ms_garch_fit`); `base` 1-basiert.
"""
function _prepare_ms_info(returns, config, base, K, garch_model, ar_gm, tvtp)
    MG = SimLev.MsGarch
    MG._ms_garch_check(K, garch_model)
    st = SimLev.RStats
    R = _mat(returns)
    ex = R[:, base] .- 1; n = length(ex)
    Ki = Int(Float64(K isa AbstractVector || K isa Tuple ? first(K) : K))
    gm = String(garch_model isa AbstractVector || garch_model isa Tuple ? first(garch_model) : garch_model)
    fit = try
        MG._ms_garch_fit(ex, K, garch_model)
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
                Float64(_dvec(st.lm_fit(hcat(ones(length(i)), lag_ex[i]), ex[i])["coefficients"])[2])
            catch e
                e isa InterruptException && rethrow()
                NA
            end
            isfinite(b) && (phi[r] = max(-0.5, min(0.5, b)))
            l = try
                Float64(_dvec(st.lm_fit(reshape(sig[i], :, 1), ex[i] .- mu[r] .- phi[r] .* lag_ex[i])["coefficients"])[1])
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
                        g = st.glm("y ~ x"; family = st.r_binomial(), env = Dict("y" => Int.(to .== j), "x" => x))
                        Float64(st.coef(g)["x"])
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

"Verfahrensspezifische Vorberechnung (Port von `.prepare_method_info`)."
function _prepare_method_info(returns, config, method, params)
    R = _mat(returns)
    p = _get_base_params(method, params, size(R, 1))
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
    method == "ms_garch" && (info["ms"] = _prepare_ms_info(R, config, base, p["ms_n_regimes"], p["ms_garch_model"], false, false))
    method == "ms_ar_garch_m" && (info["ms"] = _prepare_ms_info(R, config, base, p["ms_ar_n_regimes"], p["ms_ar_garch_model"], true, false))
    method == "tvtp_ms_garch" && (info["ms"] = _prepare_ms_info(R, config, base, p["tvtp_n_regimes"], p["tvtp_garch_model"], true, true))
    return info
end

# ═══════════════════════════════════════════════════════════════════════════
# Pfaderzeugung
# ═══════════════════════════════════════════════════════════════════════════

"`as.integer` (Abschneiden)."
_as_int(x) = x isa Integer ? Int(x) : Int(trunc(Float64(_f1(x))))

"Eine Renditematrix samt Quellzeilen erzeugen (Port von `.generate_returns`)."
function _generate_returns(returns, method, p, info, n_out)
    R = _mat(returns)
    n, k = size(R)
    from_idx(idx) = RList("ret" => R[idx, :], "idx" => idx)
    C = _core()
    g = if method == "raw"
        from_idx(C.boot_idx_iid(n, n_out))
    elseif method == "block"
        from_idx(C.boot_idx_block(n, n_out, _as_int(p["block_length"]), false))
    elseif method == "circular"
        from_idx(C.boot_idx_block(n, n_out, _as_int(p["block_length"]), true))
    elseif method == "stationary"
        from_idx(C.boot_idx_stationary(n, n_out, Float64(_f1(p["L"]))))
    elseif method == "regime"
        from_idx(C.boot_idx_regime(info["regimes"], info["trans"], n_out))
    elseif method == "tails"
        from_idx(C.boot_idx_tails(n_out, info["p"], info["p"], info["bulk"], info["left"], info["right"]))
    elseif method == "wild"
        RList("ret" => C.boot_wild(R, _as_int(p["wild_type"])), "idx" => collect(1:n))
    elseif method == "reset"
        RList("ret" => C.boot_reset(R, _f1(p["p_break"])), "idx" => collect(1:n))
    elseif method == "evt"
        lt = info["left"]; rt = _get(info, "right")
        C.boot_evt(R, info["base"] - 1, n_out, lt["prob"], lt["thresh"], lt["scale"], lt["shape"], lt["pool"],
                   rt === nothing ? 0.0 : rt["prob"], rt === nothing ? Inf : rt["thresh"],
                   rt === nothing ? 0.0 : rt["scale"], rt === nothing ? 0.0 : rt["shape"],
                   rt === nothing ? Int[] : rt["pool"], info["bulk"])
    elseif method in ("garch", "gjr_garch")
        f = info["garch"]; cr = info["cross"]
        C.boot_garch(n_out, info["base"] - 1, k, f["mu"], f["omega"], f["alpha"], f["beta"], f["gamma"],
                     f["s2_init"], f["z"], collect(1:n), cr["cols"], cr["mu"], cr["om"], cr["al"],
                     cr["be"], cr["ratio"], cr["s2"], cr["z"])
    elseif method in ("ms_garch", "ms_ar_garch_m", "tvtp_ms_garch")
        m = info["ms"]; cr = m["cross"]
        C.boot_ms_garch(n_out, info["base"] - 1, k, Int(m["K"]), m["mu"], m["omega"], m["alpha"], m["beta"], m["gamma"],
                        m["phi"], m["lambda"], m["trans"], m["delta"], m["unc"], m["stat"], m["pools"], m["z"],
                        cr["cols"], cr["mu"], cr["om"], cr["al"], cr["be"], cr["ratio"], cr["s2"], cr["z"])
    else
        _stop(@sprintf("Unbekannte Methode: %s", method))
    end
    return g
end

_auxcol(aux_rows, nm) = (aux_rows isa NamedMat ? aux_rows[:, String(nm)] : error("aux_rows ohne Spaltennamen"))

"""
Hebelprodukt-Renditen (MSCI-Formel plus Fondskosten), Port von `.letf_returns`.
`aux_rows`: Matrix der Zusatzreihen mit Spaltennamen (NamedMat) oder `nothing`.
"""
function _letf_returns(rb, letf, aux_rows)
    L = Float64(_f1(_get(letf, "leverage")))
    fin = _get(letf, "finance")
    rate = fin isa AbstractString ? _dvec(_auxcol(aux_rows, fin)) : [Float64(_f1(fin))]
    dd = _get(letf, "days")
    d = dd isa AbstractString ? _dvec(_auxcol(aux_rows, dd)) : [Float64(_f1(dd))]
    m = max(L - 1, 0.0) + max(-L, 0.0)
    rbas = Float64(_f1(_get(letf, "rate_basis"))); tbas = Float64(_f1(_get(letf, "ter_basis")))
    ex = Float64(_f1(_get(letf, "expense"))); sp = Float64(_f1(_get(letf, "spread")))
    rb = _dvec(rb)
    n = max(length(rb), length(rate), length(d))
    out = Vector{Float64}(undef, n)
    for i in 1:n
        r = rb[(i-1)%length(rb)+1]; ra = rate[(i-1)%length(rate)+1]; di = d[(i-1)%length(d)+1]
        t1 = 1 + L * (r - 1)
        t2 = (1 - L) * ra / 100 * di / rbas
        t3 = ex / 100 * di / tbas
        t4 = sp / 100 * m * di / rbas
        out[i] = t1 + t2 - t3 - t4
    end
    return out
end

"`apply(M, 2, cumprod)` (long double)."
function _cumprod_cols(M::Matrix{Float64})
    out = similar(M)
    for j in 1:size(M, 2)
        out[:, j] = _cumprod(view(M, :, j))
    end
    return out
end

"Preis-Pfad aus Renditen bauen (Port von `.build_path`); NamedMat oder `nothing`."
function _build_path(g, aux, config; start = 100.0, aux_ratio = nothing, aux_start = nothing)
    ret = g["ret"]
    idx = _ivec(g["idx"])
    ret isa AbstractMatrix || return nothing
    ret = _mat(ret)
    (any(!isfinite, ret) || any(<=(0), ret)) && return nothing
    n_out = size(ret, 1)
    P = start .* _cumprod_cols(vcat(ones(1, size(ret, 2)), ret))
    cols = copy(_cfg_list(config, "index_names"))
    blocks = Matrix{Float64}[P]
    anames = _cfg_list(config, "aux_names")
    aux_rows = aux === nothing ? nothing : NamedMat(_mat(aux)[idx, :]; colnames = anames)
    if config["n_letfs"] != 0
        Ls = Vector{Float64}[]
        inames = _cfg_list(config, "index_names")
        for lt in config["letfs"]
            r = _letf_returns(ret[:, findfirst(==(lt["base"]), inames)], lt, aux_rows)
            length(r) == 1 && n_out != 1 && (r = fill(r[1], n_out))
            any(!isfinite, r) && return nothing
            ko = findfirst(<=(0), r)
            ko === nothing || (r[ko:n_out] .= 0.0)
            push!(Ls, start .* _cumprod(vcat(1.0, Float64[_pmax(v, 0.0) for v in r])))
        end
        push!(blocks, reduce(hcat, Ls))
        append!(cols, _cfg_list(config, "letf_names"))
    end
    lv = nothing
    if aux !== nothing
        A = _mat(aux)[vcat(idx[1], idx), :]
        push!(blocks, A)
        append!(cols, anames)
    end
    M = reduce(hcat, blocks)
    if aux !== nothing && aux_ratio !== nothing
        AR = _mat(aux_ratio)
        lvm = _cumprod_cols(vcat(ones(1, size(AR, 2)), AR[idx, :]))
        s0 = aux_start !== nothing ? _dvec(aux_start) : _mat(aux)[1, :] ./ AR[1, :]
        for j in 1:size(lvm, 2), i in 1:size(lvm, 1)
            lvm[i, j] = lvm[i, j] * s0[j]
        end
        at = _get(config, "aux_type")
        off = length(cols) - length(anames)
        for (j, a) in enumerate(anames)
            _aux_type_of(at, a) == "level" && (M[:, off+j] = lvm[:, j])
        end
        lv = NamedMat(lvm; colnames = anames)
    end
    out = NamedMat(M; colnames = cols)
    lv === nothing || (out.attrs["aux_level"] = lv)
    return out
end

"ESS-Design (Port von `.ess_design`): RFrame oder `nothing`."
function _ess_design(method, params, grid, budget, n_obs)
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

"Verfahrensparameter vor dem Ziehen prüfen (Port von `.check_boot_params`)."
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

"Gemeinsame Vorbereitung für bootstrap() und bootstrap_study() (Port von `.boot_setup`)."
function _boot_setup(data, config, method, n, params, ess, ess_grid, path_length)
    _is_config(config) || _stop("config muss mit bootstrap_config() erstellt werden")
    method in _BOOT_METHODS || _stop("Unbekannte Methode '" * string(method) * "'. Verfügbar: " * join(_BOOT_METHODS, ", "))
    (!_isnum(n) || n < 1) && _stop("n muss eine positive Zahl sein")
    if path_length !== nothing && (!_num1(path_length) || _f1(path_length) < 1 || _f1(path_length) != _round0(_f1(path_length)))
        _stop(@sprintf("path_length muss eine ganze Zahl >= 1 sein (erhalten: %s).", _show(path_length)))
    end
    ex = _extract_returns(data, config)
    n_obs = size(ex["ret"], 1)
    n_out = _as_int(path_length !== nothing ? path_length : n_obs)
    if method in ("wild", "reset") && n_out != n_obs
        _stop(@sprintf("Verfahren '%s' erhält die Chronologie; path_length muss %d sein.", method, n_obs))
    end
    params = _resolve_auto(params, ex["ret"], config, method)
    design = ess ? _ess_design(method, params, ess_grid, _as_int(n), n_obs) : nothing
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
            _prepare_method_info(ex["ret"], config, method, cp)
        catch err
            (err isa UndefVarError || err isa MethodError) && rethrow()
            _stop(@sprintf("Vorberechnung fehlgeschlagen: %s", _errmsg(err)))
        end
        push!(infos, info)
    end
    base_p = RList[_get_base_params(method, cp, n_obs) for cp in combos]
    for bp in base_p
        _check_boot_params(method, bp, n_obs)
    end
    weights = design === nothing ? ones(n_paths) : design["weight"][combo_of_path]
    weights = weights ./ _rsum(weights) .* length(weights)
    return RList("ex" => ex, "n_obs" => n_obs, "n_out" => n_out, "design" => design, "combos" => combos, "base_p" => base_p,
                 "infos" => infos, "combo_of_path" => combo_of_path, "n_paths" => n_paths, "weights" => weights)
end

"Einen gültigen Pfad mit eigenem Zufallsstrom erzeugen (Port von `.draw_path`); `i` 1-basiert."
function _draw_path(setup, i, stream, config, method, max_tries)
    _R().set_random_seed(stream)
    c_id = setup["combo_of_path"][i]
    err = "Pfad ungültig (Indexrendite <= 0 oder nicht endlich)"
    ex = setup["ex"]
    for tr in 1:Int(max_tries)
        g = try
            _generate_returns(ex["ret"], method, setup["base_p"][c_id], setup["infos"][c_id], setup["n_out"])
        catch e
            (e isa UndefVarError || e isa MethodError) && rethrow()
            err = _errmsg(e)
            nothing
        end
        if g !== nothing
            P = _build_path(g, ex["aux"], config; aux_ratio = ex["aux_ratio"], aux_start = ex["aux_start"])
            P === nothing || return (path = P, tries = tr, err = nothing)
        end
    end
    return (path = nothing, tries = Int(max_tries), err = err)
end

# ═══════════════════════════════════════════════════════════════════════════
# bootstrap()
# ═══════════════════════════════════════════════════════════════════════════

"`sample.int(.Machine\$integer.max, 1L)`."
_new_seed() = Int(first(_R().sample_int(2147483647, 1)))

"""
    bootstrap(data, config; method = "raw", n = 1000, params = nothing, ess = false,
              ess_grid = nothing, progress = true, path_length = nothing, seed = nothing,
              cores = 1, max_tries = 10)

Bootstrap-Pfade erzeugen (Port von `bootstrap()`); `method` darf auch drittes
Positionsargument sein. Ergebnis: RList der Klasse `bootstrap_result`.
"""
function bootstrap(data, config, method_pos = nothing; method = "raw", n = 1000, params = nothing, ess = false,
                   ess_grid = nothing, progress = true, path_length = nothing, seed = nothing, cores = 1, max_tries = 10)
    data = SimLev.as_rframe(data)
    method_pos === nothing || (method = method_pos)
    t0 = time()
    setup = _boot_setup(data, config, method, n, params, ess, ess_grid, path_length)
    seed === nothing && (seed = _new_seed())
    streams = _with_rng_restore(() -> _make_streams(seed, setup["n_paths"]))
    res = _with_rng_restore(() -> _par_lapply(1:setup["n_paths"],
        i -> _draw_path(setup, i, streams[i], config, method, max_tries), cores))
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
    validate_bootstrap(result; min_rows = nothing, verbose = true)

Bootstrap-Ergebnis validieren und bereinigen: entfernt leere, unvollständige
oder nicht endliche Pfade sowie Pfade mit abweichender Zeilenzahl und normiert
die Gewichte neu auf Mittel 1.
"""
function validate_bootstrap(result; min_rows = nothing, verbose = true)
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
    bootstrap_data(result, i = 1; dates = nothing, start_date = "2000-01-01")

Bootstrap-Pfad als RFrame für `simulation()`: Spalte `date` und alle
Pfadspalten; ausdrücklich als "rate" gekennzeichnete Zusatzreihen stehen im
Attribut `aux_type` (`attrs(df)["aux_type"]`).
"""
function bootstrap_data(result, i_pos = 1; i = i_pos, dates = nothing, start_date = "2000-01-01")
    is_res = _is_boot_result(result)
    P = is_res ? result["paths"][Int(i)] : result
    nr = _nrow(P)
    dates === nothing && (dates = _seq_dates(_todate(start_date, "start_date")[1], nr))
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

"Standard-Kennzahlen einer Simulation für [`bootstrap_study`](@ref) (benannter Vektor)."
function study_metrics(res)
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

"Schlüsselwörter von `simulation()` (oder `nothing`, wenn beliebige erlaubt sind)."
function _sim_kwnames()
    out = Symbol[]
    for m in methods(SimLev.simulation)
        kws = try
            Base.kwarg_decl(m)
        catch
            Symbol[]
        end
        for k in kws
            endswith(string(k), "...") && return nothing
            push!(out, k)
        end
    end
    return out
end

"`do.call(simulation, c(list(data = df, strategy = strategy), args))`."
function _sim_call(df, strategy, args::RList)
    kw = _sim_kwnames()
    if kw !== nothing
        bad = [k for k in keys(args) if !(Symbol(k) in kw)]
        if !isempty(bad)
            txt = join([string(k, " = ", _deparse(args[k])) for k in bad], ", ")
            _stop(string("unused argument", length(bad) > 1 ? "s" : "", " (", txt, ")"))
        end
    end
    return SimLev.simulation(df, strategy; (Symbol(k) => v for (k, v) in args)...)
end

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

module _ChunkIO
import ...SimLev
_F(u::UInt64) = reinterpret(Float64, u)
_RV(v, n) = SimLev.RVector(v; names = n)
_RL(ps, cls) = SimLev.RList(ps...; class = cls)
function _NM(v, r, c, rn, cn, at)
    m = SimLev.NamedMat(reshape(v, r, c); rownames = rn, colnames = cn)
    for (k, x) in at
        m.attrs[k] = x
    end
    m
end
end

function _ser(io::IO, x)
    if x === nothing
        print(io, "nothing")
    elseif x isa Bool
        print(io, x ? "true" : "false")
    elseif x isa Integer
        print(io, "Int(", Int(x), ")")
    elseif x isa Float64
        print(io, "_F(0x", string(reinterpret(UInt64, x); base = 16, pad = 16), ")")
    elseif x isa AbstractString
        print(io, repr(String(x)))
    elseif x isa Date
        print(io, "Dates.Date(", Dates.year(x), ",", Dates.month(x), ",", Dates.day(x), ")")
    elseif x isa RVector
        print(io, "_RV("); _ser(io, x.values); print(io, ","); _ser(io, x.names); print(io, ")")
    elseif x isa NamedMat
        print(io, "_NM("); _ser(io, vec(x.data)); print(io, ",", size(x, 1), ",", size(x, 2), ",")
        _ser(io, x.rownames); print(io, ","); _ser(io, x.colnames); print(io, ",Dict{String,Any}(")
        for (k, v) in x.attrs
            print(io, repr(k), "=>"); _ser(io, v); print(io, ",")
        end
        print(io, "))")
    elseif x isa RList
        print(io, "_RL(Pair{String,Any}[")
        for (k, v) in x
            print(io, repr(k), "=>"); _ser(io, v); print(io, ",")
        end
        print(io, "],"); _ser(io, collect(String, x.class)); print(io, ")")
    elseif x isa NamedTuple
        print(io, "(;")
        for (k, v) in pairs(x)
            print(io, k, "="); _ser(io, v); print(io, ",")
        end
        print(io, ")")
    elseif x isa AbstractDict
        print(io, "Dict{String,Any}(")
        for (k, v) in x
            print(io, repr(string(k)), "=>"); _ser(io, v); print(io, ",")
        end
        print(io, ")")
    elseif x isa AbstractMatrix
        print(io, "reshape("); _ser(io, vec(collect(x))); print(io, ",", size(x, 1), ",", size(x, 2), ")")
    elseif x isa AbstractVector
        T = eltype(x)
        print(io, T <: Float64 ? "Float64[" : T <: Bool ? "Bool[" : T <: Integer ? "Int[" : T <: AbstractString ? "String[" :
                  T <: Date ? "Date[" : "Any[")
        for v in x
            _ser(io, v); print(io, ",")
        end
        print(io, "]")
    else
        error("chunk_dir: Wert vom Typ $(typeof(x)) nicht speicherbar")
    end
end
_save_chunk(f, x) = open(io -> (_ser(io, x); nothing), f, "w")
function _load_chunk(f)
    ex = Meta.parse(read(f, String))
    m = Module(:ChunkLoad)
    Core.eval(m, :(using Dates; import SimLev; using SimLev.Bootstrap._ChunkIO: _F, _RV, _RL, _NM))
    return Core.eval(m, ex)
end

"""
    bootstrap_study(data, config; method = "stationary", n = 1000, strategies, params = nothing,
                    ess = false, ess_grid = nothing, path_length = nothing, dates = nothing,
                    start_date = "2000-01-01", burn_in = 0, sim_args = nothing, metrics = study_metrics,
                    benchmark = nothing, cores = 1, chunk_size = 25, seed = nothing, chunk_dir = nothing,
                    max_tries = 10, keep_paths = 0, keep_returns = "none", keep_aux = nothing, progress = true)

Strategien auf Bootstrap-Pfaden auswerten (Port von `bootstrap_study()`).
`strategies`: benannte Liste (NamedTuple/Dict/Pairs) Name → Strategie oder
Spezifikation `(strategy = …, signal = df -> …, args = (…), map = (alias = "spalte",))`;
die Signal-Funktion bekommt ein RFrame und liefert ein RFrame oder benannte Spalten.
"""
function bootstrap_study(data, config, method_pos = nothing; method = "stationary", n = 1000, strategies = nothing,
                         params = nothing, ess = false, ess_grid = nothing, path_length = nothing, dates = nothing,
                         start_date = "2000-01-01", burn_in = 0, sim_args = nothing, metrics = study_metrics,
                         benchmark = nothing, cores = 1, chunk_size = 25, seed = nothing, chunk_dir = nothing,
                         max_tries = 10, keep_paths = 0, keep_returns = nothing, keep_aux = nothing, progress = true)
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
    sim_args = _as_rlist(sim_args)
    setup = _boot_setup(data, config, method, n, params, ess, ess_grid, path_length)
    n_out = setup["n_out"]
    dates === nothing && (dates = _seq_dates(_todate(start_date, "start_date")[1], n_out + 1))
    _len(dates) != n_out + 1 && _stop(@sprintf("dates braucht Länge %d (Pfadlänge + 1).", n_out + 1))
    dates = _todate(dates, "dates")
    burn_in >= n_out && _stop("burn_in ist länger als der Pfad.")
    seed === nothing && (seed = _new_seed())
    n_paths = setup["n_paths"]
    streams = _with_rng_restore(() -> _make_streams(seed, n_paths))
    cs = Float64(chunk_size)
    keyv = Float64[ceil(i / cs) for i in 1:n_paths]
    chunks = [findall(==(k), keyv) for k in sort(unique(keyv))]
    chunk_dir === nothing || mkpath(chunk_dir)
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
        for nm in snames
            sp = specs[nm]
            df = copy(df0)
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
            bi > 0 && (df = _sim_rows(df, bi+1:SimLev.nrow(df)))
            args = _modify_list(sim_args, _get(sp, "args"))
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
            f = joinpath(chunk_dir, @sprintf("chunk_%05d_seed%d%s.rds", ci, Int(seed), keep_returns != "none" ? "_" * keep_returns : ""))
        end
        f !== nothing && isfile(f) && return _load_chunk(f)
        out = Any[eval_path(i) for i in chunks[ci]]
        f !== nothing && _save_chunk(f, out)
        progress && cores <= 1 && _message(@sprintf("  Chunk %d/%d fertig (%.0f s)", ci, length(chunks), time() - t0))
        return out
    end
    progress && _message(@sprintf("Bootstrap-Studie '%s': %d Pfade x %d Strategien, %d Chunks, %d Kern(e)",
                                  method, n_paths, length(specs), length(chunks), Int(cores)))
    resc = _with_rng_restore(() -> _par_lapply(1:length(chunks), run_chunk, cores))
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

"Gewichtete Quantile (gewichteter Typ 7, Akinshin 2023), Port von `.wquantile`."
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

Wahrscheinlichkeiten aus einer Bootstrap-Studie. Bedingungen als Zeichenketten
in R-Syntax (Spaltennamen von `study.results` als Variablen, z. B.
`"cagr > 0 & max_drawdown <= 0.5"`; siehe Kopf dieser Datei) oder Funktionen
`RFrame -> Vektor`. Unbenannte Bedingungen werden nach ihrem Text benannt,
benannte über Schlüsselwörter (`joint = "cagr > 0 & max_drawdown <= 0.5"`).
Freie Variablen werden in `env` gesucht. `thresholds`: Strategie → (Name →
Bedingung); ersetzt für diese Strategie die übrigen Bedingungen.
Ergebnis: RFrame mit `strategy`, `condition`, `probability`, `se`, `n`.
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

"Zusammenfassung einer Bootstrap-Studie (R: `summary.SimLevBootstrapStudy`)."
function _summary_study(obj; metrics = ["cagr", "ttwror", "max_drawdown", "sharpe", "ulcer_index", "final_value"],
                        probs = [0.05, 0.25, 0.5, 0.75, 0.95])
    tab = obj["results"]
    metrics = metrics isa AbstractString ? [metrics] : collect(String, metrics)
    metrics = [m for m in _uniq(metrics) if haskey(tab, m)]
    probs = _dvec(probs)
    qn = String[_sp("q%02d", _round0(100 * p)) for p in probs]
    rows = RFrame[]
    for s in collect(String, _values(obj["strategies"]))
        sel = tab["strategy"] .== s
        for m in metrics
            x = _dvec(tab[m])[sel]; w = _dvec(tab["weight"])[sel]
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
            pairs_ = Tuple{Int,Int}[]
            for pv in sort(unique(vcat(dpath, bpath)); lt = (a, b) -> a < b)
                for i in findall(==(pv), dpath), j in findall(==(pv), bpath)
                    push!(pairs_, (dsel[i], bsel[j]))
                end
            end
            for m in metrics
                col = _dvec(tab[m])
                dif = Float64[col[i] - col[j] for (i, j) in pairs_]
                better = m in _LOWER_BETTER ? dif .< 0 : dif .> 0
                w = Float64[_dvec(tab["weight"])[i] for (i, _) in pairs_]
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
`density()` je Strategie im Wertebereich der Kennzahl).
"""
function _plot_study(x; metric = "cagr", file = nothing, width = 640, height = 420)
    tab = x["results"]
    strats = collect(String, _values(x["strategies"]))
    dl = [_dvec(tab[metric])[tab["strategy"] .== s] for s in strats]
    allv = filter(isfinite, reduce(vcat, dl; init = Float64[]))
    dens = Any[]
    for v in dl
        v = filter(isfinite, v)
        dd = SimLev.RStats.density(v)
        push!(dens, (_dvec(_get(dd, "x")), _dvec(_get(dd, "y"))))
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
