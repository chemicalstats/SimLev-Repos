# Herkunft:           nachgebildet nach R 4.3.3, src/library/stats/R/optimize.R und src/library/stats/src/optimize.c
#                     (do_fmin, fcn1); Brent_fmin seit 1.6.0 im Kern (core/slc_opt_fmin.cpp, bis 1.5.2 _optim.jl)
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); Verfahren R. P. Brent, Algorithms for
#                     Minimization without Derivatives (1973), über Netlib go/fmin.f (ohne Urheber-
#                     und Lizenzvermerk)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
# Eindimensionales Verfahren optimize aus R 4.3.3 stats/R/optimize.R und
# stats/src/optimize.c; Python: _r/stats_optim.py. Teil des Untermoduls RStats (eingebunden in stats.jl).
#
# Seit 1.0.0 entfallen optim, optimhess und nlminb (PORT): SimLev optimiert mit den eigenen
# Verfahren der C-Bibliothek slc (SimLev.SLib). Seit 1.5.2 entfällt uniroot (ohne Aufrufer, seit 1.4.0
# rechnet XIRR im Kern mit sl_r_zeroin2).

# ── optimize ────────────────────────────────────────────────────

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
    # Brent fmin seit 1.6.0 im Kern (core/slc_opt_fmin.cpp, Frage/Antwort; bis 1.5.2 r/_optim.jl)
    ws = Vector{Float64}(undef, 24)                       # SL_FMIN_WS
    SimLev.SLib.fmin_init!(ws, lower, upper, tol)
    need, val = SimLev.SLib.fmin_ask!(ws)
    while need
        SimLev.SLib.fmin_tell!(ws, fcn1(val))
        need, val = SimLev.SLib.fmin_ask!(ws)
    end
    obj = f(val, args...; kwargs...)
    a = _num1(obj)
    return RList((maximum ? "maximum" : "minimum") => val, "objective" => (length(a) == 1 ? a[1] : obj))
end
