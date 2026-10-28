# Kovarianz und Korrelation (cor, cov, var, sd, cov2cor) sowie scale aus R 4.3.3 stats/src/cov.c,
# stats/R/cor.R und base/R/scale.R; Python: _r/stats_cor.py.
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

"MEAN-Makro: zwei Durchläufe in long double; Ergebnis double."
function _mean_ld(col::AbstractVector{Float64})
    nobs = length(col)
    s = _LD0
    for v in col
        s = s + F80(v)
    end
    tmp = s / F80(nobs)
    if isfinite(Float64(tmp))
        s2 = _LD0
        for v in col
            s2 = s2 + (F80(v) - tmp)
        end
        tmp = tmp + s2 / F80(nobs)
    end
    return Float64(tmp)
end

"sum (LD)(a - am) * (b - bm)."
function _ld_cross(a, am::Float64, b, bm::Float64)
    s = _LD0
    lam = F80(am); lbm = F80(bm)
    @inbounds for i in eachindex(a)
        s = s + (F80(a[i]) - lam) * (F80(b[i]) - lbm)
    end
    s
end

@inline _isign(d::Float64) = d > 0 ? 1 : d < 0 ? -1 : 0

function _kendall_sum(xx, yy)
    n = length(xx)
    tot = 0
    @inbounds for k in 1:n, j in 1:n
        tot += _isign(xx[k] - xx[j]) * _isign(yy[k] - yy[j])
    end
    Float64(tot)
end

function _kendall_count_ne(xx)
    n = length(xx)
    tot = 0
    @inbounds for k in 1:n, j in 1:n
        xx[k] != xx[j] && (tot += 1)
    end
    Float64(tot)
end

_clamp1(v::Float64) = v >= 1.0 ? 1.0 : (v <= -1.0 ? -1.0 : v)

function _cov_complete1!(X, ind, ans, sd0, cor, kendall)
    n, ncx = size(X)
    nobs = count(ind)
    if nobs <= 1
        fill!(ans, NA)
        return
    end
    Xi = X[ind, :]
    xm = zeros(ncx)
    kendall || (for i in 1:ncx; xm[i] = _mean_ld(view(Xi, :, i)); end)
    n1 = nobs - 1
    for i in 1:ncx, j in 1:i
        if !kendall
            s = _ld_cross(view(Xi, :, i), xm[i], view(Xi, :, j), xm[j])
            ans[i, j] = ans[j, i] = Float64(s / F80(n1))
        else
            ans[i, j] = ans[j, i] = _kendall_sum(view(Xi, :, i), view(Xi, :, j))
        end
    end
    if cor
        for i in 1:ncx
            xm[i] = _csqrt(ans[i, i])
        end
        for i in 1:ncx
            for j in 1:i-1
                if xm[i] == 0 || xm[j] == 0
                    sd0[] = true
                    ans[i, j] = ans[j, i] = NA
                else
                    ans[i, j] = ans[j, i] = _clamp1(ans[i, j] / (xm[i] * xm[j]))
                end
            end
            ans[i, i] = 1.0
        end
    end
end

function _cov_na_1!(X, has_na, ans, sd0, cor, kendall)
    n, ncx = size(X)
    if n <= 1
        fill!(ans, NA)
        return
    end
    xm = fill(NaN, ncx)
    if !kendall
        for i in 1:ncx
            xm[i] = has_na[i] ? NA : _mean_ld(view(X, :, i))
        end
    end
    n1 = n - 1
    for i in 1:ncx
        if has_na[i]
            for j in 1:i
                ans[i, j] = NA; ans[j, i] = NA
            end
            continue
        end
        for j in 1:i
            if has_na[j]
                ans[i, j] = ans[j, i] = NA
            elseif !kendall
                ans[i, j] = ans[j, i] = Float64(_ld_cross(view(X, :, i), xm[i], view(X, :, j), xm[j]) / F80(n1))
            else
                ans[i, j] = ans[j, i] = _kendall_sum(view(X, :, i), view(X, :, j))
            end
        end
    end
    if cor
        for i in 1:ncx
            has_na[i] || (xm[i] = _csqrt(ans[i, i]))
        end
        for i in 1:ncx
            if !has_na[i]
                for j in 1:i-1
                    if xm[i] == 0 || xm[j] == 0
                        sd0[] = true
                        ans[i, j] = ans[j, i] = NA
                    else
                        ans[i, j] = ans[j, i] = _clamp1(ans[i, j] / (xm[i] * xm[j]))
                    end
                end
            end
            ans[i, i] = 1.0
        end
    end
end

"COV_SDEV aus cov_complete2/cov_na_2: (double) SQRTL(sum)."
function _sdev2(col, m, n1, kendall)
    s = kendall ? F80(_kendall_count_ne(col)) : _ld_cross(col, m, col, m) / F80(n1)
    return Float64(_ldsqrt(s))
end

function _cov_complete2!(X, Y, ind, ans, sd0, cor, kendall)
    ncx = size(X, 2); ncy = size(Y, 2)
    nobs = count(ind)
    if nobs <= 1
        fill!(ans, NA)
        return
    end
    Xi = X[ind, :]; Yi = Y[ind, :]
    xm = zeros(ncx); ym = zeros(ncy)
    n1 = nobs - 1
    if !kendall
        for i in 1:ncx; xm[i] = _mean_ld(view(Xi, :, i)); end
        for i in 1:ncy; ym[i] = _mean_ld(view(Yi, :, i)); end
    end
    for i in 1:ncx, j in 1:ncy
        if !kendall
            ans[i, j] = Float64(_ld_cross(view(Xi, :, i), xm[i], view(Yi, :, j), ym[j]) / F80(n1))
        else
            ans[i, j] = _kendall_sum(view(Xi, :, i), view(Yi, :, j))
        end
    end
    if cor
        xs = [_sdev2(view(Xi, :, i), xm[i], n1, kendall) for i in 1:ncx]
        ys = [_sdev2(view(Yi, :, j), ym[j], n1, kendall) for j in 1:ncy]
        for i in 1:ncx, j in 1:ncy
            if xs[i] == 0.0 || ys[j] == 0.0
                sd0[] = true
                ans[i, j] = NA
            else
                ans[i, j] = _clamp1(ans[i, j] / (xs[i] * ys[j]))
            end
        end
    end
end

function _cov_na_2!(X, Y, hx, hy, ans, sd0, cor, kendall)
    n, ncx = size(X); ncy = size(Y, 2)
    if n <= 1
        fill!(ans, NA)
        return
    end
    xm = zeros(ncx); ym = zeros(ncy)
    n1 = n - 1
    if !kendall
        for i in 1:ncx; xm[i] = hx[i] ? NA : _mean_ld(view(X, :, i)); end
        for i in 1:ncy; ym[i] = hy[i] ? NA : _mean_ld(view(Y, :, i)); end
    end
    for i in 1:ncx
        if hx[i]
            ans[i, :] .= NA
            continue
        end
        for j in 1:ncy
            if hy[j]
                ans[i, j] = NA
            elseif !kendall
                ans[i, j] = Float64(_ld_cross(view(X, :, i), xm[i], view(Y, :, j), ym[j]) / F80(n1))
            else
                ans[i, j] = _kendall_sum(view(X, :, i), view(Y, :, j))
            end
        end
    end
    if cor
        xs = [hx[i] ? NA : _sdev2(view(X, :, i), xm[i], n1, kendall) for i in 1:ncx]
        ys = [hy[j] ? NA : _sdev2(view(Y, :, j), ym[j], n1, kendall) for j in 1:ncy]
        for i in 1:ncx
            hx[i] && continue
            for j in 1:ncy
                hy[j] && continue
                if xs[i] == 0.0 || ys[j] == 0.0
                    sd0[] = true
                    ans[i, j] = NA
                else
                    ans[i, j] = _clamp1(ans[i, j] / (xs[i] * ys[j]))
                end
            end
        end
    end
end

function _cov_pairwise!(X, Y, ans, sd0, cor, kendall, sym)
    ncx = size(X, 2); ncy = size(Y, 2)
    for i in 1:ncx
        for j in (sym ? (1:i) : (1:ncy))
            xx = view(X, :, i); yy = view(Y, :, j)
            ok = .!(isnan.(xx) .| isnan.(yy))
            nobs = count(ok)
            if nobs >= 2
                xo = xx[ok]; yo = yy[ok]
                n1 = nobs - 1
                if !kendall
                    xmean = _ldsum(xo) / F80(nobs)
                    ymean = _ldsum(yo) / F80(nobs)
                    s = _LD0; xsd = _LD0; ysd = _LD0
                    for k in 1:nobs
                        xmd = F80(xo[k]) - xmean
                        ymd = F80(yo[k]) - ymean
                        s = s + xmd * ymd
                        xsd = xsd + xmd * xmd
                        ysd = ysd + ymd * ymd
                    end
                else
                    s = _LD0; xsd = _LD0; ysd = _LD0
                    for k in 1:nobs
                        t1 = 0; t2 = 0; t3 = 0
                        for l in 1:k-1
                            sx = _isign(xo[k] - xo[l]); sy = _isign(yo[k] - yo[l])
                            t1 += sx * sy; t2 += sx * sx; t3 += sy * sy
                        end
                        s = s + F80(t1); xsd = xsd + F80(t2); ysd = ysd + F80(t3)
                    end
                end
                if cor
                    if _ldiszero(xsd) || _ldiszero(ysd)
                        sd0[] = true
                        val = NA
                    else
                        if !kendall
                            xsd = xsd / F80(n1); ysd = ysd / F80(n1); s = s / F80(n1)
                        end
                        s = s / (_ldsqrt(xsd) * _ldsqrt(ysd))
                        c1 = _ldcmp(s, F80(1.0)); c2 = _ldcmp(s, F80(-1.0))
                        s = (c1 == 0 || c1 == 1) ? F80(1.0) : ((c2 == 0 || c2 == -1) ? F80(-1.0) : s)
                        val = Float64(s)
                    end
                elseif !kendall
                    val = Float64(s / F80(n1))
                else
                    val = Float64(s)
                end
                ans[i, j] = val
            else
                ans[i, j] = NA
            end
            sym && (ans[j, i] = ans[i, j])
        end
    end
end

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
    na_fail = false; everything = false; empty_err = true; pair = false
    if method_na == 1
        na_fail = true
    elseif method_na == 2
        isempty(X) && error("no complete element pairs")
    elseif method_na == 3
        pair = true
    elseif method_na == 4
        everything = true; empty_err = false
    elseif method_na == 5
        empty_err = false
    else
        error("invalid 'use' (computational method)")
    end
    (empty_err && isempty(X)) && error("'x' is empty")
    ans = fill(NA, ncx, ncy)
    sd0 = Ref(false)
    hasna(M) = Bool[n > 0 && any(isnan, view(M, :, j)) for j in 1:size(M, 2)]
    function complete(X, Y)
        ind = Bool[!any(isnan, view(X, i, :)) for i in 1:size(X, 1)]
        Y === nothing || (ind .&= Bool[!any(isnan, view(Y, i, :)) for i in 1:size(Y, 1)])
        (na_fail && !all(ind)) && error("missing observations in cov/cor")
        ind
    end
    if Y === nothing
        if everything
            _cov_na_1!(X, hasna(X), ans, sd0, cor, kendall)
        elseif !pair
            ind = complete(X, nothing)
            _cov_complete1!(X, ind, ans, sd0, cor, kendall)
            (empty_err && !any(ind)) && error("no complete element pairs")
        else
            _cov_pairwise!(X, X, ans, sd0, cor, kendall, true)
        end
    else
        if everything
            _cov_na_2!(X, Y, hasna(X), hasna(Y), ans, sd0, cor, kendall)
        elseif !pair
            ind = complete(X, Y)
            _cov_complete2!(X, Y, ind, ans, sd0, cor, kendall)
            (empty_err && !any(ind)) && error("no complete element pairs")
        else
            _cov_pairwise!(X, Y, ans, sd0, cor, kendall, false)
        end
    end
    sd0[] && @warn "the standard deviation is zero"
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

function _colmean_narm(col)
    ok = filter(!isnan, col)
    isempty(ok) && return NaN
    return Float64(_ldsum(ok) / F80(length(ok)))
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
