# Referenzfälle aus R (Katalog nach Zweck): Lesen der Dateien und Vergleich mit Julia.
# Bis 1.4.0 julia/test/golden_tools.jl (Engine-Fälle) und julia/test/reftree.jl (Modulfälle), hier zusammengeführt.
#
# Eine Datei tests/<gruppe>/faelle/<bereich>.jsonl.gz (Gruppen gleichlauf, fehler, ausgabe; erzeugt mit
# tests/gleichlauf/erzeugen/<bereich>.R, Format in tests/gleichlauf/erzeugen/ref_tools.R) hat in Zeile 1 den
# Eingabespeicher, danach je Zeile einen Test: ein Szenario (Fall) oder eine Tabelle (Feld tabelle, je Zeile ein eigener
# Aufruf in einem frischen Modul, Abweichungen nennen die Zeile). Formate:
# - Modulformat (Feld module): Eingaben, R-, Python- und Julia-Code (jl), R-Ergebnis als Baum. Die Eingaben
#   werden in Julia-Objekte übersetzt (siehe src/r/types.jl), der Julia-Code läuft in einem frischen Modul (mit
#   SimLev und Dates) und setzt result. Verglichen werden Ergebnis (bitgenau, NA ≠ NaN, Vorzeichen der Null),
#   Konsolenausgabe, Druckausgabe (show mit MIME text/plain), Warnungen (@warn-Meldungen) und Fehlermeldungen.
#   Lockerungen: SIMLEV_LAX_NA=1 (NA = NaN), SIMLEV_STRICT_ZERO=0 (-0 = +0).
# - Engine-Format (ohne module; Bereich engine): Daten, Strategie, Bausteine von simulation() und die exakten
#   R-Ergebnisse (run_engine; inklusive NA ≠ NaN und Textausgabe).
#
# Dazu ein minimaler JSON-Parser (ordnungserhaltend) und gzip-Lesen über zlib.

using Dates
import Zlib_jll

# ── JSON ────────────────────────────────────────────────────────────────────
struct JObj
    keys::Vector{String}
    vals::Vector{Any}
end
Base.getindex(o::JObj, k::AbstractString) = (i = findfirst(==(k), o.keys); i === nothing ? throw(KeyError(k)) : o.vals[i])
Base.haskey(o::JObj, k::AbstractString) = k in o.keys
Base.get(o::JObj, k::AbstractString, d) = haskey(o, k) ? o[k] : d
Base.pairs(o::JObj) = (o.keys[i] => o.vals[i] for i in eachindex(o.keys))

mutable struct _P
    s::String
    i::Int
end
_peek(p) = p.s[p.i]
function _ws(p)
    while p.i <= ncodeunits(p.s) && p.s[p.i] in (' ', '\n', '\r', '\t')
        p.i = nextind(p.s, p.i)
    end
end
function _val(p)
    _ws(p)
    c = _peek(p)
    if c == '{'
        p.i += 1; ks = String[]; vs = Any[]
        _ws(p)
        if _peek(p) == '}'
            p.i += 1; return JObj(ks, vs)
        end
        while true
            _ws(p); k = _str(p); _ws(p)
            @assert _peek(p) == ':'; p.i += 1
            push!(ks, k); push!(vs, _val(p)); _ws(p)
            c = _peek(p); p.i += 1
            c == '}' && return JObj(ks, vs)
        end
    elseif c == '['
        p.i += 1; out = Any[]
        _ws(p)
        if _peek(p) == ']'
            p.i += 1; return out
        end
        while true
            push!(out, _val(p)); _ws(p)
            c = _peek(p); p.i += 1
            c == ']' && return out
        end
    elseif c == '"'
        return _str(p)
    elseif startswith(SubString(p.s, p.i), "true")
        p.i += 4; return true
    elseif startswith(SubString(p.s, p.i), "false")
        p.i += 5; return false
    elseif startswith(SubString(p.s, p.i), "null")
        p.i += 4; return nothing
    else
        j = p.i
        while p.i <= ncodeunits(p.s) && (p.s[p.i] in "+-0123456789.eE")
            p.i += 1
        end
        t = p.s[j:p.i-1]
        return occursin(r"[.eE]", t) ? parse(Float64, t) : parse(Int, t)
    end
end
function _str(p)
    @assert _peek(p) == '"'
    p.i += 1
    io = IOBuffer()
    while true
        c = p.s[p.i]
        if c == '"'
            p.i += 1; return String(take!(io))
        elseif c == '\\'
            e = p.s[p.i+1]
            if e == 'u'
                cp = parse(UInt16, p.s[p.i+2:p.i+5]; base = 16)
                p.i += 6
                if 0xd800 <= cp <= 0xdbff && p.s[p.i] == '\\'
                    lo = parse(UInt16, p.s[p.i+2:p.i+5]; base = 16); p.i += 6
                    write(io, Char(0x10000 + ((UInt32(cp) - 0xd800) << 10) + (UInt32(lo) - 0xdc00)))
                else
                    write(io, Char(cp))
                end
                continue
            end
            write(io, e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e == 'b' ? '\b' : e == 'f' ? '\f' : e)
            p.i += 2
        else
            write(io, c); p.i = nextind(p.s, p.i)
        end
    end
end
parse_json(s::AbstractString) = _val(_P(String(s), 1))

# ── gzip ────────────────────────────────────────────────────────────────────
"Ruft `f(zeile)` für jede nicht leere Zeile der gzip-Datei `path` auf, eine nach der anderen (seit 1.6.3; bis 1.6.2
lag die ganze Datei als Text im Speicher)."
function gz_zeilen(f, path::AbstractString)
    fh = ccall((:gzopen, Zlib_jll.libz), Ptr{Cvoid}, (Cstring, Cstring), path, "rb")
    fh == C_NULL && error("kann $path nicht öffnen")
    acc = UInt8[]; buf = Vector{UInt8}(undef, 1 << 16)
    try
        while true
            n = ccall((:gzread, Zlib_jll.libz), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cuint), fh, buf, length(buf))
            n < 0 && error("gzread-Fehler in $path")
            n == 0 && break
            s = 1; i = length(acc) + 1          # vor i steht kein Zeilenende mehr
            append!(acc, view(buf, 1:n))
            while (j = findnext(==(0x0a), acc, i)) !== nothing
                j > s && f(String(acc[s:j-1]))
                s = i = j + 1
            end
            s > 1 && deleteat!(acc, 1:s-1)
        end
        isempty(acc) || f(String(acc))      # letzte Zeile ohne Zeilenende
    finally
        ccall((:gzclose, Zlib_jll.libz), Cint, (Ptr{Cvoid},), fh)
    end
    nothing
end

# ── Laden ───────────────────────────────────────────────────────────────────
unhex(v) = v === nothing || v == "NA" ? SimLev.NA : v == "NaN" ? NaN : v isa Number ? Float64(v) : parse(Float64, v)
_vec(x) = x isa AbstractVector ? x : [x]
_plain(x) = x isa JObj ? [k => _plain(v) for (k, v) in pairs(x)] : x isa AbstractVector ? [_plain(v) for v in x] : x

"Engine-Fall (Engine-Format, geparst) → (Fall, Daten, Strategie, Argumente)."
function load_case(d)
    nms = String[]; cols = AbstractVector[]
    for nm in _vec(d["data"]["order"])
        c = d["data"]["cols"][nm]
        vals = _vec(c["values"])
        v = c["type"] == "date" ? Date[SimLev.from_days(Int(x)) for x in vals] :
            c["type"] == "logical" ? (any(x -> x === nothing, vals) ? Union{Missing,Bool}[x === nothing ? missing : x for x in vals] :
                                      Bool[x for x in vals]) :
            Float64[unhex(x) for x in vals]
        push!(nms, nm); push!(cols, v)
    end
    # Daten als RFrame (seit 1.6.3; bis 1.6.2 als NamedTuple: ein neuer Typ je Spaltensatz, für den simulation() und die
    # Hülle hier je Fall neu übersetzt wurden). Beide gehen in simulation() durch dieselbe Umwandlung (_to_frame); nur
    # doppelte Namen oder ungleich lange Spalten bleiben ein NamedTuple wie bisher (gleiche Meldung).
    data = if !isempty(cols) && allunique(nms) && allequal(length.(cols))
        SimLev.RFrame(nms, cols, length(cols[1]), nothing, Dict{String,Any}(), String[])
    else
        NamedTuple(Pair{Symbol,Any}[Symbol(nm) => v for (nm, v) in zip(nms, cols)])
    end
    items = Pair{String,Any}[]
    legacy = true
    for (nm, a) in pairs(d["strategy"])
        f = Pair{String,Any}[]
        for (k, v) in pairs(a)
            v = v isa JObj && haskey(v, "hex") ? unhex(v["hex"]) : v
            push!(f, k => v)
        end
        any(p -> p.first == "tax_regime", f) && (legacy = false)
        push!(items, nm => f)
    end
    strategy = if legacy
        items
    else
        SimLev.create_strategy([nm => SimLev._config_from_mapping(Dict(f)) for (nm, f) in items]...)
    end
    args = Pair{Symbol,Any}[Symbol(k) => _arg(v) for (k, v) in pairs(d["args"])]
    return d, data, strategy, args
end

"Baustein aus dem Fall (`{\"block\": <Konstruktor>, \"args\": {...}}`); angelegt erst in `run_case`."
struct _BlockSpec
    ctor::Symbol
    args::Vector{Pair{Symbol,Any}}
end

function _arg(v)
    if v isa JObj && haskey(v, "block") && haskey(v, "args")
        return _BlockSpec(Symbol(v["block"]), Pair{Symbol,Any}[Symbol(k) => _arg(x) for (k, x) in pairs(v["args"])])
    end
    v = _plain(v)
    v isa AbstractVector && !isempty(v) && all(x -> x isa Number, v) && (v = [x for x in v])
    return v
end

_mkblock(v) = v isa _BlockSpec ? getfield(SimLev, v.ctor)(; (p.first => _mkblock(p.second) for p in v.args)...) : v

"Schlüsselwörter `(io = io, <args>...)` von simulation() als NamedTuple in einem Schritt (seit 1.6.3; bis 1.6.2 Paar für
Paar zusammengefügt, je Zwischentyp eine Übersetzung von merge); doppelte Namen wie bisher (der letzte gilt)."
function _kwargs(args::Vector{Pair{Symbol,Any}}, io)
    ks = first.(args)
    (allunique(ks) && !(:io in ks)) || return (; io = io, (p.first => _mkblock(p.second) for p in args)...)
    NamedTuple{(:io, ks...)}((io, (_mkblock(p.second) for p in args)...))
end

# ── Vergleich ───────────────────────────────────────────────────────────────
_tok(x::Float64) = isnan(x) ? (SimLev.isna_strict(x) ? "NA" : "NaN") : string(reinterpret(UInt64, x); base = 16)
# gleich wie `_tok(a) == _tok(b)` (bzw. ohne strict_na: NA und NaN gleich), ohne Text je Wert (seit 1.6.3)
_tokgleich(a::Float64, b::Float64, strict_na::Bool) =
    isnan(a) ? isnan(b) && (!strict_na || SimLev.isna_strict(a) == SimLev.isna_strict(b)) :
               !isnan(b) && reinterpret(UInt64, a) == reinterpret(UInt64, b)

function cmp_vec!(errs, name, ref, got; strict_na::Bool = true)
    r = _vec(ref)
    g = got isa AbstractVector ? collect(got) : [got]
    if length(r) != length(g)
        push!(errs, "$name: Länge $(length(r)) vs $(length(g))"); return
    end
    bad = Int[]
    for i in eachindex(r)
        _tokgleich(unhex(r[i]), Float64(g[i]), strict_na) || push!(bad, i)
    end
    if !isempty(bad)
        i = bad[1]
        push!(errs, "$name: $(length(bad)) Abweichungen, erste bei $i: R=$(r[i]) Julia=$(Float64(g[i])) [$(_tok(Float64(g[i])))]")
    end
end

"Rechnet einen Engine-Fall (Engine-Format, geparst) in Julia nach; Liste der Abweichungen (leer = bitgleich)."
function run_engine(d; strict_na::Bool = true, verbose::Bool = false)
    d, data, strategy, args = load_case(d)
    buf = IOBuffer()
    # Die Blöcke unten haben feste Typen (ein Any-Feld statt der Fallwerte), sonst wäre jede Typkombination eine neue
    # Übersetzung von with_logger/redirect_stderr (seit 1.6.3)
    a = Any[data, strategy, args]
    res = try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            redirect_stderr(devnull) do
                Core.kwcall(_kwargs(a[3], buf), SimLev.simulation, a[1], a[2])   # = simulation(…; io = buf, args...)
            end
        end
    catch e
        haskey(d, "error") && return String[]
        return ["Julia-Fehler: " * sprint(showerror, e) * (verbose ? "\n" * sprint(Base.show_backtrace, catch_backtrace()) : "")]
    end
    haskey(d, "error") && return ["R-Fehler ($(d["error"])), Julia lief durch"]
    r = d["result"]
    errs = String[]
    cmp_vec!(errs, "worth", r["worth"], res.worth; strict_na)
    cmp_vec!(errs, "drawdowns", r["drawdowns"], res.drawdowns; strict_na)
    Bool.(_vec(r["filled"])) == collect(res.filled) || push!(errs, "filled unterschiedlich")
    cmp_vec!(errs, "cagr", r["cagr"], res.cagr; strict_na)
    cmp_vec!(errs, "ttwror", r["ttwror"], res.ttwror; strict_na)
    for (k, v) in pairs(r["statistics"])
        cmp_vec!(errs, "stat." * k, v, res.statistics[k]; strict_na)
    end
    for (k, v) in pairs(r["tax_report"])
        got = get(res.tax_report, k, nothing)
        got isa SimLev.RFrame && continue                      # tariff_years: nicht im Golden-Format
        got isa SimLev.RList && (got = Float64[Float64(x) for x in values(got)])   # next_year: Werte in R-Reihenfolge
        got === nothing && (push!(errs, "tax.$k fehlt"); continue)
        cmp_vec!(errs, "tax." * k, v, got; strict_na)
    end
    for (k, v) in pairs(r["buys"]); cmp_vec!(errs, "buys." * k, v, res.buys[k]; strict_na); end
    for (k, v) in pairs(r["sells"]); cmp_vec!(errs, "sells." * k, v, res.sells[k]; strict_na); end
    for (a, fields) in pairs(r["report"]), (f, v) in pairs(fields)
        cmp_vec!(errs, "report.$a.$f", v, res.report[a][f]; strict_na)
    end
    if haskey(d, "stdout") && d["stdout"] !== nothing
        got = String(take!(buf))
        endswith(got, "\n") && (got = got[1:prevind(got, end)])
        if got != d["stdout"]
            push!(errs, "details-Ausgabe unterscheidet sich")
            verbose && push!(errs, _first_diff(d["stdout"], got))
        end
    end
    if SimLev.format_result(res) != r["print"]
        push!(errs, "print()-Ausgabe unterscheidet sich")
        verbose && push!(errs, _first_diff(r["print"], SimLev.format_result(res)))
    end
    return errs
end

function _first_diff(a::String, b::String)
    la = split(a, '\n'); lb = split(b, '\n')
    for i in 1:max(length(la), length(lb))
        x = i <= length(la) ? la[i] : "<fehlt>"
        y = i <= length(lb) ? lb[i] : "<fehlt>"
        x != y && return "  Zeile $i:\n    R:     $x\n    Julia: $y"
    end
    return "  (nur Zeilenende verschieden)"
end

using Logging

# Die Referenzen entstanden mit R unter LC_ALL=C.UTF-8 (ICU-Kollation "root"); für den
# Vergleich dieselbe Kollation erzwingen, unabhängig vom Locale des Rechners.
SimLev.REnv.set_collate_default!("icu:root") && SimLev.RStats.collate_reset()
const _LAX_NA = SimLev.REnv.lax_na()
const _STRICT_ZERO = SimLev.REnv.strict_zero()

_aslist(v) = v === nothing ? Any[] : v isa AbstractVector ? v : Any[v]
_vals(node) = (v = get(node, "v", nothing); v === nothing ? Any[nothing] : v isa AbstractVector ? v : Any[v])

const _EPOCH = Date(1970, 1, 1)

# ── Laden (Katalog tests/<gruppe>/faelle) ────────────────────────────────────────
_isref(v) = v isa JObj && get(v, "t", nothing) == "ref"

const GRUPPEN = ("gleichlauf", "fehler", "ausgabe")

"Ordner der Dateien einer Gruppe: tests/<gruppe>/faelle bzw. \$SIMLEV_FAELLE_DIR/<gruppe>."
function faelle_dir(gruppe)
    d = get(ENV, "SIMLEV_FAELLE_DIR", "")
    isempty(d) ? normpath(joinpath(@__DIR__, "..", gruppe, "faelle")) : joinpath(d, gruppe)
end

"Bereichsdateien `<bereich>.jsonl.gz` in `dir` (sortiert)."
bereiche(dir) = isdir(dir) ? [joinpath(dir, f) for f in sort(readdir(dir)) if endswith(f, ".jsonl.gz")] : String[]

"Eingabespeicher (aus Zeile 1) einer Bereichsdatei, dann `f(store, fall)` für jeden Fall (je Zeile einer), einer nach
dem anderen: Es liegt immer nur ein Fall im Speicher (seit 1.6.3). Liefert den Eingabespeicher."
function je_fall(f, path)
    store = nothing
    gz_zeilen(path) do z
        if store === nothing
            store = parse_json(z)["inputs"]
        else
            f(store, parse_json(z))
        end
    end
    store === nothing && error("$path: leer (ohne Kopfzeile)")
    store
end

"Kopf (Eingabespeicher) und alle Fälle einer Bereichsdatei (Zeile 1 Kopf, dann je Zeile ein Fall)."
function lies_bereich(path)
    cases = Any[]
    store = je_fall((_, c) -> push!(cases, c), path)
    return store, cases
end

"`<modul>/<id>`; Engine-Format: `cases/<id>` (f…, r…) bzw. `extra/<id>` (x…, y…)."
kennung(c) = haskey(c, "module") ? string(c["module"], "/", c["id"]) :
             string(first(c["id"]) in ('f', 'r') ? "cases/" : "extra/", c["id"])

"Ersetzt Verweise in `case[\"inputs\"]` durch die Bäume aus dem Eingabespeicher `store`."
function resolve_ref_inputs!(case, store)
    inp = get(case, "inputs", nothing)
    (inp isa JObj && any(_isref, inp.vals)) || return case
    for i in eachindex(inp.vals)
        v = inp.vals[i]
        _isref(v) || continue
        haskey(store, v["k"]) || error("Eingabe $(inp.keys[i]) (Schlüssel $(v["k"])) fehlt im Eingabespeicher")
        inp.vals[i] = store[v["k"]]
    end
    case
end

const _INDEX = Dict{String,Any}()

"Zeilen einer Tabelle als eigene Fälle (JObj): Kennung <id>/<z>, gemeinsame und eigene Eingaben aufgelöst."
function zeilen(case, store)
    resolve_ref_inputs!(case, store)
    gemein = get(case, "inputs", nothing)
    out = JObj[]
    for row in case["tabelle"]
        resolve_ref_inputs!(row, store)
        eigen = get(row, "inputs", nothing)
        ks = String[]; vs = Any[]
        for src in (gemein, eigen)
            src isa JObj || continue
            for (k, v) in pairs(src)
                i = findfirst(==(k), ks)
                i === nothing ? (push!(ks, k); push!(vs, v)) : (vs[i] = v)
            end
        end
        keep = [i for i in eachindex(row.keys) if row.keys[i] != "inputs"]
        push!(out, JObj(vcat(row.keys[keep], ["id", "inputs"]),
                        vcat(row.vals[keep], [string(case["id"], "/", row["z"]), JObj(ks, vs)])))
    end
    out
end

"Fall bzw. Tabellenzeile `<modul>/<id>` aus dem Katalog (alle Gruppen), Eingaben aufgelöst (für die Grafiktests);
Zeilen der Tabellen tragen die bisherige Fallkennung als Zeilennamen."
function fall(key)
    if isempty(_INDEX)
        for g in GRUPPEN, p in bereiche(faelle_dir(g))
            store, cases = lies_bereich(p)
            for c in cases
                if haskey(c, "tabelle")
                    for rc in zeilen(c, store)
                        get!(_INDEX, string(c["module"], "/", rc["z"]), (rc, nothing))
                    end
                end
                tl = get(c, "teile", nothing)
                for t in (tl === nothing ? String[] : tl isa AbstractString ? [tl] : tl)
                    d = JObj(vcat(c.keys, "_teil"), vcat(c.vals, Any[t]))
                    get!(_INDEX, string(c["module"], "/", t), (d, store))
                end
                get!(_INDEX, kennung(c), (c, store))
            end
        end
    end
    c, store = _INDEX[key]
    store === nothing ? c : resolve_ref_inputs!(c, store)
end

"Einen Fall in Julia nachrechnen (Modul- oder Engine-Format); Liste der Abweichungen (leer = bitgleich)."
function pruefe_fall(case, store; strict_na = Sys.islinux())
    haskey(case, "module") || return run_engine(case; strict_na)
    haskey(case, "tabelle") && return pruefe_tabelle(case, store)
    errs = try
        run_ref_case(resolve_ref_inputs!(case, store))
    catch e
        ["Werkzeugfehler: " * sprint(showerror, e)]
    end
    errs
end

# Jede Zeile läuft wie ein einzelner Fall in einem frischen Modul. Ein gemeinsames Modul je Tabelle war gleich
# schnell (Suite 406 s gegen 404 s; die Zeit geht in das Übersetzen der Aufrufe) und wurde deshalb nicht übernommen.
"Tabelle (Feld tabelle): jede Zeile ein eigener Aufruf mit den gemeinsamen und eigenen Eingaben; Abweichungen nennen die Zeile."
function pruefe_tabelle(case, store)
    errs = String[]
    for rc in zeilen(case, store)
        e = try
            run_ref_case(rc)
        catch ex
            ["Werkzeugfehler: " * sprint(showerror, ex)]
        end
        append!(errs, ["Zeile $(rc["z"]): " * x for x in e])
    end
    errs
end

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

function _get(@nospecialize(obj), name::String)
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
_names_of(x::AbstractVector{<:Pair}) = String[string(p.first) for p in x]   # benannter Vektor als Paare ("A" => "wA")

function _flat(@nospecialize(x))
    x isa SimLev.RFrame && return vcat([collect(c) for c in x.cols]...)
    x isa SimLev.NamedMat && return vec(x.data)
    x isa AbstractMatrix && return vec(x)
    x isa SimLev.RVector && return collect(x.values)
    x isa AbstractDict && return collect(values(x))
    x isa NamedTuple && return collect(values(x))
    x isa AbstractVector{<:Pair} && return Any[p.second for p in x]
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

# compare! und seine Helfer übersetzen `py` nicht je Typ (@nospecialize): Jedes Szenario liefert einen eigenen Typ
# (etwa eine NamedTuple seiner Teile); je Typ neu übersetzt kostete das rund 50 s der Julia-Suite. Die Schleifen über
# die Elemente stehen hinter einer Funktionsgrenze (_abweichend_num, _abweichend_sonst) und werden je Vektortyp übersetzt.
"Vergleicht `py` (Julia-Objekt) mit dem R-Baum `ref`; hängt Abweichungen an `errs` an."
function compare!(errs, ref, @nospecialize(py), path = "result"; maxerr = 40)
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
        bad = t in ("num", "int", "date") ? _abweichend_num(t == "date", rv, pv) : _abweichend_sonst(rv, pv)
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

function _abweichend_num(datum::Bool, rv, pv)
    bad = Int[]
    for i in eachindex(rv)
        r = rv[i] === missing ? SimLev.NA : datum ? Float64(Dates.value(rv[i] - _EPOCH)) : Float64(rv[i])
        _numeq(r, _num(pv[i])) || push!(bad, i)
    end
    bad
end

function _abweichend_sonst(rv, pv)
    bad = Int[]
    for i in eachindex(rv)
        a = rv[i]; b = pv[i]
        b isa AbstractFloat && isnan(b) && (b = missing)
        ok = (a === missing && b === missing) || (a !== missing && b !== missing && a == b)
        ok || push!(bad, i)
    end
    bad
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
    # Das Feld sys_time (feste Uhr für gosolnp) wird seit 1.0.0 nicht mehr ausgewertet;
    # nur die ausgesetzten Fälle des Moduls rugarch haben es.
    return _run_ref_case(case; kw...)
end

function _neues_modul()
    m = Module(:RefCase)
    Core.eval(m, :(using SimLev, Dates))
    Core.eval(m, :(const SL = SimLev))
    m
end

function _run_ref_case(case; check_print = true, check_output = true, check_warnings = true)
    get(case, "nur", "") == "py" && return String[]   # Fall nur für Python (seit 1.6.1)
    haskey(case, "jl") || return ["kein Julia-Code (Feld jl) im Fall"]
    m = _neues_modul()
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
