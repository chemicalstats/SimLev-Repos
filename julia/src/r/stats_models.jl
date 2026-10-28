# Lineare und verallgemeinerte lineare Modelle (lm_fit, lm, poly, summary_lm, glm, r_binomial, coef, fitted,
# residuals, generisches predict) sowie p_adjust, ecdf, ave, aggregate und t_test aus R 4.3.3 stats/R/lm.R,
# glm.R, contr.poly.R, family.R, p.adjust.R, ecdf.R, ave.R, aggregate.R, t.test.R und stats/src/family.c;
# Python: _r/stats_models.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).

# ── lm.fit / lm / poly / glm ─────────────────────────────────────────────

_LA() = SimLev.RLinalg

"""
    lm_fit(x, y; offset = nothing, method = "qr", tol = 1e-7, singular_ok = true)

`lm.fit(x, y, offset, method, tol, singular.ok)` (LINPACK dqrls): RList
(Klasse \"lm\") mit coefficients (RVector), residuals, effects (RVector),
rank, fitted.values, assign, qr (RList \"qr\": qr, qraux, pivot, tol, rank),
df.residual.
"""
function lm_fit(x, y; offset = nothing, method::AbstractString = "qr", tol::Real = 1e-07, singular_ok::Bool = true)
    if x isa NamedMat
        X = _fmat(x.data); cn = x.colnames; rn_x = x.rownames
    elseif x isa RFrame
        X, _, cn = _as_cov_input(x); rn_x = x.rownames
    elseif x isa AbstractMatrix
        X = _fmat(x); cn = nothing; rn_x = nothing
    else
        error("'x' must be a matrix")
    end
    n = size(X, 1)
    n == 0 && error("0 (non-NA) cases")
    p = size(X, 2)
    ynames = nothing
    if y isa RVector
        ynames = y.names
        Y = Float64[_fl(v) for v in y.values]
    elseif y isa NamedMat
        Y = _fmat(y.data)
    elseif y isa AbstractMatrix
        Y = _fmat(y)
    else
        Y = _v(y)
    end
    ymat = Y isa AbstractMatrix && size(Y, 2) > 1
    (Y isa AbstractMatrix && size(Y, 2) == 1) && (Y = Y[:, 1])
    if p == 0
        return RList("coefficients" => Float64[], "residuals" => y, "fitted.values" => 0 .* Y, "rank" => 0,
                     "df.residual" => size(Y, 1); class = "lm")
    end
    offset !== nothing && (Y = Y .- (offset isa Number ? Float64(offset) : _v(offset)))
    size(Y, 1) != n && error("incompatible dimensions")
    method != "qr" && @warn "method = '$method' is not supported. Using 'qr'"
    all(isfinite, X) || error("NA/NaN/Inf in 'x'")
    all(isfinite, Y) || error("NA/NaN/Inf in 'y'")
    Y2 = reshape(Y, n, :)
    z = _LA().dqrls(X, Y2, Float64(tol))
    (!singular_ok && z.rank < p) && error("singular fit encountered")
    rank = z.rank
    pivot = z.pivot
    dn = cn !== nothing ? cn : ["x$i" for i in 1:p]
    nmeff = vcat([dn[pivot[i]] for i in 1:rank], fill("", n - rank))
    coef = copy(z.coefficients)
    coef[rank+1:end, :] .= NA
    if z.pivoted
        c2 = similar(coef)
        c2[pivot, :] = coef
        coef = c2
    end
    resid = z.residuals
    eff = z.effects
    fitted = Y2 .- resid
    offset !== nothing && (fitted = fitted .+ reshape(offset isa Number ? fill(Float64(offset), n) : _v(offset), n, :))
    qcn = cn === nothing ? nothing : (z.pivoted ? [cn[i] for i in pivot] : cn)
    q = RList("qr" => _out(z.qr, rn_x, qcn), "qraux" => z.qraux, "pivot" => pivot, "tol" => Float64(tol),
              "rank" => rank; class = "qr")
    if ymat
        res = RList("coefficients" => NamedMat(coef; rownames = dn), "residuals" => resid,
                    "effects" => NamedMat(eff; rownames = nmeff), "rank" => rank, "fitted.values" => fitted;
                    class = "lm")
    else
        res = RList("coefficients" => RVector(coef[:, 1]; names = dn), "residuals" => _vec_out(resid[:, 1], ynames),
                    "effects" => RVector(eff[:, 1]; names = nmeff), "rank" => rank,
                    "fitted.values" => _vec_out(fitted[:, 1], ynames); class = "lm")
    end
    res["assign"] = nothing
    res["qr"] = q
    res["df.residual"] = n - rank
    return res
end

_coefs_get(c, k) = c isa AbstractDict ? c[k] : getproperty(c, Symbol(k))

"""
    poly(x, degree = 1; coefs = nothing, raw = false, simple = false)

`poly(x, degree, coefs, raw, simple)` (orthogonale Polynome wie R):
NamedMat n×degree (Spaltennamen "1", "2", …) mit den Attributen "coefs"
(RList alpha, norm2), "degree" und "class" (`attrs(m)`).
"""
function poly(x, degree::Integer = 1; coefs = nothing, raw::Bool = false, simple::Bool = false)
    xv = _v(x)
    degree = Int(degree)
    degree < 1 && error("'degree' must be at least 1")
    n = length(xv)
    cnames = string.(1:degree)
    if raw
        Z = Float64[SimLev.r_pow(v, k) for v in xv, k in 1:degree]
        return NamedMat(Z; colnames = cnames, attrs = Dict{String,Any}("degree" => collect(1:degree),
                                                                       "class" => ["poly", "matrix"]))
    end
    if coefs === nothing
        any(isnan, xv) && error("missing values are not allowed in 'poly'")
        degree >= length(unique(_z0.(xv))) && error("'degree' must be less than number of unique points")
        xbar = _rmean(xv)
        xc = xv .- xbar
        X = Float64[SimLev.r_pow(v, k) for v in xc, k in 0:degree]
        QR = _LA().qr(X)
        QR["rank"] < degree && error("'degree' must be less than number of unique points")
        zq = QR["qr"]
        zq = zq isa NamedMat ? copy(zq.data) : copy(zq)
        for j in 1:size(zq, 2), i in 1:size(zq, 1)
            i == j || (zq[i, j] = 0.0)
        end
        Z = _LA().qr_qy(QR, zq)
        Z = Z isa NamedMat ? Z.data : Z
        Z2 = Z .* Z
        norm2 = [_rsum(Z2[:, k]) for k in 1:size(Z, 2)]
        alpha = ([_rsum(xc .* Z2[:, k]) for k in 1:size(Z, 2)] ./ norm2 .+ xbar)[1:degree]
        norm2 = vcat(1.0, norm2)
    else
        alpha = _v(_coefs_get(coefs, "alpha"))
        norm2 = _v(_coefs_get(coefs, "norm2"))
        Z = ones(n, degree + 1)
        Z[:, 2] = xv .- alpha[1]
        for i in 2:degree
            Z[:, i+1] = (xv .- alpha[i]) .* Z[:, i] .- (norm2[i+1] / norm2[i]) .* Z[:, i-1]
        end
    end
    sq = sqrt.(norm2[2:end])
    Z = Z ./ permutedims(sq)
    Z = Z[:, 2:end]
    return NamedMat(Z; colnames = cnames,
                    attrs = Dict{String,Any}("coefs" => RList("alpha" => _vec_out(alpha), "norm2" => norm2),
                                             "degree" => collect(1:degree), "class" => ["poly", "matrix"]))
end

# Minimaler Formel-Parser für die Formen, die das Paket nutzt:
#   y ~ x,  y ~ x1 + x2,  y ~ X (Matrix),  y ~ poly(x, d),  y ~ stats::poly(x, d),
#   Achsenabschnitt entfernen mit "- 1" oder "0 +".

function _split_top(s::AbstractString, sep::Char)
    out = String[]
    depth = 0
    cur = IOBuffer()
    for ch in s
        if ch in "(["
            depth += 1
        elseif ch in ")]"
            depth -= 1
        end
        if ch == sep && depth == 0
            push!(out, String(take!(cur)))
        else
            print(cur, ch)
        end
    end
    push!(out, String(take!(cur)))
    out
end

"Spaltennamen-Präfix wie R's deparse (\", \" zwischen Argumenten)."
function _deparse_call(term::AbstractString)
    t = strip(term)
    occursin('(', t) || return String(t)
    fn, rest = split(t, '(', limit = 2)
    inner = rest[1:findlast(')', rest)-1]
    args = [strip(a) for a in _split_top(inner, ',')]
    return strip(fn) * "(" * join(args, ", ") * ")"
end

function _eval_lit(e::AbstractString, ns)
    s = String(strip(e))
    haskey(ns, s) && return ns[s]
    s in ("TRUE", "T") && return true
    s in ("FALSE", "F") && return false
    v = tryparse(Float64, s)
    v !== nothing && return v
    error("Formelterm '$s' wird nicht unterstützt")
end

function _eval_term(term::AbstractString, ns)
    t = String(strip(term))
    haskey(ns, t) && return ns[t]
    tt = replace(replace(t, "stats::" => ""), "base::" => "")
    if startswith(tt, "poly(")
        inner = tt[6:findlast(')', tt)-1]
        args = [strip(a) for a in _split_top(inner, ',')]
        xv = _eval_term(args[1], ns)
        kw = Dict{Symbol,Any}()
        pos = Any[]
        for a in args[2:end]
            if occursin('=', a) && !startswith(a, "=")
                k, v = split(a, '=', limit = 2)
                kw[Symbol(strip(k))] = _eval_lit(v, ns)
            else
                push!(pos, _eval_lit(a, ns))
            end
        end
        isempty(pos) || (kw[:degree] = pos[1])
        deg = Int(pop!(kw, :degree, 1))
        haskey(kw, :raw) && (kw[:raw] = Bool(kw[:raw]))
        return poly(xv, deg; kw...)
    end
    return _eval_lit(tt, ns)
end

_nsdict(x::Nothing) = Dict{String,Any}()
_nsdict(x::AbstractDict) = Dict{String,Any}(string(k) => v for (k, v) in x)
_nsdict(x::NamedTuple) = Dict{String,Any}(string(k) => v for (k, v) in pairs(x))
_nsdict(x::RFrame) = Dict{String,Any}(k => c for (k, c) in zip(names(x), x.cols))

function _model_frame(formula::AbstractString, data, env)
    occursin('~', formula) || error("invalid formula")
    lhs, rhs = split(formula, '~', limit = 2)
    ns = _nsdict(env)
    rownames = nothing
    if data !== nothing
        merge!(ns, _nsdict(data))
        data isa RFrame && (rownames = data.rownames)
    end
    intercept = true
    terms = String[]
    expanded = String[]
    for t in strip.(_split_top(rhs, '+'))
        parts = _split_top(t, '-')
        push!(expanded, String(strip(parts[1])))
        for pp in parts[2:end]
            if strip(pp) == "1"
                intercept = false
            elseif !isempty(strip(pp))
                error("Formelterm '-$(strip(pp))' wird nicht unterstützt")
            end
        end
    end
    for t in expanded
        t == "" && continue
        if t in ("0", "-1")
            intercept = false
            continue
        end
        t == "1" && continue
        push!(terms, t)
    end
    yv = _eval_term(strip(lhs), ns)
    cols = Tuple{String,Any}[(t, _eval_term(t, ns)) for t in terms]
    return String(strip(lhs)), yv, cols, intercept, rownames
end

function _design(y, cols, intercept::Bool, rownames)
    yv = y isa AbstractMatrix ? _fmat(y isa NamedMat ? y.data : y) : _v(y)
    n = size(yv, 1)
    mats = Matrix{Float64}[]
    names = String[]
    assign = Int[]
    ok = yv isa AbstractMatrix ? Bool[!any(isnan, view(yv, i, :)) for i in 1:n] : .!isnan.(yv)
    for (k, (lab, v)) in enumerate(cols)
        if v isa AbstractMatrix || v isa RFrame
            a, _, cn = _as_cov_input(v)
            push!(mats, a)
            pre = _deparse_call(lab)
            ok .&= Bool[!any(isnan, view(a, i, :)) for i in 1:size(a, 1)]
            if size(a, 2) == 1
                push!(names, pre); push!(assign, k)
                continue
            end
            cn === nothing && (cn = string.(1:size(a, 2)))
            append!(names, pre .* cn)
            append!(assign, fill(k, size(a, 2)))
        else
            a = _v(v)
            push!(mats, reshape(a, :, 1))
            push!(names, _deparse_call(lab))
            push!(assign, k)
            ok .&= .!isnan.(a)
        end
    end
    X = intercept ? hcat(ones(n), mats...) : (isempty(mats) ? zeros(n, 0) : hcat(mats...))
    if intercept
        names = vcat("(Intercept)", names)
        assign = vcat(0, assign)
    end
    rownames === nothing && (rownames = string.(1:n))
    return X, yv, names, assign, ok, rownames
end

"""
    lm(formula; data = nothing, env = nothing, kwargs...)

`lm(formula, data)` für einfache Formeln ("y ~ x", "y ~ x1 + x2", "y ~ X" mit
Matrix X, "y ~ poly(x, d)", ohne Achsenabschnitt mit "- 1"/"0 +"). Variablen
aus `data` (RFrame/NamedTuple/Dict), `env` (Dict/NamedTuple) oder
Schlüsselwortargumenten. Fehlende Werte: na.omit. Ergebnis: RList (Klasse
\"lm\") wie `lm_fit` plus `model`.
"""
function lm(formula::AbstractString; data = nothing, env = nothing, kwargs...)
    ns = _nsdict(env)
    for (k, v) in kwargs
        ns[string(k)] = v
    end
    ylab, yv, cols, intercept, rownames = _model_frame(formula, data, ns)
    X, y, names, assign, ok, rn = _design(yv, cols, intercept, rownames)
    keep = ok
    Xk = X[keep, :]
    yk = y[keep]
    rnk = rn[keep]
    fit = lm_fit(NamedMat(Xk; rownames = rnk, colnames = names), RVector(yk; names = rnk))
    fit["assign"] = assign
    fit["xlevels"] = RList()
    fit["call"] = nothing
    fit["terms"] = RList("intercept" => (intercept ? 1 : 0), "formula" => formula)
    model = RList(ylab => yk)
    for (lab, v) in cols
        model[lab] = v isa NamedMat ? NamedMat(v.data[keep, :]; colnames = v.colnames, attrs = v.attrs) :
                     v isa AbstractMatrix ? v[keep, :] : _v(v)[keep]
    end
    fit["model"] = model
    all(keep) || (fit["na.action"] = findall(.!keep))
    return fit
end

"`coef(obj)`."
coef(obj) = obj["coefficients"]
"`fitted(obj)`."
fitted(obj) = obj["fitted.values"]
"`residuals(obj)` (Antwort-Residuen)."
residuals(obj) = obj["residuals"]

_vals(x) = x isa RVector ? Float64[_fl(v) for v in x.values] : x isa AbstractArray ? Float64[_fl(v) for v in vec(x)] : Float64[_fl(x)]

"`summary.lm(object)`: residuals, coefficients (NamedMat), aliased, sigma, df, r.squared, adj.r.squared, fstatistic, cov.unscaled."
function summary_lm(object)
    z = object
    p = Int(z["rank"])
    rdf = z["df.residual"]
    r = _vals(z["residuals"])
    terms = get(z, "terms", nothing)
    intercept = terms === nothing ? 1 : Int(get(terms, "intercept", 1))
    ans = RList(; class = "summary.lm")
    if p == 0
        n = length(r)
        rss = _rsum(r .* r)
        resvar = rss / rdf
        al = isnan.(_vals(z["coefficients"]))
        ans["residuals"] = z["residuals"]
        ans["aliased"] = al
        ans["df"] = [0, n, length(al)]
        ans["coefficients"] = NamedMat(zeros(0, 4); colnames = ["Estimate", "Std. Error", "t value", "Pr(>|t|)"])
        ans["sigma"] = _csqrt(resvar)
        ans["r.squared"] = 0.0
        ans["adj.r.squared"] = 0.0
        return ans
    end
    Qr = z["qr"]
    Qm = Qr["qr"]
    Q = Qm isa NamedMat ? Qm.data : Qm
    n = size(Q, 1)
    n - p != rdf && @warn "residual degrees of freedom in object suggest this is not an \"lm\" fit"
    f = _vals(z["fitted.values"])
    if intercept != 0
        d = f .- _rmean(f)
        mss = _rsum(d .* d)
    else
        mss = _rsum(f .* f)
    end
    rss = _rsum(r .* r)
    resvar = rss / rdf
    if isfinite(resvar)
        mf = _rmean(f)
        resvar < (mf * mf + var(f)) * 1e-30 && @warn "essentially perfect fit: summary may be unreliable"
    end
    R = _LA().chol2inv(Q[1:p, 1:p])
    R = R isa AbstractMatrix ? R : fill(Float64(R), 1, 1)
    se = [_csqrt(R[i, i] * resvar) for i in 1:p]
    cf = z["coefficients"]
    cfv = _vals(cf)
    piv = collect(Int, Qr["pivot"] isa Number ? [Qr["pivot"]] : Qr["pivot"])
    est = cfv[piv[1:p]]
    tval = est ./ se
    pv = Float64[2 * SimLev.RNmath.pt(abs(t), Float64(rdf); lower_tail = false) for t in tval]
    cnames = cf isa RVector && cf.names !== nothing ? cf.names : string.(0:length(cfv)-1)
    rn = [cnames[i] for i in piv[1:p]]
    ans["residuals"] = z["residuals"]
    ans["coefficients"] = NamedMat(hcat(est, se, tval, pv); rownames = rn,
                                   colnames = ["Estimate", "Std. Error", "t value", "Pr(>|t|)"])
    ans["aliased"] = RVector(isnan.(cfv); names = cnames)
    ans["sigma"] = _csqrt(resvar)
    ans["df"] = [p, rdf, size(Q, 2)]
    if p != intercept
        df_int = intercept != 0 ? 1 : 0
        rsq = mss / (mss + rss)
        ans["r.squared"] = rsq
        ans["adj.r.squared"] = 1 - (1 - rsq) * ((n - df_int) / rdf)
        ans["fstatistic"] = RVector([(mss / (p - df_int)) / resvar, Float64(p - df_int), Float64(rdf)];
                                    names = ["value", "numdf", "dendf"])
    else
        ans["r.squared"] = 0.0
        ans["adj.r.squared"] = 0.0
    end
    ans["cov.unscaled"] = NamedMat(R; rownames = rn, colnames = rn)
    return ans
end

const _INVEPS = 1 / _DBL_EPS

function _logit_link(mu)
    m = _v(mu)
    out = similar(m)
    for (i, x) in enumerate(m)
        (x < 0 || x > 1) && error("Value " * _g(x) * " out of range (0, 1)")
        q = x != 1 ? x / (1 - x) : Inf
        out[i] = SimLev.RLibm.log(q)
    end
    out
end

function _logit_linkinv(eta)
    e = _v(eta)
    out = similar(e)
    for (i, t) in enumerate(e)
        tmp = t < -30.0 ? _DBL_EPS : (t > 30.0 ? _INVEPS : SimLev.RLibm.exp(t))
        out[i] = tmp / (1 + tmp)
    end
    out
end

function _logit_mu_eta(eta)
    e = _v(eta)
    out = similar(e)
    for (i, t) in enumerate(e)
        if t > 30.0 || t < -30.0
            out[i] = _DBL_EPS
        else
            ex = SimLev.RLibm.exp(t)
            opexp = 1 + ex
            out[i] = ex / (opexp * opexp)
        end
    end
    out
end

_y_log_y(y, mu) = y != 0.0 ? y * SimLev.RLibm.log(y / mu) : 0.0

function _binomial_dev_resids(y, mu, wt)
    yv = _v(y); muv = _v(mu); wv = _v(wt)
    n = length(yv)
    out = Vector{Float64}(undef, n)
    for i in 1:n
        mui = length(muv) > 1 ? muv[i] : muv[1]
        yi = yv[i]
        w = length(wv) > 1 ? wv[i] : wv[1]
        out[i] = 2 * w * (_y_log_y(yi, mui) + _y_log_y(1 - yi, 1 - mui))
    end
    out
end

function _binomial_aic(y, n, mu, wt, dev)
    isdefined(SimLev.RNmath, :dbinom) || return NaN
    nv = _v(n); wv = _v(wt); yv = _v(y); muv = _v(mu)
    m = any(>(1), nv) ? nv : wv
    fac = Float64[m[i] > 0 ? wv[i] / m[i] : 0.0 for i in eachindex(m)]
    rr(v) = SimLev.RFmt.r_round(v)
    db = _v(SimLev.RNmath.dbinom(_v(rr(m .* yv)), _v(rr(m)), muv; log = true))
    return -2 * _rsum(fac .* db)
end

"`binomial(link = \"logit\")` (nur der Logit-Link aus family.c): RList (Klasse \"family\")."
function r_binomial(link::AbstractString = "logit")
    link != "logit" && error("binomial(): nur link = 'logit' ist portiert")
    return RList("family" => "binomial", "link" => "logit", "linkfun" => _logit_link, "linkinv" => _logit_linkinv,
                 "variance" => (mu -> (m = _v(mu); m .* (1 .- m))), "dev.resids" => _binomial_dev_resids,
                 "aic" => _binomial_aic, "mu.eta" => _logit_mu_eta,
                 "validmu" => (mu -> (m = _v(mu); all(isfinite, m) && all(t -> 0 < t < 1, m))),
                 "valideta" => (eta -> true), "dispersion" => 1; class = "family")
end

"""
    glm(formula; family = r_binomial(), data = nothing, weights = nothing, control = nothing, env = nothing, kwargs...)

`glm(formula, family = binomial(), data)` mit IRLS wie glm.fit (Familie
binomial/logit). Ergebnis: RList (Klasse c(\"glm\", \"lm\")).
"""
function glm(formula::AbstractString; family = nothing, data = nothing, weights = nothing, control = nothing,
             env = nothing, kwargs...)
    family === nothing && (family = r_binomial())
    family isa Function && (family = family())
    ns = _nsdict(env)
    for (k, v) in kwargs
        ns[string(k)] = v
    end
    ylab, yv, cols, intercept, rownames = _model_frame(formula, data, ns)
    X, y, names, assign, ok, rn = _design(yv, cols, intercept, rownames)
    X = X[ok, :]; y = y[ok]; rn = rn[ok]
    ctl = Dict{String,Any}("epsilon" => 1e-8, "maxit" => 25, "trace" => false)
    control === nothing || merge!(ctl, _ctl_dict(control))
    fit = glm_fit(X, y; weights = weights, family = family, control = ctl, intercept = intercept,
                  xnames = names, ynames = rn)
    fit["call"] = nothing
    fit["formula"] = formula
    fit["terms"] = RList("intercept" => (intercept ? 1 : 0))
    return fit
end

"`glm.fit` (IRLS) wie R."
function glm_fit(x, y; weights = nothing, start = nothing, etastart = nothing, mustart = nothing, offset = nothing,
                 family = nothing, control = nothing, intercept::Bool = true, singular_ok::Bool = true,
                 xnames = nothing, ynames = nothing)
    family === nothing && error("'family' argument seems not to be a valid family object")
    ctl = Dict{String,Any}("epsilon" => 1e-8, "maxit" => 25, "trace" => false)
    control === nothing || merge!(ctl, _ctl_dict(control))
    eps_c = Float64(ctl["epsilon"])
    eps_c <= 0 && error("value of 'epsilon' must be > 0")
    maxit = Int(ctl["maxit"])
    maxit <= 0 && error("maximum number of iterations must be > 0")
    X = x isa AbstractMatrix ? _fmat(x isa NamedMat ? x.data : x) : reshape(_v(x), :, 1)
    y = copy(_v(y))
    nobs = length(y)
    nvars = size(X, 2)
    wts = weights === nothing ? ones(nobs) : copy(_v(weights))
    off = offset === nothing ? zeros(nobs) : _v(offset)
    variance = family["variance"]
    linkinv = family["linkinv"]
    dev_resids = family["dev.resids"]
    mu_eta = family["mu.eta"]
    valideta = get(family, "valideta", e -> true)
    validmu = get(family, "validmu", m -> true)
    n_ = ones(nobs)
    y[wts .== 0] .= 0
    any(t -> t < 0 || t > 1, y) && error("y values must be 0 <= y <= 1")
    ms = (wts .* y .+ 0.5) ./ (wts .+ 1)
    mm = wts .* y
    rmm = _v(SimLev.RFmt.r_round(mm))
    any(i -> abs(mm[i] - rmm[i]) > 1e-3, eachindex(mm)) && @warn "non-integer #successes in a binomial glm!"
    mustart === nothing && (mustart = ms)
    conv = false
    coefold = nothing
    mprod(A, b) = _v(_LA().matprod(A, b))
    if etastart !== nothing
        eta = _v(etastart)
    elseif start !== nothing
        start = _v(start)
        length(start) != nvars && error("length of 'start' should equal $nvars and correspond to initial coefs")
        coefold = copy(start)
        eta = off .+ mprod(X, start)
    else
        eta = family["linkfun"](mustart)
    end
    mu = linkinv(eta)
    (validmu(mu) && valideta(eta)) || error("cannot find valid starting values: please specify some")
    devold = _rsum(dev_resids(y, mu, wts))
    boundary = false
    start === nothing && (start = fill(NA, nvars))
    coef = nothing
    fit = nothing
    it = 0
    good = wts .> 0
    w = nothing
    dev = devold
    for itr in 1:maxit
        it = itr
        good = wts .> 0
        varmu = variance(mu)[good]
        any(isnan, varmu) && error("NAs in V(mu)")
        any(==(0), varmu) && error("0s in V(mu)")
        mev = mu_eta(eta)
        any(isnan, mev[good]) && error("NAs in d(mu)/d(eta)")
        good = (wts .> 0) .& (mev .!= 0)
        if !any(good)
            conv = false
            @warn "no observations informative at iteration $it"
            break
        end
        z = (eta .- off)[good] .+ (y .- mu)[good] ./ mev[good]
        w = sqrt.((wts[good] .* (mev[good] .* mev[good])) ./ variance(mu)[good])
        fit = _LA().dqrls(X[good, :] .* w, reshape(z .* w, :, 1), min(1e-7, eps_c / 1000))
        cf = fit.coefficients[:, 1]
        if !all(isfinite, cf)
            conv = false
            @warn "non-finite coefficients at iteration $it"
            break
        end
        nobs < fit.rank && error(nobs == 1 ? "X matrix has rank $(fit.rank), but only $nobs observation" :
                                 "X matrix has rank $(fit.rank), but only $nobs observations")
        (!singular_ok && fit.rank < nvars) && error("singular fit encountered")
        start = copy(start)
        start[fit.pivot] = cf
        eta = mprod(X, start)
        eta = eta .+ off
        mu = linkinv(eta)
        dev = _rsum(dev_resids(y, mu, wts))
        ctl["trace"] == true && println("Deviance = " * SimLev.RFmt.as_character(dev) * " Iterations - $it")
        boundary = false
        if !isfinite(dev)
            coefold === nothing && error("no valid set of coefficients has been found: please supply starting values")
            @warn "step size truncated due to divergence"
            ii = 1
            while !isfinite(dev)
                ii > maxit && error("inner loop 1; cannot correct step size")
                ii += 1
                start = (start .+ coefold) ./ 2
                eta = mprod(X, start) .+ off
                mu = linkinv(eta)
                dev = _rsum(dev_resids(y, mu, wts))
            end
            boundary = true
        end
        if !(valideta(eta) && validmu(mu))
            coefold === nothing && error("no valid set of coefficients has been found: please supply starting values")
            @warn "step size truncated: out of bounds"
            ii = 1
            while !(valideta(eta) && validmu(mu))
                ii > maxit && error("inner loop 2; cannot correct step size")
                ii += 1
                start = (start .+ coefold) ./ 2
                eta = mprod(X, start) .+ off
                mu = linkinv(eta)
            end
            boundary = true
            dev = _rsum(dev_resids(y, mu, wts))
        end
        if abs(dev - devold) / (0.1 + abs(dev)) < eps_c
            conv = true
            coef = copy(start)
            break
        end
        devold = dev
        coef = copy(start)
        coefold = copy(start)
    end
    conv || @warn "glm.fit: algorithm did not converge"
    boundary && @warn "glm.fit: algorithm stopped at boundary value"
    epsw = 10 * _DBL_EPS
    (any(>(1 - epsw), mu) || any(<(epsw), mu)) && @warn "glm.fit: fitted probabilities numerically 0 or 1 occurred"
    coef === nothing && (coef = copy(start))
    rank = fit !== nothing ? fit.rank : 0
    if fit !== nothing && rank < nvars
        coef[fit.pivot[rank+1:end]] .= NA
    end
    resid = (y .- mu) ./ mu_eta(eta)
    xn = xnames
    res = RList(; class = ["glm", "lm"])
    res["coefficients"] = xn !== nothing ? RVector(coef; names = xn) : _vec_out(coef)
    res["residuals"] = _vec_out(resid, ynames)
    res["fitted.values"] = _vec_out(mu, ynames)
    xxnames = nothing
    if fit !== nothing
        xxnames = xn !== nothing ? [xn[i] for i in fit.pivot] : nothing
        eff = fit.effects[:, 1]
        res["effects"] = xxnames !== nothing ? RVector(eff; names = vcat(xxnames[1:rank], fill("", count(good) - rank))) : eff
        qrm = fit.qr
        nr = min(count(good), nvars)
        if nr < nvars
            Rmat = Matrix{Float64}(undef, nvars, nvars)
            for j in 1:nvars, i in 1:nvars
                Rmat[i, j] = i == j ? 1.0 : 0.0
            end
            Rmat[1:nr, 1:nvars] = qrm[1:nr, 1:nvars]
        else
            Rmat = qrm[1:nvars, 1:nvars]
        end
        for j in 1:nvars, i in j+1:nvars
            Rmat[i, j] = 0.0
        end
        res["R"] = _out(Rmat, xxnames, xxnames)
    end
    res["rank"] = rank
    if fit !== nothing
        res["qr"] = RList("qr" => _out(fit.qr, nothing, xxnames), "rank" => rank, "qraux" => fit.qraux,
                          "pivot" => fit.pivot, "tol" => min(1e-7, eps_c / 1000); class = "qr")
    end
    res["family"] = family
    res["linear.predictors"] = _vec_out(eta, ynames)
    res["deviance"] = fit !== nothing ? dev : devold
    wtdmu = intercept ? _rsum(wts .* y) / _rsum(wts) : linkinv(off)
    nulldev = _rsum(dev_resids(y, wtdmu, wts))
    n_ok = nobs - count(==(0), wts)
    nulldf = n_ok - (intercept ? 1 : 0)
    resdf = n_ok - rank
    aic_model = try
        family["aic"](y, n_, mu, wts, res["deviance"]) + 2 * rank
    catch
        NaN
    end
    res["aic"] = aic_model
    res["null.deviance"] = nulldev
    res["iter"] = it
    wt = zeros(nobs)
    w !== nothing && (wt[good] = w .* w)
    res["weights"] = _vec_out(wt, ynames)
    res["prior.weights"] = _vec_out(wts, ynames)
    res["df.residual"] = resdf
    res["df.null"] = nulldf
    res["y"] = _vec_out(y, ynames)
    res["converged"] = conv
    res["boundary"] = boundary
    return res
end

# ── p.adjust / ecdf / ave / aggregate / t.test ───────────────────────────

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

"`t.test.default(x, y, alternative, mu, paired, var.equal, conf.level)`: RList (Klasse \"htest\")."
function t_test(x, y = nothing; alternative::AbstractString = "two.sided", mu::Real = 0, paired::Bool = false,
                var_equal::Bool = false, conf_level::Real = 0.95)
    alts = ["two.sided", "less", "greater"]
    am = [a for a in alts if startswith(a, alternative)]
    length(am) != 1 && error("'arg' should be one of “two.sided”, “less”, “greater”")
    alternative = am[1]
    isnan(mu) && error("'mu' must be a single number")
    (isfinite(conf_level) && 0 <= conf_level <= 1) || error("'conf.level' must be a single number between 0 and 1")
    mu = Float64(mu); conf_level = Float64(conf_level)
    xv = _v(x)
    if y !== nothing
        yv = _v(y)
        dname = "x and y"
        if paired
            ok = .!(isnan.(xv) .| isnan.(yv))
            xok = yok = ok
        else
            yok = .!isnan.(yv)
            xok = .!isnan.(xv)
        end
        yv = yv[yok]
    else
        dname = "x"
        paired && error("'y' is missing for paired test")
        xok = .!isnan.(xv)
        yv = nothing
    end
    xv = xv[xok]
    if paired
        xv = xv .- yv
        yv = nothing
    end
    nx = length(xv)
    mx = _rmean(xv)
    vx = nx > 1 ? var(xv) : NA
    eps = _DBL_EPS
    NM = SimLev.RNmath
    if yv === nothing
        nx < 2 && error("not enough 'x' observations")
        df = Float64(nx - 1)
        stderr_ = sqrt(vx / nx)
        stderr_ < 10 * eps * abs(mx) && error("data are essentially constant")
        tstat = (mx - mu) / stderr_
        method = paired ? "Paired t-test" : "One Sample t-test"
        estimate = RVector([mx]; names = [paired ? "mean difference" : "mean of x"])
    else
        ny = length(yv)
        (nx < 1 || (!var_equal && nx < 2)) && error("not enough 'x' observations")
        (ny < 1 || (!var_equal && ny < 2)) && error("not enough 'y' observations")
        (var_equal && nx + ny < 3) && error("not enough observations")
        my = _rmean(yv)
        vy = ny > 1 ? var(yv) : NA
        method = (var_equal ? " " : "Welch ") * "Two Sample t-test"
        estimate = RVector([mx, my]; names = ["mean of x", "mean of y"])
        if var_equal
            df = Float64(nx + ny - 2)
            v = 0.0
            nx > 1 && (v = v + (nx - 1) * vx)
            ny > 1 && (v = v + (ny - 1) * vy)
            v = v / df
            stderr_ = sqrt(v * (1 / nx + 1 / ny))
        else
            stderrx = sqrt(vx / nx)
            stderry = sqrt(vy / ny)
            stderr_ = sqrt(stderrx * stderrx + stderry * stderry)
            df = SimLev.r_pow(stderr_, 4) / (SimLev.r_pow(stderrx, 4) / (nx - 1) + SimLev.r_pow(stderry, 4) / (ny - 1))
        end
        stderr_ < 10 * eps * max(abs(mx), abs(my)) && error("data are essentially constant")
        tstat = (mx - my - mu) / stderr_
    end
    if alternative == "less"
        pval = NM.pt(tstat, df)
        cint = [-Inf, tstat + NM.qt(conf_level, df)]
    elseif alternative == "greater"
        pval = NM.pt(tstat, df; lower_tail = false)
        cint = [tstat - NM.qt(conf_level, df), Inf]
    else
        pval = 2 * NM.pt(-abs(tstat), df)
        alpha = 1 - conf_level
        c = NM.qt(1 - alpha / 2, df)
        cint = [tstat + (-c), tstat + c]
    end
    cint = RVector([mu + v * stderr_ for v in cint]; attrs = Dict{String,Any}("conf.level" => conf_level))
    return RList("statistic" => RVector([tstat]; names = ["t"]), "parameter" => RVector([df]; names = ["df"]),
                 "p.value" => pval, "conf.int" => cint, "estimate" => estimate,
                 "null.value" => RVector([mu]; names = [paired ? "mean difference" : (y !== nothing ? "difference in means" : "mean")]),
                 "stderr" => stderr_, "alternative" => alternative, "method" => method, "data.name" => dname;
                 class = "htest")
end

"Generisches `predict` (smooth.spline; lm/glm: angepasste Werte bzw. linearer Prädiktor)."
function predict(object, args...; kwargs...)
    if object isa RList
        "smooth.spline" in object.class && return predict_smooth_spline(object, args...; kwargs...)
        if "smooth.spline.fit" in object.class
            x = isempty(args) ? nothing : args[1]
            return _predict_ssfit(object, x, Int(get(kwargs, :deriv, 0)))
        end
        if isempty(args) && isempty(kwargs)
            "glm" in object.class && return object["linear.predictors"]
            "lm" in object.class && return object["fitted.values"]
        end
    end
    error("predict() für dieses Objekt ist nicht portiert")
end
