# Optimierer optimize, uniroot, optim, optimhess und die nlminb-Anbindung an die PORT-Bibliothek aus R 4.3.3
# stats/R/optimize.R, optim.R, nlminb.R und stats/src/optimize.c, optim.c, port.c; Python: _r/stats_optim.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).

# ── optimize / uniroot / optim ───────────────────────────────────────────

"Rückgabe einer Zielfunktion als double-Vektor (coerceVector)."
_num1(v) = v isa Number || v === missing ? Float64[_fl(v)] : _v(v)

"""
    optimize(f, interval = nothing, args...; lower, upper, maximum = false, tol = .Machine\$double.eps^0.25, kwargs...)

`optimize(f, interval, ..., lower, upper, maximum, tol)` (Brent fmin): RList
mit `minimum` (bzw. `maximum`) und `objective`.
"""
function optimize(f, interval = nothing, args...; lower = nothing, upper = nothing, maximum::Bool = false,
                  tol::Real = 0.0001220703125, kwargs...)
    lower === nothing && (lower = Base.minimum(_v(interval)))
    upper === nothing && (upper = Base.maximum(_v(interval)))
    lower = Float64(lower); upper = Float64(upper)
    seen = Set{String}()
    function fcn1(x)
        a = _num1(f(x, args...; kwargs...))
        length(a) != 1 && error("invalid function value in 'optimize'")
        v = maximum ? -a[1] : a[1]
        if !isfinite(v)
            _warn1!(seen, "NA/Inf replaced by maximum positive value")
            return _DBL_MAX
        end
        return v
    end
    isfinite(lower) || error("invalid 'xmin' value")
    isfinite(upper) || error("invalid 'xmax' value")
    lower >= upper && error("'xmin' not less than 'xmax'")
    tol = Float64(tol)
    (!isfinite(tol) || tol <= 0.0) && error("invalid 'tol' value")
    val = brent_fmin(lower, upper, fcn1, tol)
    obj = f(val, args...; kwargs...)
    a = _num1(obj)
    return RList((maximum ? "maximum" : "minimum") => val, "objective" => (length(a) == 1 ? a[1] : obj))
end
const optimise = optimize

_g(x) = SimLev.r_sprintf("%g", x)

"""
    uniroot(f, interval = nothing, args...; lower, upper, f_lower, f_upper, extendInt = "no", check_conv = false, tol, maxiter = 1000, trace = 0, kwargs...)

`uniroot(...)`: RList mit `root`, `f.root`, `iter`, `init.it`, `estim.prec`.
"""
function uniroot(f, interval = nothing, args...; lower = nothing, upper = nothing, f_lower = nothing,
                 f_upper = nothing, extendInt::AbstractString = "no", check_conv::Bool = false,
                 tol::Real = 0.0001220703125, maxiter::Integer = 1000, trace::Integer = 0, kwargs...)
    if interval !== nothing
        length(_v(interval)) != 2 && error("'interval' must be a vector of length 2")
    end
    lower === nothing && (lower = Base.minimum(_v(interval)))
    upper === nothing && (upper = Base.maximum(_v(interval)))
    lower = Float64(lower); upper = Float64(upper)
    lower < upper || error("lower < upper  is not fulfilled")
    ff(x) = (v = _num1(f(x, args...; kwargs...)); isempty(v) ? NaN : v[1])
    f_lower === nothing && (f_lower = ff(lower))
    isnan(f_lower) && error("f.lower = f(lower) is NA")
    f_upper === nothing && (f_upper = ff(upper))
    isnan(f_upper) && error("f.upper = f(upper) is NA")
    f_lower = Float64(f_lower); f_upper = Float64(f_upper)
    sigs = [("yes", nothing), ("downX", -1.0), ("no", 0.0), ("upX", 1.0)]
    ext = isempty(extendInt) ? [] : [v for (k, v) in sigs if startswith(k, extendInt)]
    length(ext) != 1 && error("'arg' should be one of “no”, “yes”, “downX”, “upX”")
    Sig = ext[1]
    trunc_(x) = isnan(x) ? x : max(min(x, _DBL_MAX), -_DBL_MAX)
    flo = trunc_(f_lower)
    fup = trunc_(f_upper)
    doX = (Sig === nothing && flo * fup > 0) || (Sig !== nothing && (Sig * flo > 0 || Sig * fup < 0))
    it = 0
    if doX
        trace != 0 && print("search in [" * _g(lower) * "," * _g(upper) * "]" * (trace >= 2 ? "\n" : " ... "))
        Delta(u) = 0.01 * max(1e-4, abs(u))
        if Sig === nothing
            delta = [Delta(lower), Delta(upper)]
            while (f_lower * f_upper > 0) && (isfinite(lower) || isfinite(upper))
                iF = (isfinite(lower), isfinite(upper))
                it += 1
                it > maxiter && error("no sign change found in $(it - 1) iterations")
                if iF[1]
                    ol, of = lower, f_lower
                    lower = lower - delta[1]
                    f_lower = ff(lower)
                    if isnan(f_lower)
                        lower, f_lower = ol, of
                        delta[1] = delta[1] / 4
                    end
                end
                if iF[2]
                    ol, of = upper, f_upper
                    upper = upper + delta[2]
                    f_upper = ff(upper)
                    if isnan(f_upper)
                        upper, f_upper = ol, of
                        delta[2] = delta[2] / 4
                    end
                end
                trace >= 2 && println(SimLev.r_sprintf(" .. modified lower,upper: (%15s,%15s)", _g(lower), _g(upper)))
                delta = [2 * delta[1], 2 * delta[2]]
            end
        else
            delta = Delta(lower)
            while Sig * f_lower > 0
                it += 1
                it > maxiter && error("no sign change found in $(it - 1) iterations")
                lower = lower - delta
                f_lower = ff(lower)
                trace >= 2 && println(" .. modified lower: " * _g(lower))
                delta = 2 * delta
            end
            delta = Delta(upper)
            while Sig * f_upper < 0
                it += 1
                it > maxiter && error("no sign change found in $(it - 1) iterations")
                upper = upper + delta
                f_upper = ff(upper)
                trace >= 2 && println(" .. modified upper: " * _g(upper))
                delta = 2 * delta
            end
        end
        (trace != 0 && trace < 2) && println("extended to [" * _g(lower) * ", " * _g(upper) * "] in $it steps")
    end
    sg(v) = isnan(v) ? NaN : (v == 0 ? 0.0 : copysign(1.0, v))
    prod = sg(f_lower) * sg(f_upper)
    if !(!isnan(prod) && prod <= 0)
        error(doX ? "did not succeed extending the interval endpoints for f(lower) * f(upper) <= 0" :
              "f() values at end points not of opposite sign")
    end
    if doX && it != 0
        flo = trunc_(f_lower)
        fup = trunc_(f_upper)
    end
    isfinite(lower) || error("invalid 'xmin' value")
    isfinite(upper) || error("invalid 'xmax' value")
    lower >= upper && error("'xmin' not less than 'xmax'")
    tol = Float64(tol)
    (!isfinite(tol) || tol <= 0.0) && error("invalid 'tol' value")
    maxit = Int(maxiter)
    maxit <= 0 && error("'maxiter' must be positive")
    warned = String[]
    seen = Set{String}()
    function fcn2(x)
        v = _num1(f(x, args...; kwargs...))
        length(v) != 1 && error("invalid function value in 'zeroin'")
        val = v[1]
        if !isfinite(val)
            msg = val == -Inf ? "-Inf replaced by maximally negative value" : "NA/Inf replaced by maximum positive value"
            check_conv ? push!(warned, msg) : _warn1!(seen, msg)
            return val == -Inf ? -_DBL_MAX : _DBL_MAX
        end
        return val
    end
    root, itr, prec = zeroin2(lower, upper, flo, fup, fcn2, tol, maxit)
    (check_conv && !isempty(warned)) && error("convergence problem in zero finding: " * warned[1])
    if itr < 0
        msg = maxiter == 1 ? "_NOT_ converged in $maxiter iteration" : "_NOT_ converged in $maxiter iterations"
        check_conv && error(msg)
        @warn msg
        itr = Int(maxiter)
    end
    if doX
        itr = itr + it
        init_it = it
    else
        init_it = missing
    end
    return RList("root" => root, "f.root" => ff(root), "iter" => itr, "init.it" => init_it, "estim.prec" => prec)
end

const _OPTIM_METHODS = ("Nelder-Mead", "BFGS", "CG", "L-BFGS-B", "SANN", "Brent")

"fminfn/fmingr aus optim.c."
struct _Fn{F,G}
    fn::F
    gr::G
    fnscale::Float64
    parscale::Vector{Float64}
    ndeps::Union{Nothing,Vector{Float64}}
    names::Union{Nothing,Vector{String}}
    lower::Union{Nothing,Vector{Float64}}
    upper::Union{Nothing,Vector{Float64}}
    usebounds::Bool
end
_Fn(fn, gr, fnscale, parscale, ndeps, names; lower = nothing, upper = nothing, usebounds = false) =
    _Fn(fn, gr, fnscale, parscale, ndeps, names, lower, upper, usebounds)

_wrap(F::_Fn, x) = F.names === nothing ? (length(x) == 1 ? x[1] : collect(Float64, x)) : RVector(collect(Float64, x); names = F.names)

function _call(F::_Fn, x)
    s = _num1(F.fn(_wrap(F, x)))
    length(s) != 1 && error("objective function in optim evaluates to length $(length(s)) not 1")
    return s[1]
end

function _fminfn(F::_Fn, p)
    x = Vector{Float64}(undef, length(p))
    for i in eachindex(p)
        isfinite(p[i]) || error("non-finite value supplied by optim")
        x[i] = p[i] * F.parscale[i]
    end
    return _call(F, x) / F.fnscale
end

function _fmingr(F::_Fn, p)
    n = length(p)
    ps = F.parscale
    if F.gr !== nothing
        x = Vector{Float64}(undef, n)
        for i in 1:n
            isfinite(p[i]) || error("non-finite value supplied by optim")
            x[i] = p[i] * ps[i]
        end
        s = _num1(F.gr(_wrap(F, x)))
        length(s) != n && error("gradient in optim evaluated to length $(length(s)) not $n")
        return Float64[s[i] * ps[i] / F.fnscale for i in 1:n]
    end
    df = zeros(n)
    x = Float64[p[i] * ps[i] for i in 1:n]
    if !F.usebounds
        for i in 1:n
            eps = F.ndeps[i]
            x[i] = (p[i] + eps) * ps[i]
            val1 = _call(F, x) / F.fnscale
            x[i] = (p[i] - eps) * ps[i]
            val2 = _call(F, x) / F.fnscale
            df[i] = (val1 - val2) / (2 * eps)
            isfinite(df[i]) || error("non-finite finite-difference value [$i]")
            x[i] = p[i] * ps[i]
        end
    else
        for i in 1:n
            epsused = eps = F.ndeps[i]
            tmp = p[i] + eps
            if tmp > F.upper[i]
                tmp = F.upper[i]
                epsused = tmp - p[i]
            end
            x[i] = tmp * ps[i]
            val1 = _call(F, x) / F.fnscale
            tmp = p[i] - eps
            if tmp < F.lower[i]
                tmp = F.lower[i]
                eps = p[i] - tmp
            end
            x[i] = tmp * ps[i]
            val2 = _call(F, x) / F.fnscale
            df[i] = (val1 - val2) / (epsused + eps)
            isfinite(df[i]) || error("non-finite finite-difference value [$i]")
            x[i] = p[i] * ps[i]
        end
    end
    return df
end

_ctl_dict(control::Nothing) = Dict{String,Any}()
_ctl_dict(control::AbstractDict) = Dict{String,Any}(replace(string(k), "warn_1d_NelderMead" => "warn.1d.NelderMead") => v for (k, v) in control)
_ctl_dict(control::NamedTuple) = _ctl_dict(Dict(pairs(control)))
_ctl_keys(control::Nothing) = String[]
_ctl_keys(control::NamedTuple) = [replace(string(k), "warn_1d_NelderMead" => "warn.1d.NelderMead") for k in keys(control)]
_ctl_keys(control::AbstractDict) = [replace(string(k), "warn_1d_NelderMead" => "warn.1d.NelderMead") for k in keys(control)]
_resize(v::Vector{Float64}, n) = n == 0 ? Float64[] : Float64[v[(i - 1) % length(v) + 1] for i in 1:n]

"""
    optim(par, fn, gr = nothing, args...; method = "Nelder-Mead", lower = -Inf, upper = Inf, control = nothing, hessian = false, kwargs...)

`optim(...)`; Methoden "Nelder-Mead", "BFGS", "CG", "L-BFGS-B", "Brent".
`control` als Dict/NamedTuple wie in R (maxit, reltol, abstol, fnscale,
parscale, ndeps, factr, pgtol, lmm, alpha, beta, gamma, type, trace, REPORT,
warn.1d.NelderMead). Ergebnis: RList mit par, value, counts (RVector
function/gradient), convergence, message (und hessian).
"""
function optim(par, fn, gr = nothing, args...; method::AbstractString = "Nelder-Mead", lower = -Inf, upper = Inf,
               control = nothing, hessian::Bool = false, kwargs...)
    names = _names_of(par)
    pv = _v(par)
    fn1 = p -> fn(p, args...; kwargs...)
    gr1 = gr === nothing ? nothing : (p -> gr(p, args...; kwargs...))
    meths = [m for m in _OPTIM_METHODS if startswith(m, method)]
    length(meths) != 1 && error("'arg' should be one of “Nelder-Mead”, “BFGS”, “CG”, “L-BFGS-B”, “SANN”, “Brent”")
    method = meths[1]
    lo = _v(lower); up = _v(upper)
    if (any(>(-Inf), lo) || any(<(Inf), up)) && !(method in ("L-BFGS-B", "Brent"))
        @warn "bounds can only be used with method L-BFGS-B (or Brent)"
        method = "L-BFGS-B"
    end
    npar = length(pv)
    con = Dict{String,Any}("trace" => 0, "fnscale" => 1.0, "parscale" => ones(npar), "ndeps" => fill(1e-3, npar),
                           "maxit" => 100, "abstol" => -Inf, "reltol" => sqrt(_DBL_EPS), "alpha" => 1.0,
                           "beta" => 0.5, "gamma" => 2.0, "REPORT" => 10, "warn.1d.NelderMead" => true, "type" => 1,
                           "lmm" => 5, "factr" => 1e7, "pgtol" => 0.0, "tmax" => 10, "temp" => 10.0)
    nms = ["trace", "fnscale", "parscale", "ndeps", "maxit", "abstol", "reltol", "alpha", "beta", "gamma",
           "REPORT", "warn.1d.NelderMead", "type", "lmm", "factr", "pgtol", "tmax", "temp"]
    method == "Nelder-Mead" && (con["maxit"] = 500)
    if method == "SANN"
        con["maxit"] = 10000
        con["REPORT"] = 100
    end
    ctl = _ctl_dict(control)
    merge!(con, ctl)
    no = [k for k in _ctl_keys(control) if !(k in nms)]
    isempty(no) || @warn "unknown names in control: " * join(no, ", ")
    if con["trace"] < 0
        @warn "read the documentation for 'trace' more carefully"
    elseif method == "SANN" && con["trace"] != 0 && Int(con["REPORT"]) == 0
        error("'trace != 0' needs 'REPORT >= 1'")
    end
    (method == "L-BFGS-B" && (haskey(ctl, "reltol") || haskey(ctl, "abstol"))) &&
        @warn "method L-BFGS-B uses 'factr' (and 'pgtol') instead of 'reltol' and 'abstol'"
    (npar == 1 && method == "Nelder-Mead" && con["warn.1d.NelderMead"] === true) &&
        @warn "one-dimensional optimization by Nelder-Mead is unreliable:\nuse \"Brent\" or optimize() directly"
    (npar > 1 && method == "Brent") && error("method = \"Brent\" is only available for one-dimensional optimization")
    lo = _resize(lo, npar); up = _resize(up, npar)
    if method == "Brent"
        (all(isfinite, lo) && all(isfinite, up)) || error("'lower' and 'upper' must be finite values")
        fs = Float64(con["fnscale"])
        o = optimize(p -> _num1(fn(p, args...; kwargs...))[1] / fs; lower = lo[1], upper = up[1],
                     tol = Float64(con["reltol"]))
        res = RList("par" => o["minimum"], "value" => o["objective"] * fs,
                    "counts" => RVector(Union{Missing,Int}[missing, missing]; names = ["function", "gradient"]),
                    "convergence" => 0, "message" => nothing)
    else
        res = _optim_c(pv, names, fn1, gr1, method, con, lo, up)
    end
    hessian && (res["hessian"] = optimhess(res["par"], fn, gr, args...; control = con, kwargs...))
    return res
end

function _asint(v)
    v === nothing && error("'maxit' is not an integer")
    return trunc(Int, Float64(v))
end

function _optim_c(pv, names, fn1, gr1, method, con, lo, up)
    npar = length(pv)
    trace = Int(con["trace"])
    fnscale = Float64(con["fnscale"])
    ps = _v(con["parscale"])
    length(ps) != npar && error("'parscale' is of the wrong length")
    dpar = Float64[pv[i] / ps[i] for i in 1:npar]
    abstol = Float64(con["abstol"])
    reltol = Float64(con["reltol"])
    maxit = _asint(con["maxit"])
    function get_ndeps()
        nd = _v(con["ndeps"])
        length(nd) != npar && error("'ndeps' is of the wrong length")
        nd
    end
    msg = nothing
    if method == "Nelder-Mead"
        F = _Fn(fn1, nothing, fnscale, ps, nothing, names)
        X, val, fail, fncount = nmmin(npar, dpar, p -> _fminfn(F, p), abstol, reltol, Float64(con["alpha"]),
                                      Float64(con["beta"]), Float64(con["gamma"]), trace, maxit)
        par = Float64[X[i] * ps[i] for i in 1:npar]
        grcount = nothing
    elseif method == "SANN"
        error("optim(method = \"SANN\") ist nicht portiert")
    elseif method == "BFGS"
        nrep = Int(con["REPORT"])
        nd = gr1 !== nothing ? nothing : get_ndeps()
        F = _Fn(fn1, gr1, fnscale, ps, nd, names)
        b, val, fncount, grcount, fail = vmmin(npar, dpar, p -> _fminfn(F, p), p -> _fmingr(F, p), maxit, trace,
                                               fill(true, npar), abstol, reltol, nrep)
        par = Float64[b[i] * ps[i] for i in 1:npar]
    elseif method == "CG"
        typ = Int(con["type"])
        nd = gr1 !== nothing ? nothing : get_ndeps()
        F = _Fn(fn1, gr1, fnscale, ps, nd, names)
        X, val, fail, fncount, grcount = cgmin(npar, dpar, p -> _fminfn(F, p), p -> _fmingr(F, p), abstol, reltol,
                                               typ, trace, maxit)
        par = Float64[X[i] * ps[i] for i in 1:npar]
    else
        nrep = Int(con["REPORT"])
        factr = Float64(con["factr"])
        pgtol = Float64(con["pgtol"])
        lmm = Int(con["lmm"])
        nd = gr1 !== nothing ? nothing : get_ndeps()
        lower = Float64[lo[i] / ps[i] for i in 1:npar]
        upper = Float64[up[i] / ps[i] for i in 1:npar]
        nbd = Int[isfinite(lower[i]) ? (isfinite(upper[i]) ? 2 : 1) : (isfinite(upper[i]) ? 3 : 0) for i in 1:npar]
        F = _Fn(fn1, gr1, fnscale, ps, nd, names; lower = lower, upper = upper, usebounds = true)
        x, val, fail, fncount, grcount, msg = lbfgsb(npar, lmm, dpar, lower, upper, nbd, p -> _fminfn(F, p),
                                                     p -> _fmingr(F, p), factr, pgtol, maxit; trace = trace,
                                                     nREPORT = nrep)
        par = Float64[x[i] * ps[i] for i in 1:npar]
    end
    return RList("par" => _vec_out(par, names), "value" => val * fnscale,
                 "counts" => RVector(Union{Missing,Int}[fncount, grcount === nothing ? missing : grcount];
                                     names = ["function", "gradient"]),
                 "convergence" => Int(fail), "message" => msg)
end

"`optimHess(par, fn, gr, ..., control)` (Hesse-Matrix wie in optim)."
function optimhess(par, fn, gr = nothing, args...; control = nothing, kwargs...)
    names = _names_of(par)
    pv = _v(par)
    npar = length(pv)
    con = Dict{String,Any}("fnscale" => 1.0, "parscale" => ones(npar), "ndeps" => fill(1e-3, npar))
    if control !== nothing
        for (k, v) in _ctl_dict(control)
            haskey(con, k) && (con[k] = v)
        end
    end
    fnscale = Float64(con["fnscale"])
    ps = _v(con["parscale"])
    length(ps) != npar && error("'parscale' is of the wrong length")
    nd = _v(con["ndeps"])
    length(nd) != npar && error("'ndeps' is of the wrong length")
    fn1 = p -> fn(p, args...; kwargs...)
    gr1 = gr === nothing ? nothing : (p -> gr(p, args...; kwargs...))
    F = _Fn(fn1, gr1, fnscale, ps, nd, names)
    dpar = Float64[pv[i] / ps[i] for i in 1:npar]
    ans = zeros(npar, npar)
    for i in 1:npar
        eps = nd[i] / ps[i]
        dpar[i] = dpar[i] + eps
        df1 = _fmingr(F, dpar)
        dpar[i] = dpar[i] - 2 * eps
        df2 = _fmingr(F, dpar)
        for j in 1:npar
            ans[j, i] = (fnscale * (df1[j] - df2[j])) / (2 * eps * ps[i] * ps[j])
        end
        dpar[i] = dpar[i] + eps
    end
    for i in 1:npar, j in 1:i-1
        tmp = 0.5 * (ans[j, i] + ans[i, j])
        ans[j, i] = ans[i, j] = tmp
    end
    return _out(ans, names, names)
end

# ── nlminb (PORT) ─────────────────────────────────────────────────────────

const _PORT_CPOS = ("eval.max" => 17, "iter.max" => 18, "trace" => 19, "maxiter" => 18,
                    "abs.tol" => 31, "rel.tol" => 32, "x.tol" => 33, "xf.tol" => 34,
                    "step.min" => 35, "step.max" => 36, "sing.tol" => 37,
                    "scale.init" => 38, "diff.g" => 42)

const _PORT_MSG = Dict(3 => "X-convergence (3)", 4 => "relative convergence (4)",
                       5 => "both X-convergence and relative convergence (5)",
                       6 => "absolute function convergence (6)", 7 => "singular convergence (7)",
                       8 => "false convergence (8)",
                       9 => "function evaluation limit reached without convergence (9)",
                       10 => "iteration limit reached without convergence (10)",
                       14 => "storage only has been allocated (14)", 15 => "LIV too small (15)",
                       16 => "LV too small (16)", 63 => "fn cannot be computed at initial par (63)",
                       65 => "gr cannot be computed at initial par (65)",
                       300 => "initial par violates constraints")

"`pmatch(nms, table)` (duplicates.ok = FALSE); 0 = NA."
function _pmatch(nms::Vector{String}, table::Vector{String})
    used = falses(length(table))
    ans = zeros(Int, length(nms))
    for (i, s) in enumerate(nms), (j, t) in enumerate(table)
        if !used[j] && s == t
            ans[i] = j; used[j] = true
            break
        end
    end
    for (i, s) in enumerate(nms)
        (ans[i] != 0 || isempty(s)) && continue
        mtch = 0; cnt = 0
        for (j, t) in enumerate(table)
            if !used[j] && startswith(t, s)
                mtch = j; cnt += 1
            end
        end
        if mtch > 0 && cnt == 1
            used[mtch] = true
            ans[i] = mtch
        end
    end
    return ans
end

"`any(x != ref)` mit R's NA-Logik (`missing` = NA)."
function _r_any_ne(x::Vector{Float64}, ref::Float64)
    na = false
    for e in x
        if isnan(e)
            na = true
        elseif e != ref
            return true
        end
    end
    return na ? missing : false
end

function _ctl_int(val)
    val isa Bool && return Int(val)
    f = Float64(val)
    if isnan(f) || abs(f) >= 2147483648.0
        isnan(f) || @warn "NAs introduced by coercion to integer range"
        return -2147483648
    end
    return Int(trunc(f))
end

_ctl_pairs(control::Nothing) = Pair{String,Any}[]
_ctl_pairs(control::NamedTuple) = Pair{String,Any}[string(k) => v for (k, v) in pairs(control)]
_ctl_pairs(control) = Pair{String,Any}[string(k) => v for (k, v) in control]

"""
    nlminb(start, objective, gradient = nothing, hessian = nothing, args...;
           scale = 1, control = nothing, lower = -Inf, upper = Inf, kwargs...)

`nlminb(start, objective, gradient, hessian, ..., scale, control, lower, upper)`:
Minimierung mit der PORT-Bibliothek (`drmnf`, `drmng`, `drmnh` und die Varianten
mit Schranken `drmnfb`, `drmngb`, `drmnhb`) wie in R.

- `start`: Startwerte (Vektor oder benannter `RVector`).
- `objective`: Zielfunktion `objective(par, args...; kwargs...)`; `par` ist wie
  `start` benannt (`RVector`), sonst ein Vektor (Länge 1: Skalar).
- `gradient`: optional, Gradient (Länge n); `hessian`: optional (nur mit
  `gradient`), Hesse-Matrix n × n.
- `scale`: Skalierung der Parameter (wird auf n verlängert).
- `control`: `NamedTuple`, Pair-Vektor oder `Dict` mit `eval.max`, `iter.max`,
  `trace`, `abs.tol`, `rel.tol`, `x.tol`, `xf.tol`, `step.min`, `step.max`,
  `sing.tol`, `scale.init`, `diff.g` (Teilnamen wie in R; die Reihenfolge
  zählt nur für die Warnung über unbekannte Namen).
- `lower`, `upper`: Schranken (werden auf n verlängert).

Ergebnis: `RList` mit `par`, `objective`, `convergence`, `iterations`,
`evaluations` (`RVector` function/gradient) und `message`.
"""
function nlminb(start, objective, gradient = nothing, hessian = nothing, args...; scale = 1,
                control = nothing, lower = -Inf, upper = Inf, kwargs...)
    names = _names_of(start)
    pv = copy(_v(start))
    n = length(pv)
    liv = 78 + 3n
    lv = 130 + (n * (n + 27)) ÷ 2
    iv = zeros(Int, liv)
    v = zeros(lv)
    SimLev.RPort.divset(2, iv, liv, lv, v)
    ctl = _ctl_pairs(control)
    if !isempty(ctl)
        nms = String[first(p) for p in ctl]
        vals = Any[last(p) for p in ctl]
        tab = String[first(p) for p in _PORT_CPOS]
        pos = _pmatch(nms, tab)
        nap = pos .== 0
        if any(nap)
            msg = length(nap) == 1 ? "unrecognized control element named %s ignored" :
                  "unrecognized control elements named %s ignored"
            @warn replace(msg, "%s" => join(["‘" * nms[i] * "’" for i in eachindex(nms) if nap[i]], ", "))
            vals = vals[.!nap]
            pos = pos[.!nap]
        end
        ivv = [(last(_PORT_CPOS[p]), vals[i]) for (i, p) in enumerate(pos) if p <= 4]
        vvv = [(last(_PORT_CPOS[p]), vals[i]) for (i, p) in enumerate(pos) if p > 4]
        ivi = Int[_ctl_int(val) for (_, val) in ivv]
        for ((k, _), val) in zip(ivv, ivi)
            iv[k] = val
        end
        for (k, val) in vvv
            v[k] = Float64(val)
        end
    end
    fn = p -> objective(p, args...; kwargs...)
    gr = hs = nothing
    if gradient !== nothing
        gr = p -> gradient(p, args...; kwargs...)
        if hessian !== nothing
            hessian isa Bool && error("logical 'hessian' argument not allowed.  See documentation.")
            hs = p -> hessian(p, args...; kwargs...)
        end
    end
    lo = _v(lower)
    up = _v(upper)
    a1 = _r_any_ne(lo, -Inf)
    bounded = a1 === true ? true : _r_any_ne(up, Inf)
    (a1 === missing && bounded === false) && (bounded = missing)
    bounded === missing && error("missing value where TRUE/FALSE needed")
    low = bounded ? Float64[lo[(i - 1) % length(lo) + 1] for i in 1:n] : nothing
    upp = bounded ? Float64[up[(i - 1) % length(up) + 1] for i in 1:n] : nothing
    sc = _v(scale)
    d = n == 0 ? Float64[] : Float64[sc[(i - 1) % length(sc) + 1] for i in 1:n]
    x = SimLev.RPort.port_nlminb(fn, gr, hs, low, upp, d, iv, v, pv, names)
    iv1 = iv[1]
    if 19 <= iv1 <= 43
        hit = [first(p) for p in _PORT_CPOS if last(p) == iv1]
        msg = isempty(hit) ?
              SimLev.RFmt.r_sprintf("V[IV[1]] = V[%d] = %g is out of range (see PORT docu.)", iv1, v[iv1]) :
              SimLev.RFmt.r_sprintf("'control' component '%s' = %g, is out of range", hit[1], v[iv1])
    else
        msg = get(_PORT_MSG, iv1, "See PORT documentation.  Code ($iv1)")
    end
    return RList("par" => _vec_out(x, names), "objective" => v[10],
                 "convergence" => (3 <= iv1 <= 6 ? 0 : 1), "iterations" => iv[31],
                 "evaluations" => RVector([iv[6], iv[30]]; names = ["function", "gradient"]),
                 "message" => msg)
end
