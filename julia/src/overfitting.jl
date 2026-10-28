# Overfitting – r/R/overfitting.R (Vorlage python/simlev/overfitting.py)
#
#  overfit_pbo()                    Probability of Backtest Overfitting (CSCV)
#  sharpe_probabilistic()   Probabilistic Sharpe Ratio
#  sharpe_deflated()        Deflated Sharpe Ratio inkl. effektiver Versuchsanzahl
#  overfit_walk_forward()           rollierende Auswahl In-Sample, Bewertung Out-of-Sample
#  param_bootstrap()        beste Punkte einer Suche auf Bootstrap-Pfaden
#  sharpe_haircut()         Sharpe-Ratio-Abschlag für Mehrfachtests
#
# Daneben die kleinen R-Hilfen (colSums, order, rank, median, match.arg,
# modifyList, SVG-Grafik …), die ParamSearch und Sensitivity mitbenutzen.
module Overfitting

import ..SimLev
using ..SimLev: _res_abline!, _res_fig, _res_finish, _res_hline!, _res_legend!, _res_line!, _res_panel, _res_points!,
                _res_range, _res_rect!, _res_vline!
using Dates
using Logging

const SL = SimLev
const NA = SimLev.NA

export overfit_pbo, sharpe_probabilistic, sharpe_deflated, overfit_walk_forward, param_bootstrap, sharpe_haircut

# ═════════════════════════════════════════════════════════════════════════════
# Kleine R-Hilfen (auch von ParamSearch / Sensitivity benutzt)
# ═════════════════════════════════════════════════════════════════════════════

_f64(v) = v === missing || v === nothing ? NA : Float64(v)
_isna(v) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))

"R's `match.arg(arg)` mit der Fehlermeldung von R."
function _match_arg(value, choices)
    ch = String[String(c) for c in choices]
    value === nothing && return ch[1]
    if value isa Union{AbstractVector,Tuple}
        String[String(string(v)) for v in value] == ch && return ch[1]
        length(value) == 1 || error("'arg' must be of length 1")
        value = first(value)
    end
    v = String(string(value))
    v in ch && return v
    hits = isempty(v) ? String[] : [c for c in ch if startswith(c, v)]
    length(hits) == 1 && return hits[1]
    error("'arg' should be one of " * join(("“" * c * "”" for c in ch), ", "))
end

"`sprintf` (R) für Skalare → String."
function _spf(f::AbstractString, args...)
    s = SL.RFmt.sprintf(f, args...)
    return s isa AbstractString ? String(s) : String(first(s))
end
"`sprintf` (R) vektoriell → Vector{String}."
function _spfv(f::AbstractString, v)
    s = SL.RFmt.sprintf(f, v)
    return s isa AbstractString ? [String(s)] : String[String(x) for x in s]
end
"`format(x)` (R) → Vector{String}."
function _formatv(x; kw...)
    s = SL.RFmt.format(x; kw...)
    return s isa AbstractString ? [String(s)] : String[String(t) for t in s]
end
"`as.character(x)` (R) eines Skalars."
function _as_chr(x)
    x isa AbstractString && return String(x)
    s = SL.RFmt.as_character(x)
    return s isa AbstractString ? String(s) : String(first(s))
end

"`print(df, row.names = FALSE)` als Text."
function _print_df(df; row_names = false)
    s = SL.RFmt.print_data_frame(df; row_names = row_names)
    s isa AbstractString && return String(s)
    return sprint(io -> SL.RFmt.print_data_frame(io, df; row_names = row_names))
end

_colsum1(M, j) = (s = SL.F80(0.0); @inbounds for i in axes(M, 1); s = s + SL.F80(M[i, j]); end; s)
"`colSums` (long double, sequenziell)."
_colsums(M::AbstractMatrix) = Float64[Float64(_colsum1(M, j)) for j in axes(M, 2)]
"`colMeans`: long-double-Summe / n."
function _colmeans(M::AbstractMatrix)
    n = size(M, 1)
    n == 0 && return fill(NaN, size(M, 2))
    return Float64[Float64(_colsum1(M, j) / SL.F80(n)) for j in axes(M, 2)]
end
"`rowSums` (long double je Zeile)."
function _rowsums(M::AbstractMatrix)
    out = Vector{Float64}(undef, size(M, 1))
    for i in axes(M, 1)
        s = SL.F80(0.0)
        for j in axes(M, 2); s = s + SL.F80(M[i, j]); end
        out[i] = Float64(s)
    end
    out
end
"`rowMeans` (long double je Zeile / p)."
function _rowmeans(M::AbstractMatrix)
    p = size(M, 2)
    out = Vector{Float64}(undef, size(M, 1))
    for i in axes(M, 1)
        s = SL.F80(0.0)
        for j in axes(M, 2); s = s + SL.F80(M[i, j]); end
        out[i] = Float64(s / SL.F80(p))
    end
    out
end
"`cumprod` (long double)."
function _cumprod(x)
    out = Vector{Float64}(undef, length(x))
    s = SL.F80(1.0)
    for (i, v) in enumerate(x)
        s = s * SL.F80(Float64(v))
        out[i] = Float64(s)
    end
    out
end
"`rowsum(M, g, reorder = FALSE)`: double-Akkumulation in Zeilenreihenfolge."
function _rowsum(M::AbstractMatrix, codes::Vector{Int}, ng::Int)
    out = zeros(ng, size(M, 2))
    for i in axes(M, 1), j in axes(M, 2)
        out[codes[i], j] += M[i, j]
    end
    out
end

"`which.max` (erster Index des Maximums ohne NA; `nothing`, wenn leer)."
function _which_max(v)
    best = nothing
    for i in eachindex(v)
        x = Float64(v[i])
        isnan(x) && continue
        (best === nothing || x > Float64(v[best])) && (best = i)
    end
    best
end
"`max.col(M, ties.method = \"first\")` (0 = NA)."
function _max_col_first(M::AbstractMatrix)
    out = zeros(Int, size(M, 1))
    for r in axes(M, 1)
        any(isnan, view(M, r, :)) && continue
        m = 1; a = M[r, 1]
        for c in 2:size(M, 2)
            b = M[r, c]
            a < b && (a = b; m = c)
        end
        out[r] = m
    end
    out
end

_okey(x::Real) = (f = Float64(x); f == 0 ? 0.0 : f)
_okey(x) = x
_isna_key(x) = x === missing || x === nothing || (x isa Real && isnan(Float64(x)))
"`order(v, decreasing, na.last)` (stabil wie R's Radix-Sortierung); `na_last = nothing` entfernt NA."
function _order(v::AbstractVector; decreasing::Bool = false, na_last = true)
    idx = collect(eachindex(v))
    na = [i for i in idx if _isna_key(v[i])]
    ok = [i for i in idx if !_isna_key(v[i])]
    keys_ = [_okey(v[i]) for i in ok]
    p = sortperm(keys_; alg = Base.Sort.DEFAULT_STABLE, rev = decreasing)
    o = ok[p]
    na_last === nothing && return o
    return na_last ? vcat(o, na) : vcat(na, o)
end
"`rank(x)` mit `ties.method = \"average\"` (NA zuletzt; `RStats.r_rank`, -0 und 0 gleichrangig)."
function _rank_avg(x)
    v = Float64[_f64(e) for e in x]
    r = SL.RStats.r_rank(v)
    Float64[Float64(t) for t in (r isa SL.RVector ? r.values : r isa AbstractVector ? r : [r])]
end
"`stats::median(x)` (`RStats.median`: R's Teilsortierung, Mittel der beiden mittleren Werte in long double)."
_median(x; na_rm::Bool = false) = Float64(SL.RStats.median(Float64[_f64(e) for e in x]; na_rm = na_rm))
"`mean()` eines logischen Vektors (NA, falls ein Element NA ist)."
function _mean_lgl(v::AbstractVector)
    isempty(v) && return NaN
    any(ismissing, v) && return NA
    return SL.r_mean_int(Int[x ? 1 : 0 for x in v])
end
_lgl(f, a::Float64, b::Float64) = (isnan(a) || isnan(b)) ? missing : f(a, b)
_pmax(a::Float64, b::Float64) = isnan(a) ? a : (b > a ? b : a)
_pmin(a::Float64, b::Float64) = isnan(a) ? a : (b < a ? b : a)
_sign(v::Float64) = isnan(v) ? v : v > 0 ? 1.0 : v < 0 ? -1.0 : 0.0

"Schlüssel/Werte einer benannten Liste (RList, Dict, NamedTuple, Pair-Vektor, RVector)."
_kv(x::Nothing) = Pair{String,Any}[]
_kv(x::SL.RList) = Pair{String,Any}[k => v for (k, v) in x]
_kv(x::AbstractDict) = Pair{String,Any}[String(string(k)) => v for (k, v) in x]
_kv(x::NamedTuple) = Pair{String,Any}[String(k) => v for (k, v) in pairs(x)]
_kv(x::SL.RVector) = x.names === nothing ? Pair{String,Any}[] : Pair{String,Any}[k => v for (k, v) in zip(x.names, x.values)]
_kv(x::AbstractVector{<:Pair}) = Pair{String,Any}[String(string(p.first)) => p.second for p in x]
_kv(x::Tuple) = Pair{String,Any}[String(string(p.first)) => p.second for p in x]
_kv(x::SL.RFrame) = Pair{String,Any}[k => c for (k, c) in pairs(x)]
_kv(x) = Pair{String,Any}[]
_as_rlist(x::SL.RList) = x
_as_rlist(x) = SL.RList(_kv(x)...)
_islistlike(x) = x isa SL.RList || x isa AbstractDict || x isa NamedTuple || x isa AbstractVector{<:Pair}

"Element einer Liste (`x\$k`, `NULL` → `nothing`)."
function _lget(x, k::AbstractString)
    x === nothing && return nothing
    x isa SL.RList && return get(x, k, nothing)
    x isa SL.RFrame && return haskey(x, k) ? x[k] : nothing
    x isa NamedTuple && return get(x, Symbol(k), nothing)
    x isa SL.Strategy && return nothing
    if x isa AbstractDict
        haskey(x, k) && return x[k]
        haskey(x, Symbol(k)) && return x[Symbol(k)]
        return nothing
    end
    x isa AbstractVector{<:Pair} && (for p in x; String(string(p.first)) == k && return p.second; end; return nothing)
    return nothing
end

"`utils::modifyList(x, val)` (rekursiv für Listen, `nothing` entfernt)."
function _modify_list(x, val)
    out = copy(_as_rlist(x))
    for (k, v) in _kv(val)
        isempty(k) && continue
        old = get(out, k, nothing)
        if old !== nothing && _islistlike(old) && _islistlike(v) && !(old isa SL.RFrame) && !(v isa SL.RFrame)
            out[k] = _modify_list(old, v)
        elseif v === nothing
            delete!(out, k)
        else
            out[k] = v
        end
    end
    out
end

"`conditionMessage(e)`."
_cond_msg(e) = e isa ErrorException ? e.msg : e isa KeyError ? string(e.key) :
               hasproperty(e, :msg) ? string(getproperty(e, :msg)) : sprint(showerror, e)

"`suppressWarnings(suppressMessages(f()))`."
function _quiet(f)
    with_logger(NullLogger()) do
        SL.RParallel.suppress_messages(f)
    end
end

"Benannter Vektor einer Kennzahlfunktion → (Namen, Werte)."
function _metric_pairs(m)
    if m isa SL.RVector
        nm = m.names === nothing ? String[] : m.names
        return nm, Float64[_f64(v) for v in m.values]
    elseif m isa Union{SL.RList,AbstractDict,NamedTuple,AbstractVector{<:Pair}}
        kv = _kv(m)
        return String[p.first for p in kv], Float64[_f64(p.second) for p in kv]
    end
    error("metrics() muss einen benannten numerischen Vektor liefern")
end

"Datumswerte über `SimLev.DataPrep._to_date` → Vector{Date}."
function _dates(x, what)
    d = SL.DataPrep._to_date(x, what)
    d isa Date && return [d]
    return collect(d)
end
_days(d::Date) = Dates.value(d - Date(1970, 1, 1))

# ── SVG-Grafik: Bausteine `_res_*` (Stil Ergebnisgrafiken) in svg.jl ──────────

# ═════════════════════════════════════════════════════════════════════════════
# Renditematrix
# ═════════════════════════════════════════════════════════════════════════════

_is_ps(x) = x isa SL.RList && SL.inherits(x, "SimLevParamSearch")

const _ERR_MAT = "x muss ein SimLevParamSearch oder eine numerische Renditematrix sein."

_numeltype(T) = (S = Base.nonmissingtype(T); S <: Real)
_isnumvec(v::AbstractVector) = _numeltype(eltype(v)) && !(Base.nonmissingtype(eltype(v)) <: Bool) ||
                               (eltype(v) === Any && !isempty(v) && all(e -> e === missing || (e isa Real && !(e isa Bool)), v))
_tofloat(v) = Float64[_f64(e) for e in v]

"`as.matrix(x)` einer numerischen Eingabe → (Matrix, Spaltennamen oder nothing, Zeilennamen oder nothing)."
function _as_return_matrix(x)
    if x isa SL.RFrame
        cols = x.cols
        isempty(cols) && return zeros(SL.nrow(x), 0), String[], x.rownames
        all(c -> _numeltype(eltype(c)) || _isnumvec(c), cols) || error(_ERR_MAT)
        any(c -> _isnumvec(c), cols) || error(_ERR_MAT)       # nur logische Spalten: logische Matrix
        M = Matrix{Float64}(undef, SL.nrow(x), length(cols))
        for (j, c) in enumerate(cols); M[:, j] = _tofloat(c); end
        return M, names(x), x.rownames
    elseif x isa SL.NamedMat
        _numeltype(eltype(x.data)) && !(Base.nonmissingtype(eltype(x.data)) <: Bool) || error(_ERR_MAT)
        return Float64[_f64(v) for v in x.data], x.colnames, x.rownames
    elseif x isa AbstractMatrix
        _numeltype(eltype(x)) && !(Base.nonmissingtype(eltype(x)) <: Bool) || error(_ERR_MAT)
        return Float64[_f64(v) for v in x], nothing, nothing
    elseif x isa AbstractVector
        _isnumvec(x) || error(_ERR_MAT)
        rn = x isa SL.RVector ? x.names : nothing
        return reshape(_tofloat(x), :, 1), nothing, rn
    elseif x isa Real && !(x isa Bool)
        return fill(Float64(x), 1, 1), nothing, nothing
    end
    error(_ERR_MAT)
end

"Interne Renditequelle wie die Liste `rr` in R."
mutable struct _RR
    R::Matrix{Float64}
    cn::Vector{String}
    rn::Union{Nothing,Vector{String}}
    dates::Union{Nothing,Vector{Date}}
    ppy::Float64
    cols::Vector{Int}
end

_isokey(d::Date) = (th = d + Day(4 - Dates.dayofweek(d)); lpad(string(Dates.year(th)), 4, '0') * "-" * lpad(string(Dates.week(d)), 2, '0'))
_ymkey(d::Date) = lpad(string(Dates.year(d)), 4, '0') * "-" * lpad(string(Dates.month(d)), 2, '0')

function _rr(x, frequency, dates = nothing, risk_free = 0)
    if _is_ps(x)
        ret = get(x, "returns", nothing)
        ret === nothing && error("Suche ohne gespeicherte Renditen (keep_returns = FALSE).")
        R, cn, rn = _as_return_matrix(ret)
        dates = get(x, "dates", nothing)
    else
        R, cn, rn = _as_return_matrix(x)
    end
    cn === nothing && (cn = ["p$j" for j in 1:size(R, 2)])
    cn = collect(String, cn)
    keep = [any(isfinite, view(R, :, j)) for j in 1:size(R, 2)]
    R = R[:, keep]
    cols = findall(keep)
    cn = cn[keep]
    dts = dates === nothing ? nothing : _dates(dates, "dates")
    if dts !== nothing && frequency != "day"
        key = frequency == "week" ? _isokey.(dts) : _ymkey.(dts)
        length(key) == size(R, 1) || error("incorrect length for 'group'")
        lev = unique(key)
        pos = Dict(k => i for (i, k) in enumerate(lev))
        codes = Int[pos[k] for k in key]
        S = _rowsum(SL.RLibm.log1p.(R), codes, length(lev))
        R = SL.RLibm.exp.(S) .- 1.0
        rn = lev
        last = vcat([key[i] != key[i+1] for i in 1:length(key)-1], true)
        dts = dts[last]
    end
    ok = [!any(isnan, view(R, i, :)) for i in 1:size(R, 1)]
    R = R[ok, :]
    rn === nothing || (rn = collect(String, rn)[ok])
    dts === nothing || (dts = dts[ok])
    ppy = if dts !== nothing && length(dts) > 1
        (length(dts) - 1) / (Float64(_days(dts[end]) - _days(dts[1])) / 365.25)
    else
        Dict("day" => 252.0, "week" => 52.0, "month" => 12.0)[frequency]
    end
    R = R .- Float64(risk_free) / 100 / ppy
    return _RR(R, cn, rn, dts, ppy, cols)
end

"""
    _of_returns(x, frequency, dates = nothing, risk_free = 0)

Renditematrix und Datum aus Suche oder Matrix holen, ggf. aggregieren
(`.of_returns`). Liefert `RList(R, dates, ppy, cols)`; `R` als `NamedMat`.
"""
function _of_returns(x, frequency, dates = nothing, risk_free = 0)
    x = SimLev.as_rframe(x)
    rr = _rr(x, frequency, dates, risk_free)
    return SL.RList("R" => SL.NamedMat(rr.R; rownames = rr.rn, colnames = rr.cn), "dates" => rr.dates,
                    "ppy" => rr.ppy, "cols" => SL.RVector(rr.cols; names = rr.cn))
end

"Kennzahl aus Summen-Statistiken (elementweise, auch Matrizen; `.of_metric`)."
function _of_metric(n, s1, s2, sdn, sl, metric; c1 = s1)
    m = s1 ./ n
    metric == "sharpe" && return m ./ sqrt.(_pmax.((s2 .- c1 .* c1 ./ n) ./ (n - 1), 1e-300))
    metric == "sortino" && return m ./ sqrt.(_pmax.(sdn ./ n, 1e-300))
    metric == "geometric" && return SL.RLibm.expm1.(sl ./ n)
    metric == "mean" && return m
    error("metric: 'sharpe', 'sortino', 'geometric' oder 'mean'.")
end
_of_metric(n, s1::Real, s2::Real, sdn::Real, sl::Real, metric; c1 = s1) =
    _of_metric(n, Float64[s1], Float64[s2], Float64[sdn], Float64[sl], metric; c1 = Float64[c1])[1]

"Kennzahl je Spalte einer Renditematrix (`.of_col_metric`)."
function _of_col_metric(R::AbstractMatrix{Float64}, metric)
    n = size(R, 1)
    s1 = _colsums(R)
    metric == "mean" && return s1 ./ n
    if metric == "sharpe"
        cm = _colmeans(R)
        Rc = R .- cm'
        return _of_metric(n, s1, _colsums(Rc .* Rc), nothing, nothing, metric; c1 = _colsums(Rc))
    elseif metric == "sortino"
        P = _pmin.(R, 0.0)
        return _of_metric(n, s1, nothing, _colsums(P .* P), nothing, metric)
    elseif metric == "geometric"
        return _of_metric(n, s1, nothing, nothing, _colsums(SL.RLibm.log1p.(R)), metric)
    end
    error("metric: 'sharpe', 'sortino', 'geometric' oder 'mean'.")
end
function _of_col_metric(R::SL.NamedMat, metric)
    v = _of_col_metric(Float64[_f64(e) for e in R.data], metric)
    R.colnames === nothing ? v : SL.RVector(v; names = R.colnames)
end
_of_col_metric(R::AbstractMatrix, metric) = _of_col_metric(Float64[_f64(e) for e in R], metric)
_of_col_metric(R::AbstractVector, metric) = _of_col_metric(reshape(_tofloat(R), :, 1), metric)

"Spalten ohne Schwankung (Sharpe Ratio nicht definiert) ausschließen."
function _of_drop_flat(rr::_RR, what)
    sdv = Float64[SL.r_sd(view(rr.R, :, j)) for j in 1:size(rr.R, 2)]
    flat = findall(s -> !(s > 1e-10), sdv)
    isempty(flat) && return rr
    length(flat) == size(rr.R, 2) &&
        error("$what: alle Spalten ohne Schwankung (Standardabweichung <= 1e-10); Sharpe Ratio nicht definiert.")
    @warn "$what: $(length(flat)) Spalte(n) ohne Schwankung (Standardabweichung <= 1e-10 je Periode, z. B. Geldmarkt mit festem Zins; Punkt(e) $(join(rr.cols[flat], ", "))) ausgeschlossen - Sharpe Ratio dort nicht definiert."
    keep = setdiff(1:size(rr.R, 2), flat)
    rr.R = rr.R[:, keep]; rr.cn = rr.cn[keep]; rr.cols = rr.cols[keep]
    rr
end

# ═════════════════════════════════════════════════════════════════════════════
# PBO
# ═════════════════════════════════════════════════════════════════════════════

"`combn(S, k)` in lexikographischer Reihenfolge (eine Kombination je Element)."
function _combn(S::Int, k::Int)
    out = Vector{Vector{Int}}()
    c = collect(1:k)
    while true
        push!(out, copy(c))
        i = k
        while i >= 1 && c[i] == S - k + i; i -= 1; end
        i == 0 && break
        c[i] += 1
        for j in i+1:k; c[j] = c[j-1] + 1; end
    end
    out
end

"Koeffizienten (Achsenabschnitt, Steigung) von `lm(y ~ x)` (na.omit)."
function _lm_coef(x::Vector{Float64}, y::Vector{Float64})
    ok = [!(isnan(a) || isnan(b)) for (a, b) in zip(x, y)]
    X = hcat(ones(count(ok)), x[ok])
    fit = SL.RStats.lm_fit(X, y[ok])
    cf = fit isa AbstractVector ? fit : (fit isa SL.RList || fit isa AbstractDict) ? fit["coefficients"] :
         hasproperty(fit, :coefficients) ? getproperty(fit, :coefficients) : fit[:coefficients]
    cf = cf isa SL.RVector ? cf.values : collect(cf)
    return _f64(cf[1]), _f64(cf[2])
end

"""
    overfit_pbo(x; S = 16, metric = "sharpe", frequency = "week", dates = nothing, risk_free = 0)

Probability of Backtest Overfitting mit Combinatorially Symmetric
Cross-Validation (Bailey, Borwein, López de Prado & Zhu 2017). `x` ist eine
`SimLevParamSearch` mit Renditen oder eine numerische Renditematrix (Zeilen =
Perioden, Spalten = Punkte). Ergebnis: `RList` der Klasse `SimLevPBO`.
"""
function overfit_pbo(x; S = 16, metric = nothing, frequency = nothing, dates = nothing, risk_free = 0)
    x = SimLev.as_rframe(x)
    metric = _match_arg(metric, ("sharpe", "sortino", "geometric", "mean"))
    frequency = _match_arg(frequency, ("week", "day", "month"))
    S = trunc(Int, S)
    (S < 2 || isodd(S)) && error("S muss gerade und >= 2 sein.")
    rr = _rr(x, frequency, dates, risk_free)
    metric == "sharpe" && (rr = _of_drop_flat(rr, "overfit_pbo"))
    R = rr.R
    N = size(R, 2); Tn = size(R, 1)
    N < 2 && error("Mindestens zwei Punkte nötig.")
    bl = Tn ÷ S
    bl < 4 && error("Zu wenige Beobachtungen ($Tn) für S = $S Blöcke.")
    R = R[(Tn - bl * S + 1):Tn, :]
    blk = repeat(1:S, inner = bl)
    Rc = R .- _colmeans(R)'
    B1 = _rowsum(R, blk, S); B2 = _rowsum(Rc .* Rc, blk, S)
    Pm = _pmin.(R, 0.0)
    Bd = _rowsum(Pm .* Pm, blk, S); Bl = _rowsum(SL.RLibm.log1p.(R), blk, S); Bc = _rowsum(Rc, blk, S)
    T1, T2, Td, Tl, Tc = _colsums(B1), _colsums(B2), _colsums(Bd), _colsums(Bl), _colsums(Bc)
    combos = _combn(S, S ÷ 2)
    C = length(combos); half = bl * S / 2
    lam = zeros(C); isb = zeros(C); oosb = zeros(C); oosm = zeros(C)
    for st in 1:2000:C
        idx = st:min(C, st + 1999); k = length(idx)
        Ind = zeros(k, S)
        for (r, ci) in enumerate(idx), s in combos[ci]
            Ind[r, s] = 1.0
        end
        mp(B) = Matrix{Float64}(SL.RLinalg.matprod(Ind, B))
        I1, I2, Id, Il, Ic = mp(B1), mp(B2), mp(Bd), mp(Bl), mp(Bc)
        rep_t(v) = repeat(permutedims(v), k, 1)
        IS = _of_metric(half, I1, I2, Id, Il, metric; c1 = Ic)
        OOS = _of_metric(half, rep_t(T1) .- I1, rep_t(T2) .- I2, rep_t(Td) .- Id, rep_t(Tl) .- Il, metric;
                         c1 = rep_t(Tc) .- Ic)
        best = _max_col_first(IS)
        for r in 1:k
            b = best[r]
            ob = b == 0 ? NA : OOS[r, b]
            row = view(OOS, r, :)
            rk = if isnan(ob) || any(isnan, row)
                NA
            else
                lt = 0; eq = 0
                for v in row; v < ob && (lt += 1); v == ob && (eq += 1); end
                Float64(lt) + (Float64(eq) + 1) / 2
            end
            w = rk / (N + 1)
            lam[idx[r]] = SL.RLibm.log(w / (1 - w))
            isb[idx[r]] = b == 0 ? NA : IS[r, b]
            oosb[idx[r]] = ob
            oosm[idx[r]] = _median(row)
        end
    end
    intercept, slope = _lm_coef(isb, oosb)
    return SL.RList("pbo" => _mean_lgl([_lgl(<=, v, 0.0) for v in lam]), "lambda" => lam, "is_best" => isb,
                    "oos_best" => oosb, "oos_median" => oosm, "slope" => slope, "intercept" => intercept,
                    "prob_loss" => _mean_lgl([_lgl(<, v, 0.0) for v in oosb]), "S" => S, "n_combos" => C,
                    "n_points" => N, "n_obs" => bl * S, "metric" => metric, "frequency" => frequency,
                    "ppy" => rr.ppy; class = "SimLevPBO")
end

function _print_pbo(io::IO, x)
    print(io, "Probability of Backtest Overfitting (PBO, CSCV)\n")
    print(io, _spf("  %d Punkte, %d Beobachtungen (%s), S = %d Blöcke, %d Aufteilungen, Kennzahl %s\n",
                   x["n_points"], x["n_obs"], x["frequency"], x["S"], x["n_combos"], x["metric"]))
    print(io, _spf("  PBO:                              %.1f %%\n", 100 * x["pbo"]))
    print(io, _spf("  Median-Logit lambda:              %.2f\n", _median(x["lambda"])))
    print(io, _spf("  Leistungsabfall (Steigung OOS~IS): %.2f\n", x["slope"]))
    print(io, _spf("  OOS-Verlustwahrscheinlichkeit:    %.1f %%\n", 100 * x["prob_loss"]))
    ob = Float64.(collect(x["oos_best"])); om = Float64.(collect(x["oos_median"]))
    print(io, _spf("  Gewählter Punkt OOS vor Median:   %.1f %%\n", 100 * _mean_lgl([_lgl(>, a, b) for (a, b) in zip(ob, om)])))
    N = Int(x["n_points"])
    print(io, _spf("  Lesart: PBO nahe 0 = Auswahl trägt, um %.0f %% = Zufall%s, darüber = Auswahl schadet.\n",
                   100 * (N + N % 2) / (2 * N), isodd(N) ? " (ungerade Punktezahl: (N + 1) / (2N))" : ""))
    nothing
end

function _plot_pbo(x; file = nothing, kw...)
    f = _res_fig(900, 400)
    lam = filter(isfinite, Float64.(collect(x["lambda"])))
    lo, hi = isempty(lam) ? (-1.0, 1.0) : extrema(lam)
    lo == hi && (lo -= 0.5; hi += 0.5)
    nb = 40; bw = (hi - lo) / nb
    cnt = zeros(Int, nb)
    for v in lam; cnt[clamp(floor(Int, (v - lo) / bw) + 1, 1, nb)] += 1; end
    p = _res_panel(f, 60, 40, 360, 300, (lo, hi), (0.0, max(1, maximum(cnt; init = 0)) * 1.05);
                   title = "Logits (PBO " * _spf("%.0f", 100 * x["pbo"]) * " %)", xlab = "λ", ylab = "Häufigkeit")
    for i in 1:nb
        cnt[i] > 0 && _res_rect!(f, p, lo + (i - 1) * bw, 0.0, lo + i * bw, cnt[i]; fill = "#2C6E9B", stroke = "white")
    end
    _res_vline!(f, p, 0.0)
    xb = Float64.(collect(x["is_best"])); yb = Float64.(collect(x["oos_best"]))
    q = _res_panel(f, 520, 40, 360, 300, _res_range(xb), _res_range(yb); title = "Leistungsabfall",
                   xlab = "$(x["metric"]) In-Sample (bester Punkt)", ylab = "Out-of-Sample")
    _res_points!(f, q, xb, yb; r = 2, opacity = 0.4)
    _res_abline!(f, q, Float64(x["intercept"]), Float64(x["slope"]))
    _res_hline!(f, q, 0.0)
    # dargestellte Werte: endliche Logits (Histogramm), Punkte In-/Out-of-Sample
    data = SL.RList("logits" => SL.RFrame("lambda" => lam),
                    "degradation" => SL.RFrame("is_best" => xb, "oos_best" => yb))
    return (_res_finish(f; file = file), data)
end

# ═════════════════════════════════════════════════════════════════════════════
# PSR / DSR
# ═════════════════════════════════════════════════════════════════════════════

"""
    sharpe_probabilistic(r; benchmark = 0, ppy = 52)

Wahrscheinlichkeit (Anteil), dass die wahre Sharpe Ratio über `benchmark`
(p. a.) liegt, unter Berücksichtigung von Stichprobenlänge, Schiefe und
Wölbung (Bailey & López de Prado 2012).
"""
function sharpe_probabilistic(r; benchmark = 0, ppy = 52)
    v = _tofloat(r isa AbstractVector ? r : [r])
    v = filter(isfinite, v)
    n = length(v)
    mu = SL.r_mean(v); sd = SL.r_sd(v)
    sr = mu / sd
    sr0 = Float64(benchmark) / sqrt(Float64(ppy))
    z = (v .- SL.r_mean(v)) ./ SL.r_sd(v)
    g3 = SL.r_mean(Float64[SL.r_pow(e, 3.0) for e in z])
    g4 = SL.r_mean(Float64[SL.r_pow(e, 4.0) for e in z])
    den = 1 - g3 * sr + (g4 - 1) / 4 * (sr * sr)
    den = isnan(den) ? den : max(den, 1e-12)
    return Float64(SL.RNmath.pnorm((sr - sr0) * sqrt(Float64(n - 1)) / sqrt(den)))
end

"""
    sharpe_deflated(x; id = nothing, n_trials = nothing, effective = true,
                    frequency = "week", dates = nothing, risk_free = 0)

Deflated Sharpe Ratio (Bailey & López de Prado 2014) des besten (oder des
Punkts `id`) einer Suche bzw. Renditematrix. Ergebnis: `RList` der Klasse
`SimLevDSR`.
"""
function sharpe_deflated(x; id = nothing, n_trials = nothing, effective::Bool = true, frequency = nothing,
                         dates = nothing, risk_free = 0)
    x = SimLev.as_rframe(x)
    frequency = _match_arg(frequency, ("week", "day", "month"))
    rr = _of_drop_flat(_rr(x, frequency, dates, risk_free), "sharpe_deflated")
    R = rr.R
    N = size(R, 2)
    sr = _of_col_metric(R, "sharpe")
    j = if id === nothing
        _which_max(sr)
    else
        jj = findfirst(==(Float64(id)), Float64.(rr.cols))
        jj === nothing && error("id nicht unter den gültigen Punkten (Spalten ohne endliche Werte oder ohne Schwankung zählen nicht).")
        jj
    end
    rho = if N > 1
        Cm = SL.RStats.cor(R)
        Cm = Cm isa SL.NamedMat ? Cm.data : Cm
        SL.r_mean(Float64[Cm[i, k] for k in 1:N for i in 1:k-1]; na_rm = true)
    else
        1.0
    end
    n_eff = max(1.0, rho + (1 - max(rho, 0.0)) * N)
    isnan(rho) && error("missing value where TRUE/FALSE needed")      # R: if (rho < 0) mit NaN
    rho < 0 && (n_eff = N)
    Nt = n_trials !== nothing ? n_trials : (effective ? n_eff : N)
    v = N > 1 ? SL.r_var(sr) : 0.0
    g = 0.5772156649
    sr0 = (Nt > 1 && v > 0) ? sqrt(v) * ((1 - g) * SL.RNmath.qnorm(1 - 1 / Nt) +
                                         g * SL.RNmath.qnorm(1 - 1 / (Nt * SL.RLibm.exp(1.0)))) : 0.0
    r = R[:, j]
    sq = sqrt(rr.ppy)
    return SL.RList("id" => rr.cols[j], "sharpe" => sr[j] * sq, "sr0" => sr0 * sq,
                    "psr" => sharpe_probabilistic(r; benchmark = 0, ppy = rr.ppy),
                    "dsr" => sharpe_probabilistic(r; benchmark = sr0 * sq, ppy = rr.ppy),
                    "n_trials" => Nt, "n_points" => N, "n_eff" => n_eff, "rho" => rho, "var_sr" => v * rr.ppy,
                    "n_obs" => size(R, 1), "frequency" => frequency; class = "SimLevDSR")
end

function _print_dsr(io::IO, x)
    print(io, "Deflated Sharpe Ratio\n")
    print(io, _spf("  Punkt #%d, %d Beobachtungen (%s)\n", x["id"], x["n_obs"], x["frequency"]))
    print(io, _spf("  Sharpe Ratio (p. a.):                 %.3f\n", x["sharpe"]))
    print(io, _spf("  Versuche: %d nominal, %.1f effektiv (mittlere Korrelation %.2f), verwendet %.1f\n",
                   x["n_points"], Float64(x["n_eff"]), x["rho"], Float64(x["n_trials"])))
    print(io, _spf("  Erwartetes Maximum ohne Können (p. a.):  %.3f\n", x["sr0"]))
    print(io, _spf("  PSR (SR > 0):                         %.1f %%\n", 100 * x["psr"]))
    print(io, _spf("  DSR (SR > erwartetes Maximum):        %.1f %%\n", 100 * x["dsr"]))
    print(io, "  Lesart: DSR über 95 % = Ergebnis hält der Mehrfachtest-Korrektur stand.\n")
    nothing
end

# ═════════════════════════════════════════════════════════════════════════════
# Walk-Forward
# ═════════════════════════════════════════════════════════════════════════════

_strs(x) = x === nothing ? String[] : x isa AbstractString ? [String(x)] : String[String(v) for v in x]
_r_round(x) = Float64(SL.RFmt.r_round(Float64(x)))
function _add_m(date::Date, months)
    d = SL.DataPrep._add_months([date], _r_round(months))
    return d isa Date ? d : first(d)
end

"""
    overfit_walk_forward(x; train = 5, test = 1, step = test, anchored = false,
                 metric = "sharpe", select = "best", risk_free = 0)

Walk-Forward-Auswahl auf den täglichen Renditen einer `SimLevParamSearch`
(Fensterlängen in Jahren, intern ganze Monate). Ergebnis: `RList` der Klasse
`SimLevWalkForward` mit `windows`, `series`, `summary`, `hindsight_id` und
den Einstellungen.
"""
function overfit_walk_forward(x; train = 5, test = 1, step = nothing, anchored::Bool = false, metric = nothing,
                      select = nothing, risk_free = 0)
    x = SimLev.as_rframe(x)
    step === nothing && (step = test)
    metric = _match_arg(metric, ("sharpe", "sortino", "geometric", "mean"))
    select = _match_arg(select, ("best", "plateau"))
    (_is_ps(x) && get(x, "returns", nothing) !== nothing) || error("x muss ein SimLevParamSearch mit Renditen sein.")
    rr = _rr(x, "day", nothing, risk_free)
    R = rr.R; d = rr.dates
    dn = Float64[_days(v) for v in d]
    nb = select == "plateau" ? SL.ParamSearch._ps_neighbours(x) : nothing
    t0 = d[1]; last = d[end]
    win = Vector{Any}()
    k = 0
    res = x["results"]
    n_res = SL.nrow(res)
    while true
        ts = _add_m(t0, 12 * (train + k * step))
        ts >= last && break
        tr = anchored ? t0 : _add_m(t0, 12 * k * step)
        te = _add_m(t0, 12 * (train + k * step + test))
        is_rows = findall(v -> v >= tr && v < ts, d)
        oos_rows = findall(v -> v >= ts && v < te, d)
        (length(is_rows) < 20 || length(oos_rows) < 5) && break
        m_is = _of_col_metric(R[is_rows, :], metric)
        score = m_is
        if select == "plateau"
            full = fill(NA, n_res)
            full[rr.cols] = m_is
            score = Float64[SL.r_mean(full[nb[cid]]; na_rm = true) for cid in rr.cols]
        end
        j = _which_max(score)
        m_oos = _of_col_metric(R[oos_rows, :], metric)
        Ro = R[oos_rows, :]
        push!(win, (train_start = d[is_rows[1]], test_start = d[oos_rows[1]], test_end = d[oos_rows[end]],
                    id = rr.cols[j], is_metric = m_is[j], oos_metric = m_oos[j],
                    oos_rank = (_rank_avg(m_oos)[j] - 0.5) / length(m_oos),
                    oos_return = SL.r_prod(1 .+ Ro[:, j]) - 1,
                    oos_average = SL.r_mean(Float64[SL.r_prod(1 .+ Ro[:, c]) for c in 1:size(Ro, 2)] .- 1)))
        k += 1
    end
    isempty(win) && error("Historie zu kurz für ein Trainings- und Testfenster.")
    params = _strs(x["params"])
    ids = Int[w.id for w in win]
    W = SL.RFrame("train_start" => Date[w.train_start for w in win], "test_start" => Date[w.test_start for w in win],
                  "test_end" => Date[w.test_end for w in win], "id" => ids)
    for p in params
        W[p] = res[p][ids]
    end
    for nm in (:is_metric, :oos_metric, :oos_rank, :oos_return, :oos_average)
        W[String(nm)] = Float64[getfield(w, nm) for w in win]
    end
    nW = length(win)
    seg = Vector{Vector{Int}}()
    for i in 1:nW
        r = findall(v -> v >= win[i].test_start && v <= win[i].test_end, d)
        i < nW && (r = r[d[r] .< win[i+1].test_start])
        push!(seg, r)
    end
    rows = reduce(vcat, seg; init = Int[])
    colpos = Dict(c => i for (i, c) in enumerate(rr.cols))
    chosen = reduce(vcat, [fill(colpos[ids[i]], length(seg[i])) for i in 1:nW]; init = Int[])
    wf = Float64[R[rows[i], chosen[i]] for i in eachindex(rows)]
    span = R[rows, :]
    hind = _which_max(Float64[SL.r_prod(1 .+ span[:, c]) for c in 1:size(span, 2)])
    yrs = SL.r_sum(dn[rows[2:end]] .- dn[rows[2:end] .- 1]) / 365.25
    ann(r) = SL.r_pow(SL.r_prod(1 .+ r), 1 / yrs) - 1
    avg = _rowmeans(span)
    series = SL.RFrame("date" => d[rows], "walk_forward" => _cumprod(1 .+ wf), "hindsight" => _cumprod(1 .+ span[:, hind]),
                       "average" => _cumprod(1 .+ avg))
    smry = SL.RVector([ann(wf), ann(span[:, hind]), ann(avg), SL.r_mean(W["oos_rank"]),
                       SL.r_mean(W["oos_metric"]) / SL.r_mean(W["is_metric"]), Float64(count(ids[2:end] .!= ids[1:end-1]))];
                      names = ["cagr_walk_forward", "cagr_hindsight", "cagr_average", "mean_oos_rank", "efficiency", "switches"])
    return SL.RList("windows" => W, "series" => series, "summary" => smry, "hindsight_id" => rr.cols[hind],
                    "metric" => metric, "select" => select, "train" => train, "test" => test, "anchored" => anchored,
                    "params" => params; class = "SimLevWalkForward")
end

_ymd_str(d::Date) = _ymkey(d)

function _print_wf(io::IO, x)
    print(io, _spf("Walk-Forward (%s, Training %g J., Test %g J., Auswahl %s nach %s)\n",
                   x["anchored"] ? "verankert" : "rollierend", Float64(x["train"]), Float64(x["test"]), x["select"], x["metric"]))
    W = x["windows"]
    y = SL.RFrame("Test" => String[_ymkey(a) * " bis " * _ymkey(b) for (a, b) in zip(W["test_start"], W["test_end"])],
                  "Punkt" => W["id"])
    for p in _strs(x["params"])
        y[p] = W[p]
    end
    y["IS"] = _spfv("%.3f", W["is_metric"])
    y["OOS"] = _spfv("%.3f", W["oos_metric"])
    y["OOS-Rang"] = _spfv("%.0f %%", 100 .* W["oos_rank"])
    y["Rendite"] = _spfv("%.1f %%", 100 .* W["oos_return"])
    y["Mittel"] = _spfv("%.1f %%", 100 .* W["oos_average"])
    print(io, _print_df(y), "\n")
    s = x["summary"]
    print(io, _spf("\nCAGR Walk-Forward %.2f %%, Rückschau-Bester (#%d) %.2f %%, Durchschnitt aller Punkte %.2f %%\n",
                   100 * s["cagr_walk_forward"], x["hindsight_id"], 100 * s["cagr_hindsight"], 100 * s["cagr_average"]))
    print(io, _spf("Mittlerer OOS-Rang %.0f %% (50 %% = Zufall), Effizienz OOS/IS %.2f, %d Wechsel\n",
                   100 * s["mean_oos_rank"], s["efficiency"], Int(s["switches"])))
    nothing
end

function _plot_wf(x; file = nothing, kw...)
    s = x["series"]
    dd = Float64[_days(v) for v in s["date"]]
    ys = [s["walk_forward"], s["hindsight"], s["average"]]
    allv = filter(v -> isfinite(v) && v > 0, vcat(ys...))
    lo, hi = isempty(allv) ? (0.5, 2.0) : extrema(allv)
    lo == hi && (lo /= 1.1; hi *= 1.1)
    f = _res_fig(760, 420)
    yrs = unique(Dates.year.(s["date"]))
    xt = Float64[_days(Date(y, 1, 1)) for y in yrs if dd[1] <= _days(Date(y, 1, 1)) <= dd[end]]
    p = _res_panel(f, 70, 40, 660, 320, (dd[1], dd[end] == dd[1] ? dd[1] + 1 : dd[end]), (lo, hi); logy = true,
                   title = "Walk-Forward Out-of-Sample", ylab = "Wachstum (log)", xticks = xt,
                   xticklabels = [string(Dates.year(SL.from_days(Int(t)))) for t in xt])
    cols = ["#2C6E9B", "#B5562B", "#737373"]
    for (v, c, w) in zip(ys, cols, (2, 1.3, 1.3)); _res_line!(f, p, dd, v; color = c, width = w); end
    _res_legend!(f, 85, 60, ["Walk-Forward", "Rückschau-Bester", "Durchschnitt"], cols)
    data = SL.RList("growth" => SL.RFrame("date" => collect(Date, s["date"]), "walk_forward" => _tofloat(s["walk_forward"]),
                                          "hindsight" => _tofloat(s["hindsight"]), "average" => _tofloat(s["average"])))
    return (_res_finish(f; file = file), data)
end

# ═════════════════════════════════════════════════════════════════════════════
# Bootstrap der besten Punkte
# ═════════════════════════════════════════════════════════════════════════════

"""
    param_bootstrap(x, data, config; ids = nothing, top = 5, by = "objective",
                    map = nothing, include = RList(), kwargs...)

Baut für die `top` besten Punkte einer Suche die Spezifikationen mit dem
`builder` der Suche und wertet sie mit `bootstrap_study()` auf denselben
Pfaden aus. Weitere Schlüsselwörter gehen an `bootstrap_study()`. Ergebnis:
`SimLevBootstrapStudy` mit Attribut `param_ids` (Strategiename → id), siehe
[`param_ids`](@ref).
"""
function param_bootstrap(x, data, config; ids = nothing, top = 5, by = nothing, map = nothing,
                         include = nothing, kwargs...)
    data = SimLev.as_rframe(data)
    by = _match_arg(by, ("objective", "plateau"))
    _is_ps(x) || error("x muss ein SimLevParamSearch sein.")
    res = x["results"]
    if ids === nothing
        v = by == "plateau" ? SL.ParamSearch.param_plateau(x)["plateau_mean"] : res[String(x["objective"])]
        o = _order(_tofloat(v); decreasing = get(x, "maximize", nothing) === true, na_last = nothing)
        ids = res["id"][o[1:min(Int(top), length(o))]]
    end
    ids = Int[Int(i) for i in (ids isa AbstractVector ? ids : [ids])]
    params = _strs(x["params"])
    specs = Pair{String,Any}[]
    for i in ids
        p = SL.RList((pn => res[pn][i] for pn in params)...)
        sp = _as_rlist(SL.ParamSearch._as_spec(x["builder"](p)))
        sp = copy(sp)
        if map !== nothing
            old = _kv(get(sp, "map", nothing))
            sp["map"] = SL.RVector(String[string(p.second) for p in vcat(old, _kv(map))];
                                   names = String[p.first for p in vcat(old, _kv(map))])
        end
        push!(specs, "p$i" => sp)
    end
    strategies = SL.RList(vcat(specs, _kv(include))...)
    # sim_args aus kwargs ergänzen die der Suche (oberste Ebene; Bausteine werden ersetzt, nicht gemischt)
    dots = SL.RList((String(k) => v for (k, v) in kwargs)...)
    sa = SL._sim_args_set(SL.RList(), get(x, "sim_args", SL.RList()), "param_bootstrap")
    if haskey(dots, "sim_args")
        sa = SL._sim_args_set(sa, dots["sim_args"], "param_bootstrap"); delete!(dots, "sim_args")
    end
    args = _modify_list(SL.RList("data" => data, "config" => config, "strategies" => strategies,
                                 "burn_in" => get(x, "burn_in", 0)), dots)
    args["sim_args"] = sa
    a = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in args if !(k in ("data", "config")))
    st = SL.Bootstrap.bootstrap_study(args["data"], args["config"]; a...)
    pid = SL.RVector(ids; names = String[p.first for p in specs])
    _set_param_ids!(st, pid)
    return st
end

# Attribut `param_ids` (R: attr(st, "param_ids")): RList kennt keine Attribute;
# daher eine Tabelle nach Objektidentität. Abfrage über `param_ids(st)`.
const _PARAM_IDS = IdDict{Any,Any}()
const _PARAM_IDS_LOCK = ReentrantLock()
function _set_param_ids!(st, pid)
    if st isa SL.RFrame || st isa SL.RVector
        SL.attrs(st)["param_ids"] = pid
    else
        lock(() -> (_PARAM_IDS[st] = pid), _PARAM_IDS_LOCK)
    end
    st
end
"Attribut `param_ids` eines Ergebnisses von [`param_bootstrap`](@ref) (Strategiename → id)."
param_ids(st) = (st isa SL.RFrame || st isa SL.RVector) ? get(SL.attrs(st), "param_ids", nothing) : lock(() -> get(_PARAM_IDS, st, nothing), _PARAM_IDS_LOCK)

# ═════════════════════════════════════════════════════════════════════════════
# Haircut
# ═════════════════════════════════════════════════════════════════════════════

"""
    sharpe_haircut(x; n_obs = nothing, n_tests = nothing, frequency = "week",
                   dates = nothing, risk_free = 0, ppy = 52)

Sharpe-Ratio-Abschlag für Mehrfachtests (Harvey & Liu 2015) nach
Bonferroni, Holm und Benjamini-Hochberg-Yekutieli. `x`: Suche, Renditematrix
oder Vektor annualisierter Sharpe Ratios (dann `n_obs` und `ppy`). Ergebnis:
`RFrame` absteigend nach `sharpe`, Attribute `n_tests` und `n_obs`.
"""
function sharpe_haircut(x; n_obs = nothing, n_tests = nothing, frequency = nothing, dates = nothing,
                        risk_free = 0, ppy = 52)
    x = SimLev.as_rframe(x)
    frequency = _match_arg(frequency, ("week", "day", "month"))
    isvec = (x isa AbstractVector && !(x isa SL.RFrame) && _isnumvec(x)) || (x isa Real && !(x isa Bool))
    if isvec
        n_obs === nothing && error("n_obs angeben.")
        sr = _tofloat(x isa AbstractVector ? x : [x]) ./ sqrt(Float64(ppy))
        Tn = n_obs
        ids = collect(1:length(sr))
        ppy = Float64(ppy)
    else
        rr = _of_drop_flat(_rr(x, frequency, dates, risk_free), "sharpe_haircut")
        sr = _of_col_metric(rr.R, "sharpe")
        Tn = size(rr.R, 1)
        ppy = rr.ppy
        ids = rr.cols
    end
    M = n_tests !== nothing ? n_tests : length(sr)
    tstat = sr .* sqrt(Float64(Tn))
    p = 2 .* Float64[SL.RNmath.pnorm(-abs(t)) for t in tstat]
    function padj(method)
        pp = vcat(p, ones(Int(max(0, M - length(p)))))
        pv = SL.RStats.p_adjust(pp, method; n = max(M, length(p)))
        return Float64[_f64(v) for v in pv][1:length(p)]
    end
    back(pa) = _sign.(sr) .* Float64[SL.RNmath.qnorm(1 - min(a, 1) / 2) for a in pa] ./ sqrt(Float64(Tn)) .* sqrt(ppy)
    sh = sr .* sqrt(ppy)
    out = SL.RFrame("id" => ids, "sharpe" => sh, "t" => tstat, "p" => p)
    for (nm, m) in (("bonferroni", "bonferroni"), ("holm", "holm"), ("bhy", "BY"))
        pa = padj(m); sa = back(pa)
        out["p_" * nm] = pa
        out["sharpe_" * nm] = sa
        out["haircut_" * nm] = Float64[isnan(s) ? NA : s != 0 ? 1 - a / s : NA for (a, s) in zip(sa, sh)]
    end
    o = _order(-sh)
    res = SL.rows(out, o)
    SL.attrs(res)["n_tests"] = M
    SL.attrs(res)["n_obs"] = Tn
    return res
end

function __init__()
    SL.register_print!("SimLevPBO", _print_pbo)
    SL.register_plot!("SimLevPBO", SL._plot_method(_plot_pbo, "SimLevPBO"))
    SL.register_print!("SimLevDSR", _print_dsr)
    SL.register_print!("SimLevWalkForward", _print_wf)
    SL.register_plot!("SimLevWalkForward", SL._plot_method(_plot_wf, "SimLevWalkForward"))
end

end # module
