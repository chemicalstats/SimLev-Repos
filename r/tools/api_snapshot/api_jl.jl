# Schnittstellen-Auszug der Julia-Fassung (Etappe 3, tools/api_snapshot).
#
# Liest alle Exporte von SimLev (`names(SimLev)`) und die Methoden der
# Ergebnisklassen für `show` (R print), `r_summary` und `r_plot`. Nach
# julia/DEVELOPING.md (Abschnitt „Datenstrukturen“) registrieren die Module
# diese über `register_print!`, `register_summary!` und `register_plot!`
# (Tabellen `SimLev._PRINTERS`, `_SUMMARIES`, `_PLOTS`, Schlüssel = R-Klasse);
# `show(io, MIME"text/plain"(), x)` bzw. `r_summary`/`r_plot` verteilen danach.
#
# Je Funktion: positionelle Argumente (`Base.method_argnames`) und
# Schlüsselwörter (`Base.kwarg_decl`). Standardwerte liefert die Reflexion
# nicht; sie werden aus dem Quelltext der Definition (Datei und Zeile der
# Methode, `Meta.parseall`) gelesen. Gelingt das nicht, stehen nur die Namen
# da und `defaults_known = false` mit Vermerk. Hat eine Funktion nur die
# allgemeine Signatur `(args...; kw...)`, kommen Namen und Standardwerte aus
# der Signaturzeile des Docstrings (`args_source = "docstring"`).
#
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 julia --project=julia tools/api_snapshot/api_jl.jl [ausgabe.json]
# Voreinstellung der Ausgabe: tools/api_snapshot/out/api_jl.json
# Nur Standardbibliothek.

using SimLev
using Dates

const ROOT = pwd()
isfile(joinpath(ROOT, "julia", "src", "SimLev.jl")) || error("Bitte aus der Repo-Wurzel aufrufen.")
const OUT = isempty(ARGS) ? joinpath(ROOT, "tools", "api_snapshot", "out", "api_jl.json") : ARGS[1]
mkpath(dirname(OUT))

# ── JSON (geordnet: Vector{Pair}) ───────────────────────────────────────────
jesc(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\t" => "\\t", "\r" => "\\r")
function tojson(io, x, ind = 0)
    pad = " "^ind
    if x === nothing
        print(io, "null")
    elseif x isa Bool
        print(io, x ? "true" : "false")
    elseif x isa Integer
        print(io, x)
    elseif x isa AbstractString || x isa Symbol
        print(io, "\"", jesc(string(x)), "\"")
    elseif x isa AbstractVector{<:Pair}
        isempty(x) && return print(io, "{}")
        println(io, "{")
        for (i, (k, v)) in enumerate(x)
            print(io, pad, " \"", jesc(string(k)), "\": "); tojson(io, v, ind + 1)
            println(io, i < length(x) ? "," : "")
        end
        print(io, pad, "}")
    elseif x isa AbstractVector || x isa Tuple
        isempty(x) && return print(io, "[]")
        println(io, "[")
        for (i, v) in enumerate(x)
            print(io, pad, " "); tojson(io, v, ind + 1)
            println(io, i < length(x) ? "," : "")
        end
        print(io, pad, "]")
    else
        print(io, "\"", jesc(repr(x)), "\"")
    end
end

relpath_repo(f) = (p = String(f); startswith(p, ROOT * "/") ? p[length(ROOT)+2:end] : p)

# ── Quelltext: Definitionen mit Zeile ───────────────────────────────────────
const _PARSED = Dict{String,Vector{Any}}()   # Datei -> [(line, kind, sigexpr, body)]

function _collect!(defs, ex)
    ex isa Expr || return
    if ex.head in (:function, :(=), :->) && length(ex.args) == 2
        sig, body = ex.args
        isdef = ex.head !== :(=) || _is_callsig(sig)
        if isdef && body isa Expr && body.head === :block && !isempty(body.args) && body.args[1] isa LineNumberNode
            push!(defs, (body.args[1].line, ex.head, sig, body))
        end
    end
    for a in ex.args
        _collect!(defs, a)
    end
end
function _is_callsig(s)
    s isa Expr || return false
    s.head === :call && return true
    s.head in (:where, :(::)) && return _is_callsig(s.args[1])
    return false
end
function defs_in(file)
    get!(_PARSED, file) do
        defs = Any[]
        isfile(file) || return defs
        try
            _collect!(defs, Meta.parseall(read(file, String); filename = file))
        catch e
            @warn "Parsen fehlgeschlagen: $file ($e)"
        end
        defs
    end
end

dtext(d) = d isa Expr ? string(d) : d isa Symbol ? string(d) : d isa QuoteNode ? string(d) : repr(d)

# Argument aus der Signatur: (name, art, has_default, default)
function parg(a, kind)
    if a isa Symbol
        return (string(a), kind, false, nothing)
    elseif a isa Expr && a.head === :kw
        n = parg(a.args[1], kind)
        return (n[1], n[2], true, dtext(a.args[2]))
    elseif a isa Expr && a.head === :(::)
        return length(a.args) == 1 ? ("_", kind, false, nothing) : parg(a.args[1], kind)
    elseif a isa Expr && a.head === :...
        n = parg(a.args[1], kind)
        return (n[1] * "...", kind === "keyword" ? "kwargs_rest" : "varargs", false, nothing)
    elseif a isa Expr && a.head === :tuple
        return ("(" * join((parg(b, kind)[1] for b in a.args), ", ") * ")", kind, false, nothing)
    end
    return (string(a), kind, false, nothing)
end

function sig_args(sig)
    while sig isa Expr && sig.head in (:where, :(::)) && length(sig.args) >= 1 && !(sig.head === :(::) && length(sig.args) == 1)
        sig.head === :(::) && !_is_callsig(sig.args[1]) && sig.args[1] isa Symbol && break
        sig = sig.args[1]
    end
    if sig isa Symbol                       # x -> ...
        return [parg(sig, "positional")]
    end
    sig isa Expr || return nothing
    items = sig.head === :call ? sig.args[2:end] : sig.head === :tuple ? sig.args :
            sig.head === :block ? filter(x -> !(x isa LineNumberNode), sig.args) : [sig]
    out = Any[]
    kws = Any[]
    for a in items
        if a isa Expr && a.head === :parameters
            append!(kws, a.args)
        else
            push!(out, parg(a, "positional"))
        end
    end
    for k in kws
        push!(out, parg(k, "keyword"))
    end
    return out
end
sig_name(sig) = begin
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    sig isa Expr && sig.head === :call ? (f = sig.args[1]; f isa Expr && f.head === :. ? string(f.args[end].value) : string(f)) : nothing
end

function source_def(m::Method)
    file = String(m.file); line = Int(m.line)
    cands = [d for d in defs_in(file) if d[1] == line]
    isempty(cands) && return nothing
    mname = string(m.name)
    for d in cands
        n = sig_name(d[3])
        n !== nothing && (n == mname || endswith(mname, n)) && return d
    end
    return cands[1]
end

# ── Docstring-Signatur (nur für allgemeine Signaturen (args...; kw...)) ─────
function doc_sig(mod::Module, name::Symbol)
    for md in (mod, parentmodule(mod), SimLev)
        meta = Base.Docs.meta(md)
        b = Base.Docs.Binding(md, name)
        haskey(meta, b) || continue
        for (_, ds) in meta[b].docs
            txt = join(string.(ds.text), "")
            i = findfirst(string(name) * "(", txt)
            i === nothing && continue
            s = txt[first(i):end]; depth = 0; stop = 0
            for (j, c) in pairs(s)
                c == '(' && (depth += 1)
                c == ')' && (depth -= 1; depth == 0 && (stop = j; break))
            end
            stop == 0 && continue
            try
                ex = Meta.parse(replace(s[1:stop], r"\s+" => " "))
                if ex isa Expr && ex.head === :call
                    sa = sig_args(ex)
                    ok = sa !== nothing && all(a -> occursin(r"^[A-Za-z_][A-Za-z0-9_!]*(\.\.\.)?$", a[1]), sa)
                    ok && return sa
                end
            catch
            end
        end
    end
    return nothing
end

# ── Methode beschreiben ──────────────────────────────────────────────────────
# Platzhalter für R's missing(): der wirksame Standardwert entsteht erst im Rumpf.
const SENTINELS = ("_UNSET", "_MISSING")

function argdict(t, ma = Set{String}(), mod = nothing)
    d = Pair{String,Any}["name" => t[1], "kind" => t[2], "has_default" => t[3], "default" => t[4]]
    # Standardwert ist eine Konstante des Moduls (z. B. `op = _ops`): Wert dazu
    if t[3] && mod !== nothing && t[4] isa String && occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", t[4]) &&
       !(t[4] in SENTINELS) && t[4] != "nothing"
        s = Symbol(t[4])
        if isdefined(mod, s)
            v = getfield(mod, s)
            (v isa Function || v isa Type || v isa Module) || push!(d, "default_value" => dtext(v))
        end
    end
    if t[3] && t[4] in SENTINELS
        push!(d, "default_known" => false)
        push!(d, "default_note" => "Platzhalter $(t[4]) (R missing()); Wert entsteht im Rumpf")
    end
    t[1] in ma && push!(d, "match_arg" => true)
    d
end

# Argumente, die der Rumpf an eine *match_arg-Funktion gibt (erstes Argument
# enthält den Namen); deren match_arg liefert für `nothing` das erste Element.
function match_arg_names(def)
    found = Set{String}()
    def === nothing && return found
    has(e, n) = e === n || (e isa Expr && any(a -> has(a, n), e.args))
    function walk(e)
        e isa Expr || return
        if e.head === :call && length(e.args) >= 2
            f = e.args[1]
            fname = f isa Symbol ? string(f) : (f isa Expr && f.head === :. ? string(f.args[end] isa QuoteNode ? f.args[end].value : f.args[end]) : "")
            if endswith(fname, "match_arg")
                for s in _syms(e.args[2]); push!(found, string(s)); end
            end
        end
        foreach(walk, e.args)
    end
    walk(def[4])
    found
end
_syms(e) = e isa Symbol ? [e] : e isa Expr ? reduce(vcat, (_syms(a) for a in e.args); init = Symbol[]) : Symbol[]

function refl_args(m::Method)
    an = Base.method_argnames(m)[2:end]
    out = Any[]
    for (i, a) in enumerate(an)
        nm = string(a)
        push!(out, (m.isva && i == length(an)) ? (nm * "...", "varargs", false, nothing) : (nm, "positional", false, nothing))
    end
    for k in Base.kwarg_decl(m)
        ks = string(k)
        push!(out, endswith(ks, "...") ? (ks, "kwargs_rest", false, nothing) : (ks, "keyword", false, nothing))
    end
    out
end

is_generic(args) = !isempty(args) && all(a -> a[2] in ("varargs", "kwargs_rest"), args)

function describe(m::Method; name = string(m.name))
    d = source_def(m)
    ra = refl_args(m)
    note = String[]
    if d === nothing
        args = ra; known = false
        push!(note, "Standardwerte nicht ermittelbar (keine Definition an $(relpath_repo(m.file)):$(m.line)); nur Namen")
        src = "reflection"
    else
        args = sig_args(d[3]); known = true; src = "source"
        if args === nothing
            args = ra; known = false; src = "reflection"
            push!(note, "Signatur im Quelltext nicht lesbar; nur Namen")
        else
            # Namen gegen die Reflexion prüfen (positionell + Schlüsselwörter)
            rn = [a[1] for a in ra]; sn = [a[1] for a in args]
            if Set(rn) != Set(sn)
                push!(note, "Quelltext und Reflexion verschieden: $(join(sn, ",")) / $(join(rn, ","))")
            end
        end
    end
    if is_generic(args)
        ds = doc_sig(m.module, Symbol(name))
        if ds !== nothing
            push!(note, "Methode hat nur ($(join((a[1] for a in args), "; "))); Argumente aus der Docstring-Signatur")
            args = ds; src = "docstring"
        else
            push!(note, "Methode hat nur ($(join((a[1] for a in args), "; "))); Argumentnamen nicht ermittelbar")
            known = false
        end
    end
    return (args = args, file = relpath_repo(m.file), line = Int(m.line), known = known, src = src,
            note = isempty(note) ? nothing : join(note, "; "), def = d, mod = m.module)
end

insimlev(mod::Module) = (mod === SimLev) || (mod !== parentmodule(mod) && insimlev(parentmodule(mod)))

function describe_function(f, name)
    ms = [m for m in methods(f) if insimlev(m.module)]
    isempty(ms) && return nothing
    # Methoden einer Definition (positionelle Standardwerte erzeugen mehrere) zusammenfassen
    groups = Dict{Tuple{String,Int},Method}()
    for m in ms
        k = (String(m.file), Int(m.line))
        (!haskey(groups, k) || m.nargs > groups[k].nargs) && (groups[k] = m)
    end
    descs = [describe(m; name = name) for m in values(groups)]
    sort!(descs; by = d -> (-length(d.args), d.file, d.line))
    return descs
end

# ── Exporte ──────────────────────────────────────────────────────────────────
entries = Any[]; classes = Any[]; other = Any[]
for n in sort(names(SimLev))
    n === :SimLev && continue
    isdefined(SimLev, n) || (push!(other, Pair{String,Any}["name" => string(n), "type" => "undefiniert"]); continue)
    obj = getfield(SimLev, n)
    if obj isa Type
        push!(classes, Pair{String,Any}["name" => string(n), "type" => string(typeof(obj)),
                                         "module" => string(parentmodule(obj))])
        continue
    end
    if !(obj isa Function)
        push!(other, Pair{String,Any}["name" => string(n), "type" => string(typeof(obj)), "repr" => repr(obj)])
        continue
    end
    ds = describe_function(obj, string(n))
    if ds === nothing
        push!(other, Pair{String,Any}["name" => string(n), "type" => "Function ohne Methode in SimLev"])
        continue
    end
    d = ds[1]
    variants = [Pair{String,Any}["file" => v.file, "line" => v.line, "args" => [a[1] for a in v.args]] for v in ds[2:end]]
    push!(entries, Pair{String,Any}[
        "name" => string(n), "key" => string(n), "kind" => "function", "generic" => nothing, "class" => nothing,
        "module" => string(parentmodule(obj)), "file" => d.file, "line" => d.line,
        "args" => [argdict(a, match_arg_names(d.def), d.mod) for a in d.args], "defaults_known" => d.known, "args_source" => d.src,
        "note" => d.note, "variants" => variants])
end

# ── Methoden der Ergebnisklassen (Registrierungen) ──────────────────────────
function plot_inner(c, depth = 0)
    depth > 4 && return nothing
    T = typeof(c)
    hasfield(T, :f) && hasfield(T, :known) && return getfield(c, :f)
    for fn in fieldnames(T)
        v = getfield(c, fn)
        v isa Function && (r = plot_inner(v, depth + 1); r !== nothing && return r)
    end
    return nothing
end

function body_call(d)
    d === nothing && return nothing
    b = filter(x -> !(x isa LineNumberNode), d[4].args)
    length(b) == 1 && b[1] isa Expr && b[1].head === :call && b[1].args[1] isa Symbol ? b[1].args[1] : nothing
end

for (generic, tab, jname) in (("print", SimLev._PRINTERS, "show"), ("summary", SimLev._SUMMARIES, "r_summary"),
                              ("plot", SimLev._PLOTS, "r_plot"))
    for cls in sort(collect(keys(tab)))
        f = tab[cls]
        notes = String[]
        inner = generic == "plot" ? plot_inner(f) : nothing
        target = inner === nothing ? f : inner
        ms = [m for m in methods(target)]
        m = ms[argmax([mm.nargs for mm in ms])]
        d = describe(m)
        args = copy(d.args)
        if inner !== nothing
            push!(notes, "über _plot_method (Zeichenfunktion $(m.name), $(d.file):$(d.line))")
            # Form der plot-Methode wie _plot_method: (x, args...; <Schlüsselwörter von f>, file = nothing)
            kws = [a for a in args if a[2] == "keyword" && a[1] != "file"]
            args = Any[(isempty(args) ? "x" : args[1][1], "positional", false, nothing); kws; ("file", "keyword", true, "nothing")]
        else
            g = body_call(d.def)
            if g !== nothing && any(a -> a[2] in ("varargs", "kwargs_rest"), args) && isdefined(m.module, g)
                gf = getfield(m.module, g)
                gm = [mm for mm in methods(gf)]
                if !isempty(gm)
                    gd = describe(gm[argmax([mm.nargs for mm in gm])])
                    push!(notes, "Hülle um $(g) ($(gd.file):$(gd.line))")
                    d = gd
                    args = copy(gd.args)
                end
            end
            if generic == "print" && length(args) >= 1 && args[1][1] == "io"
                popfirst!(args)
                push!(notes, "show(io, x): io entfällt")
            end
        end
        d.note === nothing || push!(notes, d.note)
        push!(entries, Pair{String,Any}[
            "name" => "$(jname)($(cls))", "key" => "$(generic).$(cls)", "kind" => "method", "generic" => generic,
            "class" => cls, "module" => string(m.module), "file" => d.file, "line" => d.line,
            "args" => [argdict(a, match_arg_names(d.def), d.mod) for a in args], "defaults_known" => d.known, "args_source" => d.src,
            "note" => isempty(notes) ? nothing : join(notes, "; "), "variants" => Any[]])
    end
end

res = Pair{String,Any}[
    "language" => "Julia",
    "source" => "names(SimLev); SimLev._PRINTERS/_SUMMARIES/_PLOTS",
    "generated" => Dates.format(now(), "yyyy-mm-dd HH:MM:SS"),
    "tool" => "tools/api_snapshot/api_jl.jl",
    "notes" => ["Standardwerte aus dem Quelltext (Meta.parseall an Datei:Zeile der Methode); args_source sagt, woher.",
                "defaults_known = false: nur Namen (Reflexion), Standardwerte nicht ermittelbar.",
                "print-Methoden: registrierte show-Funktion f(io, x); io entfällt."],
    "functions" => entries, "classes" => classes, "other" => other]
open(OUT, "w") do io
    tojson(io, res); println(io)
end
nf = count(e -> e[3].second == "function", entries)
println("Julia: $nf Funktionen, $(length(entries) - nf) Methoden, $(length(classes)) Typen, $(length(other)) sonstige -> $OUT")
