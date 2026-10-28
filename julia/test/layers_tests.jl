# Schichtentest: keine Datei in src/ greift auf eine höhere Schicht zu.
#
# Schichten (Anhang F des Entwicklungsdokuments): 0 R-Interna (src/r/), 1 Daten und
# Strategie, 2 Engine, 3 Analysen, 4 Ausgabe; SimLev.jl, exports.jl und precompile.jl
# sind die Paketebene darüber. Gelesen wird der Quelltext, nicht der geladene Zustand:
#   - `using`/`import`-Zeilen: `..SimLev: a, b` (die Namen werden der Datei zugeordnet, die
#     sie auf Paketebene definiert), `..Modul`, `..Modul: a`, `..SimLev.Modul`;
#   - qualifizierte Zugriffe `Modul.f`, `SimLev.Modul.f` und `SimLev.f` (das Gegenstück zu
#     Pythons `_ext("modul", …)`) und in Dateien der Paketebene die Aufrufe `f(` von Namen,
#     die eine andere Datei der Paketebene definiert; ohne Kommentare und Zeichenketten.
# Dateien, die ein Untermodul per `include` einbindet, gehören zu dessen Datei.
# Erlaubt sind Zugriffe auf dieselbe oder eine tiefere Schicht. Bekannte Ausnahmen stehen
# mit Begründung in `_LKNOWN`; eine neue Abweichung lässt den Test scheitern, ebenso eine
# Ausnahme, die es nicht mehr gibt (dann aus `_LKNOWN` streichen).

using Test

const _LSRC = normpath(joinpath(@__DIR__, "..", "src"))
const _LTOP = 5

# Datei (relativ zu src/) -> Schicht; alle Dateien unter r/ sind Schicht 0.
const _LLAYERS = Dict(
    # 1 Daten und Strategie: Eingaben der Simulation (Reihen, Strategie, Signale, Tarif)
    "dates.jl" => 1, "config.jl" => 1, "trigger.jl" => 1, "data.jl" => 1, "tax_tariff.jl" => 1,
    "data_prep.jl" => 1, "backcast.jl" => 1, "bonds.jl" => 1, "signals_core.jl" => 1, "signals.jl" => 1,
    # 2 Engine
    "core.jl" => 2, "result.jl" => 2, "engine.jl" => 2, "sim_phases.jl" => 2, "sim_loop.jl" => 2,
    "sim_evaluate.jl" => 2, "sim_blocks.jl" => 2,   # Bausteine: Eingaben der Engine, übersetzt in deren Argumente
    "wrapper.jl" => 2,   # Fonds-Wrapper (Etappe 6.5c): Anteilswert über simulation()
    # 3 Analysen (je eine Datei, Kerne bei ihrem Modul)
    "bootstrap_core.jl" => 3, "bootstrap.jl" => 3, "withdrawal_core.jl" => 3, "withdrawal.jl" => 3,
    "dependence_core.jl" => 3, "dependence.jl" => 3, "regimes.jl" => 3, "ms_garch.jl" => 3,
    "scenarios.jl" => 3, "optimize_core.jl" => 3, "optimize.jl" => 3, "tactical.jl" => 3,
    "deep_analysis.jl" => 3, "planning.jl" => 3, "analysis_tests.jl" => 3, "overfitting.jl" => 3,
    "param_search.jl" => 3, "sensitivity.jl" => 3,
    # 4 Ausgabe
    "svg.jl" => 4, "dashboard.jl" => 4,
    # Paketebene
    "SimLev.jl" => _LTOP, "exports.jl" => _LTOP, "precompile.jl" => _LTOP,
)

# (Datei, Datei mit dem Ziel) -> Begründung. Stand: Etappe 4.4; nicht repariert.
const _LPLOT = "plot-Methode: die Grafikbausteine (_res_*/_ana_*/_grid_*/_alloc_*/_bc_*, _esc) " *
               "liegen in svg.jl (Schicht 4), die plot-Methoden beim Objekt"
const _LKNOWN = Dict{Tuple{String,String},String}(
    ("config.jl", "engine.jl") => "_to_date_or_nothing (start) nutzt _as_date der Engine, in der Funktion",
    [("$f.jl", "svg.jl") => _LPLOT for f in ("backcast", "bootstrap", "withdrawal", "dependence", "regimes",
                                             "optimize", "tactical", "deep_analysis", "planning",
                                             "analysis_tests", "overfitting", "param_search", "sensitivity")]...,
)

_llayer(f) = startswith(f, "r/") ? 0 : _LLAYERS[f]

"Quelltext ohne Kommentare und Zeichenketten (Zeilenzahl bleibt)."
function _lstrip(src)
    keep(m) = replace(m, r"[^\n]" => " ")
    s = replace(src, r"#=.*?=#"s => keep)
    s = replace(s, r"\"\"\".*?\"\"\""s => keep)
    s = replace(s, r"\"(?:\\.|[^\"\\\n])*\"" => keep)
    s = replace(s, r"'(?:\\.|[^'\\\n])'" => keep)
    replace(s, r"#[^\n]*" => keep)
end

"Datei -> Untermodul (nothing = Paketebene SimLev), über die include-Kette ab SimLev.jl."
function _lfiles()
    owner = Dict{String,Union{Nothing,String}}()   # Datei -> Modulname
    home = Dict{String,String}()                   # Datei -> Datei, deren Schicht gilt
    modfile = Dict{String,String}()                # Modulname -> Datei
    function walk(f, mod, h)
        src = read(joinpath(_LSRC, f), String)
        m = match(r"^module\s+(\w+)"m, src)
        if f != "SimLev.jl" && m !== nothing
            mod = String(m[1]); modfile[mod] = f; h = f
        end
        owner[f] = mod; home[f] = h
        # include-Zeilen nur aus Code (ohne Kommentare); der Pfad selbst ist eine Zeichenkette
        code = replace(src, r"#=.*?=#"s => "", r"^\s*#[^\n]*"m => "")
        for inc in eachmatch(r"^\s*include\(\"([^\"]+)\"\)"m, code)
            g = normpath(joinpath(dirname(f), inc[1]))
            walk(g, mod, mod === nothing ? g : h)    # in einem Untermodul: Schicht der Moduldatei
        end
    end
    walk("SimLev.jl", nothing, "SimLev.jl")
    owner, home, modfile
end

"Auf Paketebene definierte Namen -> Dateien."
function _lnames(owner)
    idx = Dict{String,Vector{String}}()
    pat = [r"^(?:@\w+\s+)*function\s+([A-Za-z_][\w!]*)"m, r"^(?:@\w+\s+)*(?:mutable\s+)?struct\s+([A-Za-z_]\w*)"m,
           r"^abstract\s+type\s+([A-Za-z_]\w*)"m, r"^primitive\s+type\s+([A-Za-z_]\w*)"m,
           r"^macro\s+([A-Za-z_]\w*)"m, r"^const\s+([A-Za-z_][\w!]*)"m,
           r"^([A-Za-z_][\w!]*)(?:\{[^}]*\})?\([^\n]*\)\s*(?:::\s*[^=\n]+)?(?:where\s+[^=\n]+)?=(?!=)"m,
           r"^([A-Za-z_][\w!]*)\s*=(?!=)"m]
    for (f, mod) in owner
        (mod === nothing && f != "SimLev.jl") || continue
        src = _lstrip(read(joinpath(_LSRC, f), String))
        for p in pat, m in eachmatch(p, src)
            push!(get!(idx, String(m[1]), String[]), f)
        end
    end
    idx
end

"Eingerückt definierte Namen (z. B. in `if Sys.ARCH === :x86_64 … end`), nur falls oben nicht gefunden."
function _lnested(owner, nm)
    p = Regex("^[ \\t]+(?:@\\w+\\s+)*(?:(?:function|const|primitive\\s+type|(?:mutable\\s+)?struct)\\s+)?" *
              nm * "\\b(?:\\s+\\d+\\s+end|\\(|\\s*=|\\s*\\{|\\s*<:|\\s*\\n)", "m")
    fs = [f for (f, mod) in owner if mod === nothing && f != "SimLev.jl" &&
          occursin(p, _lstrip(read(joinpath(_LSRC, f), String)))]
    isempty(fs) ? nothing : fs
end

"(Datei, Zieldatei, Zeile) aller Zugriffe."
function _ldeps()
    owner, home, modfile = _lfiles()
    names_ = _lnames(owner)
    out = Tuple{String,String,Int}[]
    unknown = String[]
    nested = Dict{String,Vector{String}}()
    line(src, i) =count(==('\n'), SubString(src, 1, i)) + 1
    for (f, mod) in owner
        src = _lstrip(read(joinpath(_LSRC, f), String))
        me = home[f]
        add(t, i) = (t != me && push!(out, (me, t, line(src, i))))
        # using/import-Zeilen (auch fortgesetzt über mehrere Zeilen nach einem Komma)
        for m in eachmatch(r"^\s*(?:using|import)\s+((?:[^\n]*,[ \t]*\n)*[^\n]*)"m, src)
            for part in split(m[1], r",\s*(?=\.)")       # mehrere Module in einer Zeile
                mm = match(r"^\s*(\.+)([\w.]+)\s*(?::\s*(.*))?$"s, part)
                mm === nothing && continue
                path = split(mm[2], "."); items = mm[3] === nothing ? String[] :
                    [strip(x) for x in split(mm[3], ",") if !isempty(strip(x))]
                path[1] == "SimLev" && (path = path[2:end])
                if !isempty(path)                        # ..Modul / ..SimLev.Modul
                    haskey(modfile, path[1]) && add(home[modfile[path[1]]], m.offset)
                else                                     # ..SimLev: Namen
                    for it in items
                        nm = String(match(r"^[\w!@]+", it).match)
                        if haskey(modfile, nm)
                            add(home[modfile[nm]], m.offset)
                        elseif (fs = get(names_, nm, nothing); fs !== nothing || (fs = _lnested(owner, nm)) !== nothing)
                            add(fs[argmin([_llayer(home[x]) for x in fs])], m.offset)
                        else
                            push!(unknown, "$f: $nm")
                        end
                    end
                end
            end
        end
        # qualifizierte Zugriffe auf Untermodule (`Modul.f`, `SimLev.Modul.f`)
        for (nm, g) in modfile
            for m in eachmatch(Regex("(?<![\\w.])(?:SimLev\\.)?" * nm * "\\.(?=[A-Za-z_])"), src)
                add(home[g], m.offset)
            end
        end
        # qualifizierte Zugriffe auf Namen der Paketebene (`SimLev.f`); erzeugte Namen
        # (exports.jl) haben keine Fundstelle und bleiben unberücksichtigt
        for m in eachmatch(r"(?<![\w.])SimLev\.([A-Za-z_][\w!]*)(?!\.)", src)
            nm = String(m[1])
            haskey(modfile, nm) && continue
            fs = get(names_, nm, nothing)
            fs === nothing && (fs = get!(() -> something(_lnested(owner, nm), String[]), nested, nm))
            isempty(fs) || add(fs[argmin([_llayer(home[x]) for x in fs])], m.offset)
        end
        # Dateien der Paketebene rufen Namen anderer Dateien der Paketebene ohne Import auf (`f(`)
        if mod === nothing && f != "SimLev.jl"
            for m in eachmatch(r"(?<![\w.:])([A-Za-z_][\w!]*)\(", src)
                fs = get(names_, String(m[1]), nothing)
                (fs === nothing || f in fs) && continue
                add(fs[argmin([_llayer(home[x]) for x in fs])], m.offset)
            end
        end
    end
    out, unknown
end

function _lviolations()
    deps, unknown = _ldeps()
    v = Dict{Tuple{String,String},Vector{Int}}()
    for (f, t, l) in deps
        _llayer(t) > _llayer(f) && push!(get!(v, (f, t), Int[]), l)
    end
    v, unknown
end

@testset "Schichten (src/)" begin
    owner, home, _ = _lfiles()
    files = Set(home[f] for f in keys(owner) if !startswith(home[f], "r/"))
    @test sort(collect(setdiff(files, keys(_LLAYERS)))) == String[]          # Schicht fehlt
    @test sort(collect(setdiff(keys(_LLAYERS), files))) == String[]          # Datei gibt es nicht mehr
    v, unknown = _lviolations()
    @test unknown == String[]                                               # Name ohne Fundstelle
    neu = sort([k for k in keys(v) if !haskey(_LKNOWN, k)])
    for (f, t) in neu
        println("Schichtverstoß: $f (Schicht $(_llayer(f))) greift auf $t (Schicht $(_llayer(t))) zu, Zeile ",
                join(sort(unique(v[(f, t)])), ", "))
    end
    @test neu == Tuple{String,String}[]
    @test sort([k for k in keys(_LKNOWN) if !haskey(v, k)]) == Tuple{String,String}[]   # Ausnahme veraltet
end

@testset "Schalter SIMLEV_* nur in src/r/env.jl" begin
    # Umgebungsschalter liest und setzt nur SimLev.REnv (Etappe 4.5)
    root = normpath(joinpath(@__DIR__, ".."))
    env = joinpath(root, "src", "r", "env.jl")
    hits = String[]
    for sub in ("src", "test", "tools"), (dp, _, fs) in walkdir(joinpath(root, sub)), f in fs
        p = joinpath(dp, f)
        (endswith(f, ".jl") && p != env) || continue
        for (i, ln) in enumerate(eachline(p))
            occursin(r"(\bENV\b|withenv)[^\n]*[\"]SIMLEV_", ln) && push!(hits, "$(relpath(p, root)):$i")
        end
    end
    @test hits == String[]
end
