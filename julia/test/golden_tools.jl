# Hilfsfunktionen für den Golden-Master-Abgleich mit dem R-Paket:
# minimaler JSON-Parser (ordnungserhaltend), gzip-Lesen über zlib, Laden eines
# Falls und bitgenauer Vergleich (inklusive NA ≠ NaN und Textausgabe).

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
function read_gz(path::AbstractString)
    fh = ccall((:gzopen, Zlib_jll.libz), Ptr{Cvoid}, (Cstring, Cstring), path, "rb")
    fh == C_NULL && error("kann $path nicht öffnen")
    io = IOBuffer(); buf = Vector{UInt8}(undef, 1 << 16)
    while true
        n = ccall((:gzread, Zlib_jll.libz), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cuint), fh, buf, length(buf))
        n < 0 && error("gzread-Fehler in $path")
        n == 0 && break
        write(io, view(buf, 1:n))
    end
    ccall((:gzclose, Zlib_jll.libz), Cint, (Ptr{Cvoid},), fh)
    return String(take!(io))
end
read_case(path) = parse_json(endswith(path, ".gz") ? read_gz(path) : read(path, String))

# ── Laden ───────────────────────────────────────────────────────────────────
unhex(v) = v === nothing || v == "NA" ? SimLev.NA : v == "NaN" ? NaN : v isa Number ? Float64(v) : parse(Float64, v)
_vec(x) = x isa AbstractVector ? x : [x]
_plain(x) = x isa JObj ? [k => _plain(v) for (k, v) in pairs(x)] : x isa AbstractVector ? [_plain(v) for v in x] : x

function load_case(path)
    d = read_case(path)
    cols = Pair{Symbol,Any}[]
    for nm in _vec(d["data"]["order"])
        c = d["data"]["cols"][nm]
        vals = _vec(c["values"])
        v = c["type"] == "date" ? Date[SimLev.from_days(Int(x)) for x in vals] :
            c["type"] == "logical" ? (any(x -> x === nothing, vals) ? Union{Missing,Bool}[x === nothing ? missing : x for x in vals] :
                                      Bool[x for x in vals]) :
            Float64[unhex(x) for x in vals]
        push!(cols, Symbol(nm) => v)
    end
    data = NamedTuple(cols)
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

"Baustein aus dem Fall (`{\"block\": <Konstruktor>, \"args\": {...}}`, Etappe 6.3); angelegt erst in `run_case`."
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

# ── Vergleich ───────────────────────────────────────────────────────────────
_tok(x::Float64) = isnan(x) ? (SimLev.isna_strict(x) ? "NA" : "NaN") : string(reinterpret(UInt64, x); base = 16)
_reftok(v) = (x = unhex(v); _tok(x))

function cmp_vec!(errs, name, ref, got; strict_na::Bool = true)
    r = _vec(ref)
    g = got isa AbstractVector ? collect(got) : [got]
    if length(r) != length(g)
        push!(errs, "$name: Länge $(length(r)) vs $(length(g))"); return
    end
    bad = Int[]
    for i in eachindex(r)
        a = _reftok(r[i]); b = _tok(Float64(g[i]))
        if a != b
            (!strict_na && (a in ("NA", "NaN")) && (b in ("NA", "NaN"))) && continue
            push!(bad, i)
        end
    end
    if !isempty(bad)
        i = bad[1]
        push!(errs, "$name: $(length(bad)) Abweichungen, erste bei $i: R=$(r[i]) Julia=$(Float64(g[i])) [$(_tok(Float64(g[i])))]")
    end
end

"Rechnet einen Golden-Fall in Julia nach; gibt eine Liste von Abweichungen zurück."
function run_case(path; strict_na::Bool = true, verbose::Bool = false)
    d, data, strategy, args = load_case(path)
    buf = IOBuffer()
    res = try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            redirect_stderr(devnull) do
                SimLev.simulation(data, strategy; io = buf, (p.first => _mkblock(p.second) for p in args)...)
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
