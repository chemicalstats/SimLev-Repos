# Herkunft:           nachgebildet nach R 4.3.3, src/library/stats/R/lm.R (Zugriffe), p.adjust.R,
#                     ecdf.R, ave.R, aggregate.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang; seit 1.6.0 rechnen p.adjust und ecdf im C-Kern
#                     core/slc_rbase_models.cpp (sl_r_p_adjust, sl_r_ecdf).
# Generische Zugriffe coef, fitted, residuals sowie p_adjust, ecdf, ave und aggregate aus R 4.3.3
# stats/R/lm.R (Zugriffe), p.adjust.R, ecdf.R, ave.R und aggregate.R; Python: _r/stats_models.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).
#
# Seit 1.0.0 entfallen lm_fit, lm, poly, summary_lm, glm/r_binomial, t_test und das
# generische predict: SimLev rechnet kleinste Quadrate, Logit-IRLS, Polynomfit, r² und den
# Welch-Test selbst (C-Bibliothek slc, SimLev.SLib).

# ── generische Zugriffe ──────────────────────────────────────────────────


"`coef(obj)`."
coef(obj) = obj["coefficients"]
"`fitted(obj)`."
fitted(obj) = obj["fitted.values"]
"`residuals(obj)` (Antwort-Residuen)."
residuals(obj) = obj["residuals"]


# ── p.adjust / ecdf / ave / aggregate ────────────────────────────────────

const _PADJ = ["holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none"]

const _PADJ_CODE = Dict("holm" => 0, "hochberg" => 1, "hommel" => 2, "bonferroni" => 3, "BH" => 4, "BY" => 5, "none" => 6)

"`p.adjust(p, method, n)`."
function p_adjust(p, method::AbstractString = "holm"; n = nothing)
    hits = [m for m in _PADJ if startswith(m, method)]
    method in _PADJ && (hits = [method])
    length(hits) != 1 && error("'arg' should be one of " * join(["“$(m)”" for m in _PADJ], ", "))
    method = hits[1]
    method == "fdr" && (method = "BH")
    pv, nm = _vec(p)
    p0 = copy(pv)
    nna = .!isnan.(pv)
    pp = pv[nna]
    lp = length(pp)
    n === nothing && (n = lp)
    n >= lp || error("n >= lp is not TRUE")
    n <= 1 && return _vec_out(p0, nm)
    r = SimLev._rb_p_adjust(Vector{Float64}(pp), Float64(n), _PADJ_CODE[method])   # C-Kern sl_r_p_adjust (seit 1.6.0)
    p0[nna] = r
    return _vec_out(p0, nm)
end

"`ecdf(x)`: aufrufbare Treppenfunktion (ApproxFun, attrs nobs)."
function ecdf(x)
    vals, yv, n = SimLev._rb_ecdf(Vector{Float64}(_v(x)))   # C-Kern sl_r_ecdf (seit 1.6.0)
    return ApproxFun(vals, yv, 2, 0.0, 1.0, 0.0, Dict{String,Any}("nobs" => n, "class" => ["ecdf", "stepfun", "function"]))
end

_gkey(v) = v isa AbstractFloat ? _z0(Float64(v)) : v
const _isna_el = SimLev._isna   # r/rnum.jl (seit 1.6.3)
_grpvals(g) = g isa RVector ? g.values : g isa AbstractArray ? vec(g) : [g]

"`ave(x, ..., FUN = mean)`; FUN erhält einen Vector."
function ave(x, groups...; FUN = nothing)
    xv, nm = _vec(x)
    FUN === nothing && (FUN = _rmean)
    out = copy(xv)
    if isempty(groups)
        r = _v(FUN(xv))
        for i in eachindex(out)
            out[i] = r[(i - 1) % length(r) + 1]
        end
        return _vec_out(out, nm)
    end
    gs = [_grpvals(g) for g in groups]
    d = Dict{Any,Vector{Int}}()
    keys_ = Any[]
    for i in eachindex(xv)
        k = Tuple(_gkey(g[i]) for g in gs)
        any(_isna_el, k) && continue
        haskey(d, k) || (d[k] = Int[]; push!(keys_, k))
        push!(d[k], i)
    end
    # Gruppen in der Reihenfolge von interaction(...): Stufen wie factor()
    # (Zahlen numerisch, Zeichenketten nach R's Kollation), erste Variable
    # läuft am schnellsten
    pos = Dict{Any,Int}[]
    for g in gs
        ok = [!_isna_el(v) for v in g]
        lv = any(ok) ? r_sort(unique(_gkey.(g[ok]))) : Any[]
        lv isa AbstractVector || (lv = [lv])
        push!(pos, Dict{Any,Int}(_gkey(v) => i for (i, v) in enumerate(lv)))
    end
    sort!(keys_; by = k -> Tuple(pos[j][k[j]] for j in length(k):-1:1))
    for k in keys_
        ix = d[k]
        r = _v(FUN(xv[ix]))
        for (t, i) in enumerate(ix)
            out[i] = r[(t - 1) % length(r) + 1]
        end
    end
    return _vec_out(out, nm)
end

_bypairs(by::AbstractDict) = [(string(k), v) for (k, v) in by]
_bypairs(by::NamedTuple) = [(string(k), v) for (k, v) in pairs(by)]
_bypairs(by::AbstractVector{<:Pair}) = [(string(p.first), p.second) for p in by]

"`aggregate(x, by = list(name = g, ...), FUN)` für einen Vektor x: RFrame mit den Gruppenspalten und x."
function aggregate(x, by, FUN)
    xv = _v(x)
    bp = _bypairs(by)
    names_ = [b[1] for b in bp]
    levels = Vector{Any}[]
    codes = Vector{Int}[]
    for (_, g0) in bp
        g = _grpvals(g0)
        ok = [!_isna_el(v) for v in g]
        lv = collect(r_sort(unique(_gkey.(g[ok]))) |> (t -> t isa AbstractVector ? t : [t]))
        push!(levels, lv)
        pos = Dict{Any,Int}(_gkey(v) => i for (i, v) in enumerate(lv))
        push!(codes, [ok[i] ? get(pos, _gkey(g[i]), 0) : 0 for i in eachindex(g)])
    end
    combos = Dict{Vector{Int},Vector{Int}}()
    for i in eachindex(xv)
        key = [c[i] for c in codes]
        any(==(0), key) && continue
        push!(get!(combos, key, Int[]), i)
    end
    function grp(key)
        g = 0; mult = 1
        for (k, lv) in zip(key, levels)
            g += (k - 1) * mult
            mult *= length(lv)
        end
        g
    end
    ks = sort(collect(keys(combos)); by = grp)
    cols = Pair{String,Any}[]
    for (j, nm) in enumerate(names_)
        push!(cols, nm => [levels[j][k[j]] for k in ks])
    end
    push!(cols, "x" => Float64[first(_v(FUN(xv[combos[k]]))) for k in ks])
    return RFrame(cols...)
end


