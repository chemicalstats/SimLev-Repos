# Referenzbäume: Vergleich der Julia-Fassung mit den R-Referenzfällen in
# golden/modules/<modul>/*.json.gz (erzeugt mit golden/modules/ref_tools.R).
#
# Jeder Fall enthält Eingaben, R-Code, Python-Code (`py`), Julia-Code (`jl`)
# und das R-Ergebnis als Baum. Die Eingaben werden in Julia-Objekte
# übersetzt (siehe src/r/types.jl), der Julia-Code läuft in einem frischen
# Modul (mit `using SimLev`, `using Dates`) und setzt `result`. Verglichen
# werden Ergebnis (bitgenau, NA ≠ NaN, Vorzeichen der Null), Konsolenausgabe,
# Druckausgabe (`show(io, MIME"text/plain"(), result)`), Warnungen
# (`@warn`-Meldungen) und Fehlermeldungen.
#
# Lockerungen über Umgebungsvariablen: SIMLEV_LAX_NA=1 (NA = NaN),
# SIMLEV_STRICT_ZERO=0 (-0 = +0).
#
# Format 2: Größere Eingaben stehen je Modul einmal im Eingabespeicher
# <modul>/_inputs.json.gz; der Fall trägt dafür den Verweis {"t": "ref", "k": …}.
# `read_ref_case` liest einen Fall und löst die Verweise auf (gleicher Baum wie im
# Format 1); `list_ref_cases` listet die Fälle eines Ordners ohne den Speicher.

using Dates
using Logging
isdefined(@__MODULE__, :parse_json) || include(joinpath(@__DIR__, "golden_tools.jl"))

# Die Referenzen entstanden mit R unter LC_ALL=C.UTF-8 (ICU-Kollation "root"); für den
# Vergleich dieselbe Kollation erzwingen, unabhängig vom Locale des Rechners.
SimLev.REnv.set_collate_default!("icu:root") && SimLev.RStats.collate_reset()
const _LAX_NA = SimLev.REnv.lax_na()
const _STRICT_ZERO = SimLev.REnv.strict_zero()

_aslist(v) = v === nothing ? Any[] : v isa AbstractVector ? v : Any[v]
_vals(node) = (v = get(node, "v", nothing); v === nothing ? Any[nothing] : v isa AbstractVector ? v : Any[v])

const _EPOCH = Date(1970, 1, 1)

# ── Laden (Format 1 und 2) ──────────────────────────────────────────────────
const REF_INPUTS_FILE = "_inputs.json.gz"
const _STORE_CACHE = Ref{Any}(nothing)     # (Pfad, mtime, Größe) => Eingaben des zuletzt genutzten Speichers

_isref(v) = v isa JObj && get(v, "t", nothing) == "ref"

function _ref_store(dir)
    p = abspath(joinpath(dir, REF_INPUTS_FILE))
    isfile(p) || error("Eingabespeicher $p fehlt")
    tag = (p, mtime(p), filesize(p))
    c = _STORE_CACHE[]
    c !== nothing && c[1] == tag && return c[2]
    st = read_case(p)["inputs"]
    _STORE_CACHE[] = (tag, st)
    st
end

"Ersetzt Verweise in `case[\"inputs\"]` durch die Bäume aus dem Eingabespeicher von `dir`."
function resolve_ref_inputs!(case, dir)
    inp = get(case, "inputs", nothing)
    (inp isa JObj && any(_isref, inp.vals)) || return case
    st = _ref_store(dir)
    for i in eachindex(inp.vals)
        v = inp.vals[i]
        _isref(v) || continue
        haskey(st, v["k"]) || error("Eingabe $(inp.keys[i]) (Schlüssel $(v["k"])) fehlt in $(joinpath(dir, REF_INPUTS_FILE))")
        inp.vals[i] = st[v["k"]]
    end
    case
end

"Liest einen Referenzfall (Format 1 oder 2) samt aufgelösten Eingaben."
read_ref_case(path) = resolve_ref_inputs!(read_case(path), dirname(abspath(path)))

"Dateinamen der Referenzfälle in `dir` (sortiert, ohne den Eingabespeicher)."
list_ref_cases(dir) = sort(filter(f -> (endswith(f, ".json.gz") || endswith(f, ".json")) && !startswith(f, "_"), readdir(dir)))

function _dvec(node)
    t = node["t"]
    v = _vals(node)
    if t == "num"
        return Float64[unhex(x) for x in v]
    elseif t == "int"
        any(x -> x === nothing || x == "NA", v) && return Union{Missing,Int}[x === nothing || x == "NA" ? missing : Int(unhex(x)) for x in v]
        return Int[Int(unhex(x)) for x in v]
    elseif t == "lgl"
        any(isnothing, v) && return Union{Missing,Bool}[x === nothing ? missing : Bool(x) for x in v]
        return Bool[Bool(x) for x in v]
    elseif t == "chr"
        any(isnothing, v) && return Union{Missing,String}[x === nothing ? missing : String(x) for x in v]
        return String[String(x) for x in v]
    elseif t == "date"
        any(isnothing, v) && return Union{Missing,Date}[x === nothing ? missing : _EPOCH + Day(Int(x)) for x in v]
        return Date[_EPOCH + Day(Int(x)) for x in v]
    end
    error("Vektortyp $t")
end

"Baum → Julia-Objekt (Eingaben)."
function decode(node)
    t = node["t"]
    t in ("null", "skip") && return nothing
    t == "ref" && error("Verweis auf den Eingabespeicher ($(get(node, "k", "?"))) nicht aufgelöst; Fall mit read_ref_case laden")
    if t in ("num", "int", "lgl", "chr", "date")
        a = _dvec(node)
        nms = get(node, "names", nothing)
        cls = get(node, "class", nothing)
        if nms !== nothing || (cls !== nothing && cls != "factor")
            at = Dict{String,Any}()
            cls !== nothing && cls != "factor" && (at["class"] = String.(_aslist(cls)))
            return SimLev.RVector(a; names = nms === nothing ? nothing : String.(_aslist(nms)), attrs = at)
        end
        return length(a) == 1 ? a[1] : a
    elseif t == "df"
        nms = String.(_aslist(get(node, "names", nothing)))
        cols = AbstractVector[_dvec_or(c) for c in _aslist(get(node, "cols", nothing))]
        rn = get(node, "row_names", nothing)
        cls = get(node, "class", nothing)
        return SimLev.RFrame(nms, cols; rownames = rn === nothing ? nothing : String.(_aslist(rn)),
                             class = cls === nothing ? String[] : String.(_aslist(cls)),
                             nrow = Int(get(node, "nrow", isempty(cols) ? 0 : length(cols[1]))))
    elseif t == "mat"
        dim = Int.(_aslist(node["dim"]))
        vals = _vals(node)
        typ = get(node, "type", "double")
        a = typ in ("double", "integer") ? Float64[unhex(x) for x in vals] :
            typ == "logical" ? (any(isnothing, vals) ? Union{Missing,Bool}[x === nothing ? missing : x for x in vals] : Bool[x for x in vals]) :
            Any[x === nothing ? missing : x for x in vals]
        length(dim) == 2 || return reshape(a, dim...)
        m = reshape(a, dim[1], dim[2])
        dn = get(node, "dimnames", nothing)
        if dn !== nothing
            dn = dn isa AbstractVector ? dn : dn isa JObj ? collect(Any, dn.vals) : Any[dn]
            rn = length(dn) >= 1 && dn[1] !== nothing ? String.(_aslist(dn[1])) : nothing
            cn = length(dn) >= 2 && dn[2] !== nothing ? String.(_aslist(dn[2])) : nothing
            return SimLev.NamedMat(m; rownames = rn, colnames = cn)
        end
        return m
    elseif t == "list"
        vals = Any[decode(x) for x in _aslist(get(node, "v", nothing))]
        nms = get(node, "names", nothing)
        if nms !== nothing
            cls = get(node, "class", nothing)
            x = SimLev.RList(; class = cls === nothing ? String[] : String.(_aslist(cls)))
            for (k, v) in zip(String.(_aslist(nms)), vals)
                x[k] = v
            end
            return x
        end
        return vals
    end
    error("unbekannter Knotentyp $t")
end
_dvec_or(c) = c["t"] in ("num", "int", "lgl", "chr", "date") ? _dvec(c) : decode(c)

# ── Python/Julia-Objekt → Vergleich ──────────────────────────────────────────

struct _Missing end
const MISSING_EL = _Missing()

function _get(obj, name::String)
    obj === nothing && return MISSING_EL
    if obj isa SimLev.RFrame || obj isa SimLev.RList || obj isa AbstractDict
        return haskey(obj, name) ? obj[name] : MISSING_EL
    elseif obj isa SimLev.RVector
        return haskey(obj, name) ? obj[name] : MISSING_EL
    elseif obj isa NamedTuple
        return haskey(obj, Symbol(name)) ? getfield(obj, Symbol(name)) : MISSING_EL
    end
    s = Symbol(name)
    hasproperty(obj, s) && return getproperty(obj, s)
    return MISSING_EL
end

_names_of(x) = nothing
_names_of(x::SimLev.RVector) = x.names
_names_of(x::AbstractDict) = String.(collect(keys(x)))
_names_of(x::NamedTuple) = String.(collect(keys(x)))

function _flat(x)
    x isa SimLev.RFrame && return vcat([collect(c) for c in x.cols]...)
    x isa SimLev.NamedMat && return vec(x.data)
    x isa AbstractMatrix && return vec(x)
    x isa SimLev.RVector && return collect(x.values)
    x isa AbstractDict && return collect(values(x))
    x isa NamedTuple && return collect(values(x))
    x isa AbstractVector && return collect(x)
    x isa Tuple && return collect(x)
    return Any[x]
end

_num(x) = x === missing || x === nothing ? SimLev.NA : x isa Bool ? Float64(x) : x isa Date ? Float64(Dates.value(x - _EPOCH)) :
          x isa Number ? Float64(x) : nothing

function _numeq(r::Float64, p)
    p === nothing && return false
    if isnan(r)
        isnan(p) || return false
        _LAX_NA && return true
        return SimLev.isna_strict(r) == SimLev.isna_strict(p)
    end
    isnan(p) && return false
    if r == 0 && p == 0
        return !_STRICT_ZERO || signbit(r) == signbit(p)
    end
    return r == p
end

_hx(x::Float64) = isnan(x) ? (SimLev.isna_strict(x) ? "NA" : "NaN") : string(x)

"Vergleicht `py` (Julia-Objekt) mit dem R-Baum `ref`; hängt Abweichungen an `errs` an."
function compare!(errs, ref, py, path = "result"; maxerr = 40)
    length(errs) >= maxerr && return errs
    t = ref["t"]
    t == "skip" && return errs
    if py === MISSING_EL
        t == "null" && return errs
        push!(errs, "$path: fehlt in Julia"); return errs
    end
    if t == "null"
        (py === nothing || (applicable(length, py) && !(py isa AbstractString) && length(py) == 0)) && return errs
        push!(errs, "$path: R NULL, Julia $(typeof(py))"); return errs
    end
    if t in ("num", "int", "lgl", "chr", "date")
        if py === nothing
            v = get(ref, "v", nothing)
            v isa AbstractVector && isempty(v) && return errs
            push!(errs, "$path: Julia nothing"); return errs
        end
        rv = _dvec(ref)
        pv = _flat(py)
        if length(rv) != length(pv)
            push!(errs, "$path: Länge R $(length(rv)), Julia $(length(pv))"); return errs
        end
        bad = Int[]
        if t in ("num", "int", "date")
            for i in eachindex(rv)
                r = rv[i] === missing ? SimLev.NA : t == "date" ? Float64(Dates.value(rv[i] - _EPOCH)) : Float64(rv[i])
                _numeq(r, _num(pv[i])) || push!(bad, i)
            end
        else
            for i in eachindex(rv)
                a = rv[i]; b = pv[i]
                b isa AbstractFloat && isnan(b) && (b = missing)
                ok = (a === missing && b === missing) || (a !== missing && b !== missing && a == b)
                ok || push!(bad, i)
            end
        end
        if !isempty(bad)
            i = bad[1]
            _rp(x) = x isa Float64 ? _hx(x) : repr(x)
            push!(errs, "$path: $(length(bad))/$(length(rv)) abweichend, erste [$i]: R=$(_rp(rv[i])) Julia=$(_rp(pv[i]))")
        end
        nms = get(ref, "names", nothing)
        if nms !== nothing
            pn = _names_of(py)
            pn !== nothing && String.(_aslist(nms)) != pn && push!(errs, "$path: Namen R $(first(_aslist(nms), 6)), Julia $(first(pn, 6))")
        end
        return errs
    end
    if t == "df"
        nms = String.(_aslist(get(ref, "names", nothing)))
        cols = _aslist(get(ref, "cols", nothing))
        if py isa SimLev.RFrame && haskey(ref, "nrow") && SimLev.nrow(py) != Int(ref["nrow"])
            push!(errs, "$path: Zeilen R $(ref["nrow"]), Julia $(SimLev.nrow(py))"); return errs
        end
        for (nm, c) in zip(nms, cols)
            compare!(errs, c, _get(py, nm), "$path\$$nm"; maxerr)
        end
        return errs
    end
    if t == "mat"
        dim = Int.(_aslist(ref["dim"]))
        if py isa AbstractMatrix && length(dim) == 2 && size(py) != Tuple(dim)
            push!(errs, "$path: Dimension R $dim, Julia $(size(py))"); return errs
        end
        typ = get(ref, "type", "double")
        kind = typ in ("double", "integer") ? "num" : typ == "logical" ? "lgl" : "chr"
        compare!(errs, Dict("t" => kind, "v" => get(ref, "v", nothing)), py isa SimLev.NamedMat ? py.data : py, path; maxerr)
        dn = get(ref, "dimnames", nothing)
        if dn !== nothing && py isa SimLev.NamedMat
            dn = dn isa AbstractVector ? dn : dn isa JObj ? collect(Any, dn.vals) : Any[dn]
            length(dn) >= 2 && dn[2] !== nothing && py.colnames !== nothing && String.(_aslist(dn[2])) != py.colnames &&
                push!(errs, "$path: Spaltennamen R $(first(_aslist(dn[2]), 6)), Julia $(first(py.colnames, 6))")
            length(dn) >= 1 && dn[1] !== nothing && py.rownames !== nothing && String.(_aslist(dn[1])) != py.rownames &&
                push!(errs, "$path: Zeilennamen abweichend")
        end
        return errs
    end
    if t == "list"
        vals = _aslist(get(ref, "v", nothing))
        nms = get(ref, "names", nothing)
        if nms !== nothing
            for (i, (nm, v)) in enumerate(zip(String.(_aslist(nms)), vals))
                if nm == ""
                    el = py isa AbstractVector && i <= length(py) ? py[i] : MISSING_EL
                    compare!(errs, v, el, "$path[[$i]]"; maxerr)
                else
                    compare!(errs, v, _get(py, nm), "$path\$$nm"; maxerr)
                end
            end
            return errs
        end
        pl = py isa AbstractDict ? collect(values(py)) : py isa Tuple ? collect(py) : py
        if !(pl isa AbstractVector)
            push!(errs, "$path: R Liste, Julia $(typeof(py))"); return errs
        end
        length(pl) != length(vals) && (push!(errs, "$path: Listenlänge R $(length(vals)), Julia $(length(pl))"); return errs)
        for (i, v) in enumerate(vals)
            compare!(errs, v, pl[i], "$path[[$i]]"; maxerr)
        end
        return errs
    end
    push!(errs, "$path: unbekannter Knotentyp $t")
    errs
end

# ── Ausführen ────────────────────────────────────────────────────────────────

struct _WarnCollector <: AbstractLogger
    msgs::Vector{String}
end
Logging.min_enabled_level(::_WarnCollector) = Logging.Warn
Logging.shouldlog(::_WarnCollector, args...) = true
Logging.catch_exceptions(::_WarnCollector) = false
function Logging.handle_message(l::_WarnCollector, level, message, args...; kw...)
    level >= Logging.Warn && level < Logging.Error && (string(message) in l.msgs || push!(l.msgs, string(message)))
    nothing
end

_errmsg(e) = e isa ErrorException ? e.msg : hasproperty(e, :msg) ? string(getproperty(e, :msg)) : sprint(showerror, e)

function _difflines(a, b; n = 30)
    la = split(a, '\n'); lb = split(b, '\n')
    out = String[]
    for i in 1:max(length(la), length(lb))
        x = i <= length(la) ? la[i] : "<fehlt>"; y = i <= length(lb) ? lb[i] : "<fehlt>"
        x == y && continue
        push!(out, "  R:  " * x); push!(out, "  Jl: " * y)
        length(out) >= n && break
    end
    join(out, "\n")
end

"Führt einen Fall aus; Rückgabe: Liste der Abweichungen (leer = bitgleich)."
function run_ref_case(case; kw...)
    # feste Uhrzeit des Falls (Feld sys_time) für SimLev.RBase.sys_time; setzt danach zurück
    st = get(case, "sys_time", nothing)
    st === nothing && return _run_ref_case(case; kw...)
    SimLev.REnv.with_r_sys_time(st isa AbstractString ? String(st) : string(Float64(st))) do
        _run_ref_case(case; kw...)
    end
end

function _run_ref_case(case; check_print = true, check_output = true, check_warnings = true)
    haskey(case, "jl") || return ["kein Julia-Code (Feld jl) im Fall"]
    m = Module(:RefCase)
    Core.eval(m, :(using SimLev, Dates))
    Core.eval(m, :(const SL = SimLev))
    inp = get(case, "inputs", nothing)
    if inp !== nothing
        for (k, v) in pairs(inp)
            Core.eval(m, :($(Symbol(k)) = $(QuoteNode(decode(v)))))
        end
    end
    logger = _WarnCollector(String[])
    err = nothing
    bt = nothing
    out = ""
    mktemp() do path, io
        try
            with_logger(logger) do
                redirect_stdout(io) do
                    Base.include_string(m, case["jl"], "jl:" * string(case["id"]))
                end
            end
        catch e
            err = e isa LoadError ? e.error : e
            bt = catch_backtrace()
        end
        flush(io)
        out = read(path, String)
    end
    errs = String[]
    if get(case, "error", nothing) !== nothing
        err === nothing && return ["R bricht ab ($(case["error"])), Julia nicht"]
        _errmsg(err) == case["error"] || push!(errs, "Fehlermeldung abweichend:\n  R:  $(case["error"])\n  Jl: $(_errmsg(err))")
        return errs
    end
    err !== nothing && return ["Julia-Fehler: " * sprint(showerror, err) * "\n" * sprint(Base.show_backtrace, bt)[1:min(end, 3000)]]
    Base.invokelatest(isdefined, m, :result) || return ["Julia-Code setzt `result` nicht"]
    res = Base.invokelatest(getglobal, m, :result)
    compare!(errs, case["result"], res)
    if check_output && get(case, "output", "") != ""
        got = endswith(out, "\n") ? chop(out) : out
        got == case["output"] || push!(errs, "Konsolenausgabe abweichend\n" * _difflines(case["output"], got))
    end
    if check_print && get(case, "print", nothing) !== nothing
        got = try
            sprint(show, MIME"text/plain"(), res)
        catch e
            push!(errs, "print-Ausgabe: Julia-Fehler " * sprint(showerror, e)); return errs
        end
        endswith(got, "\n") && (got = String(chop(got)))
        got == case["print"] || push!(errs, "print-Ausgabe abweichend\n" * _difflines(case["print"], got))
    end
    if check_warnings
        rw = String.(_aslist(get(case, "warnings", nothing)))
        rw == logger.msgs || push!(errs, "Warnungen abweichend:\n  R:  $(rw)\n  Jl: $(logger.msgs)")
    end
    errs
end
