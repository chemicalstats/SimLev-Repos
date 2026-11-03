# Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/cov.c; nachgebildet nach R 4.3.3,
#                     src/library/stats/R/cor.R; src/library/base/R/scale.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Kovarianz und Korrelation rechnet der C-Kern
#                     core/slc_rbase_cov.c.
# Kovarianz und Korrelation (cor, cov, var, sd, cov2cor) sowie scale aus R 4.3.3 stats/src/cov.c,
# stats/R/cor.R und base/R/scale.R; Python: _r/stats_cor.py. rechnet der Kern von cov/cor
# (pearson, kendall; alle `use`) in C (core/slc_rbase_cov.c, gemeinsam mit Python).
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

function _rank_cols(u)
    X, ismat, cn = _as_cov_input(u)
    isempty(X) && return u
    if ismat
        nr, nc = size(X)
        R = nr > 1 ? hcat([Float64[_fl(t) for t in _ranks_keep(X[:, j])] for j in 1:nc]...) :
            Float64[i for i in 1:nr, j in 1:nc]
        rn = u isa RFrame ? u.rownames : u isa NamedMat ? u.rownames : nothing
        return _out(R, rn, cn)
    end
    return Float64[_fl(t) for t in _ranks_keep(vec(X))]
end
function _ranks_keep(v)
    r = r_rank(v; na_last = "keep")
    r isa RVector ? r.values : r isa AbstractVector ? r : [r]
end

function _drop_rows(x, keep::AbstractVector{Bool})
    x isa RFrame && return SimLev.rows(x, keep)
    x isa NamedMat && return NamedMat(x.data[keep, :]; rownames = x.rownames === nothing ? nothing : x.rownames[keep],
                                      colnames = x.colnames)
    x isa AbstractMatrix && return x[keep, :]
    x isa RVector && return RVector(x.values[keep]; names = x.names === nothing ? nothing : x.names[keep])
    return _v(x)[keep]
end
function _na_omit_rows(x)
    X, _, _ = _as_cov_input(x)
    keep = Bool[!any(isnan, view(X, i, :)) for i in 1:size(X, 1)]
    _drop_rows(x, keep)
end

function _cor_cov(x, y, use, method, cor::Bool)
    na_method = _pmatch_use(use)
    method in ("pearson", "kendall", "spearman") || error("'arg' should be one of “pearson”, “kendall”, “spearman”")
    (!_is_matlike(x) && y === nothing) && error("supply both 'x' and 'y' or a matrix-like 'x'")
    method == "pearson" && return _corcov(x, y, na_method, false, cor)
    kend = method == "kendall"
    if na_method in (2, 5)
        y === nothing && return _corcov(_rank_cols(_na_omit_rows(x)), nothing, na_method, kend, cor)
        X, _, _ = _as_cov_input(x)
        Y, _, _ = _as_cov_input(y)
        keep = Bool[!(any(isnan, view(X, i, :)) || any(isnan, view(Y, i, :))) for i in 1:size(X, 1)]
        return _corcov(_rank_cols(_drop_rows(x, keep)), _rank_cols(_drop_rows(y, keep)), na_method, kend, cor)
    end
    if na_method != 3
        return _corcov(_rank_cols(x), y === nothing ? nothing : _rank_cols(y), na_method, kend, cor)
    end
    cor || error("cannot handle 'pairwise.complete.obs'")
    X, xmat, xcn = _as_cov_input(x)
    rk(v) = (rr_ = r_rank(v); Float64[_fl(t) for t in (rr_ isa AbstractVector ? rr_ : [rr_])])
    if y === nothing
        ncx = size(X, 2)
        ncx == 0 && error("'x' is empty")
        r = zeros(ncx, ncx)
        for i in 1:ncx, j in 1:i
            x2 = X[:, i]; y2 = X[:, j]
            ok = .!(isnan.(x2) .| isnan.(y2))
            r[i, j] = any(ok) ? _corcov(rk(x2[ok]), rk(y2[ok]), 1, kend, true) : NA
        end
        if ncx == 1
            d = r[1, 1]
            isnan(d) && error("invalid 'nrow' value (too large or NA)")
            m = trunc(Int, d)
            m < 0 && error("invalid 'nrow' value (< 0)")
            m != 1 && error("non-conformable arrays")
            r = (r .+ r) .- 1.0
        else
            rt = permutedims(r)
            r = Float64[(r[i, j] + rt[i, j]) - (i == j ? r[i, i] : 0.0) for i in 1:ncx, j in 1:ncx]
        end
        return _out(r, xcn, xcn)
    end
    Y, ymat, ycn = _as_cov_input(y)
    (isempty(X) || isempty(Y)) && error("both 'x' and 'y' must be non-empty")
    r = zeros(size(X, 2), size(Y, 2))
    for i in 1:size(X, 2), j in 1:size(Y, 2)
        x2 = X[:, i]; y2 = Y[:, j]
        ok = .!(isnan.(x2) .| isnan.(y2))
        r[i, j] = any(ok) ? _corcov(rk(x2[ok]), rk(y2[ok]), 1, kend, true) : NA
    end
    (xmat || ymat) && return _out(r, xcn, ycn)
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
    D = [X[i, i] for i in 1:p]
    pos = [!isnan(d) && d > 0 for d in D]
    Is = [pos[i] ? sqrt(1.0 / D[i]) : NaN for i in 1:p]
    (any(.!pos) || any(!isfinite, Is)) && @warn "diag(V) had non-positive or NA entries; the non-finite result may be dubious"
    r = Matrix{Float64}(undef, p, p)
    for j in 1:p, i in 1:p
        v = (Is[i] * X[i, j]) * Is[j]
        # R: Ergebnis genau dann NA, wenn V[i,j] NA ist; jedes andere NaN ist NaN
        isnan(v) && (v = isna_strict(X[i, j]) ? NA : NaN)
        r[i, j] = v
    end
    for i in 1:p
        r[i, i] = 1.0
    end
    return _out(r, rn, cn)
end

"`colMeans(x, na.rm = TRUE)` einer Spalte (long-double-Summe / Anzahl, C-Kern)."
_colmean_narm(col) = SimLev._rb_margsums(collect(Float64, col), length(col), 1, true, true, false)[1]

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
    if center isa Bool
        if center
            cen = [_colmean_narm(X[:, j]) for j in 1:nc]
            X = X .- permutedims(cen)
        end
    else
        cen = _v(center)
        length(cen) != nc && error("length of 'center' must equal the number of columns of 'x'")
        X = X .- permutedims(cen)
    end
    if scale isa Bool
        if scale
            sc = zeros(nc)
            for j in 1:nc
                v = filter(!isnan, X[:, j])
                sc[j] = _csqrt(_rsum(v .* v) / max(1, length(v) - 1))
            end
            X = X ./ permutedims(sc)
        end
    else
        sc = _v(scale)
        length(sc) != nc && error("length of 'scale' must equal the number of columns of 'x'")
        X = X ./ permutedims(sc)
    end
    at = Dict{String,Any}()
    cen === nothing || (at["scaled:center"] = _vec_out(cen, cn))
    sc === nothing || (at["scaled:scale"] = _vec_out(sc, cn))
    return NamedMat(X; rownames = rn, colnames = cn, attrs = at)
end
