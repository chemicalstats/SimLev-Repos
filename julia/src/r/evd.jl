"""
Nachbildung von evd 2.3-7.1 (Teil: `fpot`), im R-Paket übernommen als `.evd_fpot`.

Herkunft: R-Paket evd 2.3-7.1 (CRAN, 2024-09-21), `R/uvfit.R` (`fpot`,
`fpot.norm`) und `src/pot.c` (`nlgpd`); Autoren: Alec Stephenson. Function
fbvpot by Chris Ferro. Lizenz: GPL-3. Nach Julia übertragen und angepasst für
SimLev (siehe `julia/COPYRIGHTS.md`).

Nachgebildet ist `fpot(x, threshold, model = "gpd", ...)` mit `fpot.norm`
(`cmax = FALSE`, `mper = NULL`): Startwerte, die negative Log-Likelihood
`nlgpd` aus `src/pot.c` (Strafwert `1e6`, Exponential-Grenzfall für
`|shape| <= DBL_EPSILON^0.3`), die Prüfung von `.C` auf nicht endliche
Argumente, der `optim`-Aufruf mit `hessian = TRUE`, feste Parameter
(`scale`/`shape`), die Standardfehler über `qr`/`solve.qr` und alle Meldungen
von evd. Nicht nachgebildet sind `model = "pp"`, `cmax = TRUE` (Cluster) und
`mper` (Quantil-Parametrisierung); sie werfen einen Fehler.

SimLev nutzt `fpot` in `.fit_tail` (`bootstrap`, Verfahren `"evt"`) bei
mindestens 30 Überschreitungen; R nutzt dafür die übernommene Fassung
`.evd_fpot` (`r/R/vendor_evd.R`, `r/src/vendor_evd.c`), evd selbst ist nicht
mehr nötig. Vorlage: `python/simlev/_r/evd.py`.
"""
module REvd

import ..SimLev
import ..SimLev: RList, RVector, NamedMat, NA

export fpot, nlgpd

const _DBL_EPS = 2.220446049250313e-16

_warn(msg) = (@warn String(msg); nothing)

"`.C` mit `NAOK = FALSE`: nicht endliche double-Argumente sind ein Fehler."
function _c_check(exceed::Vector{Float64}, loc::Float64, scale::Float64, shape::Float64)
    all(isfinite, exceed) || error("NA/NaN/Inf in foreign function call (arg 1)")
    isfinite(loc) || error("NA/NaN/Inf in foreign function call (arg 3)")
    isfinite(scale) || error("NA/NaN/Inf in foreign function call (arg 4)")
    isfinite(shape) || error("NA/NaN/Inf in foreign function call (arg 5)")
    nothing
end

"""
    nlgpd(exceed, loc, scale, shape)

Negative Log-Likelihood der GPD wie `nlgpd` in evd `src/pot.c`: `1e6` für
`scale <= 0` oder einen Punkt außerhalb des Trägers; für
`|shape| <= DBL_EPSILON^0.3` die Exponentialverteilung. Summiert wie in C
sequenziell in `double`.
"""
function nlgpd(exceed, loc, scale, shape)
    ex = Float64[Float64(v) for v in exceed]
    loc = Float64(loc); scale = Float64(scale); shape = Float64(shape)
    _c_check(ex, loc, scale, shape)
    eps = SimLev.RLibm.pow(_DBL_EPS, 0.3)          # R_pow(DBL_EPSILON, 0.3)
    scale <= 0 && return 1e6
    lsc = SimLev.RLibm.log(1 / scale)
    n = length(ex)
    dvec = Vector{Float64}(undef, n)
    if abs(shape) <= eps
        for i in 1:n
            d = (ex[i] - loc) / scale
            dvec[i] = lsc - d
        end
    else
        a = 1 / shape + 1
        for i in 1:n
            d = (ex[i] - loc) / scale
            d = 1 + shape * d
            d <= 0 && return 1e6
            dvec[i] = lsc - a * SimLev.RLibm.log(d)
        end
    end
    dns = 0.0
    for i in 1:n
        dns = dns - dvec[i]
    end
    return dns
end

_isnumtype(T) = (S = Base.nonmissingtype(T); S <: Real && !(S <: Bool))

function _numvec(x)
    x === nothing && return nothing
    if x isa Real
        x isa Bool && return nothing
        return [Float64(x)]
    end
    x isa AbstractVector || return nothing
    v = x isa RVector ? x.values : x
    _isnumtype(eltype(v)) || return nothing
    return Float64[e === missing ? NA : Float64(e) for e in v]
end

_pairs_of(s::NamedTuple) = [(String(k), v) for (k, v) in pairs(s)]
_pairs_of(s::AbstractDict) = [(String(k), v) for (k, v) in s]
_pairs_of(s::RList) = [(k, s[k]) for k in keys(s)]
_first(v) = v isa AbstractArray ? Float64(first(v)) : Float64(v)

"""
    fpot(x, threshold; model = "gpd", start = nothing, npp = length(x), cmax = false, r = 1,
         ulow = -Inf, rlow = 1, mper = nothing, std_err = true, corr = false, method = "BFGS",
         warn_inf = true, kwargs...)

Peaks-over-Threshold-Anpassung der verallgemeinerten Pareto-Verteilung
(evd `fpot`, bitgleich zu evd 2.3-7.1): Maximum-Likelihood-Schätzung von
`scale` und `shape` für die Werte von `x` über `threshold` (`optim` mit
`method`, `hessian = TRUE`).

`start`: NamedTuple/Dict mit Startwerten (`scale`, `shape`; Standard:
Mittel der Überschreitungen minus Schwelle und `0`). `std_err`:
Standardfehler und Kovarianzmatrix, `corr`: Korrelationsmatrix. `warn_inf`:
warnen, wenn die negative Log-Likelihood am Start `1e6` ist. `kwargs`: feste
Parameter `scale`/`shape` sowie `control`, `lower`, `upper` für `optim` (wie
R's `...`). Von `model`, `cmax`, `r`, `ulow`, `rlow`, `mper` sind nur die
Voreinstellungen nachgebildet.

Ergebnis: RList der Klasse `c("pot", "uvevd", "evd")` mit den Elementen von
R (`estimate`, `std.err`, `fixed`, `param`, `deviance`, `corr`, `var.cov`,
`convergence`, `counts`, `message`, `threshold`, …, `scale`; ohne `call`).
"""
function fpot(x, threshold; model::AbstractString = "gpd", start = nothing, npp = nothing, cmax::Bool = false,
              r = 1, ulow = -Inf, rlow = 1, mper = nothing, std_err::Bool = true, corr::Bool = false,
              method::AbstractString = "BFGS", warn_inf::Bool = true, kwargs...)
    model in ("gpd", "pp") || error("'arg' should be one of “gpd”, “pp”")
    xv = _numvec(x)
    (xv === nothing || isempty(xv)) && error("`x' must be a non-empty numeric vector")
    th = _numvec(threshold)
    (th === nothing || length(th) != 1) && error("`threshold' must be a numeric value")
    thr = th[1]
    if mper !== nothing
        model == "pp" && error("`mper' cannot be specified in point process models")
        error("evd-Nachbildung: fpot mit mper (fpot.quantile) nicht nachgebildet")
    end
    model == "pp" && error("evd-Nachbildung: fpot mit model = \"pp\" nicht nachgebildet")
    cmax && error("evd-Nachbildung: fpot mit cmax = TRUE (clusters) nicht nachgebildet")
    param = ["scale", "shape"]
    opt_kw = Pair{Symbol,Any}[]
    dots = Tuple{String,Float64}[]
    for (k, v) in pairs(kwargs)
        if k in (:control, :lower, :upper)
            push!(opt_kw, k => v)
        elseif String(k) in param
            push!(dots, (String(k), _first(v)))
        else
            throw(ArgumentError("fpot: unbekanntes Argument $k"))
        end
    end
    dot_names = String[k for (k, _) in dots]
    nn = length(xv)
    npp === nothing && (npp = nn)
    # fpot.norm, cmax = FALSE
    exceed = isnan(thr) ? fill(thr, count(!isnan, xv)) : Float64[v for v in xv if v > thr && !isnan(v)]
    nhigh = nat = length(exceed)
    nhigh == 0 && error("no data above threshold")
    pat = nat / nn
    if start === nothing
        st = [("scale", SimLev.r_mean(exceed) - thr), ("shape", 0.0)]
        st = [(k, v) for (k, v) in st if !(k in dot_names)]
    else
        (start isa NamedTuple || start isa AbstractDict) || error("`start' must be a named list")
        st = [(k, _first(v)) for (k, v) in _pairs_of(start)]
    end
    isempty(st) && error("there are no parameters left to maximize over")
    nm = String[k for (k, _) in st]
    any(k -> !(k in param), nm) && error("`start' specifies unknown arguments")
    fixed = [(k, v) for (k, v) in dots if k in param]
    fnames = String[k for (k, _) in fixed]
    any(p -> !(p in nm || p in fnames), param) && error("unspecified parameters")
    for k in fnames
        k in nm && error("formal argument \"$k\" matched by multiple actual arguments")
    end
    fixed_d = Dict{String,Float64}(fixed)
    function nllh(p)
        a = copy(fixed_d)
        for (i, k) in enumerate(nm)
            a[k] = Float64(p[i])
        end
        return nlgpd(exceed, thr, a["scale"], a["shape"])
    end
    p0 = RVector(Float64[v for (_, v) in st]; names = nm)
    warn_inf && nllh(p0) == 1e6 && _warn("negative log-likelihood is infinite at starting values")
    opt = SimLev.RStats.optim(p0, nllh; method = method, hessian = true, opt_kw...)
    par = opt["par"]
    par isa RVector || (par = RVector(Float64[Float64(v) for v in (par isa AbstractArray ? par : [par])]; names = nm))
    conv = opt["convergence"]
    if conv != 0
        _warn("optimization may not have succeeded")
        conv == 1 && (conv = "iteration limit reached")
    else
        conv = "successful"
    end
    se = var_cov = corr_v = nothing
    if std_err
        tol = SimLev.RLibm.pow(_DBL_EPS, 0.5)
        q = SimLev.RLinalg.qr(opt["hessian"]; tol = tol)
        Q = q["qr"]
        q["rank"] != size(Q isa NamedMat ? Q.data : Q, 2) &&
            error("observed information matrix is singular; use std.err = FALSE")
        var_cov = SimLev.RLinalg.solve_qr(q)
        d = SimLev.RLinalg.diag(var_cov)
        sev = d isa Number ? [Float64(d)] : Float64[Float64(v) for v in (d isa RVector ? d.values : d)]
        any(v -> v <= 0, sev) && error("observed information matrix is singular; use std.err = FALSE")
        any(isnan, sev) && error("missing value where TRUE/FALSE needed")
        sev = sqrt.(sev)
        se = RVector(sev; names = nm)
        if corr
            k = length(sev)
            mat = SimLev.RLinalg.diag(1 ./ sev; nrow = k)
            cm = SimLev.RLinalg.matprod(SimLev.RLinalg.matprod(mat, var_cov), mat)
            cm = copy(cm isa NamedMat ? cm.data : (cm isa Number ? fill(Float64(cm), 1, 1) : Matrix{Float64}(cm)))
            for i in 1:k
                cm[i, i] = 1.0
            end
            corr_v = NamedMat(cm; rownames = nm, colnames = nm)
        end
    end
    fixed_v = isempty(fixed) ? nothing : RVector(Float64[v for (_, v) in fixed]; names = fnames)
    param_v = fixed_v === nothing ? RVector(copy(par.values); names = copy(par.names)) :
              RVector(vcat(par.values, fixed_v.values); names = vcat(par.names, fixed_v.names))
    scale = RVector([param_v["scale"]]; names = ["scale"])
    return RList("estimate" => par, "std.err" => se, "fixed" => fixed_v, "param" => param_v,
                 "deviance" => 2 * opt["value"], "corr" => corr_v, "var.cov" => var_cov,
                 "convergence" => conv, "counts" => opt["counts"], "message" => opt["message"],
                 "threshold" => thr, "cmax" => false, "r" => nothing, "ulow" => ulow, "rlow" => rlow,
                 "npp" => npp, "nhigh" => nhigh, "nat" => nat, "pat" => pat, "extind" => nothing,
                 "data" => xv, "exceedances" => exceed, "mper" => nothing, "scale" => scale;
                 class = ["pot", "uvevd", "evd"])
end

end # module
