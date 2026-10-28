# Optimize – Portfolio-Optimierung und Risikozerlegung (r/R/optimize.R)
#
#   portfolio_optimize()    Minimum-Varianz, Mean-Variance, maximale Sharpe Ratio,
#                           maximale Diversifikation, Risikoparität (Risikobudgets),
#                           Hierarchical Risk Parity, minimaler CVaR/CDaR, inverse
#                           Volatilität, Gleichgewichtung; Box-Grenzen,
#                           Kovarianzschätzer (Stichprobe, Ledoit-Wolf, EWMA,
#                           Rauschfilter, Gerber), Resampling (Michaud)
#   efficient_frontier()    Effizienzgrenze unter denselben Grenzen
#   rolling_optimization()  Optimierung in rollierenden Fenstern → Zielgewichte für
#                           tactical_simulation()
#   risk_contributions()    Euler-Zerlegung von Volatilität bzw. CVaR
#   cpcv_portfolio()        kombinatorische Kreuzvalidierung (CPCV)
#
# Löser ohne Zusatzpakete (Kerne in OptimizeCore): FISTA auf dem beschränkten
# Simplex, gedämpftes Newton-Verfahren für die Risikoparität, geglätteter CVaR,
# Clusterbaum (hclust "single") für HRP.
#
# Ergebnisobjekte: `RList` mit Klasse `SimLevOptimization`, `SimLevFrontier`,
# `SimLevCPCV`; rolling_optimization() liefert `SimLevWeights` (RFrame, siehe
# Tactical) mit den Attributen `source`, `decision_rows`, `failed_dates` in
# `attrs(w)`. Eingaben: Renditematrix (`Matrix`, `NamedMat`, `RFrame` ohne
# `date`) oder Kursdaten (`RFrame` mit Spalte `date`); benannte Vektoren als
# `RVector`, `Dict`, `NamedTuple` oder `Pair`-Liste.
module Optimize

import ..SimLev
using ..SimLev: _alloc_c, _alloc_ticks, _esc
using ..SimLev: RList, RFrame, RVector, NamedMat, NA, isna_strict, F80
using Dates

export portfolio_optimize, efficient_frontier, rolling_optimization, risk_contributions, cpcv_portfolio,
       print_SimLevOptimization, print_SimLevFrontier, print_SimLevCPCV,
       plot_SimLevOptimization, plot_SimLevFrontier

const _METHODS = ["min_variance", "max_sharpe", "mean_variance", "max_diversification", "risk_parity", "hrp",
                  "min_cvar", "min_cdar", "inverse_vol", "equal"]
const _COVS = ["sample", "ledoit_wolf", "ewma", "denoise", "gerber"]
const _FREQS = ["week", "day", "month"]
const _PO_FORMALS = ["x", "assets", "method", "lower", "upper", "cov", "mu", "risk_free", "risk_aversion", "budget",
                     "alpha", "frequency", "resample", "block", "seed"]

# ═══════════════════════════════════════════════════════════════════════════
# kleine R-Hilfen
# ═══════════════════════════════════════════════════════════════════════════

_match_arg(arg, choices) = SimLev.DataPrep._match_arg(arg, choices)
_sprintf(fmt, args...) = (s = SimLev.RFmt.sprintf(fmt, args...); s isa AbstractString ? String(s) : String(first(s)))
_sqrt(x::Float64) = x < 0 ? NaN : sqrt(x)

"R-`format(x)` eines Vektors → Zeichenvektor (gemeinsame Breite)."
function _fmt1(x)
    r = SimLev.RFmt.format(x)
    r isa AbstractString ? [String(r)] : String[String(s) for s in r]
end

"`sum(x)` in long double (sequenziell)."
_ldsum(x) = SimLev.r_sum(x)

"`colMeans` (long double, Division in long double)."
function _colmeans(A::AbstractMatrix{Float64})
    n, p = size(A)
    out = Vector{Float64}(undef, p)
    for j in 1:p
        if n == 0
            out[j] = NaN
            continue
        end
        s = F80(0.0)
        @inbounds for i in 1:n
            s = s + SimLev._ldq(A[i, j])
        end
        out[j] = Float64(s / F80(n))
    end
    out
end

"`rowSums` (long double)."
function _rowsums(A::AbstractMatrix{Float64})
    n, p = size(A)
    out = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        s = F80(0.0)
        for j in 1:p
            s = s + SimLev._ldq(A[i, j])
        end
        out[i] = Float64(s)
    end
    out
end

"`mean` eines logischen Vektors."
_mean_lgl(x) = SimLev.r_mean_int(Int[v ? 1 : 0 for v in x])

_asmat(x::NamedMat) = Matrix{Float64}(x.data)
_asmat(x::AbstractMatrix) = Matrix{Float64}(x)
_asmat(x::AbstractVector) = reshape(Float64[Float64(v) for v in x], :, 1)
_asmat(x::Real) = fill(Float64(x), 1, 1)
_asvec(x::NamedMat) = Float64[v for v in vec(x.data)]
_asvec(x::RVector) = Float64[Float64(v) for v in x.values]
_asvec(x::AbstractArray) = Float64[Float64(v) for v in vec(x)]
_asvec(x::Real) = Float64[Float64(x)]

"`x %*% y` (Referenz-BLAS-Reihenfolge über RLinalg)."
_mp(x, y) = _asmat(SimLev.RLinalg.matprod(_asmat(x), _asmat(y)))
"`drop(R %*% w)`."
_mat_vec(R, w) = vec(_mp(R, reshape(_asvec(w), :, 1)))
"`drop(t(w) %*% S %*% w)`."
function _quad(w, S)
    wv = _asvec(w)
    _mp(_mp(reshape(wv, 1, :), S), reshape(wv, :, 1))[1, 1]
end
"`stats::cov(R)` als Matrix."
_cov(R) = _asmat(SimLev.RStats.cov(_asmat(R)))
_col_means(R) = _colmeans(_asmat(R))
_cov2cor(S) = _asmat(SimLev.RStats.cov2cor(_asmat(S)))

_getf(o, k::String) = o isa AbstractDict ? o[k] : o isa NamedTuple ? getfield(o, Symbol(k)) : getproperty(o, Symbol(k))

"`eigen(M, symmetric = TRUE)` → (Werte absteigend, Vektoren)."
function _eigen_sym(M)
    e = SimLev.RLinalg.eigen(_asmat(M); symmetric = true)
    (_asvec(_getf(e, "values")), _asmat(_getf(e, "vectors")))
end
_eigvals_sym(M) = _asvec(_getf(SimLev.RLinalg.eigen(_asmat(M); symmetric = true, only_values = true), "values"))

"`stats::quantile(x, p, names = FALSE, type = 7)` (ein Wert)."
function _quantile(x, p)
    q = SimLev.RStats.quantile(_asvec(x), Float64(p); names = false, type = 7)
    q isa Real ? Float64(q) : Float64(first(q isa RVector ? q.values : q))
end

"`diag(v, N)`."
function _diagm(v, N::Int)
    vv = v isa Real ? [Float64(v)] : _asvec(v)
    D = zeros(N, N)
    for i in 1:N
        D[i, i] = vv[mod1(i, length(vv))]
    end
    D
end
_diag(S::AbstractMatrix) = Float64[S[i, i] for i in 1:min(size(S)...)]

"`which.max` (erstes Maximum, NA/NaN übergangen; 0 wenn keins)."
function _which_max(v)
    k = 0
    for i in eachindex(v)
        x = v[i]
        isnan(x) && continue
        (k == 0 || x > v[k]) && (k = i)
    end
    k
end
function _which_min(v)
    k = 0
    for i in eachindex(v)
        x = v[i]
        isnan(x) && continue
        (k == 0 || x < v[k]) && (k = i)
    end
    k
end

_unique(v) = (out = similar(v, 0); for s in v; s in out || push!(out, s); end; out)
_setdiff(a, b) = _unique([x for x in a if !(x in b)])

_isna(v) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))
_isnum(v) = (v isa Real && !(v isa Bool)) || v === missing

"Benannter Vektor → (Namen oder `nothing`, Werte, numerisch?)."
function _named_vec(x)
    x === nothing && return (nothing, Any[], false)
    nm, vals = if x isa RVector
        (x.names === nothing ? nothing : copy(x.names), Any[v for v in x.values])
    elseif x isa AbstractDict
        (String[string(k) for k in keys(x)], Any[v for v in values(x)])
    elseif x isa NamedTuple
        (String[string(k) for k in keys(x)], Any[v for v in values(x)])
    elseif x isa Pair
        ([string(x.first)], Any[x.second])
    elseif x isa AbstractVector && !isempty(x) && all(p -> p isa Pair, x)
        (String[string(p.first) for p in x], Any[p.second for p in x])
    elseif x isa Union{AbstractString,Symbol,Real,Missing,Date}
        (nothing, Any[x])
    elseif x isa Union{AbstractArray,Tuple}
        (nothing, Any[v for v in x])
    else
        (nothing, Any[x])
    end
    (nm, vals, all(_isnum, vals))
end

function _fmt_vals(vals, isnum)
    isnum && return _fmt1(Float64[v === missing ? NA : Float64(v) for v in vals])
    String[_isna(v) ? "NA" : v isa Bool ? (v ? "TRUE" : "FALSE") : string(v) for v in vals]
end

_q(v) = join(("'" * string(s) * "'" for s in v), ", ")

_warn(msg) = (@warn msg; nothing)
_errmsg(e) = e isa ErrorException ? e.msg : hasproperty(e, :msg) ? string(getproperty(e, :msg)) : sprint(showerror, e)

# Warnung SimLevBoundsPercent: Aufrufer können sie abfangen (R: withCallingHandlers);
# der Handler gilt je Aufgabe (task-lokal, thread-sicher für RParallel)
const _BOUNDS_KEY = :SimLev_Optimize_bounds_handler
function _warn_bounds(msg)
    tls = current_task().storage
    h = tls === nothing ? nothing : get(tls, _BOUNDS_KEY, nothing)
    (h === nothing || h(msg)) && _warn(msg)
    nothing
end
_with_bounds_handler(f, h) = task_local_storage(f, _BOUNDS_KEY, h)

# ═══════════════════════════════════════════════════════════════════════════
# Renditen, Prüfungen
# ═══════════════════════════════════════════════════════════════════════════

_has_date(x) = x isa RFrame && haskey(x, "date")
_df_names(x::RFrame) = names(x)
_df_names(x) = String[]

_isnum_col(c) = eltype(c) <: Union{Missing,Real} && !(nonmissingtype(eltype(c)) <: Bool) && nonmissingtype(eltype(c)) !== Union{}

"Interne Renditen mit ppy (R-Klasse `SimLevOptReturns`, für cpcv_portfolio)."
_opt_returns_obj(A, cn, ppy) = RList("R" => NamedMat(A; colnames = cn), "ppy" => ppy; class = "SimLevOptReturns")

"`.opt_returns`: Periodenrenditen (einfach) → (R = Matrix, cn, ppy, dates)."
function _opt_returns(x, assets = nothing, frequency = "week")
    assets isa AbstractString && (assets = [assets])
    if x isa RList && SimLev.inherits(x, "SimLevOptReturns")
        M = x["R"]
        A = _asmat(M)
        cn = M isa NamedMat ? copy(M.colnames) : ["A$j" for j in 1:size(A, 2)]
        if assets !== nothing
            ix = [findfirst(==(String(a)), cn) for a in assets]
            A = A[:, ix]
            cn = String[String(a) for a in assets]
        end
        return (R = A, cn = cn, ppy = Float64(x["ppy"]), dates = nothing)
    end
    if _has_date(x)
        if assets === nothing
            assets = String[k for k in names(x) if k != "date" && _isnum_col(x[k])]
        end
        assets = String[String(a) for a in assets]
        rd = SimLev.Dependence._dep_returns(x, assets, nothing, frequency)
        nr = SimLev.nrow(rd)
        L = zeros(nr, length(assets))
        for (j, a) in enumerate(assets)
            c = rd[a]
            for i in 1:nr
                L[i, j] = c[i] === missing ? NA : Float64(c[i])
            end
        end
        A = SimLev.RLibm.expm1(L)
        A = reshape(A, nr, length(assets))
        dd = SimLev.DataPrep._to_date(rd["date"], "date")
        ppy = nr == 0 ? NaN : Float64(nr - 1) / (Float64(Dates.value(dd[nr] - dd[1])) / 365.25)
        return (R = A, cn = assets, ppy = ppy, dates = dd)
    end
    cn = nothing
    isnum = true
    if x isa RFrame
        cn = names(x)
        cols = [x[k] for k in cn]
        isnum = all(c -> _isnum_col(c) || eltype(c) <: Union{Missing,Bool}, cols)
        Araw = isnum ? Float64[c[i] === missing ? NA : Float64(c[i]) for i in 1:SimLev.nrow(x), c in cols] :
                       Any[c[i] for i in 1:SimLev.nrow(x), c in cols]
    elseif x isa NamedMat
        cn = x.colnames === nothing ? nothing : copy(x.colnames)
        Araw = x.data
    elseif x isa AbstractMatrix
        Araw = x
    elseif x isa AbstractVector
        Araw = reshape(collect(x), :, 1)
    else
        error("x muss Kursdaten mit Spalte 'date' oder eine numerische Renditematrix sein.")
    end
    if !(Araw isa AbstractMatrix{<:Real}) || eltype(Araw) <: Bool
        isnum = all(v -> _isnum(v) || v isa Bool, Araw) && !all(v -> v isa Bool, Araw)
    end
    cn === nothing && (cn = String["A$j" for j in 1:size(Araw, 2)])
    if assets !== nothing
        assets = String[String(a) for a in assets]
        miss = _setdiff(assets, cn)
        isempty(miss) || error("Spalten fehlen: " * join(miss, ", "))
        Araw = Araw[:, [findfirst(==(a), cn) for a in assets]]
        cn = assets
    end
    isnum || error("x muss Kursdaten mit Spalte 'date' oder eine numerische Renditematrix sein.")
    A = Float64[v === missing ? NA : Float64(v) for v in Araw]
    A = reshape(A, size(Araw))
    _opt_check_finite(A, cn)
    ok = [!any(isnan, @view A[i, :]) for i in 1:size(A, 1)]
    ppy = frequency == "day" ? 252.0 : frequency == "week" ? 52.0 : 12.0
    (R = A[ok, :], cn = cn, ppy = ppy, dates = nothing)
end

"`.opt_check_finite`: unendliche Renditen mit Spalte und Zeile melden."
function _opt_check_finite(A, cn)
    pos = Tuple{Int,Int}[]
    for j in 1:size(A, 2), i in 1:size(A, 1)
        isinf(A[i, j]) && push!(pos, (j, i))
    end
    isempty(pos) && return nothing
    cols = _unique([cn[j] for (j, _) in pos])
    j0 = pos[1][1]
    first_ = minimum(i for (j, i) in pos if j == j0)
    error("x: unendliche Rendite(n) (Inf/-Inf) in der Renditematrix, Spalte(n) $(_q(cols)) ($(length(pos)) Wert(e), " *
          "erster in Zeile $(first_)); Renditen als endliche Anteile angeben (fehlende Werte als NA).")
end

"`.opt_check_alpha`: Tail-Wahrscheinlichkeit als Anteil in (0, 0.5]."
function _opt_check_alpha(alpha, fn)
    _, vals, isnum = _named_vec(alpha)
    one = isnum && length(vals) == 1 && !_isna(vals[1]) && isfinite(Float64(vals[1]))
    one && Float64(vals[1]) > 0 && Float64(vals[1]) <= 0.5 && return nothing
    hint = ""
    if one
        a = Float64(vals[1])
        if a >= 1
            hint = _sprintf(" - als Anteil angeben (z. B. %g statt %g)", a / 100, a)
        elseif a > 0.5
            hint = _sprintf(" - gemeint ist der Tail-Anteil, nicht das Konfidenzniveau (%g -> alpha = %g)", a, 1 - a)
        end
    end
    error("$fn: alpha muss die Tail-Wahrscheinlichkeit als Anteil in (0, 0.5] sein, z. B. 0.05 = schlechteste " *
          "5 % (erhalten: $(join(_fmt_vals(vals, isnum), ", ")))$hint.")
end

"`.opt_bounds`: Skalar, benannter oder positionsweiser Vektor → Wert je Anlage."
function _opt_bounds(b, nm, default, what = "upper")
    names_, vals, isnum = _named_vec(b)
    if !isnum || isempty(vals) || any(_isna, vals)
        error("$what: numerischer Wert bzw. Vektor ohne NA erwartet (erhalten: $(join(_fmt_vals(vals, isnum), ", "))).")
    end
    v = Float64[Float64(x) for x in vals]
    N = length(nm)
    if names_ === nothing
        length(v) == 1 && return fill(v[1], N)
        length(v) == N && return v
        error("$what: unbenannter Vektor der Länge $(length(v)) passt nicht zu $N Anlagen (Skalar, benannter Vektor " *
              "oder ein Wert je Anlage in Spaltenreihenfolge).")
    end
    unk = _setdiff(names_, nm)
    isempty(unk) || error("$what: unbekannte Anlage(n) $(_q(unk)); vorhanden: $(join(nm, ", ")).")
    out = fill(Float64(default), N)
    for (k, x) in zip(names_, v)
        out[findfirst(==(k), nm)] = x
    end
    out
end

"`.opt_check_bounds`: Unter- und Obergrenzen prüfen (Long-only, erfüllbar)."
function _opt_check_bounds(lower, upper, nm)
    lo = _opt_bounds(lower, nm, 0.0, "lower")
    hi = _opt_bounds(upper, nm, 1.0, "upper")
    hi[hi .== Inf] .= 1.0
    if any(>(1), hi)
        big = findall(>(1), hi)
        fb = _fmt1(hi[big])
        _warn_bounds("upper: Obergrenze(n) > 1 (" * join(("$(nm[i]) = $s" for (i, s) in zip(big, fb)), ", ") *
                     "); Grenzen sind Anteile (0.26 = 26 %), Werte > 1 wirken wie 1. Prozentangabe? Dann durch 100 teilen.")
    end
    any(<(0), lo) && error("lower: Untergrenzen müssen >= 0 sein (Long-only; erhalten $(join(_fmt1(lo[lo .< 0]), ", "))).")
    slo = _ldsum(lo)
    shi = _ldsum(hi)
    if slo > 1 + 1e-12 || shi < 1 - 1e-12 || any(lo .> hi)
        error(_sprintf("Grenzen nicht erfüllbar (sum(lower) <= 1 <= sum(upper) und lower <= upper; hier " *
                       "sum(lower) = %g, sum(upper) = %g).", slo, shi))
    end
    (lo, hi)
end

"`.opt_flat`: Anlagen ohne Schwankung."
_opt_flat(S, nm) = String[nm[i] for i in eachindex(nm) if _sqrt(max(S[i, i], 0.0)) <= 1e-10]

# ═══════════════════════════════════════════════════════════════════════════
# Kovarianzschätzer
# ═══════════════════════════════════════════════════════════════════════════

function _psd(M, N)
    vals, V = _eigen_sym(M)
    D = _diagm(Float64[isnan(v) ? v : max(v, 1e-12) for v in vals], N)
    M2 = _mp(_mp(V, D), permutedims(V))
    (M2 .+ permutedims(M2)) ./ 2
end

"`.opt_cov` auf einer Matrix (Float64)."
function _opt_cov_m(R::Matrix{Float64}, type::String)
    S = _cov(R)
    Tn, N = size(R)
    (type == "sample" || N < 2) && return S
    if type == "ledoit_wolf"
        cm = _colmeans(R)
        X = R .- reshape(cm, 1, :)
        S1 = _asmat(SimLev.RLinalg.crossprod(X)) ./ Tn
        m = _ldsum(_diag(S1)) / N
        dm = _diagm(m, N)
        nrm(Am) = (a = vec(Am); _ldsum(a .* a) / N)
        d2 = nrm(S1 .- dm)
        acc = Vector{Float64}(undef, Tn)
        for t in 1:Tn
            xt = X[t, :]
            acc[t] = nrm(xt .* permutedims(xt) .- S1)
        end
        b2 = min(d2, _ldsum(acc) / (Float64(Tn) * Float64(Tn)))
        a2 = d2 - b2
        Sh = (b2 / d2) .* dm .+ (a2 / d2) .* S1
        return Sh .* Tn ./ (Tn - 1)
    end
    if type == "ewma"
        hl = min(52.0, max(5.0, Tn / 4))
        lam = SimLev.r_pow(0.5, 1 / hl)
        w = Float64[SimLev.r_pow(lam, Float64(k)) for k in (Tn-1):-1:0]
        w = w ./ _ldsum(w)
        mu = Float64[_ldsum(R[:, j] .* w) for j in 1:N]
        X = R .- reshape(mu, 1, :)
        Xs = X .* sqrt.(w)
        C = _asmat(SimLev.RLinalg.crossprod(Xs)) ./ (1 - _ldsum(w .* w))
        return _psd(C, N)
    end
    sd = Float64[_sqrt(v) for v in _diag(S)]
    if type == "denoise"
        pos = sd .> 0
        if !all(pos)
            out = S .* 0
            if any(pos)
                ix = findall(pos)
                out[ix, ix] = _opt_cov_m(R[:, ix], "denoise")
            end
            return out
        end
        C = _cov2cor(S)
        vals, V = _eigen_sym(C)
        q = 1 + sqrt(N / Tn)
        lmax = q * q
        noise = vals .< lmax
        if count(noise) > 1
            vals[noise] .= SimLev.r_mean(vals[noise])
        end
        C2 = _mp(_mp(V, _diagm(vals, N)), permutedims(V))
        C2 = _cov2cor(C2)
        return _psd(C2 .* (sd .* permutedims(sd)), N)
    end
    # Gerber-Statistik (GS2)
    H = 0.5 .* sd
    Up = Float64.(R .>= reshape(H, 1, :))
    Dn = Float64.(R .<= reshape(-H, 1, :))
    cp(A, B) = Float64[sum(A[:, i] .* B[:, j]) for i in 1:N, j in 1:N]    # ganzzahlige Zählungen (exakt)
    Uu = cp(Up, Up)
    Dd = cp(Dn, Dn)
    Ud = cp(Up, Dn)
    nc = Uu .+ Dd
    nd = Ud .+ permutedims(Ud)
    G = Float64[nc[i, j] + nd[i, j] > 0 ? (nc[i, j] - nd[i, j]) / (nc[i, j] + nd[i, j]) : 0.0 for i in 1:N, j in 1:N]
    for i in 1:N
        G[i, i] = 1.0
    end
    _psd(G .* (sd .* permutedims(sd)), N)
end

"""
    _opt_cov(R, type = "sample")

`.opt_cov`: Kovarianzschätzer `"sample"`, `"ledoit_wolf"`, `"ewma"`,
`"denoise"` oder `"gerber"` (Matrix bzw. `NamedMat` mit den Spaltennamen).
"""
function _opt_cov(R, type = "sample")
    type = _match_arg(type, _COVS)
    S = _opt_cov_m(_asmat(R), type)
    cn = R isa NamedMat ? R.colnames : nothing
    cn === nothing ? S : NamedMat(S; rownames = cn, colnames = cn)
end

# ═══════════════════════════════════════════════════════════════════════════
# Löser
# ═══════════════════════════════════════════════════════════════════════════

_proj_capped_simplex(v, lo, hi) = SimLev.OptimizeCore.proj_box_simplex(v, lo, hi)

"`.qp_simplex`: FISTA für min 0.5 w'Qw + c'w auf dem beschränkten Simplex."
function _qp_simplex(Q, cvec, lo, hi, w0 = nothing; maxit = 20000, tol = 1e-12)
    Qm = _asmat(Q)
    N = size(Qm, 2)
    ev = _eigvals_sym(Qm)
    L = any(isnan, ev) ? NaN : max(maximum(ev), 1e-12)
    w0 = w0 === nothing ? fill(1 / N, N) : w0
    SimLev.OptimizeCore.qp_box_simplex(Qm, cvec, lo, hi, w0, L, Int(maxit), tol)
end

"`.risk_parity`: Risikobudgets (Spinu 2013, gedämpftes Newton)."
function _risk_parity(S, b)
    S = _asmat(S)
    b = _asvec(b)
    N = size(S, 2)
    y = 1 ./ sqrt.(_diag(S))
    y = y ./ _ldsum(y)
    f(z) = 0.5 * _quad(z, S) - _ldsum(b .* SimLev.RLibm.log(z))
    for _ in 1:200
        g = _mat_vec(S, y) .- b ./ y
        H = S .+ _diagm(b ./ (y .* y), N)
        dx = _asvec(SimLev.RLinalg.solve(H, g))
        step = 1.0
        while true
            yn = y .- step .* dx
            cond = any(<=(0), yn) ? true : f(yn) > f(y) - 1e-4 * step * _ldsum(g .* dx)
            cond || break
            step = step / 2
            step < 1e-12 && break
        end
        y = y .- step .* dx
        maximum(abs.(dx .* step)) < 1e-14 && break
    end
    y ./ _ldsum(y)
end

function _hclust_order(Dm)
    h = SimLev.RStats.hclust(SimLev.RStats.as_dist(Dm), "single")
    Int[Int(v) for v in _getf(h, "order")]
end

"`.hrp`: Hierarchical Risk Parity (Lopez de Prado 2016)."
function _hrp(S)
    S = _asmat(S)
    N = size(S, 2)
    N == 1 && return [1.0]
    C = _cov2cor(S)
    Dm = (1 .- C) ./ 2
    Dm[Dm .< 0] .= 0.0
    ordv = _hclust_order(sqrt.(Dm))
    w = ones(N)
    clusters = [ordv]
    function cv(ix)
        s = S[ix, ix]
        iv = 1 ./ _diag(s)
        iv = iv ./ _ldsum(iv)
        _quad(iv, s)
    end
    while !isempty(clusters)
        nxt = Vector{Vector{Int}}()
        for cl in clusters
            length(cl) > 1 || continue
            h = div(length(cl), 2)
            c1 = cl[1:h]
            c2 = cl[(h+1):end]
            v1 = cv(c1)
            v2 = cv(c2)
            a = 1 - v1 / (v1 + v2)
            w[c1] = w[c1] .* a
            w[c2] = w[c2] .* (1 - a)
            push!(nxt, c1, c2)
        end
        clusters = nxt
    end
    w ./ _ldsum(w)
end

"`.min_cvar`: minimaler CVaR (geglättet, FISTA)."
function _min_cvar(R, alpha, lo, hi)
    R = _asmat(R)
    N = size(R, 2)
    sc = SimLev.r_sd(vec(R))
    w = _proj_capped_simplex(fill(1 / N, N), lo, hi)
    zeta = _quantile(.-_mat_vec(R, w), 1 - alpha)
    SimLev.OptimizeCore.min_cvar_core(R, alpha, lo, hi, w, zeta, [sc * 0.05, sc * 0.005], 2000)
end

"`.cdar_hist`: CDaR der kumulierten, nicht aufgezinsten Rendite."
function _cdar_hist(r, alpha)
    rv = _asvec(r)
    C = vcat(0.0, SimLev.r_cumsum(rv))
    D = (SimLev.RBase.r_cummax(C) .- C)[2:end]
    v = _quantile(D, 1 - alpha)
    SimLev.r_mean(D[D .>= v])
end

_min_cdar(R, alpha, lo, hi, iters = 3000) = SimLev.OptimizeCore.min_cdar_core(_asmat(R), alpha, lo, hi, Int(iters))

"`.cvar_hist`: historischer CVaR (Verlust positiv)."
function _cvar_hist(r, alpha)
    L = .-_asvec(r)
    v = _quantile(L, 1 - alpha)
    SimLev.r_mean(L[L .>= v])
end

# ═══════════════════════════════════════════════════════════════════════════
# Kern
# ═══════════════════════════════════════════════════════════════════════════

"`.opt_core`: ein Optimierungsschritt auf einer Renditematrix."
function _opt_core(A::Matrix{Float64}, nm, method, lo, hi, cov_type, mu, risk_free, risk_aversion, budget, alpha, ppy)
    N = size(A, 2)
    S = _opt_cov_m(A, cov_type) .* ppy
    m = mu === nothing ? _colmeans(A) .* ppy : mu ./ 100
    function mu_miss()
        any(isnan, m) && error("$method: mu für alle Anlagen angeben; es fehlt ein Wert für " *
                               "$(_q(nm[isnan.(m)])) (benannter Vektor mit allen Anlagen oder ein Wert je Spalte in Spaltenreihenfolge).")
    end
    rf = Ref(Float64(risk_free) / 100)
    sharpe_of(w, mm) = (_ldsum(w .* mm) - rf[]) / _sqrt(_quad(w, S))
    function best_sharpe(mm)
        lg = _asvec(SimLev.RStats.seq_len_out(SimLev.RLibm.log(500.0), SimLev.RLibm.log(0.05), 30))
        ws = Vector{Vector{Float64}}()
        prev = nothing
        for k in eachindex(lg)
            push!(ws, _qp_simplex(SimLev.RLibm.exp(lg[k]) .* S, .-mm, lo, hi, prev; tol = 1e-10))
            prev = ws[k]
        end
        sh = Float64[sharpe_of(w, mm) for w in ws]
        k = _which_max(sh)
        a = lg[min(length(lg), k + 1)]
        b = lg[max(1, k - 1)]
        w0 = ws[k]
        fx(x) = (w = _qp_simplex(SimLev.RLibm.exp(x) .* S, .-mm, lo, hi, w0; tol = 1e-11); (w, sharpe_of(w, mm)))
        gr = (sqrt(5) - 1) / 2
        x1 = b - gr * (b - a)
        x2 = a + gr * (b - a)
        f1 = fx(x1)
        f2 = fx(x2)
        for _ in 1:25
            if f1[2] > f2[2]
                b = x2; x2 = x1; f2 = f1; x1 = b - gr * (b - a); f1 = fx(x1)
            else
                a = x1; x1 = x2; f1 = f2; x2 = a + gr * (b - a); f2 = fx(x2)
            end
        end
        cand = [ws[k], f1[1], f2[1]]
        cand[_which_max([sh[k], f1[2], f2[2]])]
    end
    default_bounds = all(==(0), lo) && all(==(1), hi)
    if method in ("inverse_vol", "risk_parity", "hrp") && N > 1
        fl = _opt_flat(S, nm)
        isempty(fl) || error("$method: Anlage(n) $(_q(fl)) ohne Schwankung (Volatilität 0); das Verfahren ist dafür " *
                             "nicht definiert. Anlage entfernen oder z. B. min_variance verwenden.")
    end
    w = if method == "equal"
        default_bounds || _warn("equal: Grenzen werden ignoriert.")
        fill(1 / N, N)
    elseif method == "inverse_vol"
        default_bounds || _warn("inverse_vol: Grenzen werden ignoriert.")
        v = 1 ./ sqrt.(_diag(S))
        v ./ _ldsum(v)
    elseif method == "min_variance"
        _qp_simplex(S, zeros(N), lo, hi)
    elseif method == "mean_variance"
        mu_miss()
        _qp_simplex(risk_aversion .* S, .-m, lo, hi)
    elseif method == "max_sharpe"
        mu_miss()
        best_sharpe(m)
    elseif method == "max_diversification"
        rf[] = 0.0
        best_sharpe(sqrt.(_diag(S)))
    elseif method == "risk_parity"
        default_bounds || _warn("risk_parity: Grenzen werden ignoriert.")
        bb = if budget === nothing
            fill(1 / N, N)
        else
            v = _opt_bounds(budget, nm, 0.0, "budget")
            (any(<(0), v) || _ldsum(v) <= 0) && error("budget: Risikobudgets müssen >= 0 sein, mit positiver Summe.")
            v ./ _ldsum(v)
        end
        _risk_parity(S, bb)
    elseif method == "hrp"
        default_bounds || _warn("hrp: Grenzen werden ignoriert.")
        _hrp(S)
    elseif method == "min_cvar"
        _min_cvar(A, alpha, lo, hi)
    elseif method == "min_cdar"
        _min_cdar(A, alpha, lo, hi)
    else
        error("Unbekannte Methode '$method'.")
    end
    w = Float64[abs(v) < 1e-12 ? 0.0 : v for v in w]
    w ./ _ldsum(w)
end

# ═══════════════════════════════════════════════════════════════════════════
# portfolio_optimize
# ═══════════════════════════════════════════════════════════════════════════

"""
    portfolio_optimize(x; assets = nothing, method = "min_variance", lower = 0, upper = 1,
                       cov = "sample", mu = nothing, risk_free = 0, risk_aversion = 4,
                       budget = nothing, alpha = 0.05, frequency = "week", resample = 0,
                       block = nothing, seed = nothing)

Portfolio optimieren (Long-only, Summe 1, optionale Grenzen je Anlage); Port
von `portfolio_optimize()`. `x`: `RFrame` mit Spalte `date` und Kursspalten
oder Matrix einfacher Periodenrenditen als Anteil (ohne Spaltennamen `A1`,
`A2`, …). `method`: `"min_variance"`, `"max_sharpe"`, `"mean_variance"`,
`"max_diversification"`, `"risk_parity"`, `"hrp"`, `"min_cvar"`, `"min_cdar"`,
`"inverse_vol"` oder `"equal"`. Grenzen, `mu` (Prozent p. a.) und `budget` als
Skalar, benannter Vektor oder ein Wert je Anlage.

Ergebnis: `RList` der Klasse `SimLevOptimization` mit `weights`, `stats`,
`risk`, `alpha`, `method`, `bounds`, `resampled`, `cov_type`, `frequency`,
`n_obs`; Druck wie in R, `r_plot` zeichnet Gewichte und Risikoanteile (SVG).
"""
function portfolio_optimize(x; assets = nothing, method = nothing, lower = 0, upper = 1, cov = nothing, mu = nothing,
                            risk_free = 0, risk_aversion = 4, budget = nothing, alpha = 0.05, frequency = nothing,
                            resample = 0, block = nothing, seed = nothing)
    x = SimLev.as_rframe(x)
    method = _match_arg(method, _METHODS)
    cov = _match_arg(cov, _COVS)
    frequency = _match_arg(frequency, _FREQS)
    rr = _opt_returns(x, assets, frequency)
    A = rr.R
    nm = rr.cn
    N = length(nm)
    T = size(A, 1)
    T < N + 5 && error("Zu wenige Beobachtungen für die Optimierung ($T Perioden für $N Anlagen, mindestens $(N + 5)).")
    lo, hi = _opt_check_bounds(lower, upper, nm)
    _opt_check_alpha(alpha, "portfolio_optimize")
    muv = nothing
    if mu !== nothing
        muv = _opt_bounds(mu, nm, NA, "mu")
        any(isinf, muv) && error("mu: endliche Werte in Prozent p. a. erwartet (erhalten: $(join(_fmt1(muv), ", "))).")
    end
    ppy = rr.ppy
    alpha = Float64(alpha isa AbstractVector ? alpha[1] : alpha)
    core(Rx) = _opt_core(Rx, nm, method, lo, hi, cov, muv, Float64(risk_free), Float64(risk_aversion), budget, alpha, ppy)
    w = core(A)
    wb = nothing
    if resample > 0
        blk = block === nothing ? max(2.0, Float64(SimLev.RFmt.r_round(SimLev.r_pow(Float64(T), 1 / 3)))) : block
        nres = Int(resample)
        run = function ()
            out = Matrix{Float64}(undef, nres, N)
            for bb in 1:nres
                idx = SimLev.BootstrapCore.boot_idx_stationary(T, T, blk)
                out[bb, :] = core(A[idx, :])
            end
            out
        end
        wbm = SimLev.Bootstrap._with_rng_restore(run; seed = seed)
        wb = NamedMat(wbm; colnames = nm)
        wv = _colmeans(wbm)
        w = wv ./ _ldsum(wv)
    end
    out = _opt_summary(w, A, nm, ppy, cov, risk_free, alpha)
    out["method"] = method
    out["bounds"] = NamedMat(vcat(reshape(lo, 1, :), reshape(hi, 1, :)); rownames = ["lower", "upper"])
    out["resampled"] = wb
    out["cov_type"] = cov
    out["frequency"] = frequency
    out["n_obs"] = T
    out.class = ["SimLevOptimization"]
    out
end

"`.opt_summary`: Kennzahlen eines Gewichtsvektors."
function _opt_summary(w::Vector{Float64}, A::Matrix{Float64}, nm, ppy, cov_type, risk_free, alpha)
    S = _opt_cov_m(A, cov_type) .* ppy
    m = _colmeans(A) .* ppy
    q = _quad(w, S)
    vol = isnan(q) ? q : _sqrt(max(q, 0.0))
    ret = _ldsum(w .* m)
    rp = _mat_vec(A, w)
    if vol <= 1e-10
        _warn("Portfolio ohne Schwankung (Volatilität 0, nur Anlagen mit konstanter Rendite): Sharpe Ratio, " *
              "Diversifikationsverhältnis und Risikoanteile sind nicht definiert (NA).")
        vol = 0.0
        vq = NA
    else
        vq = vol
    end
    rc = w .* _mat_vec(S, w) ./ vq
    rs = rc ./ vq
    stats = RVector([ret, vol, (ret - Float64(risk_free) / 100) / vq, _cvar_hist(rp, alpha), _cdar_hist(rp, alpha),
                     _ldsum(w .* sqrt.(_diag(S))) / vq, 1 / _ldsum(w .* w), 1 / _ldsum(rs .* rs)];
                    names = ["expected_return", "volatility", "sharpe", "cvar", "cdar", "diversification_ratio",
                             "effective_n", "effective_n_risk"])
    risk = RFrame("asset" => copy(nm), "weight" => copy(w),
                  "volatility_contribution" => (isnan(vq) ? zeros(length(w)) : rc), "risk_share" => rc ./ vq)
    RList("weights" => RVector(copy(w); names = copy(nm)), "stats" => stats, "risk" => risk, "alpha" => alpha)
end

_strip_nl(s) = endswith(s, "\n") ? s[1:prevind(s, lastindex(s))] : s
_print_df(df; kw...) = _strip_nl(String(SimLev.RFmt.print_data_frame(df; kw...)))

"`print.SimLevOptimization`."
function print_SimLevOptimization(io::IO, x)
    rs = get(x, "resampled", nothing)
    print(io, _sprintf("SimLev-Optimierung: %s%s (%d Perioden, %s, Kovarianz %s)\n\n", x["method"],
                       rs === nothing ? "" : _sprintf(", Resampling %d", size(rs, 1)), x["n_obs"], x["frequency"],
                       x["cov_type"]))
    r = x["risk"]
    df = RFrame("Anlage" => collect(r["asset"]),
                "Gewicht" => String[_sprintf("%.1f %%", 100 * v) for v in r["weight"]],
                "Risikoanteil" => String[_sprintf("%.1f %%", 100 * v) for v in r["risk_share"]])
    print(io, _print_df(df; row_names = false), "\n")
    s = x["stats"]
    a = Float64(x["alpha"])
    print(io, _sprintf("\nErwartete Rendite %.2f %% p. a. (historisch), Volatilität %.2f %%, Sharpe %.3f\nCVaR(%g) %.2f %% je Periode, CDaR(%g) %.2f %% (kumuliert)\n",
                       100 * s["expected_return"], 100 * s["volatility"], s["sharpe"], a, 100 * s["cvar"], a, 100 * s["cdar"]))
    print(io, _sprintf("Diversifikationsverhältnis %.2f, effektive Anzahl: Gewichte %.1f, Risiko %.1f\n",
                       s["diversification_ratio"], s["effective_n"], s["effective_n_risk"]))
    nothing
end
print_SimLevOptimization(x) = print_SimLevOptimization(stdout, x)

# ═══════════════════════════════════════════════════════════════════════════
# efficient_frontier
# ═══════════════════════════════════════════════════════════════════════════

_dup_key(z::Float64) = isnan(z) ? (isna_strict(z) ? "NA" : "NaN") : (z == 0 ? 0.0 : z)

"""
    efficient_frontier(x; assets = nothing, n = 40, lower = 0, upper = 1, cov = "sample",
                       risk_free = 0, frequency = "week")

Effizienzgrenze: für `n` Risikoaversionen von 1e4 bis 0.02 (logarithmisch)
max μ'w − γ/2 w'Σw unter denselben Grenzen wie [`portfolio_optimize`](@ref).
Ergebnis `RList` der Klasse `SimLevFrontier` mit `frontier`, `assets`,
`risk_free`, `frequency`.
"""
function efficient_frontier(x; assets = nothing, n = 40, lower = 0, upper = 1, cov = nothing, risk_free = 0,
                            frequency = nothing)
    x = SimLev.as_rframe(x)
    cov = _match_arg(cov, _COVS)
    frequency = _match_arg(frequency, _FREQS)
    rr = _opt_returns(x, assets, frequency)
    A = rr.R
    nm = rr.cn
    lo, hi = _opt_check_bounds(lower, upper, nm)
    S = _opt_cov_m(A, cov) .* rr.ppy
    m = _colmeans(A) .* rr.ppy
    gs = SimLev.RLibm.exp(_asvec(SimLev.RStats.seq_len_out(SimLev.RLibm.log(1e4), SimLev.RLibm.log(0.02), Int(n))))
    gs = gs isa Real ? [gs] : gs
    K = length(nm)
    W = zeros(length(gs), K)
    for (i, g) in enumerate(gs)
        W[i, :] = _qp_simplex(g .* S, .-m, lo, hi)
    end
    ret = _mat_vec(W, m)
    vol = Float64[_sqrt(isnan(v) ? v : max(v, 0.0)) for v in _rowsums(_mp(W, S) .* W)]
    rret = _asvec(SimLev.RFmt.r_round(ret, 6))
    rvol = _asvec(SimLev.RFmt.r_round(vol, 6))
    seen = Set{Any}()
    keep = Bool[]
    for (a, b) in zip(rret, rvol)
        k = (_dup_key(a), _dup_key(b))
        push!(keep, !(k in seen))
        push!(seen, k)
    end
    rf = Float64(risk_free)
    sh = Float64[vol[i] > 1e-10 ? (ret[i] - rf / 100) / vol[i] : NA for i in eachindex(vol)]
    ix = findall(keep)
    cols = Pair{String,Any}["expected_return" => ret[ix], "volatility" => vol[ix], "sharpe" => sh[ix]]
    for (j, a) in enumerate(nm)
        push!(cols, a => W[ix, j])
    end
    fr = RFrame(cols...; rownames = string.(ix))
    res = RList(; class = "SimLevFrontier")
    res["frontier"] = fr
    res["assets"] = RFrame("asset" => copy(nm), "expected_return" => m, "volatility" => sqrt.(_diag(S)); rownames = nm)
    res["risk_free"] = risk_free
    res["frequency"] = frequency
    res
end

"`print.SimLevFrontier`: Minimum-Varianz und Max.-Sharpe-Punkt."
function print_SimLevFrontier(io::IO, x)
    f = x["frontier"]
    sh = _asvec(f["sharpe"])
    k = _which_max(sh)
    j = _which_min(_asvec(f["volatility"]))
    idx = _unique(k == 0 ? [j] : [j, k])
    labs = ["Minimum-Varianz", "Max. Sharpe"][1:length(idx)]
    cols = Pair{String,Any}[c => _asvec(SimLev.RFmt.r_round(_asvec(f[c])[idx], 4)) for c in names(f)]
    show = RFrame(cols...; rownames = labs)
    print(io, "Effizienzgrenze: $(SimLev.nrow(f)) Punkte\n", _print_df(show), "\n")
    nothing
end
print_SimLevFrontier(x) = print_SimLevFrontier(stdout, x)

# ═══════════════════════════════════════════════════════════════════════════
# rolling_optimization
# ═══════════════════════════════════════════════════════════════════════════

"""
    rolling_optimization(x, assets; method = "min_variance", window = 3, every = "month",
                         frequency = "week", kwargs...)

Rollierende Optimierung (Zielgewichte außerhalb der Stichprobe): an jedem
Entscheidungstermin (letzte Zeile je Monat/Quartal/Jahr, mindestens `window`
Jahre nach dem ersten Datum) wird auf dem Fenster (Termin − window·365.25 Tage,
Termin] mit [`portfolio_optimize`](@ref) optimiert (weitere Argumente über
`kwargs`); fehlgeschlagene Termine erhalten Gleichgewichtung (Warnung).
Ergebnis: `SimLevWeights` mit `attrs` `source`, `decision_rows`, `failed_dates`.
"""
function rolling_optimization(x, assets; method = "min_variance", window = 3, every = nothing, frequency = nothing,
                              kwargs...)
    x = SimLev.as_rframe(x)
    every = _match_arg(every, ["month", "quarter", "year"])
    frequency = _match_arg(frequency, _FREQS)
    if !(method isa AbstractString) || !(method in _METHODS)
        mv = method isa Union{AbstractVector,Tuple} ? collect(method) : [method]
        error("rolling_optimization: unbekanntes Verfahren $(_q(mv)); erlaubt: $(join(_METHODS, ", ")).")
    end
    dots = Dict{String,Any}(String(k) => v for (k, v) in kwargs)
    allowed = [a for a in _PO_FORMALS if !(a in ("x", "assets", "method", "frequency"))]
    bad = _unique([String(k) for (k, _) in kwargs if !(String(k) in allowed)])
    isempty(bad) || error("rolling_optimization: unbekannte bzw. unbenannte Argumente für portfolio_optimize() in ...: $(_q(bad)).")
    _has_date(x) || error("rolling_optimization: data.frame mit Spalte 'date' erwartet.")
    assets = assets isa AbstractString ? [String(assets)] : String[String(a) for a in assets]
    miss = _setdiff(assets, names(x))
    isempty(miss) || error("Spalten fehlen: " * join(miss, ", "))
    _opt_check_bounds(something(get(dots, "lower", nothing), 0), something(get(dots, "upper", nothing), 1), assets)
    _opt_check_alpha(something(get(dots, "alpha", nothing), 0.05), "rolling_optimization")
    get(dots, "mu", nothing) === nothing || _opt_bounds(dots["mu"], assets, NA, "mu")
    x = SimLev.Dependence._dep_sort_dates(x, "x")
    d = SimLev.DataPrep._to_date(x["date"], "date")
    n = length(d)
    N = length(assets)
    rows = SimLev.Tactical._period_last(d, every)
    wd = Float64(SimLev.RFmt.r_round(Float64(window) * 365.25))
    dv = Float64[Dates.value(v) for v in d]
    first_ok = dv[1] + wd
    rows = rows[dv[rows] .>= first_ok]
    isempty(rows) && error("Historie kürzer als das Fenster.")
    msg = fill("", length(rows))
    M = Matrix{Float64}(undef, length(rows), N)
    sub_cols = vcat("date", assets)
    for (k, i) in enumerate(rows)
        di = dv[i]
        sel = (dv .> di - wd) .& (dv .<= di)
        sub0 = SimLev.rows(x, sel)
        sub = RFrame(sub_cols, AbstractVector[sub0[c] for c in sub_cols])
        w = try
            _with_bounds_handler(_ -> false) do
                _asvec(portfolio_optimize(sub; assets = assets, method = method, frequency = frequency, kwargs...)["weights"])
            end
        catch e
            e isa InterruptException && rethrow()
            msg[k] = _errmsg(e)
            fill(NA, N)
        end
        if any(isnan, w)
            msg[k] == "" && (msg[k] = "Gewichte NA")
            w = fill(1 / N, N)
        end
        M[k, :] = w
    end
    failed = findall(!=(""), msg)
    if !isempty(failed)
        f0 = failed[1]
        _warn("rolling_optimization: Optimierung an $(length(failed)) von $(length(rows)) Terminen fehlgeschlagen " *
              "(erster am $(Dates.format(d[rows[f0]], "yyyy-mm-dd")): $(msg[f0])); dort Gleichgewichtung. Termine im Attribut 'failed_dates'.")
    end
    H = SimLev.Tactical._hold_rows_m(n, rows, M)
    H[1:(rows[1]-1), :] .= 1 / N
    out = SimLev.Tactical._as_weights_m(d, H, assets, "rolling " * method)
    SimLev.attrs(out)["decision_rows"] = rows
    SimLev.attrs(out)["failed_dates"] = d[rows[failed]]
    out
end

# ═══════════════════════════════════════════════════════════════════════════
# risk_contributions
# ═══════════════════════════════════════════════════════════════════════════

"""
    risk_contributions(x, weights; measure = "volatility", alpha = 0.05, frequency = "week",
                       cov = "sample")

Risikobeiträge (Euler-Zerlegung) von Volatilität oder historischem CVaR.
`weights`: benannter Gewichtsvektor oder `SimLevOptimization`. Ergebnis:
`RFrame` je Anlage (`asset`, `weight`, `contribution`, `share`, `marginal`) mit
`attrs` `total`, `measure`, `effective_n` und bei `"volatility"`
`diversification_ratio`.
"""
function risk_contributions(x, weights; measure = nothing, alpha = 0.05, frequency = nothing, cov = nothing)
    x = SimLev.as_rframe(x)
    measure = _match_arg(measure, ["volatility", "cvar"])
    frequency = _match_arg(frequency, _FREQS)
    cov = _match_arg(cov, _COVS)
    _opt_check_alpha(alpha, "risk_contributions")
    (weights isa RList && SimLev.inherits(weights, "SimLevOptimization")) && (weights = weights["weights"])
    wn, vals, isnum = _named_vec(weights)
    if !isnum || wn === nothing || any(==(""), wn) || any(_isna, vals)
        error("weights: benannter numerischer Vektor ohne NA erwartet (Namen = Spalten von x).")
    end
    avail = if _has_date(x)
        names(x)
    elseif x isa RFrame
        names(x)
    elseif x isa NamedMat && x.colnames !== nothing
        copy(x.colnames)
    else
        nc = x isa AbstractMatrix ? size(x, 2) : 1
        String["A$j" for j in 1:nc]
    end
    unk = _setdiff(wn, avail)
    isempty(unk) || error("weights: unbekannte Anlage(n) $(_q(unk)); vorhanden: $(join([a for a in avail if a != "date"], ", ")).")
    rr = _opt_returns(x, wn, frequency)
    A = rr.R
    cn = rr.cn
    w = Float64[Float64(vals[findfirst(==(c), wn)]) for c in cn]
    alpha = Float64(alpha)
    if measure == "volatility"
        S = _opt_cov_m(A, cov) .* rr.ppy
        tot = _sqrt(_quad(w, S))
        mc = _mat_vec(S, w) ./ tot
        rc = w .* mc
    else
        rp = _mat_vec(A, w)
        L = .-rp
        v = _quantile(L, 1 - alpha)
        tail = L .>= v
        mc = _colmeans(.-A[tail, :])
        rc = mc .* w
        tot = _ldsum(rc)
    end
    sh = rc ./ tot
    out = RFrame("asset" => copy(cn), "weight" => w, "contribution" => rc, "share" => sh, "marginal" => mc)
    at = SimLev.attrs(out)
    at["total"] = tot
    at["measure"] = measure
    at["effective_n"] = 1 / _ldsum(sh .* sh)
    if measure == "volatility"
        at["diversification_ratio"] = _ldsum(w .* sqrt.(_diag(_opt_cov_m(A, cov) .* rr.ppy))) / tot
    end
    out
end

# ═══════════════════════════════════════════════════════════════════════════
# cpcv_portfolio
# ═══════════════════════════════════════════════════════════════════════════

"Alle Kombinationen von `k` aus 1:n in lexikographischer Reihenfolge (`utils::combn`)."
function _combn(n::Int, k::Int)
    out = Vector{Vector{Int}}()
    c = collect(1:k)
    k > n && return out
    while true
        push!(out, copy(c))
        i = k
        while i >= 1 && c[i] == n - k + i
            i -= 1
        end
        i == 0 && break
        c[i] += 1
        for j in (i+1):k
            c[j] = c[j-1] + 1
        end
    end
    out
end

"Benannte Liste (RList, NamedTuple, Pair-Vektor, Dict) → Vektor von Paaren; sonst `nothing`."
function _as_pairs(x)
    x isa RList && return Pair{String,Any}[k => v for (k, v) in x]
    x isa NamedTuple && return Pair{String,Any}[String(k) => v for (k, v) in pairs(x)]
    x isa AbstractDict && return Pair{String,Any}[string(k) => v for (k, v) in x]
    x isa Pair && return Pair{String,Any}[string(x.first) => x.second]
    (x isa AbstractVector && !isempty(x) && all(p -> p isa Pair, x)) && return Pair{String,Any}[string(p.first) => p.second for p in x]
    nothing
end
_is_list(x) = x isa Union{RList,NamedTuple,AbstractDict} || (x isa AbstractVector && eltype(x) !== Char && !(eltype(x) <: Union{Real,AbstractString,Missing}))

"""
    cpcv_portfolio(x; assets = nothing, methods = ["equal", "inverse_vol", "min_variance",
                   "risk_parity", "max_sharpe"], n_groups = 6, test_groups = 2, purge = 2,
                   embargo = 2, frequency = "week")

Kombinatorische Kreuzvalidierung von Optimierungsverfahren (CPCV, Lopez de
Prado 2018). `methods`: Zeichenvektor von Verfahren oder benannte Liste
(`RList`, `NamedTuple`, `Pair`-Vektor) von Argumentlisten für
[`portfolio_optimize`](@ref). Ergebnis `RList` der Klasse `SimLevCPCV` mit
`splits`, `summary`, `n_splits`, `n_groups`, `test_groups`, `frequency`, `failed`.
"""
function cpcv_portfolio(x; assets = nothing, methods = ["equal", "inverse_vol", "min_variance", "risk_parity", "max_sharpe"],
                        n_groups = 6, test_groups = 2, purge = 2, embargo = 2, frequency = nothing)
    x = SimLev.as_rframe(x)
    frequency = _match_arg(frequency, _FREQS)
    rr = _opt_returns(x, assets, frequency)
    A = rr.R
    cn = rr.cn
    Tn = size(A, 1)
    for (v, nm, lo) in ((n_groups, "n_groups", 2), (test_groups, "test_groups", 1), (purge, "purge", 0), (embargo, "embargo", 0))
        _, vals, isnum = _named_vec(v)
        ok = isnum && length(vals) == 1 && !_isna(vals[1]) &&
             (f = Float64(vals[1]); isfinite(f) && f == Float64(SimLev.RFmt.r_round(f)) && f >= lo)
        ok || error("cpcv_portfolio: $nm muss eine ganze Zahl >= $lo sein (erhalten: $(join(_fmt_vals(vals, isnum), ", "))).")
    end
    ng = Int(n_groups); tg = Int(test_groups); purge = Int(purge); embargo = Int(embargo)
    tg >= ng && error("cpcv_portfolio: test_groups ($tg) muss kleiner als n_groups ($ng) sein, sonst bleibt keine Trainingsgruppe.")
    specs = if methods isa AbstractString
        Pair{String,Any}[String(methods) => RList("method" => String(methods))]
    elseif methods isa AbstractVector && !isempty(methods) && all(m -> m isa AbstractString, methods)
        Pair{String,Any}[String(m) => RList("method" => String(m)) for m in methods]
    else
        p = _as_pairs(methods)
        (p === nothing || isempty(p) || any(q -> q.first == "", p)) &&
            error("cpcv_portfolio: methods muss ein Zeichenvektor oder eine benannte Liste von Argumentlisten sein.")
        p
    end
    allowed_args = [a for a in _PO_FORMALS if !(a in ("x", "assets", "frequency"))]
    spec_pairs = Vector{Vector{Pair{String,Any}}}()
    for (nm, sp) in specs
        sp_p = (sp isa AbstractVector && isempty(sp)) || (sp isa NamedTuple && isempty(sp)) ? Pair{String,Any}[] : _as_pairs(sp)
        (sp_p === nothing || any(q -> q.first == "", sp_p)) &&
            error("cpcv_portfolio: Eintrag '$nm' von methods muss eine benannte Argumentliste sein.")
        mi = findfirst(q -> q.first == "method", sp_p)
        if mi !== nothing && sp_p[mi].second !== nothing && !(sp_p[mi].second in _METHODS)
            error("cpcv_portfolio: unbekanntes Verfahren '$(sp_p[mi].second)'; erlaubt: $(join(_METHODS, ", ")).")
        end
        bad = _unique([q.first for q in sp_p if !(q.first in allowed_args)])
        isempty(bad) || error("cpcv_portfolio: unbekannte Argumente für portfolio_optimize() in '$nm': $(_q(bad)).")
        push!(spec_pairs, sp_p)
    end
    grp = SimLev.RStats.cut(collect(1.0:Float64(Tn)), Float64(ng); labels = false)
    grp = Int[Int(g) for g in (grp isa RVector ? grp.values : grp)]
    combos = _combn(ng, tg)
    r_method = String[]; r_split = Int[]; r_ret = Float64[]; r_vol = Float64[]; r_sh = Float64[]; r_cdar = Float64[]
    f_method = String[]; f_split = Int[]; f_msg = String[]
    warned = String[]
    ppy = rr.ppy
    for (cidx, comb) in enumerate(combos)
        test = Bool[g in comb for g in grp]
        train = .!test
        function drop_rows(a, b)
            a = max(1, a); b = min(Tn, b)
            b >= a && (train[a:b] .= false)
        end
        tv = Int.(test)
        starts = findall(==(1), diff(vcat(0, tv)))
        ends = findall(==(-1), diff(vcat(tv, 0)))
        for s0 in starts
            drop_rows(s0 - purge, s0 - 1)
        end
        for e in ends
            drop_rows(e + 1, e + max(purge, embargo))
        end
        Rtr = _opt_returns_obj(A[train, :], cn, ppy)
        Rte = A[test, :]
        for (si, (nm, _)) in enumerate(specs)
            kw = Dict{Symbol,Any}(Symbol(q.first) => q.second for q in spec_pairs[si])
            handler = function (_)
                nm in warned && return false
                push!(warned, nm)
                true
            end
            w = try
                _with_bounds_handler(handler) do
                    portfolio_optimize(Rtr; frequency = frequency, kw...)["weights"]
                end
            catch e
                e isa InterruptException && rethrow()
                push!(f_method, nm); push!(f_split, cidx); push!(f_msg, _errmsg(e))
                nothing
            end
            w === nothing && continue
            wv = Float64[w[c] for c in cn]
            r = _mat_vec(Rte, wv)
            mr = SimLev.r_mean(r)
            sr = SimLev.r_sd(r)
            push!(r_method, nm); push!(r_split, cidx); push!(r_ret, mr * ppy); push!(r_vol, sr * sqrt(ppy))
            push!(r_sh, mr / sr * sqrt(ppy)); push!(r_cdar, _cdar_hist(r, 0.05))
        end
    end
    fl = isempty(f_method) ? nothing : RFrame("method" => f_method, "split" => f_split, "message" => f_msg)
    if isempty(r_method)
        error("cpcv_portfolio: keine Optimierung erfolgreich (z. B. '$(f_method[1])' in Aufteilung $(f_split[1]): $(f_msg[1])).")
    end
    if fl !== nothing
        _warn("cpcv_portfolio: $(length(f_method)) von $(length(combos) * length(specs)) Optimierungen fehlgeschlagen " *
              "(z. B. '$(f_method[1])' in Aufteilung $(f_split[1]): $(f_msg[1])); sie fehlen in der Auswertung, Einzelheiten in \$failed.")
    end
    sp = RFrame("method" => r_method, "split" => r_split, "return" => r_ret, "volatility" => r_vol, "sharpe" => r_sh,
                "cdar" => r_cdar)
    ms = sort(unique(r_method); alg = MergeSort, lt = SimLev.RStats.r_isless)   # split(): Stufen nach R's Kollation
    s_mean = Float64[]; s_sd = Float64[]; s_q10 = Float64[]; s_q50 = Float64[]; s_q90 = Float64[]
    s_vol = Float64[]; s_cdar = Float64[]
    for m in ms
        ix = findall(==(m), r_method)
        v = r_sh[ix]
        push!(s_mean, SimLev.r_mean(v)); push!(s_sd, SimLev.r_sd(v)); push!(s_q10, _quantile(v, 0.1))
        q50 = SimLev.RStats.median(v)
        push!(s_q50, Float64(q50 isa AbstractArray ? first(q50) : q50)); push!(s_q90, _quantile(v, 0.9))
        push!(s_vol, SimLev.r_mean(r_vol[ix])); push!(s_cdar, SimLev.r_mean(r_cdar[ix]))
    end
    best = String[]
    for s in sort(unique(r_split))
        ix = findall(==(s), r_split)
        push!(best, r_method[ix][_which_max(r_sh[ix])])
    end
    s_best = Float64[_mean_lgl(best .== m) for m in ms]
    o = _order_desc(s_mean)
    summ = RFrame("method" => ms[o], "mean" => s_mean[o], "sd" => s_sd[o], "q10" => s_q10[o], "q50" => s_q50[o],
                  "q90" => s_q90[o], "volatility" => s_vol[o], "cdar" => s_cdar[o], "best_share" => s_best[o])
    res = RList(; class = "SimLevCPCV")
    res["splits"] = sp
    res["summary"] = summ
    res["n_splits"] = length(combos)
    res["n_groups"] = n_groups
    res["test_groups"] = test_groups
    res["frequency"] = frequency
    res["failed"] = fl
    res
end

"`order(-x)` (stabil, -0 = 0, NA/NaN zuletzt)."
function _order_desc(x::Vector{Float64})
    idx = collect(eachindex(x))
    lt = function (i, j)
        a = -x[i]; b = -x[j]
        isnan(a) && return false
        isnan(b) && return true
        a < b
    end
    sort!(idx; alg = Base.Sort.MergeSort, lt = lt)
end

"`print.SimLevCPCV`."
function print_SimLevCPCV(io::IO, x)
    s = x["summary"]
    col(f, v) = String[_sprintf(f, Float64(z)) for z in v]
    df = RFrame("Verfahren" => collect(s["method"]), "Sharpe Mittel" => col("%.3f", s["mean"]),
                "Sharpe Sd" => col("%.3f", s["sd"]), "10 %" => col("%.3f", s["q10"]), "90 %" => col("%.3f", s["q90"]),
                "Vola" => col("%.2f %%", 100 .* s["volatility"]), "CDaR" => col("%.2f %%", 100 .* s["cdar"]),
                "bestes Verfahren" => col("%.0f %%", 100 .* s["best_share"]))
    print(io, _sprintf("CPCV: %d Gruppen, je %d Testgruppen, %d Aufteilungen (%s)\n\n", x["n_groups"], x["test_groups"],
                       x["n_splits"], x["frequency"]), _print_df(df; row_names = false), "\n")
    nothing
end
print_SimLevCPCV(x) = print_SimLevCPCV(stdout, x)

# ═══════════════════════════════════════════════════════════════════════════
# Grafiken (SVG)
# ═══════════════════════════════════════════════════════════════════════════

# Bausteine `_alloc_*` (Stil Allokationsgrafiken) in svg.jl.

"""
    plot_SimLevOptimization(x; file = nothing, width = 700, height = 420)

`plot.SimLevOptimization`: Gewichte und Risikoanteile je Anlage als gruppierte
Balken (SVG). Liefert `(svg, data)`; `data["weights"]`: `asset`, `weight`,
`risk_share` (Anteile). Über `r_plot` entsteht daraus ein `SimLevPlot`.
"""
function plot_SimLevOptimization(x; file = nothing, width = 700, height = 420)
    r = x["risk"]
    a = collect(r["asset"]); w = 100 .* _asvec(r["weight"]); s = 100 .* _asvec(r["risk_share"])
    vals = filter(isfinite, vcat(w, s, 0.0))
    ymax = maximum(vals) * 1.08
    ymin = min(0.0, minimum(vals))
    L, R, T, B = 60.0, 20.0, 40.0, 50.0
    pw = width - L - R; ph = height - T - B
    py(v) = T + ph * (1 - (v - ymin) / (ymax - ymin))
    io = IOBuffer()
    println(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\" font-family=\"sans-serif\">")
    println(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>")
    println(io, "<text x=\"$(width/2)\" y=\"22\" text-anchor=\"middle\" font-size=\"15\" font-weight=\"bold\">$(_esc("Gewichte und Risikoanteile ($(x["method"]))"))</text>")
    for t in _alloc_ticks(ymin, ymax)
        println(io, "<line x1=\"$L\" x2=\"$(L+pw)\" y1=\"$(_alloc_c(py(t)))\" y2=\"$(_alloc_c(py(t)))\" stroke=\"#e5e5e5\"/>")
        println(io, "<text x=\"$(L-6)\" y=\"$(_alloc_c(py(t)+4))\" text-anchor=\"end\" font-size=\"11\">$(_alloc_c(t))</text>")
    end
    println(io, "<text x=\"16\" y=\"$(T+ph/2)\" font-size=\"12\" transform=\"rotate(-90 16 $(T+ph/2))\" text-anchor=\"middle\">%</text>")
    K = length(a)
    gw = pw / max(K, 1)
    for k in 1:K
        x0 = L + (k - 1) * gw + gw * 0.15
        bw = gw * 0.35
        for (j, (v, col)) in enumerate(((w[k], "#2C6E9B"), (s[k], "#B5562B")))
            isfinite(v) || continue
            y1 = py(max(v, 0.0)); y0 = py(min(v, 0.0))
            println(io, "<rect x=\"$(_alloc_c(x0 + (j-1)*bw))\" y=\"$(_alloc_c(y1))\" width=\"$(_alloc_c(bw))\" height=\"$(_alloc_c(y0-y1))\" fill=\"$col\"/>")
        end
        println(io, "<text x=\"$(_alloc_c(L + (k-0.5)*gw))\" y=\"$(T+ph+18)\" text-anchor=\"middle\" font-size=\"11\">$(_esc(a[k]))</text>")
    end
    for (j, (lab, col)) in enumerate((("Gewicht", "#2C6E9B"), ("Risikoanteil", "#B5562B")))
        yy = T + 6 + (j - 1) * 16
        println(io, "<rect x=\"$(L+pw-110)\" y=\"$(yy)\" width=\"10\" height=\"10\" fill=\"$col\"/>")
        println(io, "<text x=\"$(L+pw-95)\" y=\"$(yy+9)\" font-size=\"11\">$lab</text>")
    end
    println(io, "</svg>")
    svg = String(take!(io))
    file === nothing || write(String(file), svg)
    # dargestellte Werte (Anteile wie im Ergebnis, nicht ×100)
    data = SimLev.RList("weights" => SimLev.RFrame("asset" => String[string(v) for v in a],
                                                   "weight" => _asvec(r["weight"]), "risk_share" => _asvec(r["risk_share"])))
    return (svg, data)
end

"""
    plot_SimLevFrontier(x; file = nothing, width = 700, height = 480)

`plot.SimLevFrontier`: Effizienzgrenze (Linie) mit Einzelanlagen und dem
Punkt mit der höchsten Sharpe Ratio (SVG). Liefert `(svg, data)` mit
`frontier`, `assets` (`asset`, `volatility`, `expected_return`, Anteile p. a.)
und `max_sharpe`; über `r_plot` entsteht daraus ein `SimLevPlot`.
"""
function plot_SimLevFrontier(x; file = nothing, width = 700, height = 480)
    f = x["frontier"]; a = x["assets"]
    fv = 100 .* _asvec(f["volatility"]); fr = 100 .* _asvec(f["expected_return"])
    av = 100 .* _asvec(a["volatility"]); ar = 100 .* _asvec(a["expected_return"])
    xmax = 1.18 * maximum(filter(isfinite, vcat(fv, av, 1e-9)))
    ys = filter(isfinite, vcat(fr, ar))
    ymin = minimum(ys) - 0.3; ymax = maximum(ys) + 0.3
    L, R, T, B = 60.0, 20.0, 40.0, 50.0
    pw = width - L - R; ph = height - T - B
    px(v) = L + pw * v / xmax
    py(v) = T + ph * (1 - (v - ymin) / (ymax - ymin))
    io = IOBuffer()
    println(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\" font-family=\"sans-serif\">")
    println(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>")
    println(io, "<text x=\"$(width/2)\" y=\"22\" text-anchor=\"middle\" font-size=\"15\" font-weight=\"bold\">Effizienzgrenze</text>")
    for t in _alloc_ticks(0.0, xmax)
        println(io, "<line x1=\"$(_alloc_c(px(t)))\" x2=\"$(_alloc_c(px(t)))\" y1=\"$T\" y2=\"$(T+ph)\" stroke=\"#e5e5e5\"/>")
        println(io, "<text x=\"$(_alloc_c(px(t)))\" y=\"$(T+ph+16)\" text-anchor=\"middle\" font-size=\"11\">$(_alloc_c(t))</text>")
    end
    for t in _alloc_ticks(ymin, ymax)
        println(io, "<line x1=\"$L\" x2=\"$(L+pw)\" y1=\"$(_alloc_c(py(t)))\" y2=\"$(_alloc_c(py(t)))\" stroke=\"#e5e5e5\"/>")
        println(io, "<text x=\"$(L-6)\" y=\"$(_alloc_c(py(t)+4))\" text-anchor=\"end\" font-size=\"11\">$(_alloc_c(t))</text>")
    end
    println(io, "<text x=\"$(L+pw/2)\" y=\"$(height-10)\" text-anchor=\"middle\" font-size=\"12\">Volatilität (% p. a.)</text>")
    println(io, "<text x=\"16\" y=\"$(T+ph/2)\" font-size=\"12\" transform=\"rotate(-90 16 $(T+ph/2))\" text-anchor=\"middle\">Rendite (% p. a., historisch)</text>")
    pts = join(("$(_alloc_c(px(v))),$(_alloc_c(py(r)))" for (v, r) in zip(fv, fr) if isfinite(v) && isfinite(r)), " ")
    println(io, "<polyline points=\"$pts\" fill=\"none\" stroke=\"#2C6E9B\" stroke-width=\"2\"/>")
    for (k, nm) in enumerate(a["asset"])
        println(io, "<circle cx=\"$(_alloc_c(px(av[k])))\" cy=\"$(_alloc_c(py(ar[k])))\" r=\"4\" fill=\"#B5562B\"/>")
        println(io, "<text x=\"$(_alloc_c(px(av[k])))\" y=\"$(_alloc_c(py(ar[k]) - 8))\" text-anchor=\"middle\" font-size=\"10\">$(_esc(nm))</text>")
    end
    k = _which_max(_asvec(f["sharpe"]))
    if k > 0
        cx = px(fv[k]); cy = py(fr[k])
        println(io, "<polygon points=\"$(_alloc_c(cx)),$(_alloc_c(cy-6)) $(_alloc_c(cx-5)),$(_alloc_c(cy+4)) $(_alloc_c(cx+5)),$(_alloc_c(cy+4))\" fill=\"#3E8E5A\"/>")
    end
    println(io, "</svg>")
    svg = String(take!(io))
    file === nothing || write(String(file), svg)
    # dargestellte Werte (Anteile wie im Ergebnis, nicht ×100); max_sharpe: Punkt mit der höchsten Sharpe Ratio
    fvol = _asvec(f["volatility"]); fret = _asvec(f["expected_return"])
    data = SimLev.RList("frontier" => SimLev.RFrame("volatility" => fvol, "expected_return" => fret),
                        "assets" => SimLev.RFrame("asset" => String[string(v) for v in a["asset"]],
                                                  "volatility" => _asvec(a["volatility"]),
                                                  "expected_return" => _asvec(a["expected_return"])),
                        "max_sharpe" => SimLev.RFrame("volatility" => k > 0 ? [fvol[k]] : Float64[],
                                                      "expected_return" => k > 0 ? [fret[k]] : Float64[]))
    return (svg, data)
end

function __init__()
    SimLev.register_print!("SimLevOptimization", print_SimLevOptimization)
    SimLev.register_print!("SimLevFrontier", print_SimLevFrontier)
    SimLev.register_print!("SimLevCPCV", print_SimLevCPCV)
    SimLev.register_plot!("SimLevOptimization", SimLev._plot_method(plot_SimLevOptimization, "SimLevOptimization"))
    SimLev.register_plot!("SimLevFrontier", SimLev._plot_method(plot_SimLevFrontier, "SimLevFrontier"))
end

end # module
