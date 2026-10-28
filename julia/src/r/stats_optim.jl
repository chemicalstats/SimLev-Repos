# Eindimensionale Verfahren optimize und uniroot aus R 4.3.3 stats/R/optimize.R und
# stats/src/optimize.c; Python: _r/stats_optim.py. Teil des Untermoduls RStats (eingebunden in stats.jl).
#
# Seit Etappe 9.6c entfallen optim, optimhess und nlminb (PORT): SimLev optimiert mit den eigenen
# Verfahren der C-Bibliothek slc (SimLev.SLib, Entwurf B.8).

# ── optimize / uniroot ────────────────────────────────────────────────────

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


