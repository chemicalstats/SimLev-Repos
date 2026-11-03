# Tests der Julia-Fassung (tests/ nach Zweck gegliedert; gegen das gebaute Paket julia/):
#   julia --project=julia tests/run.jl [gleichlauf] [fehler] [ausgabe] [schnittstelle]     (aus der Repo-Wurzel)
# Ohne Liste alle Gruppen. gleichlauf, fehler, ausgabe: Szenarien und Tabellen aus tests/<gruppe>/faelle (Herkunft der
# Erwartung R; strikt NA ≠ NaN); ausgabe zusätzlich die SVG-Grafiken, die es nur in Python und Julia gibt
# (ausgabe/grafik.jl); schnittstelle: eingefrorene Schnittstelle (schnittstelle/api.jl). methodik läuft nur in R
# (die Ports sichern die Szenarien von gleichlauf). Test, Logging und Zlib_jll sind Standardbibliotheken.
# Den Abgleich mit dem aktuellen R (alle Generatorfälle, Zufallsprüfungen) macht tests/werkzeuge/gleichlauf/run.sh.
using SimLev
using Test
using Dates
using Logging

include(joinpath(@__DIR__, "lib", "faelle.jl"))

const ALLE = ["gleichlauf", "fehler", "ausgabe", "schnittstelle"]
const WAHL = isempty(ARGS) ? ALLE : ARGS
for g in WAHL
    g in ALLE || error("tests/run.jl: unbekannte Gruppe $g (erlaubt: $(join(ALLE, ", ")))")
end

@testset "SimLev" begin

for g in filter(in(WAHL), ["gleichlauf", "fehler", "ausgabe"])
    @testset "$g (tests/$g/faelle)" begin
        ps = bereiche(faelle_dir(g))
        @test !isempty(ps)
        for p in ps
            store, cases = lies_bereich(p)
            b = replace(basename(p), ".jsonl.gz" => "")
            @testset "$b" begin
                for c in cases
                    errs = pruefe_fall(c, store)
                    isempty(errs) || println("FAIL $g/$b/$(kennung(c))\n    ", first(join(errs, "\n"), 1500))
                    @test isempty(errs)
                end
            end
        end
    end
end

if "ausgabe" in WAHL
    @testset "ausgabe: Grafiken (SVG)" begin
        include(joinpath(@__DIR__, "ausgabe", "grafik.jl"))
    end
end

"schnittstelle" in WAHL && include(joinpath(@__DIR__, "schnittstelle", "api.jl"))

end
