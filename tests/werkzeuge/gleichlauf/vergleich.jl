# Julia gegen R: alle Fälle von Bereichsdateien nachrechnen (Gleichlauf; bis 1.4.0 compare_reference.jl und
# compare_golden.jl).
#
# Aufruf:  julia --project=julia tests/werkzeuge/gleichlauf/vergleich.jl [--protokoll P] <datei.jsonl.gz | ordner> ...
#                [-k muster] [-v] [--lax]
#
# Ohne Pfad der Katalog tests/<gruppe>/faelle. Vergleich wie die Tests (tests/lib/faelle.jl, mit der Toleranzstufe aus
# tests/lib/toleranz.tsv seit 1.6.4), strikt NA ≠ NaN (--lax:
# NA = NaN bei Engine-Fällen). Ausgabe je Modul "<modul> <ok>/<n> bitgleich" und "Gesamt: <ok>/<n>"; Ende 1 bei
# einer Abweichung. Die Fälle werden einzeln gelesen und geprüft (seit 1.6.3; bis 1.6.2 alle einer Datei zugleich).
#
# --protokoll P (seit 1.6.3) gilt für den folgenden Pfad: dessen Ausgabe (FAIL-Zeilen, Modulzeilen, "Gesamt: <ok>/<n>")
# geht nach P, genau wie bei einem eigenen Aufruf nur mit diesem Pfad; auf die Konsole kommt dann je Datei
# "Datei <pfad>: <ok>/<n> (<s> s)" bzw. "Datei <pfad>: FEHLER (…)". So prüft ein Prozess mehrere Dateien (die
# Übersetzung gemeinsamer Teile fällt nur einmal an; tests/werkzeuge/gleichlauf/run.py). Ende 1, wenn eine dieser Dateien
# abweicht oder keinen Fall hat, oder wenn die Dateien ohne Protokoll zusammen abweichen.
using SimLev
include(joinpath(@__DIR__, "..", "..", "lib", "faelle.jl"))

"Fälle der Datei f prüfen, Ausgabe nach io; (ok, n)."
function pruefe_datei(io, f, k, verbose, strict)
    stat = Dict{String,Vector{Int}}(); order = String[]
    je_fall(f) do store, c
        key = kennung(c)
        k !== nothing && !occursin(k, key) && return
        m = split(key, "/")[1]
        haskey(stat, m) || (stat[m] = [0, 0]; push!(order, m))
        errs = try
            pruefe_fall(c, store; strict_na = strict)
        catch e
            ["Werkzeugfehler: " * sprint(showerror, e)]
        end
        stat[m][2] += 1
        if isempty(errs)
            stat[m][1] += 1
        else
            println(io, "FAIL $key")
            for e in (verbose ? errs : errs[1:min(end, 4)])
                println(io, "    ", first(replace(e, "\n" => "\n    "), verbose ? 20000 : 600))
            end
        end
    end
    ok = n = 0
    for m in order
        println(io, rpad(m, 16), " $(stat[m][1])/$(stat[m][2]) bitgleich")
        ok += stat[m][1]; n += stat[m][2]
    end
    return ok, n
end

function main(args)
    paths = Tuple{String,Union{Nothing,String}}[]; k = nothing; verbose = false; strict = true; prot = nothing
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "-k"; k = args[i + 1]; i += 1
        elseif a == "-v"; verbose = true
        elseif a == "--lax"; strict = false
        elseif a == "--protokoll"; prot = args[i + 1]; i += 1
        else push!(paths, (a, prot)); prot = nothing end
        i += 1
    end
    isempty(paths) && append!(paths, [(faelle_dir(g), nothing) for g in GRUPPEN])
    tot = tot_ok = 0          # alle Dateien (Zeile "Gesamt" auf der Konsole)
    o_n = o_ok = 0; ohne = false; eigen_ok = true
    for (p, pr) in paths
        if pr === nothing                     # Ausgabe auf die Konsole
            ohne = true
            for f in (isdir(p) ? bereiche(p) : [p])
                ok, n = pruefe_datei(stdout, f, k, verbose, strict)
                o_ok += ok; o_n += n
            end
            continue
        end
        isdir(p) && error("--protokoll gilt für eine Datei, nicht für den Ordner $p")
        t0 = time()
        ok, n = try
            open(pr, "w") do io
                r = pruefe_datei(io, p, k, verbose, strict)
                println(io, "Gesamt: $(r[1])/$(r[2])")
                r
            end
        catch e
            open(io -> println(io, "Werkzeugfehler: ", sprint(showerror, e)), pr, "a")
            println("Datei $p: FEHLER (", first(sprint(showerror, e), 300), ")"); flush(stdout)
            eigen_ok = false
            continue
        end
        println("Datei $p: $ok/$n ($(round(Int, time() - t0)) s)"); flush(stdout)
        eigen_ok &= ok == n && n > 0
        tot_ok += ok; tot += n
    end
    tot_ok += o_ok; tot += o_n
    println("Gesamt: $tot_ok/$tot")
    return eigen_ok && (!ohne || (o_ok == o_n && o_n > 0)) ? 0 : 1
end

exit(main(ARGS))
