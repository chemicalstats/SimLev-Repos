# Öffentliche Schnittstelle gegen den eingefrorenen Stand (Etappe 6.6).
#
# Lädt den Julia-Auszug tests/api/api_jl.jl (ohne seinen Skriptteil)
# in ein eigenes Modul und vergleicht `names(SimLev)` und die registrierten
# show/r_summary/r_plot-Methoden mit tests/api/frozen/jl.json:
# Funktionen und Methoden, Argumente in Reihenfolge, Art (positionell/
# Schlüsselwort), Standardwerte, dazu die Namen der exportierten Typen. Die
# Meldung nennt jede Abweichung und wie man den Stand bewusst neu festschreibt
# (Eintrag in tests/api/CHANGES.md, dann tests/api/run.sh --freeze).

module _ApiFrozen
const REPO = normpath(joinpath(@__DIR__, "..", ".."))
const SCRIPT = joinpath(REPO, "tests", "api", "api_jl.jl")
const FROZEN = joinpath(REPO, "tests", "api", "frozen", "jl.json")
const AVAILABLE = isfile(SCRIPT) && isfile(FROZEN)
AVAILABLE && cd(() -> include(SCRIPT), REPO)   # api_jl.jl liest relativ zur Repo-Wurzel
end

@testset "Schnittstelle gegen frozen/jl.json" begin
    if !_ApiFrozen.AVAILABLE
        @info "tests/api/frozen/jl.json fehlt"
        @test_skip false
    else
        ok, report = cd(() -> Base.invokelatest(_ApiFrozen.frozen_check, _ApiFrozen.FROZEN), _ApiFrozen.REPO)
        ok || println(report)
        @test ok
    end
end
