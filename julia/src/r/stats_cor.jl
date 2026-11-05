# Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/cov.c; nachgebildet nach R 4.3.3,
#                     src/library/stats/R/cor.R; src/library/base/R/scale.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Kovarianz und Korrelation rechnet der C-Kern
#                     core/slc_rbase_cov.cpp.
# Kovarianz und Korrelation (cor, cov, var, sd, cov2cor) sowie scale aus R 4.3.3 stats/src/cov.c,
# stats/R/cor.R und base/R/scale.R; Python: _r/stats_cor.py. rechnet der Kern von cov/cor
# (pearson, kendall; alle `use`) in C (core/slc_rbase_cov.cpp, gemeinsam mit Python).
# Teil des Untermoduls RStats (eingebunden in stats.jl).

# ── cov / cor (cov.c) ────────────────────────────────────────────────────

const _USE = ["all.obs", "complete.obs", "pairwise.complete.obs", "everything", "na.or.complete"]

function _pmatch_use(use::AbstractString)
    hits = [i for (i, u) in enumerate(_USE) if startswith(u, use)]
    if length(hits) != 1
        use in _USE && return findfirst(==(use), _USE)
        error("invalid 'use' argument")
    end
    return hits[1]
end

_fmat(m::AbstractMatrix) = Float64[_fl(v) for v in m]

"→ (Matrix n×nc, ist_Matrix, Spaltennamen)."
function _as_cov_input(x)
    x isa RFrame && return (hcat([Float64[_fl(v) for v in c] for c in x.cols]...)::Matrix{Float64}, true, names(x))
    x isa NamedMat && return (_fmat(x.data), true, x.colnames)
    x isa AbstractMatrix && return (_fmat(x), true, nothing)
    v = _v(x)
    return (reshape(v, :, 1), false, nothing)
end
_is_matlike(x) = x isa RFrame || x isa AbstractMatrix

"R's `cor`/`cov` mit `use` als Zahl 1–5 (C-Kern `sl_r_cov`)."
function _corcov(x, y, method_na::Int, kendall::Bool, cor::Bool)
    X, xmat, xcn = _as_cov_input(x)
    n, ncx = size(X)
    ansmat = xmat
    if y === nothing
        Y = nothing; ncy = ncx; ycn = nothing
    else
        Y, ymat, ycn = _as_cov_input(y)
        size(Y, 1) != n && error("incompatible dimensions")
        ymat && (ansmat = true)
        ncy = size(Y, 2)
    end
    1 <= method_na <= 5 || error("invalid 'use' (computational method)")
    (method_na == 2 && isempty(X)) && error("no complete element pairs")
    (method_na in (1, 2, 3) && isempty(X)) && error("'x' is empty")
    ans, sd0 = SimLev._rb_cov(vec(Matrix{Float64}(X)), n, ncx, Y === nothing ? nothing : vec(Matrix{Float64}(Y)), ncy,
                              method_na, kendall, cor)
    sd0 && @warn "the standard deviation is zero"
    if ansmat
        return y === nothing ? _out(ans, xcn, xcn) : _out(ans, xcn, ycn)
    end
    return _vec_out(vec(ans))
end

const _COR_METHODS = Dict("pearson" => 0, "kendall" => 1, "spearman" => 2)

"R's `cor`/`cov` (C-Kern `sl_r_cor`, seit 1.6.0: Ränge, NA-Regeln und paarweise Rangkorrelation im Kern)."
function _cor_cov(x, y, use, method, cor::Bool)
    na_method = _pmatch_use(use)
    haskey(_COR_METHODS, method) || error("'arg' should be one of “pearson”, “kendall”, “spearman”")
    (!_is_matlike(x) && y === nothing) && error("supply both 'x' and 'y' or a matrix-like 'x'")
    X, xmat, xcn = _as_cov_input(x)
    n, ncx = size(X)
    ansmat = xmat
    Y = nothing; ycn = nothing; ncy = ncx; ymat = false
    if y !== nothing
        Y, ymat, ycn = _as_cov_input(y)
        size(Y, 1) != n && error("incompatible dimensions")
        ymat && (ansmat = true)
        ncy = size(Y, 2)
    end
    r, sd0 = SimLev._rb_cor(vec(Matrix{Float64}(X)), n, ncx, xmat, Y === nothing ? nothing : vec(Matrix{Float64}(Y)),
                            ncy, ymat, na_method, _COR_METHODS[method], cor)
    sd0 && @warn "the standard deviation is zero"
    if na_method == 3 && method != "pearson" && y === nothing && ncx == 1
        d = r[1, 1]
        isnan(d) && error("invalid 'nrow' value (too large or NA)")
        m = trunc(Int, d)
        m < 0 && error("invalid 'nrow' value (< 0)")
        m != 1 && error("non-conformable arrays")
        r = (r .+ r) .- 1.0
    end
    ansmat && return y === nothing ? _out(r, xcn, xcn) : _out(r, xcn, ycn)
    return _vec_out(vec(r))
end

"`cor(x, y, use, method)`: pearson, kendall, spearman."
cor(x, y = nothing; use::AbstractString = "everything", method::AbstractString = "pearson") = _cor_cov(x, y, use, method, true)
"`cov(x, y, use, method)`."
cov(x, y = nothing; use::AbstractString = "everything", method::AbstractString = "pearson") = _cor_cov(x, y, use, method, false)

"`var(x, y, na.rm, use)`."
function var(x, y = nothing; na_rm::Bool = false, use = nothing)
    use === nothing && (use = na_rm ? "na.or.complete" : "everything")
    return _corcov(x, y, _pmatch_use(use), false, false)
end

"`sd(x, na.rm)` = `sqrt(var(x, na.rm))`."
function sd(x; na_rm::Bool = false)
    x = _is_matlike(x) ? _v(x) : x
    v = var(x; na_rm = na_rm)
    return isnan(v) ? v : _csqrt(v)
end

"`cov2cor(V)`."
function cov2cor(V)
    X, ismat, cn = _as_cov_input(V)
    (ismat && size(X, 1) == size(X, 2)) || error("'V' is not a square numeric matrix")
    rn = V isa NamedMat ? V.rownames : V isa RFrame ? V.rownames : nothing
    p = size(X, 1)
    r, warn = SimLev._rb_cov2cor(Matrix{Float64}(X))   # C-Kern sl_r_cov2cor (seit 1.6.0)
    warn && @warn "diag(V) had non-positive or NA entries; the non-finite result may be dubious"
    return _out(r, rn, cn)
end

"""
    scale(x; center = true, scale = true)

`scale.default(x, center, scale)`: NamedMat mit den Attributen
"scaled:center" und "scaled:scale" (`attrs(m)`).
"""
function scale(x; center = true, scale = true)
    X, _, cn = _as_cov_input(x)
    X = copy(X)
    rn = x isa NamedMat ? x.rownames : x isa RFrame ? x.rownames : x isa RVector ? x.names : nothing
    nc = size(X, 2)
    cen = nothing; sc = nothing
    cm = center isa Bool ? Int(center) : 2
    if cm == 2
        cen = collect(Float64, _v(center))
        length(cen) != nc && error("length of 'center' must equal the number of columns of 'x'")
    end
    sm = scale isa Bool ? Int(scale) : 2
    if sm == 2
        sc = collect(Float64, _v(scale))
        length(sc) != nc && error("length of 'scale' must equal the number of columns of 'x'")
    end
    cm == 1 && (cen = zeros(nc))
    sm == 1 && (sc = zeros(nc))
    X = Matrix{Float64}(X)
    SimLev._rb_scale!(X, cm, cen === nothing ? zeros(nc) : cen, sm, sc === nothing ? zeros(nc) : sc)   # C-Kern (seit 1.6.0)
    at = Dict{String,Any}()
    cen === nothing || (at["scaled:center"] = _vec_out(cen, cn))
    sc === nothing || (at["scaled:scale"] = _vec_out(sc, cn))
    return NamedMat(X; rownames = rn, colnames = cn, attrs = at)
end
