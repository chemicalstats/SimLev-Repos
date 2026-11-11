# tests/werkzeuge/precompile_check.jl – Vorkompilier-Arbeitslast von SimLev.jl mit sichtbaren Fehlern (seit 1.6.4,
# K43 T1-N7). Beim Vorkompilieren läuft jeder Schritt in `try` und verschluckt Fehler (das Laden darf nie scheitern);
# bis 1.6.3 brachen so 13 von 21 Schritten unbemerkt ab. Dieses Werkzeug führt dieselbe Arbeitslast im laufenden
# Prozess aus (`SimLev._precompile_check()`), nennt jeden gescheiterten Schritt mit Meldung und endet dann mit 1.
#
#   julia --project=julia tests/werkzeuge/precompile_check.jl
using SimLev

errs = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
    SimLev._precompile_check()
end
for (k, m) in errs
    println("Schritt '", k, "' gescheitert: ", first(split(m, '\n')))
end
println(isempty(errs) ? "Arbeitslast: alle Schritte ohne Fehler" : "Arbeitslast: $(length(errs)) Schritt(e) gescheitert")
exit(isempty(errs) ? 0 : 1)
