# Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/distance.c, hclust.f;
#                     nachgebildet nach R 4.3.3, src/library/stats/R/dist.R, hclust.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); hclust.f: F. Murtagh (1986), Änderungen Ross
#                     Ihaka, Fritz Leisch, Martin Maechler (ohne eigenen Lizenzvermerk)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang; seit 1.6.0 rechnen Abstände und Clusterbaum im Kern
#                     core/slc_rbase_clust.cpp (sl_r_dist, sl_r_hclust), hier bleiben Argumente und Rückgabe.
# Distanzen und hierarchische Clusteranalyse (dist, as_dist, hclust) aus R 4.3.3
# stats/R/dist.R, hclust.R und stats/src/distance.c, hclust.f; Python: _r/stats_cluster.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).

# ── dist / hclust ────────────────────────────────────────────────────────

const _DIST_METHODS = ["euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski"]

_mkdist(v, size, labels, diag, upper, method) =
    RVector(collect(Float64, v); attrs = Dict{String,Any}("Size" => size, "Labels" => labels, "Diag" => diag,
                                                         "Upper" => upper, "method" => method, "class" => ["dist"]))

"`dist(x, method, diag, upper, p)`: RVector (Klasse \"dist\", Attribute Size, Labels, Diag, Upper, method)."
function dist(x; method::AbstractString = "euclidean", diag::Bool = false, upper::Bool = false, p::Real = 2)
    (!isempty(method) && startswith("euclidian", method)) && (method = "euclidean")
    # pmatch: exakt vor eindeutig partiell; mehrdeutig oder leer ist NA ("invalid", seit 1.6.0 wie R)
    hits = method in _DIST_METHODS ? [findfirst(==(method), _DIST_METHODS)] :
           [i for (i, m) in enumerate(_DIST_METHODS) if !isempty(method) && startswith(m, method)]
    length(hits) == 1 || error("invalid distance method")
    mi = hits[1]
    X, _, _ = _as_cov_input(x)
    rn = x isa NamedMat ? x.rownames : x isa RFrame ? x.rownames : x isa RVector ? x.names : nothing
    nr = size(X, 1)
    p = Float64(p)
    (mi == 6 && (!isfinite(p) || p <= 0)) && error("distance(): invalid p")
    out, warned = SimLev._rb_dist(Matrix{Float64}(X), mi, p)   # C-Kern sl_r_dist (seit 1.6.0)
    warned && @warn "treating non-finite values as NA"
    return _mkdist(out, nr, rn, diag, upper, _DIST_METHODS[mi])
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

const _HC_METHODS = ["ward.D", "single", "complete", "average", "mcquitty", "median", "centroid", "ward.D2"]

"`hclust(d, method, members)` (Fortran hclust/hcass2): RList (Klasse \"hclust\")."
function hclust(d, method::AbstractString = "complete"; members = nothing)
    if method == "ward"
        println(SimLev.RParallel.r_stderr(), "The \"ward\" method has been renamed to \"ward.D\"; note new \"ward.D2\"")
        method = "ward.D"
    end
    hits = [i for (i, m) in enumerate(_HC_METHODS) if !isempty(method) && startswith(m, method)]
    method in _HC_METHODS && (hits = [findfirst(==(method), _HC_METHODS)])
    # pmatch: mehrdeutig oder leer ist NA ("invalid", seit 1.6.0 wie R)
    length(hits) == 1 || error("invalid clustering method " * method)
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
    diss = collect(Float64, view(d.values, 1:ln))
    merge, crit, order = SimLev._rb_hclust(n, iopt, collect(Float64, membr), diss)   # C-Kern sl_r_hclust (seit 1.6.0)
    return RList("merge" => merge, "height" => _vec_out(crit),
                 "order" => order, "labels" => d.attrs["Labels"], "method" => _HC_METHODS[iopt],
                 "call" => nothing, "dist.method" => d.attrs["method"]; class = "hclust")
end
