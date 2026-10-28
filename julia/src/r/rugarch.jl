# ─────────────────────────────────────────────────────────────────────────────
# RRugarch – Nachbildung von rugarch::ugarchfit (rugarch 1.5-6) für die
# Spezifikation aus .fit_garch11 (r/R/bootstrap.R), bitgleich
#
# Herkunft: R-Paket rugarch 1.5-6 (CRAN, 2026-07-18), R/rugarch-*.R und
# src/garchmodels.c, src/filters.c, src/distributions.c; Autoren: Alexios
# Galanos [aut, cre, cph], Tobias Kley [ctb]. Lizenz: GPL-3. Nach Julia
# übertragen und angepasst für SimLev (siehe julia/COPYRIGHTS.md); im R-Paket
# übernommen als .rugarch_ugarchfit (r/R/vendor_rugarch.R,
# r/src/vendor_rugarch.c). Hesse-Matrix und Scores rechnet statt numDeriv die
# eigenständig geschriebene Richardson-Extrapolation (_richardson_hessian,
# _richardson_jacobian; im R-Paket .sl_richardson_hessian/
# .sl_richardson_jacobian in r/R/richardson.R, gegen numDeriv als
# Prüf-Orakel bitgleich).
#
#   spec <- ugarchspec(variance.model = list(model = "sGARCH" | "gjrGARCH", garchOrder = c(1, 1)),
#                      mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
#                      distribution.model = "norm")
#   fit <- ugarchfit(spec = spec, data = e, solver = "hybrid"); coef(fit)
#
# Nachgebildet (Vorlage python/simlev/_r/rugarch.py):
# * .sgarchfit/.gjrgarchfit mit den Voreinstellungen von fit.control,
#   Startwerte und Schranken (.meqstartpars, .meqstart, .aparchstart), die
#   Warnung bei weniger als 100 Beobachtungen;
# * die Likelihood .sgarchLLH/.gjrgarchLLH mit dem C-Filter sgarchfilterC/
#   gjrgarchfilterC (garchmodels.c, filters.c, dnormstd aus distributions.c),
#   dem Straf-Wert nach rugarch_llh und dem Fehlerweg von .C bei nicht
#   endlichen Argumenten;
# * die Stationaritätsbedingung .sgarchcon/.gjrgarchcon (GJR mit pneg der
#   Normalverteilung, KAPPA_NORM);
# * .hybridsolver: solnp (SimLev.RSolnp), dann nlminb (SimLev.RStats.nlminb),
#   danach bis zu zweimal .gosolnpsolver (SimLev.RSolnp.gosolnp mit
#   n.restarts = 1, n.sim = 500, gestutzter Normalverteilung um die
#   Startwerte, rseed = NULL: Startwert aus der Uhr SimLev.RBase.sys_time,
#   set.seed überschreibt wie in R den globalen Zufallszustand);
# * .makefitmodel: Hesse-Matrix per Richardson (_richardson_hessian), Prüfung durch eigen (nur
#   der Fehler bei nicht endlichen Werten), solve mit Ersatzweg .hessian2sided
#   und Warnung "failed to invert hessian", der Aufruf mit returnType = "all",
#   robustvcv mit neweywestcv und die Warnung von sqrt bei negativen
#   Diagonalelementen; Scores (_richardson_jacobian) nur mit full = true;
# * die Konvergenzprüfung: bei convergence != 0 ist coef(fit) leer (nothing).
# Die Daten werden wie ein unbenannter Vektor behandelt.
# ─────────────────────────────────────────────────────────────────────────────
module RRugarch

import ..SimLev
import ..SimLev: RList, RVector, NA, isna_strict

export ugarchfit, coef, KAPPA_NORM

const _EPS = 2.220446049250313e-16          # rugarch: eps <- .Machine$double.eps
const _TINY = 1.0e-8                        # rugarch: TinY
const _SQ2PI = sqrt(2.0 * 3.141592653589793)
const _PDF_FLOOR = 2.22507e-24
const _ZERO_TOL = sqrt(_EPS / 7e-7)

# pneg(ghlambda, shape, skew, "norm") = integrate(dnorm, -Inf, 0)$value (QUADPACK dqagi in
# R 4.3.3); unabhängig von den Parametern, als Konstante aus R übernommen
# (sprintf("%a", rugarch:::pneg(0, 0, 0, "norm"))).
const KAPPA_NORM = 0x1.fffffffe3b5ap-2

_rerr(msg) = error(msg)
_warn(msg) = (@warn String(msg); nothing)
_eps13() = SimLev.r_pow(_EPS, 1.0 / 3.0)

"`max(a, b)` wie R (NaN gewinnt)."
_rmax2(a::Float64, b::Float64) = isnan(a) ? a : isnan(b) ? b : (b > a ? b : a)

# ── Likelihood ──────────────────────────────────────────────────────────────

mutable struct _GarchEnv
    llh::Float64
    csol::Int
end

struct _LLH
    x::Vector{Float64}
    gjr::Bool
    env::_GarchEnv
end

_penalty(f::_LLH) = f.env.llh + 0.1 * abs(f.env.llh)

"`.sgarchLLH`/`.gjrgarchLLH` (ARMA(0,0) mit Mittelwert, Normalverteilung)."
function (f::_LLH)(pars, returnType::Symbol = :llh)
    x = f.x
    T = length(x)
    p = Float64.(collect(pars))
    mu = p[1]; om = p[2]; al = p[3]; be = p[4]
    ga = f.gjr ? p[5] : 0.0
    # .arfimaxfilter (ARMA(0,0)): res = data - mu - imx - archm * h^0
    res = Float64[((xi - mu) - 0.0) - 0.0 * 1.0 for xi in x]
    for i in eachindex(res)
        isfinite(res[i]) || (res[i] = 0.0)
    end
    persist = f.gjr ? (al + be) + ga * KAPPA_NORM : al + be
    mvar = SimLev.r_mean(Float64[r * r for r in res])
    hEst = mvar
    om = _rmax2(_EPS, om)
    isfinite(hEst) || (hEst = SimLev.r_var(x) * (1 - persist))
    # .C(..., NAOK = FALSE): nicht endliche Argumente -> Fehler -> try-error
    if !(isfinite(mu) && isfinite(om) && isfinite(al) && isfinite(be) && isfinite(ga) && isfinite(hEst))
        f.env.csol = 1
        return _penalty(f)
    end
    f.env.csol = 0
    cm = 0.0 + mu
    r = Float64[xi - cm for xi in x]
    e = Float64[v * v for v in r]
    h = Vector{Float64}(undef, T)
    T > 0 && (h[1] = hEst)
    hp = hEst
    if f.gjr
        for i in 2:T
            nr = r[i-1] < 0.0 ? e[i-1] : 0.0
            hp = (((0.0 + om) + al * e[i-1]) + ga * nr) + be * hp
            h[i] = hp
        end
    else
        for i in 2:T
            hp = ((0.0 + om) + al * e[i-1]) + be * hp
            h[i] = hp
        end
    end
    z = Vector{Float64}(undef, T)
    LHT = Vector{Float64}(undef, T)
    lk = 0.0
    for i in 1:T
        sh = sqrt(abs(h[i]))
        zi = r[i] / sh
        z[i] = zi
        pdf = SimLev.RLibm.c_exp((-0.5 * zi) * zi) / _SQ2PI
        pdf == 0.0 && (pdf = 0.0 + _PDF_FLOOR)
        LHT[i] = SimLev.RLibm._log(pdf / sh)
        lk = lk - LHT[i]
    end
    llh = lk
    if isfinite(llh)
        f.env.llh = llh
    else
        llh = _penalty(f)
    end
    returnType === :llh && return llh
    returnType === :LHT && return Float64[-v for v in LHT]
    return Dict{String,Any}("llh" => llh, "h" => h, "epsx" => r, "z" => z,
                            "LHT" => Float64[-v for v in LHT], "persistence" => persist)
end

# ── numerische Ableitungen (Richardson-Extrapolation, eigenständig) ─────────
#
# Eigenständig geschrieben nach dem veröffentlichten Verfahren (zentrale
# Differenzen, Schrittweite |d x| bzw. zusätzlich eps nahe null, r Stufen mit
# Faktor v, Richardson-Extrapolation; Beschreibung in der Dokumentation von
# numDeriv, Linfield & Penny 1989). Kein Code aus numDeriv; wie im R-Paket
# (.sl_richardson_hessian/.sl_richardson_jacobian in r/R/richardson.R), dort
# gegen numDeriv als Prüf-Orakel bitgleich. Auswertungsfolge und Klammerung
# sind fest: die Likelihood merkt sich ihren letzten endlichen Wert
# (Strafwert), jede andere Folge ändert das Ergebnis.

"Anfangsschritt je Koordinate: `|d x|`, nahe null zusätzlich `eps`."
_richardson_steps(x, d, eps, zero_tol) =
    Float64[abs(d * xi) + eps * (abs(xi) < zero_tol ? 1.0 : 0.0) for xi in x]

"Einheitsvektoren als Spalten (wie `diag(p)` in R)."
_richardson_axes(p) = Float64[i == j ? 1.0 : 0.0 for i in 1:p, j in 1:p]

"""
Tableau (letzte Dimension = Stufen, grob zuerst) auf den extrapolierten Wert
falten: Schritt `m` tilgt den Fehlerterm `h^(2m)` mit dem Gewicht `w = v^(2m)`,
`neu_k = (alt_(k+1) * w - alt_k) / (w - 1)`.
"""
function _richardson_collapse(tab::Array{Float64}, v)
    lvl = 0
    nd = ndims(tab)
    while size(tab, nd) > 1
        lvl += 1
        w = SimLev.r_pow(Float64(v), 2.0 * lvl)
        k = size(tab, nd)
        tab = (selectdim(tab, nd, 2:k) .* w .- selectdim(tab, nd, 1:k-1)) ./ (w - 1)
    end
    dropdims(selectdim(tab, nd, 1:1); dims = nd)
end

"Hesse-Matrix einer skalaren Funktion (`.sl_richardson_hessian`)."
function _richardson_hessian(f, x::Vector{Float64}; eps = 1e-4, d = 0.1, zero_tol = _ZERO_TOL, r = 4, v = 2)
    p = length(x)
    f(x)                              # Prüfauswertung (skalar), wie in R
    centre = f(x)
    start = _richardson_steps(x, d, eps, zero_tol)
    axis = _richardson_axes(p)
    tab = zeros(r)
    pure = zeros(p)
    # reine zweite Ableitungen, Achse für Achse
    for a in 1:p
        h = start
        for s in 1:r
            fwd = f(x .+ h .* axis[:, a])
            bwd = f(x .- h .* axis[:, a])
            tab[s] = ((fwd - 2 * centre) + bwd) / (h[a] * h[a])
            h = h ./ v
        end
        pure[a] = _richardson_collapse(tab, v)[]
    end
    # gemischte Ableitungen im unteren Dreieck (a > b), zeilenweise
    low = zeros(p, p)
    for a in 1:p
        low[a, a] = pure[a]
        for b in 1:a-1
            h = start
            for s in 1:r
                fwd = f(x .+ h .* axis[:, a] .+ h .* axis[:, b])
                bwd = f(x .- h .* axis[:, a] .- h .* axis[:, b])
                tab[s] = ((((fwd - 2 * centre) + bwd) - pure[a] * (h[a] * h[a])) - pure[b] * (h[b] * h[b])) /
                         (2 * h[a] * h[b])
                h = h ./ v
            end
            low[a, b] = _richardson_collapse(tab, v)[]
        end
    end
    # symmetrisch ergänzen, verdoppelte Diagonale halbieren
    hess = low .+ permutedims(low)
    for a in 1:p
        hess[a, a] = hess[a, a] / 2
    end
    hess
end

"Jacobi-Matrix `length(f(x))` x `length(x)` (`.sl_richardson_jacobian`)."
function _richardson_jacobian(f, x::Vector{Float64}; eps = 1e-4, d = 1e-4, zero_tol = _ZERO_TOL, r = 4, v = 2)
    p = length(x)
    q = length(f(x))
    h = _richardson_steps(x, d, eps, zero_tol)
    axis = _richardson_axes(p)
    tab = fill(NaN, q, p, r)          # Einträge x Stufen
    for s in 1:r
        for a in 1:p
            fwd = f(x .+ h .* axis[:, a])
            bwd = f(x .- h .* axis[:, a])
            tab[:, a, s] = (fwd .- bwd) ./ (2 * h[a])
        end
        h = h ./ v
    end
    _richardson_collapse(tab, v)
end

"`.hessian2sided(f, x, ...)` (rugarch-numderiv.R)."
function _hessian2sided(f, x::Vector{Float64})
    n = length(x)
    fx = f(x)
    c = _eps13()
    h = Float64[_rmax2(abs(z * c), 1e-9) for z in x]
    xh = x .+ h
    h = xh .- x
    ee = zeros(n, n); for i in 1:n; ee[i, i] = h[i]; end
    gp = Float64[f(x .+ ee[:, i]) for i in 1:n]
    gm = Float64[f(x .- ee[:, i]) for i in 1:n]
    H = SimLev.RSolnp._outer(h)
    Hp = copy(H); Hm = copy(H)
    for i in 1:n, j in i:n
        Hp[i, j] = f((x .+ ee[:, i]) .+ ee[:, j])
        Hp[j, i] = Hp[i, j]
        Hm[i, j] = f((x .- ee[:, i]) .- ee[:, j])
        Hm[j, i] = Hm[i, j]
    end
    for i in 1:n, j in i:n
        H[i, j] = ((((((((Hp[i, j] - gp[i]) - gp[j]) + fx) + fx) - gm[i]) - gm[j]) + Hm[i, j]) / H[i, j]) / 2
        H[j, i] = H[i, j]
    end
    H
end

"`neweywestcv(data, nlag, center = TRUE)` (Newey-West, Bartlett-Gewichte)."
function _neweywestcv(X0::Matrix{Float64}, nlag::Integer)
    N = size(X0, 1)
    cm = SimLev.RBase.colMeans(X0)
    cmv = cm isa Real ? [Float64(cm)] : Float64.(collect(cm))
    X = X0 .- permutedims(cmv)
    bw = Float64[((nlag + 1) - s) / (nlag + 1) for s in 0:nlag]
    mm = SimLev.RSolnp._mm
    cv = (1 / N) .* mm(permutedims(X), X)
    for i in 1:nlag
        N - i == 1 && _rerr("non-conformable arrays")
        gmi = (1 / N) .* mm(permutedims(X[i+1:N, :]), X[1:N-i, :])
        gpp = gmi .+ permutedims(gmi)
        cv = cv .+ bw[i+1] .* gpp
    end
    cv
end

function _lht_vec(v, n)
    (v isa AbstractVector && length(v) == n) || _rerr("non-numeric argument to binary operator")
    Float64.(v)
end

"`robustvcv(fun, pars, nlag, hess, n, ...)` (rugarch-numderiv.R)."
function _robustvcv(fun, pars::Vector{Float64}, nlag::Integer, hess::Matrix{Float64}, n::Integer)
    k = length(pars)
    c = _eps13()
    h = Float64[_rmax2(abs(z * c), 1e-9) for z in pars]
    hplus = pars .+ h
    hminus = pars .- h
    plus = zeros(n, k); minus = zeros(n, k)
    for i in 1:k
        rp = copy(pars); rp[i] = hplus[i]
        plus[:, i] = _lht_vec(fun(rp), n)
    end
    for i in 1:k
        rm = copy(pars); rm[i] = hminus[i]
        minus[:, i] = _lht_vec(fun(rm), n)
    end
    scores = (plus .- minus) ./ (2 .* permutedims(h))
    A = hess ./ n
    Ainv = try
        SimLev.RSolnp._asmat(SimLev.RLinalg.solve(A))
    catch err
        err isa ErrorException || rethrow()
        _rerr("object 'B' not found")    # vcv = NA, B nicht gesetzt
    end
    B = nlag > 0 ? _neweywestcv(scores, nlag) : SimLev.RSolnp._asmat(SimLev.RStats.cov(scores))
    mm = SimLev.RSolnp._mm
    vcv = mm(mm(Ainv, B), Ainv) ./ n
    (vcv = vcv, B = B, A = A, scores = scores)
end

# ── Solver ──────────────────────────────────────────────────────────────────

const _SOLNP_CTRL = Dict{String,Any}("rho" => 1.0, "outer.iter" => 50.0, "inner.iter" => 1800.0,
                                     "delta" => 1.0e-8, "tol" => 1.0e-8, "trace" => 0.0)
const _NLMINB_CTRL = ["eval.max" => 2000, "trace" => 0, "iter.max" => 1500, "abs.tol" => 1e-20,
                      "rel.tol" => 1e-10, "x.tol" => 1.5e-8, "step.min" => 2.2e-14]

function _solnpsolver(pars, fun, ifn, ilb, iub, LB, UB)
    ans = try
        SimLev.RSolnp.solnp(pars, fun; ineqfun = ifn, ineqLB = [ilb], ineqUB = [iub], LB = LB, UB = UB,
                            control = _SOLNP_CTRL)
    catch err
        err isa ErrorException || rethrow()
        _warn("\nrugarch-->warning: no convergence...\n")
        return Dict{String,Any}("convergence" => 1, "message" => sprint(showerror, err),
                                "par" => fill(NA, length(pars)), "path" => ["solnp"])
    end
    Dict{String,Any}("convergence" => Int(ans["convergence"]), "message" => nothing,
                     "par" => Float64.(collect(SimLev.RSolnp._asvec(ans["pars"]))), "path" => ["solnp"])
end

function _nlminbsolver(pars, fun, parscale, LB, UB)
    ans = try
        SimLev.RStats.nlminb(pars, p -> fun(SimLev.RSolnp._asvec(p)); scale = 1 ./ parscale,
                             control = Dict{String,Any}(_NLMINB_CTRL), lower = LB, upper = UB)
    catch err
        err isa ErrorException || rethrow()
        return Dict{String,Any}("convergence" => 1, "message" => sprint(showerror, err),
                                "par" => fill(NA, length(pars)))
    end
    Dict{String,Any}("convergence" => Int(ans["convergence"]), "message" => ans["message"],
                     "par" => SimLev.RSolnp._asvec(ans["par"]))
end

"""
`.gosolnpsolver` mit `gocontrol = list()` (`.gosolnpctrl`: n.restarts = 1,
n.sim = 500, rseed = NULL, ohne Parallelisierung). `options(warn = 0)` und das
Zurücksetzen der Optionen haben keine Entsprechung (Warnungen werden immer
gemeldet).
"""
function _gosolnpsolver(pars, fun, ifn, ilb, iub, LB, UB)
    distr_opt = [Dict{String,Any}("mean" => p, "sd" => (p == 0 ? 0.1 : sqrt(p * p) * 2)) for p in pars]
    ans = try
        SimLev.RSolnp.gosolnp(pars, nothing, fun; eqfun = nothing, eqB = nothing, ineqfun = ifn,
                              ineqLB = [ilb], ineqUB = [iub], LB = LB, UB = UB, control = _SOLNP_CTRL,
                              distr = fill(2.0, length(LB)), distr_opt = distr_opt, n_restarts = 1,
                              n_sim = 500, cluster = nothing, rseed = nothing)
    catch err
        err isa ErrorException || rethrow()
        return Dict{String,Any}("convergence" => 1, "message" => sprint(showerror, err),
                                "par" => fill(NA, length(pars)))
    end
    Dict{String,Any}("convergence" => Int(ans["convergence"]), "message" => nothing,
                     "par" => Float64.(collect(SimLev.RSolnp._asvec(ans["pars"]))))
end

function _hybridsolver(pars, fun, ifn, ilb, iub, parscale, LB, UB)
    ans = _solnpsolver(pars, fun, ifn, ilb, iub, LB, UB)
    if ans["convergence"] >= 1
        ans = _nlminbsolver(pars, fun, parscale, LB, UB)
        ans["path"] = ["solnp", "nlminb"]
        if ans["convergence"] >= 1
            ans = _gosolnpsolver(pars, fun, ifn, ilb, iub, LB, UB)
            ans["path"] = ["solnp", "nlminb", "gosolnp"]
            if ans["convergence"] >= 1
                ans = _gosolnpsolver(pars, fun, ifn, ilb, iub, LB, UB)
                ans["path"] = ["solnp", "nlminb", "gosolnp", "gosolnp"]
            end
        end
    end
    ans
end

# ── ugarchfit ───────────────────────────────────────────────────────────────

"""
    ugarchfit(data; model = "sGARCH", solver = "hybrid", full = false)

`ugarchfit(spec, data, solver = "hybrid")` mit der Spezifikation aus
`.fit_garch11` (GARCH(1,1) bzw. GJR-GARCH(1,1), ARMA(0,0) mit Mittelwert,
Normalverteilung). `full = true` berechnet zusätzlich die Scores
(`_richardson_jacobian`).

Ergebnis: `RList` mit `coef` (benannter `RVector` oder `nothing` wie
`coef(fit)`), `convergence`, `message`, `solver_path`, `LLH`, `hessian`,
`cvar`, `robust_cvar`, `scores` (nur mit `full`) und `persistence`. Warnungen
und Fehler wie rugarch. Erreicht die Solver-Kette gosolnp, zieht es wie in R
Zufallsstartwerte und setzt dabei den globalen Zufallszustand mit
`set.seed(as.numeric(Sys.time()))` (`SimLev.RBase.sys_time`, Prüfschalter
`SIMLEV_R_SYS_TIME`).
"""
function ugarchfit(data; model::AbstractString = "sGARCH", solver::AbstractString = "hybrid", full::Bool = false)
    model in ("sGARCH", "gjrGARCH") || error("rugarch-Nachbildung: nur model = \"sGARCH\" oder \"gjrGARCH\"")
    solver == "hybrid" || error("rugarch-Nachbildung: nur solver = \"hybrid\"")
    gjr = model == "gjrGARCH"
    x = data isa RVector ? Float64.(data.values) : Float64.(collect(data isa Real ? [data] : data))
    n = length(x)
    n < 100 && _warn("\nugarchfit-->waring: using less than 100 data\n points for estimation\n")
    T = n
    env = _GarchEnv(1.0, 0)
    llh = _LLH(x, gjr, env)
    mdat = SimLev.r_mean(x)
    vdat = SimLev.r_var(x)
    names = gjr ? ["mu", "omega", "alpha1", "beta1", "gamma1"] : ["mu", "omega", "alpha1", "beta1"]
    mu_lb, mu_ub = mdat == 0 ? (-0.5, 0.5) : (-100 * abs(mdat), 100 * abs(mdat))
    start = [mdat, vdat / 1000, 0.05 / 1, 0.9 / 1]
    LB = [mu_lb, _EPS, 0.0, 0.0]
    UB = [mu_ub, vdat * 1000, 1 - _TINY, 1 - _TINY]
    parscale = [abs(mdat), vdat, 1.0, 1.0]
    if gjr
        push!(start, 0.05 / 1); push!(LB, -1 + _TINY); push!(UB, 1 - _TINY); push!(parscale, 1.0)
    end
    fun = (p, a...) -> llh(p, :llh)
    ifn = gjr ? ((p, a...) -> (q = SimLev.RSolnp._asvec(p); con = (q[4] + q[3]) + q[5] * KAPPA_NORM;
                              [isnan(con) ? 1.0 : con])) :
                ((p, a...) -> (q = SimLev.RSolnp._asvec(p); [q[3] + q[4]]))
    sol = _hybridsolver(start, fun, ifn, _EPS, 0.999, parscale, LB, UB)
    par = Float64.(sol["par"]) .* 1.0                     # * dscale (= 1)
    convergence = sol["convergence"]
    convergence != 0 && !gjr && _warn("\nugarchfit-->warning: solver failer to converge.")
    out = RList("coef" => nothing, "convergence" => (convergence != 0 ? 1 : 0),
                "message" => get(sol, "message", nothing), "solver_path" => get(sol, "path", nothing))
    convergence != 0 && return out
    fit = _makefitmodel(llh, par, T, full)
    out["coef"] = RVector(par; names = names)
    for (k, v) in fit
        out[k] = v
    end
    out
end

".makefitmodel (ohne feste Parameter): Hesse-Matrix, Kovarianzen, Prüfungen."
function _makefitmodel(llh::_LLH, par::Vector{Float64}, T::Integer, full::Bool)
    f = p -> llh(p, :llh)
    H = _richardson_hessian(f, par; eps = 1e-4, d = 0.1, zero_tol = _ZERO_TOL, r = 4, v = 2)
    all(isfinite, H) || _rerr("infinite or missing values in 'x'")     # eigen()
    cvar = try
        SimLev.RSolnp._asmat(SimLev.RLinalg.solve(H))
    catch err
        err isa ErrorException || rethrow()
        try
            SimLev.RSolnp._asmat(SimLev.RLinalg.solve(_hessian2sided(f, par)))
        catch err2
            err2 isa ErrorException || rethrow()
            _warn("\nrugarch-->warning: failed to invert hessian\n")
            nothing
        end
    end
    temp = llh(par, :all)
    temp isa Dict || _rerr("\$ operator is invalid for atomic vectors")
    out = Dict{String,Any}("LLH" => -temp["llh"], "hessian" => H, "cvar" => cvar, "robust_cvar" => nothing,
                           "scores" => nothing, "persistence" => temp["persistence"])
    if cvar !== nothing
        nlag = min(Int(floor(1.2 * SimLev.r_pow(Float64(T), 1.0 / 3.0))), T)
        flht = p -> llh(p, :LHT)
        rv = _robustvcv(flht, par, nlag, H, T)
        out["robust_cvar"] = rv.vcv
        full && (out["scores"] = _richardson_jacobian(flht, par; eps = 1e-4, d = 1e-4, zero_tol = _ZERO_TOL, r = 4, v = 2))
        any(i -> rv.vcv[i, i] < 0, 1:size(rv.vcv, 1)) && _warn("NaNs produced")
    end
    out
end

"`coef(fit)` eines Ergebnisses von `ugarchfit` (benannter `RVector` oder `nothing`)."
coef(fit) = fit["coef"]

end # module
