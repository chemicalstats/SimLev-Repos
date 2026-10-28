# Vergleicht die Julia-Engine bitgenau mit Golden-Master-Ergebnissen aus R.
#
# Aufruf:  julia --project=. tools/compare_golden.jl [--lax] [-v] [<ordner_oder_datei> ...] [-k fall ...]
#
#   Ohne Pfad werden golden/cases und golden/extra geprüft; bei mehreren Ordnern
#   folgt eine Gesamtsumme (wie tools/compare_golden.py). Gelesen werden .json.gz
#   und .json.
#   --lax       NA und NaN gleich behandeln
#   -v          Unterschiede ausführlich zeigen
#   -k fall …   nur diese Fälle (ohne Endung)
#
# Weiterhin möglich: compare_golden.jl <golden_dir> [case_id ...] (Argumente, die
# kein vorhandener Pfad sind, gelten als Fallkennungen).
#
# Etappe 9: ohne SIMLEV_LEGACY_TESTS=1 ist der Vergleich mit golden/cases und golden/extra
# ausgesetzt (Hinweis, Ende 0); andere Verzeichnisse (Gleichlauf) werden verglichen.

using SimLev
include(joinpath(@__DIR__, "..", "test", "golden_tools.jl"))

const DEFAULT_DIRS = [normpath(joinpath(@__DIR__, "..", "..", "golden", d)) for d in ("cases", "extra")]

_case_id(f) = replace(basename(f), r"\.json(\.gz)?$" => "")

function _collect(p, ids)
    files = isdir(p) ? [joinpath(p, f) for f in sort(readdir(p)) if endswith(f, ".json") || endswith(f, ".json.gz")] : [p]
    isempty(ids) ? files : filter(f -> _case_id(f) in ids, files)
end

function main(args)
    strict = true; verbose = false
    paths = String[]; ids = String[]
    i = 1; in_k = false
    while i <= length(args)
        a = args[i]
        if a == "--lax"; strict = false; in_k = false
        elseif a == "-v"; verbose = true; in_k = false
        elseif a == "-k"; in_k = true
        elseif in_k || !ispath(a); push!(ids, a)
        else push!(paths, a)
        end
        i += 1
    end
    verbose |= !isempty(ids)
    isempty(paths) && (paths = DEFAULT_DIRS)
    # Etappe 9 (Entwurf C.7): Vergleich mit golden/cases und golden/extra ausgesetzt
    if !SimLev.REnv.legacy_tests() && sort(normpath.(abspath.(paths))) == sort(DEFAULT_DIRS)
        println("compare_golden: Etappe 9 – Vergleich mit golden/cases und golden/extra ausgesetzt ",
                "(SIMLEV_LEGACY_TESTS=1, oder andere Verzeichnisse angeben)")
        return 0
    end
    total_ok = 0; total = 0; n_failed = 0
    t_all = time()
    for p in paths
        files = _collect(p, ids)
        isempty(files) && continue
        n_ok = 0
        t0 = time()
        for f in files
            errs = run_case(f; strict_na = strict, verbose = verbose)
            if isempty(errs)
                n_ok += 1
            else
                n_failed += 1
                println("FAIL ", basename(f))
                for e in errs[1:min(end, 8)]
                    println("    ", e)
                end
            end
        end
        println("$p: $n_ok/$(length(files)) Fälle bitgleich", strict ? " (strikt: NA ≠ NaN)" : "",
                "  [", round(time() - t0; digits = 1), " s]")
        total_ok += n_ok; total += length(files)
    end
    total == 0 && (println("keine passenden Fälle in ", join(paths, ", ")); return 1)
    length(paths) > 1 && println("gesamt: $total_ok/$total Fälle bitgleich", strict ? " (strikt: NA ≠ NaN)" : "",
                                 "  [", round(time() - t_all; digits = 1), " s]")
    return n_failed == 0 ? 0 : 1
end

exit(main(ARGS))
