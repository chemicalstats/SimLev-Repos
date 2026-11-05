# ─────────────────────────────────────────────────────────────────────────────
# Interne Hilfen mehrerer Module (seit 1.6.1; bis 1.6.0 je Modul eine Kopie oder Variante): R's
# `match.arg`, `which.max`, `which.min`; seit 1.6.3 auch die wortgleichen kleinen R-Hilfen von Optimize und Tactical
# (`_sprintf`, `_fmt1`, `_ldsum`, `_colmeans`, `_rowsums`, `_mean_lgl`, `_unique`, `_setdiff`, `_strip_nl`).
# Gegenstück python/simlev/_util.py.
# ─────────────────────────────────────────────────────────────────────────────

"""
    _match_arg(arg, choices)

R's `match.arg(arg, choices)` (R 4.3.3, base/R/match.R): `nothing` oder der vollständige
Auswahlvektor ergeben die erste Wahl, eindeutige Präfixe werden ergänzt; Prüfungen und
Meldungen wortgleich zu R. Seit 1.6.1 die einzige Fassung (bis 1.6.0 daneben zwei
Varianten ohne R's Meldungen bei einer Wahl, leerem oder nicht textförmigem Vektor); seit 1.6.3 auch für
config, dashboard, engine, sim_blocks und sim_phases (bis 1.6.2 dort noch `match_arg` aus config.jl, die einen
Vektor mit Symbolen ablehnte und einen nicht textförmigen Vektor, dessen `string()` der ganzen Auswahl glich, als
erste Wahl nahm).
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

# ─────────────────────────────────────────────────────────────────────────────
# Genauere Renditeformeln (seit 1.6.2; gleicher Ausdruck wie .cagr_q, .pow1m, .pow1m_v, .geo_ret, .geo_ann,
# .log1mr2 in r/R/utils.R, Python _util und im Kern): außerhalb der Bereiche, in denen die genaue Fassung dasselbe
# bedeutet, die bisherige Formel.
# ─────────────────────────────────────────────────────────────────────────────
"`q^(1/yrs) - 1` als `expm1(log(q) / yrs)` (q >= 0, yrs endlich und != 0)."
_cagr_q(q::Real, yrs::Real) = (q >= 0 && isfinite(yrs) && yrs != 0) ? RLibm.expm1(RLibm.log(q) / yrs) : r_pow(q, 1 / yrs) - 1
"`(1 + x)^e - 1` als `expm1(log1p(x) * e)` (x >= -1, e endlich und != 0)."
_pow1m(x::Real, e::Real) = (x >= -1 && isfinite(e) && e != 0) ? RLibm.expm1(RLibm.log1p(x) * e) : r_pow(1 + x, e) - 1
"`prod(1 + x) - 1` als `expm1(sum(log1p(x)))` (kein NA, alle x >= -1)."
_geo_ret(x::AbstractVector) = (!any(isnan, x) && all(v -> v >= -1, x)) ? RLibm.expm1(r_sum(RLibm.log1p(x))) : r_prod(1 .+ x) - 1
"`prod(1 + x)^(1/yrs) - 1` als `expm1(sum(log1p(x)) / yrs)` (wie `_geo_ret` und `_cagr_q`)."
_geo_ann(x::AbstractVector, yrs::Real) = (!any(isnan, x) && all(v -> v >= -1, x) && isfinite(yrs) && yrs != 0) ?
    RLibm.expm1(r_sum(RLibm.log1p(x)) / yrs) : r_pow(r_prod(1 .+ x), 1 / yrs) - 1
"`log(1 - r^2)`: `log1p(-r^2)` für r^2 < 1/2, sonst `log((1 - r)(1 + r))` (höchstens 1,4 ulp)."
_log1mr2(r::Real) = r * r < 0.5 ? RLibm.log1p(-(r * r)) : RLibm.log((1 - r) * (1 + r))

# ── Kleine R-Hilfen von Optimize und Tactical (seit 1.6.3 eine Fassung; bis 1.6.2 je eine wortgleiche Kopie) ──

"R-`sprintf` für Skalare → String."
_sprintf(fmt, args...) = (s = RFmt.sprintf(fmt, args...); s isa AbstractString ? String(s) : String(first(s)))
"R-`format(x)` eines Vektors → Zeichenvektor (gemeinsame Breite)."
function _fmt1(x)
    r = RFmt.format(x)
    r isa AbstractString ? [String(r)] : String[String(s) for s in r]
end
"`sum(x)` in long double (sequenziell)."
_ldsum(x) = r_sum(x)
"`colMeans` (long double, Division in long double); 0 Zeilen: NaN je Spalte."
_colmeans(A::AbstractMatrix{Float64}) = size(A, 1) == 0 ? fill(NaN, size(A, 2)) : _ld_colsums(A; mean = true)
"`rowSums` (long double; C-Kern)."
_rowsums(A::AbstractMatrix{Float64}) = _ld_rowsums(A)
"`mean` eines logischen Vektors."
_mean_lgl(x) = r_mean_int(Int[v ? 1 : 0 for v in x])
"`unique` mit erster Reihenfolge (Vergleich mit `in`)."
_unique(v) = (out = similar(v, 0); for s in v; s in out || push!(out, s); end; out)
_setdiff(a, b) = _unique([x for x in a if !(x in b)])
"Text ohne abschließenden Zeilenumbruch."
_strip_nl(s) = endswith(s, "\n") ? s[1:prevind(s, lastindex(s))] : s

"""R's `pmax(a, b)`/`pmin(a, b)` für zwei Skalare mit R's NA/NaN-Regel (`RBase._pext`: `b`, wenn `b` NaN ist oder
gewinnt, sonst `a`). Seit 1.6.3 eine Fassung für Bootstrap, Withdrawal, Overfitting und Tactical (bis 1.6.2 drei
Varianten, die sich nur bei NaN im zweiten Argument bzw. in beiden unterschieden; an allen Aufrufstellen ist ein
Argument eine endliche Konstante oder eine von `withdrawal_horizon()` geprüfte endliche Grenze)."""
_pmax(a::Float64, b::Float64) = isnan(b) ? b : isnan(a) ? a : (b > a ? b : a)
_pmin(a::Float64, b::Float64) = isnan(b) ? b : isnan(a) ? a : (b < a ? b : a)
