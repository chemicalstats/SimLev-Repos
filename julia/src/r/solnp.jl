# ─────────────────────────────────────────────────────────────────────────────
# RSolnp – Nachbildung von Rsolnp::solnp (Rsolnp 1.16), bitgleich
#
# Herkunft: R-Paket Rsolnp 1.16 (CRAN, 2015-12-28), solnp, gosolnp und Hilfen;
# Autoren: Alexios Ghalanos and Stefan Theussl. Lizenz: GPL (laut
# inst/COPYRIGHTS von Rsolnp GPL-3). Nach Julia übertragen und angepasst für
# SimLev (siehe julia/COPYRIGHTS.md); im R-Paket übernommen als .rsolnp_solnp
# und .rsolnp_gosolnp (r/R/vendor_rsolnp.R).
#
# SQP-Verfahren nach Y. Ye (1989) mit erweiterter Lagrange-Funktion für
# Gleichungs- und Ungleichungsnebenbedingungen und Parameterschranken. Die
# Rechenschritte folgen dem R-Code von solnp, .subnp und den Hilfen
# (.checkpars, .checkfun, .checkineq, .checkeq, .safefunx, .solnpctrl, .vnorm,
# .solvecond) Zeile für Zeile; Matrixprodukte, chol, solve und qr.solve kommen
# aus SimLev.RLinalg (Referenz-BLAS/LAPACK/LINPACK wie R).
#
# Vorlage: python/simlev/_r/solnp.py. Nicht nachgebildet ist die Laufzeit
# (`elapsed` ist `nothing`). .solvecond (Konditionszahl über svd) beeinflusst
# nur eine Meldung bei trace > 0; die Fehlerprüfung von svd (nicht endliche
# Werte) ist nachgebildet, die Konditionszahl für mehr als eine Nebenbedingung
# über die Eigenwerte von a %*% t(a) berechnet (nicht bitgleich, nur für die
# Meldung).
# ─────────────────────────────────────────────────────────────────────────────
module RSolnp

import ..SimLev
import ..SimLev: RList, RVector, NA, isna_strict

export solnp, gosolnp

const _EPS = 2.220446049250313e-16          # Rsolnp:::.eps
const _SQRT_EPS = sqrt(_EPS)
const _DBL_XMAX = 1.7976931348623157e308

_rerr(msg) = error(msg)
_warn(msg) = (@warn String(msg); nothing)

"Lage, die der Nachbau nicht abdeckt (würde in R anders weiterlaufen)."
struct NotPortedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::NotPortedError) = print(io, e.msg)

# ── kleine R-Hilfen ─────────────────────────────────────────────────────────

"Vergleich `a op b` im if/while von R: NA/NaN ergibt einen Fehler."
function _c(a::Real, op::Symbol, b::Real)
    a = Float64(a); b = Float64(b)
    (isnan(a) || isnan(b)) && _rerr("missing value where TRUE/FALSE needed")
    op === :lt && return a < b
    op === :le && return a <= b
    op === :gt && return a > b
    return a >= b
end
_rif(x::Real) = (isnan(Float64(x)) && _rerr("missing value where TRUE/FALSE needed"); Float64(x) != 0.0)

"`max(v)` (ohne na.rm) wie R's rmax."
function _rmax(v)
    s = 0.0; upd = false
    for x in v
        x = Float64(x)
        if isnan(x)
            isna_strict(s) || (s = x)
            upd = true
        elseif !upd || x > s
            s = x; upd = true
        end
    end
    return upd ? s : -Inf
end

"`min(v)` (ohne na.rm) wie R's rmin."
function _rmin(v)
    s = 0.0; upd = false
    for x in v
        x = Float64(x)
        if isnan(x)
            isna_strict(s) || (s = x)
            upd = true
        elseif !upd || x < s
            s = x; upd = true
        end
    end
    return upd ? s : Inf
end

"`.vnorm(x) = sum(x^2)^(1/2)`."
_vnorm(x) = SimLev.r_pow(SimLev.r_sum(Float64[v * v for v in x]), 0.5)

"`X %*% Y` für zwei Matrizen wie R's matprod."
function _mm(X::AbstractMatrix, Y::AbstractMatrix)
    size(X, 2) != size(Y, 1) && _rerr("non-conformable arguments")
    SimLev.RLinalg._matprod_core(Matrix{Float64}(X), Matrix{Float64}(Y))
end
_col(v) = reshape(Float64.(collect(v)), :, 1)
_row(v) = reshape(Float64.(collect(v)), 1, :)
"`v %*% t(v)` für einen Vektor `v`."
_outer(v) = _mm(_col(v), _row(v))
_dot(a, b) = _mm(_row(a), _col(b))[1, 1]

_asvec(x::Real) = [Float64(x)]
_asvec(x::AbstractArray) = Float64.(vec(x))
_asvec(x::RVector) = Float64.(x.values)
_asvec(::Nothing) = Float64[]
_asmat(x::AbstractMatrix) = Matrix{Float64}(x)
_asmat(x) = SimLev.RLinalg.mat(SimLev.RLinalg._as_matrix(x))

_eye(n) = (A = zeros(n, n); for i in 1:n; A[i, i] = 1.0; end; A)

"`t(apply(gap, 1, sort))[, 1]` für eine Matrix mit zwei Spalten."
function _row_min_sorted(gap::AbstractMatrix)
    out = Vector{Float64}(undef, size(gap, 1))
    for i in 1:size(gap, 1)
        a = gap[i, 1]; b = gap[i, 2]
        (isnan(a) || isnan(b)) && throw(NotPortedError("solnp-Nachbildung: NA/NaN in den Abständen zu den Schranken"))
        out[i] = b < a ? b : a
    end
    out
end

"`.solvecond(a)`: Konditionszahl über `svd(a)\$d`."
function _solvecond(a::AbstractMatrix)
    all(isfinite, a) || _rerr("infinite or missing values in 'x'")
    if size(a, 1) == 1 || size(a, 2) == 1
        return any(!=(0.0), a) ? 1.0 : Inf
    end
    ev = _asvec(SimLev.RLinalg.eigen(_mm(a, permutedims(a)); symmetric = true, only_values = true)["values"])
    d = Float64[sqrt(max(x, 0.0)) for x in ev]
    any(==(0.0), d) && return Inf
    return maximum(d) / minimum(d)
end

_cat(txt) = (print(stdout, txt); nothing)

function _subnpmsg(m)
    g1 = "solnp-->"
    txt = if m == "m1"
        "\n" * g1 * "Redundant constraints were found. Poor\n" * g1 *
        "intermediate results may result.Suggest that you\n" * g1 * "remove redundant constraints and re-OPTIMIZE\n"
    elseif m == "m2"
        "\n" * g1 * "The linearized problem has no feasible\n" * g1 * "solution.  The problem may not be feasible.\n"
    else
        "\n" * g1 * "Minor optimization routine did not converge in the \n" * g1 *
        "specified number of minor iterations.  You may need\n" * g1 *
        "to increase the number of minor iterations.        \n"
    end
    _cat(txt)
end

"`.report(iter, funv, pars)` (nur bei trace > 0)."
function _report(it, funv, pars)
    _j(v) = v isa AbstractString ? String(v) : join(v, " ")
    f1 = try
        _j(SimLev.RFmt.format(funv; digits = 4, scientific = 5, nsmall = 4))
    catch
        string(funv)
    end
    f2 = try
        _j(SimLev.RFmt.format(collect(Float64, pars); digits = 4, scientific = 6, nsmall = 5))
    catch
        join(string.(pars), " ")
    end
    _cat("\nIter: $(it) fn: $(f1)\t Pars:  $(f2)")
end

function _r_str(v::Float64)
    isna_strict(v) && return "NA"
    isnan(v) && return "NaN"
    v == Inf && return "Inf"
    v == -Inf && return "-Inf"
    return SimLev.r_as_character(v)
end

# ── Steuerung ───────────────────────────────────────────────────────────────

"`Rsolnp:::.solnpctrl`: rho, outer.iter, inner.iter, delta, tol, trace."
function _solnpctrl(control)
    defaults = Dict("rho" => 1.0, "outer.iter" => 400.0, "inner.iter" => 800.0, "delta" => 1e-07,
                    "tol" => 1e-08, "trace" => 1.0)
    (control === nothing || isempty(control)) && return defaults
    keysv = [lowercase(String(k)) for k in keys(control)]
    vals = Dict(zip(keysv, collect(values(control))))
    ans = Dict{String,Float64}()
    for (key, k) in (("rho", 3), ("outer.iter", 10), ("inner.iter", 10), ("delta", 5), ("tol", 3), ("trace", 5))
        if any(s -> first(s, k) == first(key, k), keysv)
            v = get(vals, key, nothing)
            ans[key] = v === nothing ? NA : Float64(v)
        else
            ans[key] = defaults[key]
        end
    end
    ans
end

# ── solnp ───────────────────────────────────────────────────────────────────

mutable struct _Env
    xnames::Union{Nothing,Vector{String}}
    nfn::Int
    errors::Int
    LB::Union{Nothing,Vector{Float64}}
    UB::Union{Nothing,Vector{Float64}}
    fun::Any
    eqfun::Any
    ineqfun::Any
    ineqLB::Union{Nothing,Vector{Float64}}
    ineqUB::Union{Nothing,Vector{Float64}}
    eqB::Vector{Float64}
    ind::Vector{Float64}
    args::Tuple
end

function _call(env::_Env, f, x)
    xx = env.xnames === nothing ? collect(Float64, x) : RVector(collect(Float64, x); names = env.xnames)
    f(xx, env.args...)
end

"`.safefunx`: nicht endliche Zielwerte werden zu 1e24 (mit Warnung)."
function _safefunx(env::_Env, x)
    vv = _asvec(_call(env, env.fun, x))
    v = isempty(vv) ? NaN : vv[1]
    if !isfinite(v)
        _warn("\nsolnp-->warning: " * _r_str(v) * " detected in function call...check your function\n")
        v = 1e24
    end
    v
end
_eqv(env::_Env, x) = env.eqfun === nothing ? Float64[] : _asvec(_call(env, env.eqfun, x)) .- env.eqB
_ineqv(env::_Env, x) = env.ineqfun === nothing ? Float64[] : _asvec(_call(env, env.ineqfun, x))

function _checkpars!(env::_Env, pars, LB, UB)
    pars === nothing && _rerr("\nsolnp-->error: must supply starting parameters\n")
    if LB !== nothing
        length(pars) != length(LB) && _rerr("\nsolnp-->error: LB length not equal to parameter length\n")
        UB === nothing && (UB = fill(_DBL_XMAX / 2, length(LB)))
    end
    if UB !== nothing
        length(pars) != length(UB) && _rerr("\nsolnp-->error: UB length not equal to parameter length\n")
        LB === nothing && (LB = fill(-_DBL_XMAX / 2, length(UB)))
    end
    if UB !== nothing
        any(LB .> UB) && _rerr("\nsolnp-->error: UB must be greater than LB\n")
        any(LB .== UB) && _warn("\nsolnp-->warning: Equal Lower/Upper Bounds Found. Consider\n\n\t\t\t\t\t\texcluding fixed parameters.\n")
    end
    if LB !== nothing && !any(isfinite, LB)
        LB = copy(LB)
        for i in eachindex(LB)
            isfinite(LB[i]) || (LB[i] = sign(LB[i]) * _DBL_XMAX / 2)
        end
    end
    if UB !== nothing && !any(isfinite, UB)
        UB = copy(UB)
        for i in eachindex(UB)
            isfinite(UB[i]) || (UB[i] = sign(UB[i]) * _DBL_XMAX / 2)
        end
    end
    env.LB = LB; env.UB = UB
    nothing
end

"`all(v)` mit R's NA-Logik (`nothing` = NA); NA ergibt im if einen Fehler."
function _rall(v)
    na = false
    for x in v
        if x === nothing
            na = true
        elseif !x
            return false
        end
    end
    na && _rerr("missing value where TRUE/FALSE needed")
    true
end

_optvec(x) = x === nothing ? nothing : _asvec(x)

"""
    solnp(pars, fun, args...; eqfun, eqB, ineqfun, ineqLB, ineqUB, LB, UB, control)

`Rsolnp::solnp(pars, fun, eqfun, eqB, ineqfun, ineqLB, ineqUB, LB, UB, control, ...)`:
nichtlineare Optimierung mit Nebenbedingungen (augmented Lagrange, SQP).

`pars`: Startwerte (Vektor oder benannter `RVector`); `fun(pars, args...)`:
Zielfunktion (Skalar); `args...`: weitere Argumente für alle Funktionen (R's
`...`); `eqfun`, `eqB`: Gleichungen `eqfun(pars) = eqB`; `ineqfun`,
`ineqLB`, `ineqUB`: Ungleichungen; `LB`, `UB`: Parameterschranken;
`control`: `Dict` mit `rho`, `outer.iter`, `inner.iter`, `delta`, `tol`,
`trace` (Voreinstellung wie Rsolnp: 1, 400, 800, 1e-7, 1e-8, 1).

Ergebnis: `RList` mit `pars`, `convergence` (0 = konvergiert, 1 =
Iterationsgrenze, 2 = Hesse-Matrix nicht invertierbar), `values`,
`lagrange`, `hessian`, `ineqx0`, `nfuneval`, `outer.iter`, `elapsed`
(`nothing`) und `vscale`.
"""
function solnp(pars, fun, args...; eqfun = nothing, eqB = nothing, ineqfun = nothing, ineqLB = nothing,
               ineqUB = nothing, LB = nothing, UB = nothing, control = nothing)
    xnames = pars isa RVector ? pars.names : nothing
    env = _Env(xnames, 0, 0, nothing, nothing, fun, nothing, nothing, nothing, nothing, Float64[], zeros(11), args)
    pars_in = pars
    pars === nothing && _checkpars!(env, nothing, nothing, nothing)
    pv = _asvec(pars)
    np_ = length(pv)
    ind = zeros(11)
    ind[1] = np_
    _checkpars!(env, pv, _optvec(LB), _optvec(UB))
    (env.LB !== nothing || env.UB !== nothing) && (ind[10] = 1)
    val = _asvec(fun(pars_in, args...))
    length(val) != 1 && _rerr("\nsolnp-->error: objective function returns value of length greater than 1!\n")
    funv = val[1]
    env.nfn += 1
    ineqx0 = nothing
    nineq = 0
    if ineqfun !== nothing
        ineqv = _asvec(ineqfun(pars_in, args...))
        n = length(ineqv)
        ineqLB === nothing && _rerr("\nsolnp-->error: inequality function given without lower bounds\n")
        ilb = _asvec(ineqLB)
        length(ilb) != n && _rerr("\nsolnp-->error: inequality function returns vector of different length to\n\t\t\t\t\t\t\tinequality lower bounds\n")
        ineqUB === nothing && _rerr("\nsolnp-->error: inequality function given without upper bounds\n")
        iub = _asvec(ineqUB)
        length(iub) != n && _rerr("\nsolnp-->error: inequality function returns vector of different length to\n\t\t\t\t\t\t\tinequality upper bounds\n")
        any(ilb .> iub) && _rerr("\nsolnp-->error: ineqUB must be greater than ineqLB\n")
        env.ineqLB = ilb; env.ineqUB = iub; env.ineqfun = ineqfun
        ind[4] = 1
        nineq = length(ilb)
        ind[5] = nineq
        lbx = copy(ilb); ubx = copy(iub)
        for i in 1:nineq
            isfinite(ilb[i]) || (lbx[i] = -1e10)
            isfinite(iub[i]) || (ubx[i] = 1e10)
        end
        ineqx0 = (lbx .+ ubx) ./ 2
        ind[6] = 0
    else
        ineqv = Float64[]
    end
    neq = 0
    if eqfun !== nothing
        eqb = eqB === nothing ? Float64[] : _asvec(eqB)
        eqv = _asvec(eqfun(pars_in, args...)) .- eqb
        length(eqv) != length(eqb) && _rerr("\nsolnp-->error: equality function returns vector of different length\n\t\t\t\t\t\tto equality value\n")
        env.eqB = eqb; env.eqfun = eqfun
        ind[7] = 1
        neq = length(eqb)
        ind[8] = neq
        ind[9] = 0
    else
        eqv = Float64[]
    end
    (ind[10] != 0 || ind[4] != 0) && (ind[11] = 1)
    env.ind = ind
    pbr = Matrix{Float64}[]
    env.ineqLB !== nothing && push!(pbr, hcat(env.ineqLB, env.ineqUB))
    env.LB !== nothing && push!(pbr, hcat(env.LB, env.UB))
    pb = isempty(pbr) ? nothing : vcat(pbr...)
    ctrl = _solnpctrl(control)
    rho = ctrl["rho"]; maxit = ctrl["outer.iter"]; minit = ctrl["inner.iter"]
    delta = ctrl["delta"]; tol = ctrl["tol"]; trace = ctrl["trace"]
    tc = nineq + neq
    j = funv
    jh = [funv]
    tt = zeros(3)
    if tc > 0
        lam = zeros(tc)
        constraint = vcat(eqv, ineqv)
        if ind[4] != 0
            c_in = constraint[neq+1:tc]
            tmp1 = c_in .- env.ineqLB
            tmp2 = env.ineqUB .- c_in
            tmin = Float64[_rmin((tmp1[i], tmp2[i])) for i in 1:nineq]
            _rall([isnan(t) ? nothing : t > 0 for t in tmin]) && (ineqx0 = copy(c_in))
            constraint[neq+1:tc] = c_in .- ineqx0
        end
        tt[2] = _vnorm(constraint)
        mx = Float64[x for x in (tt[2] - 10 * tol, Float64(nineq)) if !isnan(x)]
        _c(isempty(mx) ? -Inf : _rmax(mx), :le, 0) && (rho = 0.0)
    else
        lam = zeros(1)
    end
    p = vcat(ineqx0 === nothing ? Float64[] : ineqx0, pv)
    hessv = _eye(np_ + nineq)
    mu = Float64(np_)
    it = 0
    ob = vcat(funv, eqv, ineqv)
    vscale = Float64[]
    while _c(it, :lt, maxit)
        it += 1
        sub_ctrl = (rho, minit, delta, tol, trace)
        vs = ind[7] != 0 ? vcat(ob[1], ones(neq) .* _rmax(abs.(ob[2:neq+1]))) : [1.0]
        vs = ind[11] == 0 ? vcat(vs, p) : vcat(vs, ones(length(p)))
        vscale = Float64[_rmin((_rmax((abs(x), tol)), 1 / tol)) for x in vs]
        res = _subnp(p, lam, ob, hessv, mu, vscale, sub_ctrl, env, pb)
        env.errors == 1 && (maxit = it)
        p = res.p; lam = res.y; hessv = res.hessv; mu = res.lambda
        temp = p[nineq+1:nineq+np_]
        funv = _safefunx(env, temp)
        env.nfn += 1
        _rif(trace) && _report(it, funv, temp)
        eqv = _eqv(env, temp)
        ineqv = _ineqv(env, temp)
        ob = vcat(funv, eqv, ineqv)
        tt[1] = (j - ob[1]) / _rmax((abs(ob[1]), 1.0))
        j = ob[1]
        if tc > 0
            constraint = ob[2:tc+1]
            if ind[4] != 0
                c_in = constraint[neq+1:tc]
                tempv = vcat(c_in .- pb[1:nineq, 1], pb[1:nineq, 2] .- c_in)
                _c(_rmin(tempv), :gt, 0) && (p[1:nineq] = c_in)
                constraint[neq+1:tc] = c_in .- p[1:nineq]
            end
            tt[3] = _vnorm(constraint)
            if _c(tt[3], :lt, 10 * tol)
                rho = 0.0
                mu = _rmin((mu, tol))
            end
            _c(tt[3], :lt, 5 * tt[2]) && (rho = rho / 5)
            _c(tt[3], :gt, 10 * tt[2]) && (rho = 5 * _rmax((rho, sqrt(tol))))
            if _c(_rmax((tol + tt[1], tt[2] - tt[3])), :le, 0)
                lam = zeros(1)
                d = Float64[hessv[i, i] for i in 1:size(hessv, 1)]
                hessv = zeros(size(hessv)); for i in eachindex(d); hessv[i, i] = d[i]; end
            end
            tt[2] = tt[3]
        end
        _c(_vnorm(tt[1:2]), :le, tol) && (maxit = it)
        push!(jh, j)
    end
    ind[4] != 0 && (ineqx0 = p[1:nineq])
    p = p[nineq+1:nineq+np_]
    if env.errors == 1
        convergence = 2
        _rif(trace) && _cat("\nsolnp--> Solution not reliable....Problem Inverting Hessian.\n")
    elseif _c(_vnorm(tt[1:2]), :le, tol)
        convergence = 0
        _rif(trace) && _cat("\nsolnp--> Completed in $(it) iterations\n")
    else
        convergence = 1
        _rif(trace) && _cat("\nsolnp--> Exiting after maximum number of iterations\nTolerance not achieved\n")
    end
    RList("pars" => (xnames === nothing ? p : RVector(p; names = xnames)), "convergence" => convergence,
          "values" => jh, "lagrange" => lam, "hessian" => hessv, "ineqx0" => ineqx0, "nfuneval" => env.nfn,
          "outer.iter" => it, "elapsed" => nothing, "vscale" => vscale)
end

"`c(funv, eqv, ineqv) / vscale[1:(nc + 1)]` mit Zähler (wie in .subnp)."
function _eval_ob(env::_Env, x, vsc)
    funv = _safefunx(env, x)
    eqv = _eqv(env, x)
    ineqv = _ineqv(env, x)
    env.nfn += 1
    vcat(funv, eqv, ineqv) ./ vsc
end

"Rücksprung von .subnp nach fehlgeschlagener Zerlegung (.solnp_errors = 1)."
function _subnp_fail(p, vs_p, vscale, hessv, lam, env)
    env.errors = 1
    (p = p .* vs_p, y = [0.0], hessv = (vscale[1] .* hessv) ./ _outer(vs_p), lambda = lam)
end

function _recycle_mul(a, b)
    n = max(length(a), length(b))
    n % min(length(a), length(b)) != 0 && _warn("longer object length is not a multiple of shorter object length")
    Float64[a[mod1(i, length(a))] * b[mod1(i, length(b))] for i in 1:n]
end

_aug(o, yy, rho, nc) = o[1] - _dot(yy, o[2:nc+1]) + rho * SimLev.r_pow(_vnorm(o[2:nc+1]), 2.0)

"`Rsolnp:::.subnp` (ein SQP-Teilproblem)."
function _subnp(pars, yy, ob, hessv, lam, vscale, ctrl, env::_Env, pb)
    ind = env.ind
    rho, maxit, delta, tol, trace = ctrl
    neq = Int(ind[8]); nineq = Int(ind[5]); np_ = Int(ind[1])
    ch = 1
    alp = [0.0, 0.0, 0.0]
    nc = neq + nineq
    npic = np_ + nineq
    p0 = copy(Float64.(pars))
    pb = pb === nothing ? nothing : copy(pb)
    sob = [0.0, 0.0, 0.0]
    vs_o = vscale[1:nc+1]
    vs_p = vscale[neq+2:nc+np_+1]
    vs_x = vscale[nc+2:nc+np_+1]
    ob = Float64.(ob) ./ vs_o
    p0 = p0 ./ vs_p
    mm = 0
    if ind[11] != 0
        mm = ind[10] == 0 ? nineq : npic
        vv = vscale[neq+2:neq+mm+1]
        pb = pb ./ hcat(vv, vv)
    end
    yy = Float64.(collect(yy))
    nc > 0 && (yy = (vscale[2:nc+1] .* yy) ./ vscale[1])
    hessv = (hessv .* _outer(vs_p)) ./ vscale[1]
    j = ob[1]
    a = nothing
    if ind[4] != 0
        a = ind[7] == 0 ? hcat(-_eye(nineq), zeros(nineq, np_)) :
            vcat(hcat(zeros(neq, nineq), zeros(neq, np_)), hcat(-_eye(nineq), zeros(nineq, np_)))
    end
    (ind[7] != 0 && ind[4] == 0) && (a = zeros(neq, np_))
    (ind[7] == 0 && ind[4] == 0) && (a = zeros(1, np_))
    g = zeros(npic)
    p = p0[1:npic]
    b = Float64[]
    if nc > 0
        constraint = ob[2:nc+1]
        for i in 1:np_
            p0[nineq+i] = p0[nineq+i] + delta
            tmpv = p0[nineq+1:npic] .* vs_x
            ob = _eval_ob(env, tmpv, vs_o)
            g[nineq+i] = (ob[1] - j) / delta
            a[:, nineq+i] = (ob[2:nc+1] .- constraint) ./ delta
            p0[nineq+i] = p0[nineq+i] - delta
        end
        ind[4] != 0 && (constraint[neq+1:neq+nineq] = constraint[neq+1:neq+nineq] .- p0[1:nineq])
        if _c(_solvecond(a), :gt, 1 / _EPS)
            _rif(trace) && _subnpmsg("m1")
        end
        b = _mm(a, _col(p0))[:, 1] .- constraint
        ch = -1
        alp[1] = tol - _rmax(abs.(constraint))
        if _c(alp[1], :le, 0)
            ch = 1
            if ind[11] == 0
                sv = _asvec(SimLev.RLinalg.solve(_mm(a, permutedims(a)), constraint))
                p0 = p0 .- _mm(permutedims(a), _col(sv))[:, 1]
                alp[1] = 1.0
            end
        end
        if _c(alp[1], :le, 0)
            p0 = vcat(p0, 1.0)
            a = hcat(a, -_col(constraint))
            cx = vcat(zeros(npic), 1.0)
            dx = ones(npic + 1)
            go = 1.0
            minit = 0
            while _c(go, :ge, tol)
                minit += 1
                gap = hcat(p0[1:mm] .- pb[:, 1], pb[:, 2] .- p0[1:mm])
                dx[1:mm] = _row_min_sorted(gap)
                dx[npic+1] = p0[npic+1]
                ind[10] == 0 && (dx[mm+1:npic] .= _rmax(vcat(dx[1:mm], 100.0)))
                local y
                try
                    D = zeros(length(dx), length(dx)); for k in eachindex(dx); D[k, k] = dx[k]; end
                    lhs = permutedims(_mm(a, D))
                    y = _asvec(SimLev.RLinalg.qr_solve(lhs, _col(dx .* cx)))
                catch err
                    err isa ErrorException || rethrow()
                    pp = length(p0) == length(vs_p) ? p0 .* vs_p : _recycle_mul(p0, vs_p)
                    env.errors = 1
                    return (p = pp, y = [0.0], hessv = (vscale[1] .* hessv) ./ _outer(vs_p), lambda = lam)
                end
                v = dx .* (dx .* (cx .- _mm(permutedims(a), _col(y))[:, 1]))
                if _c(v[npic+1], :gt, 0)
                    z = p0[npic+1] / v[npic+1]
                    for i in 1:mm
                        if _c(v[i], :lt, 0)
                            z = _rmin((z, -(pb[i, 2] - p0[i]) / v[i]))
                        elseif _c(v[i], :gt, 0)
                            z = _rmin((z, (p0[i] - pb[i, 1]) / v[i]))
                        end
                    end
                    if _c(z, :ge, p0[npic+1] / v[npic+1])
                        p0 = p0 .- z .* v
                    else
                        p0 = p0 .- (0.9 * z) .* v
                    end
                    go = p0[npic+1]
                    minit >= 10 && (go = 0.0)
                else
                    go = 0.0
                    minit = 10
                end
            end
            if minit >= 10
                _rif(trace) && _subnpmsg("m2")
            end
            a = a[:, 1:npic]
            b = _mm(a, _col(p0[1:npic]))[:, 1]
        end
    end
    p = p0[1:npic]
    y = [0.0]
    if ch > 0
        tmpv = p[nineq+1:npic] .* vs_x
        ob = _eval_ob(env, tmpv, vs_o)
    end
    j = ob[1]
    if ind[4] != 0
        ob = copy(ob)
        ob[neq+2:nc+1] = ob[neq+2:nc+1] .- p[1:nineq]
    end
    if nc > 0
        ob = copy(ob)
        ob[2:nc+1] = (ob[2:nc+1] .- _mm(a, _col(p))[:, 1]) .+ b
        j = _aug(ob, yy, rho, nc)
    end
    minit = 0
    yg = Float64[]
    sx = Float64[]
    reduce = nothing
    sc = [0.0, 0.0]
    ob1 = ob; ob2 = ob; ob3 = ob
    ptt = zeros(npic, 3)
    while _c(minit, :lt, maxit)
        minit += 1
        if ch > 0
            for i in 1:np_
                p[nineq+i] = p[nineq+i] + delta
                tmpv = p[nineq+1:npic] .* vs_x
                obm = _eval_ob(env, tmpv, vs_o)
                ind[4] != 0 && (obm[neq+2:nc+1] = obm[neq+2:nc+1] .- p[1:nineq])
                if nc > 0
                    obm[2:nc+1] = (obm[2:nc+1] .- _mm(a, _col(p))[:, 1]) .+ b
                    obm_s = _aug(obm, yy, rho, nc)
                else
                    obm_s = obm[1]
                end
                g[nineq+i] = (obm_s - j) / delta
                p[nineq+i] = p[nineq+i] - delta
            end
            ind[4] != 0 && (g[1:nineq] .= 0.0)
        end
        if minit > 1
            yg = g .- yg
            sx = p .- sx
            sc[1] = _mm(_mm(_row(sx), hessv), _col(sx))[1, 1]
            sc[2] = _mm(_row(sx), _col(yg))[1, 1]
            if _c(sc[1] * sc[2], :gt, 0)
                sx = _mm(hessv, _col(sx))[:, 1]
                hessv = (hessv .- _outer(sx) ./ sc[1]) .+ _outer(yg) ./ sc[2]
            end
        end
        dx = 0.01 .* ones(npic)
        if ind[11] != 0
            gap = hcat(p[1:mm] .- pb[:, 1], pb[:, 2] .- p[1:mm])
            gv = _row_min_sorted(gap) .+ _SQRT_EPS .* ones(mm)
            dx[1:mm] = ones(mm) ./ gv
            ind[10] == 0 && (dx[mm+1:npic] .= _rmin(vcat(dx[1:mm], 0.01)))
        end
        go = -1.0
        lam = lam / 10
        p0 = p
        while _c(go, :le, 0)
            D = zeros(npic, npic); for k in 1:npic; D[k, k] = dx[k] * dx[k]; end
            cz = try
                _asmat(SimLev.RLinalg.chol(hessv .+ lam .* D))
            catch err
                err isa ErrorException || rethrow()
                return _subnp_fail(p, vs_p, vscale, hessv, lam, env)
            end
            cz = try
                _asmat(SimLev.RLinalg.solve(cz))
            catch err
                err isa ErrorException || rethrow()
                return _subnp_fail(p, vs_p, vscale, hessv, lam, env)
            end
            czt = permutedims(cz)
            yg = _mm(czt, _col(g))[:, 1]
            if nc == 0
                u = _mm(-cz, _col(yg))[:, 1]
            else
                cta = _mm(czt, permutedims(a))
                y = try
                    _asvec(SimLev.RLinalg.qr_solve(cta, _col(yg)))
                catch err
                    err isa ErrorException || rethrow()
                    return _subnp_fail(p, vs_p, vscale, hessv, lam, env)
                end
                u = _mm(-cz, _col(yg .- _mm(cta, _col(y))[:, 1]))[:, 1]
            end
            p0 = u[1:npic] .+ p
            if ind[11] == 0
                go = 1.0
            else
                go = _rmin(vcat(p0[1:mm] .- pb[:, 1], pb[:, 2] .- p0[1:mm]))
                lam = 3 * lam
            end
        end
        alp[1] = 0.0
        ob1 = ob
        ob2 = ob1
        sob[1] = j
        sob[2] = j
        ptt = hcat(p, p, p0)
        alp[3] = 1.0
        tmpv = ptt[nineq+1:npic, 3] .* vs_x
        ob3 = _eval_ob(env, tmpv, vs_o)
        sob[3] = ob3[1]
        ind[4] != 0 && (ob3[neq+2:nc+1] = ob3[neq+2:nc+1] .- ptt[1:nineq, 3])
        if nc > 0
            ob3[2:nc+1] = (ob3[2:nc+1] .- _mm(a, _col(ptt[:, 3]))[:, 1]) .+ b
            sob[3] = _aug(ob3, yy, rho, nc)
        end
        go = 1.0
        while _c(go, :gt, tol)
            alp[2] = (alp[1] + alp[3]) / 2
            ptt[:, 2] = (1 - alp[2]) .* p .+ alp[2] .* p0
            tmpv = ptt[nineq+1:npic, 2] .* vs_x
            ob2 = _eval_ob(env, tmpv, vs_o)
            sob[2] = ob2[1]
            ind[4] != 0 && (ob2[neq+2:nc+1] = ob2[neq+2:nc+1] .- ptt[1:nineq, 2])
            if nc > 0
                ob2[2:nc+1] = (ob2[2:nc+1] .- _mm(a, _col(ptt[:, 2]))[:, 1]) .+ b
                sob[2] = _aug(ob2, yy, rho, nc)
            end
            obm = _rmax(sob)
            if _c(obm, :lt, j)
                obn = _rmin(sob)
                go = tol * (obm - obn) / (j - obm)
            end
            condif1 = _c(sob[2], :ge, sob[1])
            condif2 = _c(sob[1], :le, sob[3]) && _c(sob[2], :lt, sob[1])
            condif3 = _c(sob[2], :lt, sob[1]) && _c(sob[1], :gt, sob[3])
            if condif1
                sob[3] = sob[2]; ob3 = ob2; alp[3] = alp[2]; ptt[:, 3] = ptt[:, 2]
            end
            if condif2
                sob[3] = sob[2]; ob3 = ob2; alp[3] = alp[2]; ptt[:, 3] = ptt[:, 2]
            end
            if condif3
                sob[1] = sob[2]; ob1 = ob2; alp[1] = alp[2]; ptt[:, 1] = ptt[:, 2]
            end
            _c(go, :ge, tol) && (go = alp[3] - alp[1])
        end
        sx = copy(p)
        yg = copy(g)
        ch = 1
        obn = _rmin(sob)
        _c(j, :le, obn) && (maxit = minit)
        reduce = (j - obn) / (1 + abs(j))
        _c(reduce, :lt, tol) && (maxit = minit)
        condif1 = _c(sob[1], :lt, sob[2])
        condif2 = _c(sob[3], :lt, sob[2]) && _c(sob[1], :ge, sob[2])
        condif3 = _c(sob[1], :ge, sob[2]) && _c(sob[3], :ge, sob[2])
        if condif1
            j = sob[1]; p = ptt[:, 1]; ob = ob1
        end
        if condif2
            j = sob[3]; p = ptt[:, 3]; ob = ob3
        end
        if condif3
            j = sob[2]; p = ptt[:, 2]; ob = ob2
        end
    end
    p = p .* vs_p
    nc > 0 && (y = (vscale[1] .* y) ./ vscale[2:nc+1])
    hessv = (vscale[1] .* hessv) ./ _outer(vs_p)
    reduce === nothing && _rerr("object 'reduce' not found")
    if _c(reduce, :gt, tol)
        _rif(trace) && _subnpmsg("m3")
    end
    (p = p, y = y, hessv = hessv, lambda = lam)
end

# ── gosolnp ─────────────────────────────────────────────────────────────────

"`a | b` für logische Skalare mit R's NA-Logik (`nothing` = NA)."
_r_or(a, b) = (a === true || b === true) ? true : (a === nothing || b === nothing) ? nothing : false

"`any(v)` mit R's NA-Logik (`nothing` = NA)."
function _r_any(v)
    na = false
    for x in v
        x === true && return true
        x === nothing && (na = true)
    end
    na ? nothing : false
end

"`x op y` elementweise mit Recycling; NA (`nothing`) bei NaN."
function _cmp_vec(x, op::Symbol, y)
    nx = length(x); ny = length(y)
    n = (nx > 0 && ny > 0) ? max(nx, ny) : 0
    out = Vector{Union{Nothing,Bool}}(undef, n)
    for i in 0:n-1
        a = Float64(x[i % nx + 1]); b = Float64(y[i % ny + 1])
        out[i+1] = (isnan(a) || isnan(b)) ? nothing : (op === :lt ? a < b : a > b)
    end
    out
end

_gos_call(f, x, parnames, args) = f(parnames === nothing ? collect(Float64, x) : RVector(collect(Float64, x); names = parnames), args...)

"""
`apply(mat, 1, f)` (Liste der Ergebnisse). Hat `mat` keine Zeilen, ruft R `f`
einmal mit einem Nullvektor auf und verwirft das Ergebnis (`ans[1L][-1L]`).
"""
function _apply_rows(mat::Matrix{Float64}, f)
    if size(mat, 1) == 0
        f(zeros(size(mat, 2)))
        return Any[]
    end
    Any[f(mat[i, :]) for i in 1:size(mat, 1)]
end

"`distr.opt[[j]]\$key` (`nothing` wie NULL)."
function _distr_opt(distr_opt, j::Int, key::String)
    (distr_opt === nothing || j > length(distr_opt)) && _rerr("subscript out of bounds")
    d = distr_opt[j]
    d === nothing && return nothing
    d isa AbstractDict && return get(d, key, get(d, Symbol(key), nothing))
    d isa NamedTuple && return get(d, Symbol(key), nothing)
    return get(d, key, nothing)
end

"`as.integer(rseed)` (NA mit Warnung außerhalb des Integer-Bereichs; `nothing` = NA)."
function _as_integer_seed(x)
    v = Float64(_asvec(x)[1])
    isnan(v) && return nothing
    if v >= 2147483648.0 || v <= -2147483648.0
        _warn("NAs introduced by coercion to integer range")
        return nothing
    end
    trunc(Int, v)
end

"`Rsolnp:::.randpars` (ohne trace und cluster)."
function _randpars(pars, fixed, fun, ineqfun, ineqLB, ineqUB, LB::Vector{Float64}, UB::Vector{Float64},
                   distr::Vector{Float64}, distr_opt, n_restarts::Int, n_sim::Int, rseed, parnames, args)
    N = length(LB)
    nr = n_restarts * n_sim
    rnd = fill(NA, nr, N)
    if fixed !== nothing
        for f in fixed
            rnd[:, f] .= pars[f]
        end
    end
    nf = [j for j in 1:N if fixed === nothing || !(j in fixed)]
    isempty(nf) && throw(NotPortedError("gosolnp-Nachbildung: alle Parameter fest (for (i in 1:0) in R)"))
    rseed === nothing && _rerr("supplied seed is not a valid integer")
    SimLev.RRng.set_seed(rseed)                         # set.seed(rseed)
    for j in nf
        dj = j <= length(distr) ? distr[j] : NaN        # distr[j] (NA außerhalb)
        col = if isnan(dj)
            nothing
        elseif trunc(Int, dj) == 1
            SimLev.RRng.runif(nr, LB[j], UB[j])
        elseif trunc(Int, dj) == 2
            SimLev.RTruncnorm.rtruncnorm(nr, LB[j], UB[j], _asvec(_distr_opt(distr_opt, j, "mean")),
                                         _asvec(_distr_opt(distr_opt, j, "sd")))
        elseif trunc(Int, dj) == 3
            SimLev.RRng.rnorm(nr, _asvec(_distr_opt(distr_opt, j, "mean")), _asvec(_distr_opt(distr_opt, j, "sd")))
        else
            nothing                                     # switch() ohne Treffer: NULL
        end
        cv = col === nothing ? Float64[] : _asvec(col)
        (isempty(cv) || nr % length(cv) != 0) &&
            _rerr("number of items to replace is not a multiple of replacement length")
        for i in 1:nr
            rnd[i, j] = cv[(i - 1) % length(cv) + 1]
        end
    end
    if ineqfun !== nothing
        ilb = _asvec(ineqLB); iub = _asvec(ineqUB)
        if length(ilb) == 1
            vals = _apply_rows(rnd, x -> _asvec(_gos_call(ineqfun, x, parnames, args)))
            ineqv = isempty(vals) ? Float64[] : reduce(vcat, vals)
            lt = _cmp_vec(ineqv, :lt, ilb); gt = _cmp_vec(ineqv, :gt, iub)
            lbviol = any(isnothing, lt) ? nothing : count(identity, lt)
            ubviol = any(isnothing, gt) ? nothing : count(identity, gt)
            cond = _r_or(lbviol === nothing ? nothing : lbviol > 0, ubviol === nothing ? nothing : ubviol > 0)
            cond === nothing && _rerr("missing value where TRUE/FALSE needed")
            if cond
                keep = trues(size(rnd, 1))
                for (i, t) in enumerate(lt); t === true && (keep[(i - 1) % size(rnd, 1) + 1] = false); end
                for (i, t) in enumerate(gt); t === true && (keep[(i - 1) % size(rnd, 1) + 1] = false); end
                rnd = rnd[keep, :]
            end
        else
            vals = _apply_rows(rnd, x -> _asvec(_gos_call(ineqfun, x, parnames, args)))
            lbv = Union{Nothing,Int}[]; ubv = Union{Nothing,Int}[]
            for v in vals
                a = _r_any(_cmp_vec(v, :lt, ilb)); b = _r_any(_cmp_vec(v, :gt, iub))
                push!(lbv, a === nothing ? nothing : Int(a)); push!(ubv, b === nothing ? nothing : Int(b))
            end
            c1 = _r_any([v === nothing ? nothing : v > 0 for v in lbv])
            c2 = _r_any([v === nothing ? nothing : v > 0 for v in ubv])
            cond = _r_or(c1, c2)
            cond === nothing && _rerr("missing value where TRUE/FALSE needed")
            if cond
                keep = trues(size(rnd, 1))
                for (i, v) in enumerate(lbv); (v !== nothing && v > 0) && (keep[i] = false); end
                for (i, v) in enumerate(ubv); (v !== nothing && v > 0) && (keep[i] = false); end
                rnd = rnd[keep, :]
            end
        end
    end
    safefun = function (x)                              # Rsolnp:::.safefun
        vv = _asvec(_gos_call(fun, x, parnames, args))
        v = isempty(vv) ? NaN : vv[1]
        if !isfinite(v)
            _warn("\ngosolnp-->warning: " * _r_str(v) * " detected in function call...check your function\n")
            v = 1e24
        end
        v
    end
    evfun = Float64[v for v in _apply_rows(rnd, safefun)]
    ix = sortperm(evfun; alg = Base.Sort.MergeSort, lt = (a, b) -> a < b)   # sort.int(..., index.return = TRUE)
    out = fill(NA, n_restarts, N + 1)
    for i in 1:n_restarts
        if i <= length(ix)
            out[i, 1:N] = rnd[ix[i], :]
            out[i, N+1] = evfun[ix[i]]
        end
    end
    out
end

"""
    gosolnp(pars = nothing, fixed = nothing, fun = nothing, args...; eqfun, eqB, ineqfun, ineqLB, ineqUB,
            LB, UB, control, distr, distr_opt, n_restarts = 1, n_sim = 20000, cluster = nothing, rseed = nothing)

`Rsolnp::gosolnp`: `solnp` mit zufälligen Startwerten (Rsolnp 1.16). Zieht
`n_restarts * n_sim` Parametervektoren (je Parameter nach `distr`: 1 =
gleichverteilt in `[LB, UB]`, 2 = gestutzte Normalverteilung mit
`distr_opt[j]["mean"]`/`["sd"]` (`SimLev.RTruncnorm.rtruncnorm`), 3 =
Normalverteilung), verwirft die, die die Ungleichungen verletzen, und startet
`solnp` von den `n_restarts` Vektoren mit dem kleinsten Zielwert. `args...`
gehen an alle Funktionen (R's `...`).

Wie in R setzt die Funktion den globalen Zufallszustand mit `set.seed(rseed)`;
bei `rseed = nothing` ist der Startwert `as.numeric(Sys.time())`
(`SimLev.RBase.sys_time`, durch `set.seed` auf ganze Sekunden abgeschnitten).

Ergebnis: `RList` (Ergebnis von `solnp` und `start.pars`, `rseed`); scheitert
`solnp` mit einem Fehler, wie in R `values = 1e10`, `convergence = 0` und
`pars = NA`. Nicht nachgebildet: `cluster`, `control\$eval.type = 2`
(`.randpars2`) und `control\$trace`.
"""
function gosolnp(pars = nothing, fixed = nothing, fun = nothing, args...; eqfun = nothing, eqB = nothing,
                 ineqfun = nothing, ineqLB = nothing, ineqUB = nothing, LB = nothing, UB = nothing,
                 control = nothing, distr = nothing, distr_opt = nothing, n_restarts = 1, n_sim = 20000,
                 cluster = nothing, rseed = nothing)
    parnames = pars isa RVector ? pars.names : nothing
    pv = pars === nothing ? nothing : _asvec(pars)
    ctrl = Dict{String,Any}()
    if control !== nothing
        for (k, v) in pairs(control)
            ctrl[String(k)] = v
        end
    end
    tr = get(ctrl, "trace", nothing)
    trace = tr === nothing ? false : _rif(Float64(_asvec(tr)[1]))
    et = get(ctrl, "eval.type", nothing)
    parmethod = et === nothing ? 1 : trunc(Int, min(abs(Float64(et)), 2))
    parmethod == 0 && (parmethod = 1)
    delete!(ctrl, "eval.type")
    if rseed === nothing
        rseed_v = SimLev.RBase.sys_time()
        seed = rseed_v
    else
        seed = _as_integer_seed(rseed)
        rseed_v = seed === nothing ? NA : Float64(seed)
    end
    LB === nothing && _rerr("\ngosolnp-->error: the function requires lower parameter bounds\n")
    UB === nothing && _rerr("\ngosolnp-->error: the function requires upper parameter bounds\n")
    (fixed !== nothing && pars === nothing) &&
        _rerr("\ngosolnp-->error: you need to provide a pars vector if using the fixed option\n")
    LBv = _asvec(LB); UBv = _asvec(UB)
    n = pv !== nothing ? length(pv) : length(LBv)
    if fixed !== nothing
        fx = unique(collect(fixed isa Real ? [fixed] : fixed))
        any(f -> !(Float64(f) == trunc(Float64(f)) && 1 <= f <= n), fx) &&
            _rerr("\ngosolnp-->error: fixed indices out of bounds\n")
        fixed = Int[Int(f) for f in fx]
    end
    dv = distr === nothing ? ones(length(LBv)) : _asvec(distr)
    for code in (2.0, 3.0)
        for j in 1:length(dv)
            dv[j] == code || continue
            _distr_opt(distr_opt, j, "mean") === nothing &&
                _rerr("\ngosolnp-->error: distr.opt[[,$(j)]] missing mean\n")
            _distr_opt(distr_opt, j, "sd") === nothing &&
                _rerr("\ngosolnp-->error: distr.opt[[,$(j)]] missing sd\n")
        end
    end
    cluster === nothing || throw(NotPortedError("gosolnp-Nachbildung: cluster (parallele Auswertung) nicht nachgebildet"))
    parmethod == 1 || throw(NotPortedError("gosolnp-Nachbildung: control\$eval.type = 2 (.randpars2) nicht nachgebildet"))
    trace && throw(NotPortedError("gosolnp-Nachbildung: control\$trace nicht nachgebildet"))
    nrs = Int(n_restarts); nsim = Int(n_sim)
    rnd = _randpars(pv, fixed, fun, ineqfun, ineqLB, ineqUB, LBv, UBv, dv, distr_opt, nrs, nsim, seed, parnames, args)
    rnd = rnd[:, 1:n]
    solution = Any[]
    for i in 1:nrs
        xx = rnd[i, :]
        x_in = parnames === nothing ? xx : RVector(xx; names = parnames)
        ans = try
            solnp(x_in, fun, args...; eqfun = eqfun, eqB = eqB, ineqfun = ineqfun, ineqLB = ineqLB,
                  ineqUB = ineqUB, LB = LB, UB = UB, control = ctrl)
        catch err
            err isa ErrorException || rethrow()
            RList("values" => 1e10, "convergence" => 0, "pars" => fill(NA, length(xx)))
        end
        push!(solution, ans)
    end
    nb = 1
    if nrs > 1
        best = Union{Nothing,Float64}[x["convergence"] != 0 ? nothing : Float64(_asvec(x["values"])[end]) for x in solution]
        fin = Float64[b for b in best if b !== nothing && !isnan(b)]
        isempty(fin) && _rerr("\ngosolnp-->Could not find a feasible starting point...exiting\n")
        mn = minimum(fin)
        nb = findfirst(b -> b !== nothing && b == mn, best)
    end
    sol = RList()
    for (k, v) in solution[nb]
        sol[k] = v
    end
    sp = rnd[nb, :]
    sol["start.pars"] = parnames === nothing ? sp : RVector(sp; names = parnames)
    sol["rseed"] = rseed_v
    sol
end

end # module
