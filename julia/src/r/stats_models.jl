# Generische Zugriffe coef, fitted, residuals sowie p_adjust, ecdf, ave und aggregate aus R 4.3.3
# stats/R/lm.R (Zugriffe), p.adjust.R, ecdf.R, ave.R und aggregate.R; Python: _r/stats_models.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).
#
# Seit Etappe 9.6c entfallen lm_fit, lm, poly, summary_lm, glm/r_binomial, t_test und das
# generische predict: SimLev rechnet kleinste Quadrate, Logit-IRLS, Polynomfit, r² und den
# Welch-Test selbst (C-Bibliothek slc, SimLev.SLib; Entwurf B.7, B.16).

# ── generische Zugriffe ──────────────────────────────────────────────────


"`coef(obj)`."
coef(obj) = obj["coefficients"]
"`fitted(obj)`."
fitted(obj) = obj["fitted.values"]
"`residuals(obj)` (Antwort-Residuen)."
residuals(obj) = obj["residuals"]

_vals(x) = x isa RVector ? Float64[_fl(v) for v in x.values] : x isa AbstractArray ? Float64[_fl(v) for v in vec(x)] : Float64[_fl(x)]


# ── p.adjust / ecdf / ave / aggregate ────────────────────────────────────

const _PADJ = ["holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none"]

function _cumext(x, greater::Bool)
    out = similar(x)
    m = greater ? -Inf : Inf
    for (k, v) in enumerate(x)
        if isnan(v)
            out[k:end] .= NA
            return out
        end
        m = greater ? (m > v ? m : v) : (m < v ? m : v)
        out[k] = m
    end
    out
end
_pmin1(x) = Float64[isnan(t) ? t : (t < 1.0 ? t : 1.0) for t in x]

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
    (n == 2 && method == "hommel") && (method = "hochberg")
    if method == "bonferroni"
        r = _pmin1(n .* pp)
    elseif method == "holm"
        i = 1:lp
        o = order(pp)
        ro = order(Float64.(o))
        r = _pmin1(_cumext(Float64.(n + 1 .- i) .* pp[o], true))[ro]
    elseif method == "hommel"
        nn_ = Int(n)
        q_p = n > lp ? vcat(pp, ones(nn_ - lp)) : copy(pp)
        i = 1:nn_
        o = order(q_p)
        q_p = q_p[o]
        ro = order(Float64.(o))
        mn = minimum(nn_ .* q_p ./ i)
        q = fill(mn, nn_)
        pa = fill(mn, nn_)
        for j in nn_-1:-1:2
            ij = 1:(nn_-j+1)
            i2 = (nn_-j+2):nn_
            q1 = minimum(j .* q_p[i2] ./ (2:j))
            q[ij] = min.(j .* q_p[ij], q1)
            q[i2] .= q[nn_-j+1]
            pa = max.(pa, q)
        end
        r = max.(pa, q_p)[lp < nn_ ? ro[1:lp] : ro]
    elseif method in ("hochberg", "BH", "BY")
        i = lp:-1:1
        o = order(pp; decreasing = true)
        ro = order(Float64.(o))
        if method == "hochberg"
            r = _pmin1(_cumext(Float64.(n + 1 .- i) .* pp[o], false))[ro]
        elseif method == "BH"
            r = _pmin1(_cumext((n ./ i) .* pp[o], false))[ro]
        else
            q = _rsum(1.0 ./ (1:Int(n)))
            r = _pmin1(_cumext((q * n ./ i) .* pp[o], false))[ro]
        end
    else
        r = pp
    end
    p0[nna] = r
    return _vec_out(p0, nm)
end

"`ecdf(x)`: aufrufbare Treppenfunktion (ApproxFun, attrs nobs)."
function ecdf(x)
    xs = sort(filter(!isnan, _v(x)); lt = <)
    n = length(xs)
    n < 1 && error("'x' must have 1 or more non-missing values")
    vals, gidx = _unique_keys(xs)
    counts = zeros(Int, length(vals))
    for g in gidx
        counts[g] += 1
    end
    yv = Float64.(cumsum(counts)) ./ n
    return ApproxFun(vals, yv, 2, 0.0, 1.0, 0.0, Dict{String,Any}("nobs" => n, "class" => ["ecdf", "stepfun", "function"]))
end

_gkey(v) = v isa AbstractFloat ? _z0(Float64(v)) : v
_isna_el(v) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))
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


