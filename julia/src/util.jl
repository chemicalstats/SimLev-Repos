# ─────────────────────────────────────────────────────────────────────────────
# Interne Hilfen mehrerer Module (seit 1.6.1; bis 1.6.0 je Modul eine Kopie oder Variante): R's
# `match.arg`, `which.max`, `which.min`. Gegenstück python/simlev/_util.py.
# ─────────────────────────────────────────────────────────────────────────────

"""
    _match_arg(arg, choices)

R's `match.arg(arg, choices)` (R 4.3.3, base/R/match.R): `nothing` oder der vollständige
Auswahlvektor ergeben die erste Wahl, eindeutige Präfixe werden ergänzt; Prüfungen und
Meldungen wortgleich zu R. Seit 1.6.1 die einzige Fassung (bis 1.6.0 daneben zwei
Varianten ohne R's Meldungen bei einer Wahl, leerem oder nicht textförmigem Vektor).
"""
function _match_arg(value, choices)
    choices = String[String(c) for c in choices]
    value === nothing && return choices[1]
    if value isa Union{AbstractVector,Tuple}
        all(v -> v isa Union{AbstractString,Symbol}, value) || error("'arg' must be NULL or a character vector")
        String[String(v) for v in value] == choices && return choices[1]
        length(value) > 1 && error("'arg' must be of length 1")
        value = isempty(value) ? "" : first(value)
    end
    value isa Union{AbstractString,Symbol} || error("'arg' must be NULL or a character vector")
    v = String(value)
    i = findfirst(==(v), choices)
    if i === nothing && !isempty(v)
        hits = findall(c -> startswith(c, v), choices)
        length(hits) == 1 && (i = hits[1])
    end
    if i === nothing
        chs = unique(filter(!isempty, choices))
        error((length(chs) == 1 ? "'arg' should be " : "'arg' should be one of ") * join(("“$(c)”" for c in chs), ", "))
    end
    choices[i]
end

"R's `which.max`: erster Index des größten Werts, NaN (und NA) übergangen; `nothing`, wenn es keinen gibt (R: `integer(0)`)."
function _which_max(v)
    k = 0; m = -Inf
    for i in eachindex(v)
        x = Float64(v[i])
        isnan(x) && continue
        if k == 0 || x > m
            k = i; m = x
        end
    end
    k == 0 ? nothing : k
end

"R's `which.min` wie [`_which_max`](@ref)."
function _which_min(v)
    k = 0; m = Inf
    for i in eachindex(v)
        x = Float64(v[i])
        isnan(x) && continue
        if k == 0 || x < m
            k = i; m = x
        end
    end
    k == 0 ? nothing : k
end
