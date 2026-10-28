# Distanzen und hierarchische Clusteranalyse (dist, as_dist, dist_as_matrix, hclust) aus R 4.3.3
# stats/R/dist.R, hclust.R und stats/src/distance.c, hclust.f; Python: _r/stats_cluster.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).

# ── dist / hclust ────────────────────────────────────────────────────────

const _DIST_METHODS = ["euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski"]

_mkdist(v, size, labels, diag, upper, method) =
    RVector(collect(Float64, v); attrs = Dict{String,Any}("Size" => size, "Labels" => labels, "Diag" => diag,
                                                         "Upper" => upper, "method" => method, "class" => ["dist"]))

"`dist(x, method, diag, upper, p)`: RVector (Klasse \"dist\", Attribute Size, Labels, Diag, Upper, method)."
function dist(x; method::AbstractString = "euclidean", diag::Bool = false, upper::Bool = false, p::Real = 2)
    startswith("euclidian", method) && (method = "euclidean")
    hits = [i for (i, m) in enumerate(_DIST_METHODS) if startswith(m, method)]
    isempty(hits) && error("invalid distance method")
    (length(hits) > 1 && !(method in _DIST_METHODS)) && error("ambiguous distance method")
    mi = length(hits) == 1 ? hits[1] : findfirst(==(method), _DIST_METHODS)
    X, _, _ = _as_cov_input(x)
    rn = x isa NamedMat ? x.rownames : x isa RFrame ? x.rownames : x isa RVector ? x.names : nothing
    nr = size(X, 1)
    p = Float64(p)
    (mi == 6 && (!isfinite(p) || p <= 0)) && error("distance(): invalid p")
    out = Float64[]
    warned = Ref(false)
    for j in 1:nr, i in j+1:nr
        push!(out, _dist1(view(X, i, :), view(X, j, :), mi, p, warned))
    end
    warned[] && @warn "treating non-finite values as NA"
    return _mkdist(out, nr, rn, diag, upper, _DIST_METHODS[mi])
end

function _dist1(a, b, method, p, warned)
    nc = length(a)
    both(x1, x2) = !isnan(x1) && !isnan(x2)
    d = 0.0; cnt = 0
    if method == 2
        d = -_DBL_MAX
        for k in 1:nc
            both(a[k], b[k]) || continue
            dev = abs(a[k] - b[k])
            isnan(dev) && continue
            dev > d && (d = dev)
            cnt += 1
        end
        cnt == 0 && return NA
        return d
    elseif method == 4
        for k in 1:nc
            x1 = a[k]; x2 = b[k]
            both(x1, x2) || continue
            s = abs(x1) + abs(x2)
            df = abs(x1 - x2)
            if s > 2.2250738585072014e-308 || df > 2.2250738585072014e-308
                dev = df / s
                if !isnan(dev) || (!isfinite(df) && df == s)
                    isnan(dev) && (dev = 1.0)
                    d += dev
                    cnt += 1
                end
            end
        end
        cnt == 0 && return NA
        cnt != nc && (d /= (cnt / nc))
        return d
    elseif method == 5
        total = 0; count = 0; dd = 0
        for k in 1:nc
            x1 = a[k]; x2 = b[k]
            both(x1, x2) || continue
            if !(isfinite(x1) && isfinite(x2))
                warned[] = true
            else
                if x1 != 0.0 || x2 != 0.0
                    count += 1
                    (x1 != 0.0 && x2 != 0.0) || (dd += 1)
                end
                total += 1
            end
        end
        total == 0 && return NA
        count == 0 && return 0.0
        return dd / count
    end
    for k in 1:nc
        both(a[k], b[k]) || continue
        dev = a[k] - b[k]
        isnan(dev) && continue
        if method == 1
            d += dev * dev
        elseif method == 3
            d += abs(dev)
        else
            d += SimLev.r_pow(abs(dev), p)
        end
        cnt += 1
    end
    cnt == 0 && return NA
    cnt != nc && (d /= (cnt / nc))
    method == 1 && return sqrt(d)
    method == 3 && return d
    return SimLev.r_pow(d, 1.0 / p)
end

_is_dist(d) = d isa RVector && "dist" in SimLev.r_class(d)

"`as.dist(m)`: unteres Dreieck einer Matrix als dist-Objekt."
function as_dist(m; diag::Bool = false, upper::Bool = false)
    _is_dist(m) && return m
    A, _, cn = _as_cov_input(m)
    rn = m isa NamedMat ? m.rownames : m isa RFrame ? m.rownames : nothing
    p = size(A, 1)
    size(A, 2) != p && @warn "non-square matrix"
    vals = Float64[A[i, j] for j in 1:size(A, 2) for i in 1:size(A, 1) if i > j]
    return _mkdist(vals, p, rn !== nothing ? rn : cn, diag, upper, nothing)
end

"`as.matrix(<dist>)` (dimnames Labels bzw. 1..n)."
function dist_as_matrix(d)
    size = d.attrs["Size"]
    M = zeros(size, size)
    k = 0
    for j in 1:size, i in j+1:size
        k += 1
        M[i, j] = d.values[k]
    end
    M = M .+ permutedims(M)
    lab = d.attrs["Labels"] !== nothing ? d.attrs["Labels"] : string.(1:size)
    return NamedMat(M; rownames = lab, colnames = lab)
end

const _HC_METHODS = ["ward.D", "single", "complete", "average", "mcquitty", "median", "centroid", "ward.D2"]

"`hclust(d, method, members)` (Fortran hclust/hcass2): RList (Klasse \"hclust\")."
function hclust(d, method::AbstractString = "complete"; members = nothing)
    if method == "ward"
        println(SimLev.RParallel.r_stderr(), "The \"ward\" method has been renamed to \"ward.D\"; note new \"ward.D2\"")
        method = "ward.D"
    end
    hits = [i for (i, m) in enumerate(_HC_METHODS) if startswith(m, method)]
    method in _HC_METHODS && (hits = [findfirst(==(method), _HC_METHODS)])
    isempty(hits) && error("invalid clustering method " * method)
    length(hits) > 1 && error("ambiguous clustering method " * method)
    iopt = hits[1]
    _is_dist(d) || error("invalid dissimilarities")
    n = Int(d.attrs["Size"])
    n > 65536 && error("size cannot be NA nor exceed 65536")
    n < 2 && error("must have n >= 2 objects to cluster")
    ln = n * (n - 1) ÷ 2
    if length(d.values) != ln
        length(d.values) < ln && error("dissimilarities of improper length")
        @warn "dissimilarities of improper length"
    end
    membr = members === nothing ? ones(n) : _v(members)
    length(membr) != n && error("invalid length of members")
    diss = collect(Float64, d.values)
    ia, ib, crit = _hclust_f(n, ln, iopt, membr, diss)
    order, iia, iib = _hcass2(n, ia, ib)
    return RList("merge" => hcat(iia[1:n-1], iib[1:n-1]), "height" => _vec_out(crit[1:n-1]),
                 "order" => order, "labels" => d.attrs["Labels"], "method" => _HC_METHODS[iopt],
                 "call" => nothing, "dist.method" => d.attrs["method"]; class = "hclust")
end

@inline _ioffst(n, i, j) = j + (i - 1) * n - (i * (i + 1)) ÷ 2

function _hclust_f(n, ln, iopt, membr0, diss)
    INF = 1.0e300
    ia = zeros(Int, n); ib = zeros(Int, n); crit = zeros(n)
    nn = zeros(Int, n); disnn = zeros(n)
    membr = collect(Float64, membr0)
    flag = fill(true, n)
    im = jj = jm = 0
    ncl = n
    if iopt == 8
        for i in 1:ln
            diss[i] = diss[i] * diss[i]
        end
    end
    for i in 1:n-1
        dmin = INF
        for j in i+1:n
            ind = _ioffst(n, i, j)
            if dmin > diss[ind]
                dmin = diss[ind]
                jm = j
            end
        end
        nn[i] = jm
        disnn[i] = dmin
    end
    isWard = iopt == 1 || iopt == 8
    while true
        dmin = INF
        for i in 1:n-1
            if flag[i] && disnn[i] < dmin
                dmin = disnn[i]
                im = i
                jm = nn[i]
            end
        end
        ncl -= 1
        i2 = min(im, jm)
        j2 = max(im, jm)
        ia[n-ncl] = i2
        ib[n-ncl] = j2
        iopt == 8 && (dmin = sqrt(dmin))
        crit[n-ncl] = dmin
        flag[j2] = false
        dmin = INF
        for k in 1:n
            if flag[k] && k != i2
                ind1 = i2 < k ? _ioffst(n, i2, k) : _ioffst(n, k, i2)
                ind2 = j2 < k ? _ioffst(n, j2, k) : _ioffst(n, k, j2)
                d12 = diss[_ioffst(n, i2, j2)]
                if isWard
                    v = ((membr[i2] + membr[k]) * diss[ind1] + (membr[j2] + membr[k]) * diss[ind2]) - membr[k] * d12
                    diss[ind1] = v / ((membr[i2] + membr[j2]) + membr[k])
                elseif iopt == 2
                    diss[ind1] = diss[ind1] <= diss[ind2] ? diss[ind1] : diss[ind2]
                elseif iopt == 3
                    diss[ind1] = diss[ind1] >= diss[ind2] ? diss[ind1] : diss[ind2]
                elseif iopt == 4
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2]) / (membr[i2] + membr[j2])
                elseif iopt == 5
                    diss[ind1] = (diss[ind1] + diss[ind2]) / 2
                elseif iopt == 6
                    diss[ind1] = ((diss[ind1] + diss[ind2]) - d12 / 2) / 2
                elseif iopt == 7
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2] -
                                  membr[i2] * membr[j2] * d12 / (membr[i2] + membr[j2])) / (membr[i2] + membr[j2])
                end
                if i2 < k
                    if diss[ind1] < dmin
                        dmin = diss[ind1]
                        jj = k
                    end
                else
                    if diss[ind1] < disnn[k]
                        disnn[k] = diss[ind1]
                        nn[k] = i2
                    end
                end
            end
        end
        membr[i2] = membr[i2] + membr[j2]
        disnn[i2] = dmin
        nn[i2] = jj
        for i in 1:n-1
            if flag[i] && (nn[i] == i2 || nn[i] == j2)
                dmin = INF
                for j in i+1:n
                    if flag[j]
                        ind = _ioffst(n, i, j)
                        if diss[ind] < dmin
                            dmin = diss[ind]
                            jj = j
                        end
                    end
                end
                nn[i] = jj
                disnn[i] = dmin
            end
        end
        ncl > 1 || break
    end
    return ia, ib, crit
end

function _hcass2(n, ia, ib)
    iia = zeros(Int, n); iib = zeros(Int, n); iorder = zeros(Int, n)
    for i in 1:n
        iia[i] = ia[i]
        iib[i] = ib[i]
    end
    for i in 1:n-2
        k = min(ia[i], ib[i])
        for j in i+1:n-1
            ia[j] == k && (iia[j] = -i)
            ib[j] == k && (iib[j] = -i)
        end
    end
    for i in 1:n-1
        iia[i] = -iia[i]
        iib[i] = -iib[i]
    end
    for i in 1:n-1
        if iia[i] > 0 && iib[i] < 0
            k = iia[i]; iia[i] = iib[i]; iib[i] = k
        end
        if iia[i] > 0 && iib[i] > 0
            k1 = min(iia[i], iib[i]); k2 = max(iia[i], iib[i])
            iia[i] = k1; iib[i] = k2
        end
    end
    iorder[1] = iia[n-1]
    iorder[2] = iib[n-1]
    loc = 2
    for i in n-2:-1:1
        for j in 1:loc
            if iorder[j] == i
                iorder[j] = iia[i]
                if j == loc
                    loc += 1
                    iorder[loc] = iib[i]
                else
                    loc += 1
                    for k in loc:-1:j+2
                        iorder[k] = iorder[k-1]
                    end
                    iorder[j+1] = iib[i]
                end
                break
            end
        end
    end
    for i in 1:n
        iorder[i] = -iorder[i]
    end
    return iorder, iia, iib
end
