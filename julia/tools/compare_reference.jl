# Vergleicht die Julia-Fassung bitgenau mit den R-Referenzfällen der
# Erweiterungsmodule (golden/modules/<modul>/*.json.gz, Format 1 und 2).
#
# Aufruf:  julia --project=. tools/compare_reference.jl [modul ...] [-k muster] [-v] [--dir pfad]
#
# Etappe 9: ohne SIMLEV_LEGACY_TESTS=1 ausgesetzt (Hinweis, Ende 0), außer --dir bzw.
# SIMLEV_MODULE_DIR zeigt auf ein anderes Verzeichnis (Gleichlaufprüfung, tools/gleichlauf/).

using SimLev
include(joinpath(@__DIR__, "..", "test", "reftree.jl"))

const _DEFAULT_MODDIR = normpath(joinpath(@__DIR__, "..", "..", "golden", "modules"))

function main(args)
    dir = SimLev.REnv.module_dir(_DEFAULT_MODDIR)
    k = nothing; verbose = false; mods = String[]
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "-k"; k = args[i+1]; i += 2; continue
        elseif a == "-v"; verbose = true
        elseif a == "--dir"; dir = args[i+1]; i += 2; continue
        else push!(mods, a) end
        i += 1
    end
    # Etappe 9 (Entwurf C.7): Vergleich mit golden/modules ausgesetzt, außer SIMLEV_LEGACY_TESTS=1
    # oder --dir/SIMLEV_MODULE_DIR zeigt auf ein anderes Verzeichnis (Gleichlauf)
    if !SimLev.REnv.legacy_tests() && normpath(abspath(dir)) == _DEFAULT_MODDIR
        println("compare_reference: Etappe 9 – Vergleich mit golden/modules ausgesetzt ",
                "(SIMLEV_LEGACY_TESTS=1, oder --dir/SIMLEV_MODULE_DIR für ein anderes Verzeichnis)")
        return 0
    end
    isempty(mods) && (mods = sort([d for d in readdir(dir) if isdir(joinpath(dir, d))]))
    tot = 0; tot_ok = 0
    for m in mods
        files = list_ref_cases(joinpath(dir, m))
        k === nothing || (files = filter(f -> occursin(k, f), files))
        ok = 0
        for f in files
            case = read_ref_case(joinpath(dir, m, f))
            errs = try
                run_ref_case(case)
            catch e
                ["Werkzeugfehler: " * sprint(showerror, e)]
            end
            if isempty(errs)
                ok += 1
            else
                println("FAIL $m/$f")
                for e in (verbose ? errs : errs[1:min(end, 4)])
                    s = replace(e, "\n" => "\n    ")
                    println("    ", verbose ? s : first(s, 600))
                end
            end
        end
        println(rpad(m, 16), " $ok/$(length(files)) bitgleich")
        tot += length(files); tot_ok += ok
    end
    println("Gesamt: $tot_ok/$tot")
    return tot_ok == tot ? 0 : 1
end

exit(main(ARGS))
