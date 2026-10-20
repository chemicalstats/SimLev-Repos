"""
Nachgebildete optionale R-Pakete (Suggests des R-Pakets).

R nimmt in einigen Funktionen einen anderen Weg, wenn ein optionales Paket
installiert ist (`requireNamespace(pkg, quietly = TRUE)`). SimLev bildet
`evd`, `rugarch` und `imputeTS` nach und verhält sich standardmäßig wie R mit
diesen Paketen. `ENV["SIMLEV_R_SUGGESTS"]` wählt, welche als installiert gelten
(wird bei jedem Aufruf gelesen): nicht gesetzt oder `all` = alle, `none`
oder leer = keines (wie R ohne die Pakete), sonst eine Liste wie
`"evd,rugarch,imputeTS"`. MSGARCH, plotly und TTR gelten immer als nicht
installiert.
"""
module RSuggests

const EMULATED = ("evd", "rugarch", "imputeTS")

function installed()
    v = get(ENV, "SIMLEV_R_SUGGESTS", nothing)
    v === nothing && return EMULATED
    v = strip(v)
    v == "all" && return EMULATED
    (v == "" || v == "none") && return ()
    want = Set(strip.(split(v, ",")))
    return Tuple(p for p in EMULATED if p in want)
end

"`requireNamespace(pkg, quietly = TRUE)` für die nachgebildeten Pakete."
has(pkg::AbstractString) = pkg in installed()

end # module
