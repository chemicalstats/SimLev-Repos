# Julia gegen R: alle Fälle von Bereichsdateien nachrechnen (Gleichlauf; bis T20 compare_reference.jl und
# compare_golden.jl).
#
# Aufruf:  julia --project=julia tests/gleichlauf/vergleich.jl <datei.jsonl.gz | ordner> ... [-k muster] [-v] [--lax]
#
# Ohne Pfad der Katalog tests/faelle. Vergleich wie die Tests (tests/julia/faelle.jl), strikt NA ≠ NaN (--lax:
# NA = NaN bei Engine-Fällen). Ausgabe je Modul "<modul> <ok>/<n> bitgleich" und "Gesamt: <ok>/<n>"; Ende 1 bei
# einer Abweichung.
using SimLev
include(joinpath(@__DIR__, "..", "julia", "faelle.jl"))

function main(args)
    paths = String[]; k = nothing; verbose = false; strict = true
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "-k"; k = args[i + 1]; i += 1
        elseif a == "-v"; verbose = true
        elseif a == "--lax"; strict = false
        else push!(paths, a) end
        i += 1
    end
    isempty(paths) && push!(paths, FAELLE)
    files = String[]
    for p in paths
        append!(files, isdir(p) ? bereiche(p) : [p])
    end
    tot = tot_ok = 0
    for f in files
        store, cases = lies_bereich(f)
        stat = Dict{String,Vector{Int}}(); order = String[]
        for c in cases
            key = kennung(c)
            k !== nothing && !occursin(k, key) && continue
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
                println("FAIL $key")
                for e in (verbose ? errs : errs[1:min(end, 4)])
                    println("    ", first(replace(e, "\n" => "\n    "), verbose ? 20000 : 600))
                end
            end
        end
        for m in order
            println(rpad(m, 16), " $(stat[m][1])/$(stat[m][2]) bitgleich")
            tot_ok += stat[m][1]; tot += stat[m][2]
        end
    end
    println("Gesamt: $tot_ok/$tot")
    return tot_ok == tot && tot > 0 ? 0 : 1
end

exit(main(ARGS))
