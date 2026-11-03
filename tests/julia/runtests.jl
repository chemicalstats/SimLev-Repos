# Tests der Julia-Fassung (T20: tests/julia, gegen das gebaute Paket julia/):
#   julia --project=julia tests/julia/runtests.jl          (aus der Repo-Wurzel; oder tests/run.sh julia)
# Drei Teile: Gleichlauf mit R über alle Fälle des Katalogs tests/faelle (faelle.jl; strikt NA ≠ NaN), die
# eingefrorene Schnittstelle (api.jl, tests/api/frozen/jl.json) und die SVG-Grafiken, die es nur in Python und
# Julia gibt (grafik.jl). Test, Logging und Zlib_jll sind Standardbibliotheken (keine eigene Testumgebung).
# Den Abgleich mit dem aktuellen R (alle Fälle der Generatoren, Zufallsprüfungen) macht tests/gleichlauf/run.sh.
using SimLev
using Test
using Dates
using Logging

include("faelle.jl")

@testset "SimLev" begin

@testset "Referenzfälle tests/faelle" begin
    ps = bereiche()
    @test !isempty(ps)
    for p in ps
        store, cases = lies_bereich(p)
        b = replace(basename(p), ".jsonl.gz" => "")
        @testset "$b" begin
            for c in cases
                errs = pruefe_fall(c, store)
                isempty(errs) || println("FAIL $b/$(kennung(c))\n    ", first(join(errs, "\n"), 1500))
                @test isempty(errs)
            end
        end
    end
end

include("api.jl")

@testset "Grafiken (SVG)" begin
    include("grafik.jl")
end

end
