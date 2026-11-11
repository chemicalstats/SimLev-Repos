# Overfitting – Gegenstück zu r/R/overfitting.R und python/simlev/overfitting.py
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
using ..SimLev: _match_arg, _which_max   # util.jl (_match_arg auch für ParamSearch/Sensitivity über OF.) (seit 1.6.1 eine Fassung)
using ..SimLev: _res_abline!, _res_fig, _res_finish, _res_hline!, _res_legend!, _res_line!, _res_panel, _res_points!,
                _res_range, _res_rect!, _res_vline!
using Dates
using Base.CoreLogging: with_logger, NullLogger   # ohne Paketabhängigkeit Logging (seit 1.6.3)

const SL = SimLev
const NA = SimLev.NA

export overfit_pbo, sharpe_probabilistic, sharpe_deflated, overfit_walk_forward, param_bootstrap, sharpe_haircut

# ═════════════════════════════════════════════════════════════════════════════
# Kleine R-Hilfen (auch von ParamSearch / Sensitivity benutzt)
# ═════════════════════════════════════════════════════════════════════════════

using ..SimLev: _isna, _f64   # r/rnum.jl (seit 1.6.3 bzw. 1.6.4)
using ..SimLev: chk_bool1, chk_dots, chk_fmt, chk_int1, chk_max, chk_nofactor, chk_num1, chk_scalar,
                chk_stop   # pruefen.jl (seit 1.6.4)
_e5_match_arg(x, ch, fn, arg) = SL.DataPrep._e5_match_arg(x, ch, fn, arg)

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

# Summen, Mittel und Kumulationen wie R in long double über die C-Kerne (core/slc_rbase.cpp)
"`colSums` (long double, sequenziell)."
_colsums(M::AbstractMatrix) = SL._ld_colsums(M)
using ..SimLev: _colmeans   # util.jl (seit 1.6.4; die Aufrufer übergeben Matrix{Float64}; _rowsums ohne Aufrufer entfällt)
"`rowMeans` (long double je Zeile / p)."
_rowmeans(M::AbstractMatrix) = SL._ld_rowsums(M; mean = true)
"`cumprod` (long double)."
_cumprod(x) = SL._rb_cumprod(Float64[Float64(v) for v in x])
"`rowsum(M, g, reorder = FALSE)`: double-Akkumulation in Zeilenreihenfolge."
function _rowsum(M::AbstractMatrix, codes::Vector{Int}, ng::Int)
    out = zeros(ng, size(M, 2))
    for i in axes(M, 1), j in axes(M, 2)
        out[codes[i], j] += M[i, j]
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
using ..SimLev: _pmax, _pmin   # util.jl (seit 1.6.3 eine Fassung; hier ist b stets eine endliche Konstante)
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
const _cond_msg = SimLev._wrapper_errmsg   # wrapper.jl (seit 1.6.3 eine Fassung)

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
    SL.chk_stop("b2b.m_metric_pairs")
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

# seit 1.6.4 Baustein ut2.of_x mit Funktionsnamen (K43 T2-B6)
_err_mat(fn) = chk_stop("ut2.of_x", fn)

_numeltype(T) = (S = Base.nonmissingtype(T); S <: Real)
_isnumvec(v::AbstractVector) = _numeltype(eltype(v)) && !(Base.nonmissingtype(eltype(v)) <: Bool) ||
                               (eltype(v) === Any && !isempty(v) && all(e -> e === missing || (e isa Real && !(e isa Bool)), v))
_tofloat(v) = Float64[_f64(e) for e in v]

"`as.matrix(x)` einer numerischen Eingabe → (Matrix, Spaltennamen oder nothing, Zeilennamen oder nothing)."
function _as_return_matrix(x, fn = "overfit_reality_check")
    if x isa SL.RFrame
        cols = x.cols
        isempty(cols) && return zeros(SL.nrow(x), 0), String[], x.rownames
        # seit 1.6.4 nur Zahlenspalten (keine logischen Spalten, B-043; Faktoren wie bisher abgelehnt)
        all(c -> !(c isa SL.RFmt.RFactor) && _isnumvec(c), cols) || _err_mat(fn)
        M = Matrix{Float64}(undef, SL.nrow(x), length(cols))
        for (j, c) in enumerate(cols); M[:, j] = _tofloat(c); end
        return M, names(x), x.rownames
    elseif x isa SL.NamedMat
        _numeltype(eltype(x.data)) && !(Base.nonmissingtype(eltype(x.data)) <: Bool) || _err_mat(fn)
        return Float64[_f64(v) for v in x.data], x.colnames, x.rownames
    elseif x isa AbstractMatrix
        _numeltype(eltype(x)) && !(Base.nonmissingtype(eltype(x)) <: Bool) || _err_mat(fn)
        return Float64[_f64(v) for v in x], nothing, nothing
    elseif x isa AbstractVector
        _isnumvec(x) || _err_mat(fn)
        rn = x isa SL.RVector ? x.names : nothing
        return reshape(_tofloat(x), :, 1), nothing, rn
    elseif x isa Real && !(x isa Bool)
        return fill(Float64(x), 1, 1), nothing, nothing
    end
    _err_mat(fn)
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

# fn: Funktionsname für die Meldungen (seit 1.6.4); Standard für den Aufrufer overfit_reality_check()
function _rr(x, frequency, dates = nothing, risk_free = 0, fn = "overfit_reality_check")
    if _is_ps(x)
        ret = get(x, "returns", nothing)
        ret === nothing && SimLev.chk_stop("rs.ps_ohne_renditen", fn)
        R, cn, rn = _as_return_matrix(ret, fn)
        dates = get(x, "dates", nothing)
    else
        x isa SL.RFmt.RFactor && _err_mat(fn)
        R, cn, rn = _as_return_matrix(x, fn)
        if dates !== nothing             # seit 1.6.4: Länge, kein Faktor, aufsteigend ohne NA (B-020)
            chk_nofactor(dates, fn, "dates")
            (dates isa Union{AbstractVector,Tuple} ? length(dates) : 1) == size(R, 1) ||
                chk_stop("laenge", fn, "dates", chk_fmt(size(R, 1)))
        end
    end
    cn === nothing && (cn = ["p$j" for j in 1:size(R, 2)])
    cn = collect(String, cn)
    keep = [any(isfinite, view(R, :, j)) for j in 1:size(R, 2)]
    R = R[:, keep]
    cols = findall(keep)
    cn = cn[keep]
    # seit 1.6.5 (CR2-G-7): Renditen unter -1 vor der Aggregation ablehnen
    any(v -> v < -1, R) && chk_stop("b2.rendite_unter", fn)
    dts = dates === nothing ? nothing : _dates(dates, "dates")
    if dts !== nothing
        dd = Float64[v === missing ? NaN : Float64(_days(v)) for v in dts]
        (any(isnan, dd) || any(i -> dd[i] < dd[i-1], 2:length(dd))) && chk_stop("e5.datum_vektor", fn, "dates")
    end
    if dts !== nothing && frequency != "day"
        # seit 1.6.4 (B-103) Gruppen über ganzzahlige Schlüssel (Montag der ISO-Woche bzw. Jahr * 12 + Monat; Daten
        # aufsteigend: jede Periode ein Lauf, in Reihenfolge des ersten Auftretens wie bisher), Text nur für die
        # Zeilennamen der Perioden
        ck = frequency == "week" ? Int[Dates.value(d) - (Dates.dayofweek(d) - 1) for d in dts] :
                                   Int[Dates.year(d) * 12 + Dates.month(d) for d in dts]
        nk = length(ck)
        nk == size(R, 1) || error("incorrect length for 'group'")
        first = Bool[i == 1 || ck[i] != ck[i-1] for i in 1:nk]
        lev = frequency == "week" ? _isokey.(dts[first]) : _ymkey.(dts[first])
        codes = cumsum(first)
        S = _rowsum(_log1p_w(R), codes, length(lev))
        R = SL.RLibm.expm1.(S)                 # seit 1.6.2 expm1 (P2)
        rn = lev
        last = vcat(Bool[ck[i] != ck[i+1] for i in 1:nk-1], true)
        dts = dts[last]
    end
    ok = [!any(isnan, view(R, i, :)) for i in 1:size(R, 1)]
    R = R[ok, :]
    rn === nothing || (rn = collect(String, rn)[ok])
    dts === nothing || (dts = dts[ok])
    any(isinf, R) && chk_stop("e5.renditen_inf", fn)   # seit 1.6.4 (B-012)
    size(R, 1) < 2 && chk_stop("e5.perioden", fn)       # seit 1.6.4 Mindestlänge (B-016)
    # seit 1.6.5 (CR2-G-7): mindestens zwei verschiedene Tage (bis 1.6.4 ppy = Inf)
    dts !== nothing && _days(dts[end]) == _days(dts[1]) && chk_stop("b2.datum_spanne", fn)
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
# seit 1.6.5 (CR2-D-4, Entscheidungen 185 K6, 187): Sharpe bzw. Sortino ohne Schwankung (<= 1e-10 je Periode) NA
function _of_flat_na(m, v)
    isnan(v) && return v
    s = sqrt(v > 0 ? v : 0.0)
    return s > 1e-10 ? m / s : NA
end
function _of_metric(n, s1, s2, sdn, sl, metric; c1 = s1)
    m = s1 ./ n
    metric == "sharpe" && return _of_flat_na.(m, (s2 .- c1 .* c1 ./ n) ./ (n - 1))
    metric == "sortino" && return _of_flat_na.(m, sdn ./ n)
    metric == "geometric" && return SL.RLibm.expm1.(sl ./ n)
    metric == "mean" && return m
    SL.chk_stop("b2b.m_flat_na")
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
        return _of_metric(n, s1, nothing, nothing, _colsums(_log1p_w(R)), metric)
    end
    SL.chk_stop("b2b.m_flat_na")
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
    flat = findall(s -> !(s > 1e-10) && !isnan(s), sdv)    # which(!(sdv > 1e-10)): NaN (z. B. bei Inf) zählt nicht
    isempty(flat) && return rr
    length(flat) == size(rr.R, 2) &&
        SL.chk_stop("b2b.m_of_drop_flat", what)
    @warn SL.chk_msg("b2b.m_of_drop_flat_2", what, length(flat), join(rr.cols[flat], ", "))
    keep = setdiff(1:size(rr.R, 2), flat)
    rr.R = rr.R[:, keep]; rr.cn = rr.cn[keep]; rr.cols = rr.cols[keep]
    rr
end

# ═════════════════════════════════════════════════════════════════════════════
# PBO
# ═════════════════════════════════════════════════════════════════════════════

"`log1p(R)` mit R's Warnung \"NaNs produced\" (Werte unter -1, -Inf; seit 1.5.1)."
function _log1p_w(R)
    SL.RLibm.log1p.(R)   # seit 1.6.4 warnt die RLibm selbst, einmal je Aufruf (C-094)
end

"`combn(S, k)` in lexikographischer Reihenfolge (Matrix k × C, eine Kombination je Spalte)."
function _combn(S::Int, k::Int)
    # utils::combn: Anzahl als Ganzzahl (as.integer(round(choose(n, m)))); jenseits von .Machine$integer.max wie R
    # Warnung und Fehler, ohne die Kombinationen aufzubauen. Ablage k x C (Int32) wie in R (seit 1.5.1)
    nc = binomial(big(S), big(k))
    if nc > typemax(Int32)
        @warn "NAs introduced by coercion to integer range"
        error("invalid 'ncol' value (too large or NA)")
    end
    out = Matrix{Int32}(undef, k, Int(nc))
    c = collect(1:k)
    col = 0
    while true
        col += 1
        for q in 1:k; out[q, col] = c[q]; end
        i = k
        while i >= 1 && c[i] == S - k + i; i -= 1; end
        i == 0 && break
        c[i] += 1
        for j in i+1:k; c[j] = c[j-1] + 1; end
    end
    out
end

"Koeffizienten (Achsenabschnitt, Steigung) wie `.sl_lsfit(cbind(1, x), y)` (na.omit)."
function _lm_coef(x::Vector{Float64}, y::Vector{Float64})
    ok = [!(isnan(a) || isnan(b)) for (a, b) in zip(x, y)]
    # cbind(1, numeric(0)) ist 1 x 1: ohne Paar wie R "Längen von x und y passen nicht" (seit 1.5.1)
    X = any(ok) ? hcat(ones(count(ok)), x[ok]) : ones(1, 1)
    fit = SL.SLib.lsfit(X, y[ok])
    cf = fit isa AbstractVector ? fit : (fit isa SL.RList || fit isa AbstractDict) ? fit["coefficients"] :
         hasproperty(fit, :coefficients) ? getproperty(fit, :coefficients) : fit[:coefficients]
    cf = cf isa SL.RVector ? cf.values : collect(cf)
    return _f64(cf[1]), _f64(cf[2])
end

"""
    overfit_pbo(x; S = 16, metric = "sharpe", frequency = "week", dates = nothing, risk_free = 0)

Probability of Backtest Overfitting (CSCV).

Teilt die Renditehistorie aller Punkte einer Parametersuche in `S` gleich lange Blöcke und bildet alle
binom(S, S/2) Aufteilungen in In-Sample- und Out-of-Sample-Hälften. Je Aufteilung wird der In-Sample- beste
Punkt bestimmt und sein Rang Out-of-Sample gemessen (Logit λ). Die PBO ist der Anteil der Aufteilungen, in
denen der gewählte Punkt Out-of-Sample nicht über dem Median landet (λ ≤ 0, Schätzer ∫_-∞^0 f(λ)dλ nach Bailey
et al.; λ = 0, also genau der Median-Rang, zählt mit). Werte nahe 0 sprechen für echte Ueberlegenheit, Werte
um 0.5 und darüber für eine Auswahl nach Zufall. Bei reinem Zufall und ungerader Punktezahl N landet der
gewählte Punkt mit Wahrscheinlichkeit 1/N genau auf dem Median; der Erwartungswert der PBO ist dann (N + 1) /
(2N) statt 0.5 (z. B. 0.67 bei N = 3, 0.6 bei N = 5). Gleichstände (z. B. identische Spalten) erhalten
mittlere Ränge und können ebenfalls λ = 0 ergeben.

# Argumente
- `x`: Renditequelle:
  Seit 1.6.4 keine logischen Spalten und keine unendlichen Renditen; nach dem Entfernen der Zeilen mit fehlenden Werten mindestens zwei Perioden.

  - `SimLevParamSearch` aus `param_search()` mit gespeicherten Renditen (`keep_returns = "day"`); verwendet
    werden `x["returns"]` (tägliche Renditen je Punkt) und `x["dates"]`;
  - numerische Matrix oder Tabelle (RFrame) nur aus numerischen Spalten (ohne Datumsspalte): Zeilen =
    Perioden, Spalten = Punkte bzw. Strategien, einfache Renditen als Anteil (0.01 = 1 %); ohne Spaltennamen
    heißen die Spalten `p1`, `p2`, ...

  Spalten ohne endlichen Wert werden verworfen, danach alle Zeilen mit einem fehlenden Wert; bei `metric =
  "sharpe"` außerdem Spalten ohne Schwankung (Standardabweichung <= 1e-10 je Periode, mit Warnung), deren
  Sharpe Ratio nicht definiert ist. Mindestens zwei Spalten nötig. Bei `print()`/`plot()`: Objekt der Klasse
  `SimLevPBO`.
- `S`: Anzahl Blöcke (gerade ganze Zahl von 2 bis 24, Standard 16 ergibt binom(16, 8) = 12870 Aufteilungen;
  seit 1.6.4 höchstens 24: binom(24, 12) = 2704156 Aufteilungen, rund 0,5 GB Speicher, in Julia 0,8 GB).
  Seit 1.6.4 ohne Abschneiden: eine gebrochene Zahl ist ein Fehler.
- `metric`: Kennzahl je Periode (nach Abzug von `risk_free`, nicht annualisiert): `"sharpe"` (Standard;
  Mittelwert / Standardabweichung), `"sortino"` (Mittelwert / Wurzel des mittleren quadrierten negativen
  Teils), `"geometric"` (geometrische Periodenrendite exp(log(1 + r)) - 1, Anteil) oder `"mean"`
  (arithmetisches Mittel, Anteil). Höher = besser.
- `frequency`: Periodenlänge der Auswertung: `"week"` (Standard), `"day"` oder `"month"`. Mit Datum (bei
  `SimLevParamSearch` immer, bei Matrizen über `dates`) werden die Tagesrenditen geometrisch zu ISO-Wochen
  bzw. Kalendermonaten verkettet. Ohne Datum wird nicht aggregiert; die Zeilen gelten dann als Perioden dieser
  Frequenz (wichtig für `ppy`). Achtung: Eine Matrix von Tagesrenditen ohne `dates` braucht `frequency =
  "day"`; mit dem Standard `"week"` wird mit 52 statt 252 Perioden je Jahr annualisiert (betrifft
  annualisierte Sharpe Ratios und `risk_free`).
- `dates`: Datum je Zeile von `x` (Date oder umwandelbar), nur bei Matrix-Eingabe; `nothing` (Standard) =
  keine Aggregation. Bei `SimLevParamSearch` wird `x["dates"]` verwendet.
  Seit 1.6.4 genau ein Datum je Zeile, aufsteigend, ohne NA und kein Faktor.
- `risk_free`: Risikoloser Zins in Prozent p. a. (2 = 2 %, Standard 0); wird als `risk_free / 100 / ppy` von
  jeder Periodenrendite abgezogen. `ppy` (Perioden je Jahr) wird aus dem Datum geschätzt: (Anzahl Perioden -
  1) / (Zeitspanne in Tagen / 365.25); ohne Datum 252 (`"day"`), 52 (`"week"`) bzw. 12 (`"month"`).

# Rückgabe
Objekt der Klasse `SimLevPBO`, eine Liste mit `pbo` (Anteil der Aufteilungen mit λ ≤ 0), `lambda` (Logit je
Aufteilung), `is_best` (In-Sample-Kennzahl des gewählten Punkts je Aufteilung), `oos_best` (seine
Out-of-Sample-Kennzahl), `oos_median` (Median der Out-of-Sample-Kennzahl aller Punkte), `slope`, `intercept`
(Regression `oos_best ~ is_best`; negative Steigung = Leistungsabfall), `prob_loss` (Anteil der Aufteilungen
mit `oos_best < 0`), `S`, `n_combos` (Anzahl Aufteilungen), `n_points` (Anzahl Spalten), `n_obs` (verwendete
Perioden), `metric`, `frequency` und `ppy`. Die Kennzahlen sind je Periode angegeben, nicht annualisiert.

# Details
Verwendet werden die letzten S ⌊ T/S ⌋ Perioden; jeder Block braucht mindestens 4 Perioden. Eingabe ist eine
Parametersuche oder eine Renditematrix (eine Spalte je Variante). Mehrere fertige Simulationen (Liste von
`SimLevResult`) werden vorher zu einer Matrix zusammengefasst, siehe Beispiel bei `overfit_reality_check()`.

# Literatur
Bailey, D. H., Borwein, J., Lopez de Prado, M. & Zhu, Q. J. (2017). The probability of backtest overfitting.
Journal of Computational Finance 20(4), 39-69.

# Beispiel
```julia
using SimLev, Random
R = 2e-4 .+ 0.01 .* randn(MersenneTwister(1), 2000, 30)   # 30 Zufallsstrategien
println(overfit_pbo(R; S = 10, frequency = "day")["pbo"])  # etwa 0.5
```
"""
function overfit_pbo(x; S = 16, metric = nothing, frequency = nothing, dates = nothing, risk_free = 0, n_splits = nothing,
                     seed = nothing)
    @nospecialize   # seit 1.6.3: ein Rumpf für alle Typen der Schlüsselwörter (Übersetzung je Aufrufform entfällt)
    x = SimLev.as_rframe(x)
    fn = "overfit_pbo"
    metric = _e5_match_arg(metric, ("sharpe", "sortino", "geometric", "mean"), fn, "metric")
    frequency = _e5_match_arg(frequency, ("week", "day", "month"), fn, "frequency")
    S = chk_int1(S, fn, "S"; lo = 2)   # seit 1.6.4 ganze Zahl (bis 1.6.3 abgeschnitten, Entscheidung 19)
    S > 24 && chk_stop("e5.pbo_S", fn)   # seit 1.6.4 S <= 24 (Speicher; Entscheidung 138, vorher 28 nach 56)
    S = Int(S)
    (S < 2 || isodd(S)) && chk_stop("ut2.pbo_S", fn)
    risk_free = chk_num1(risk_free, fn, "risk_free")
    n_splits = chk_int1(n_splits, fn, "n_splits"; lo = 1, null_ok = true)   # seit 1.6.5 (E-T2-2, Entscheidung 196)
    seed === nothing || SL.SLib.check_seed(seed, fn)
    rr = _rr(x, frequency, dates, risk_free, fn)
    metric == "sharpe" && (rr = _of_drop_flat(rr, "overfit_pbo"))
    R = rr.R
    N = size(R, 2); Tn = size(R, 1)
    N < 2 && SimLev.chk_stop("rs.zwei_punkte", fn)
    bl = Tn ÷ S
    bl < 4 && SimLev.chk_stop("rs.pbo_beob", fn, Tn, Int(S))
    R = R[(Tn - bl * S + 1):Tn, :]
    blk = repeat(1:S, inner = bl)
    Rc = R .- _colmeans(R)'
    B1 = _rowsum(R, blk, S); B2 = _rowsum(Rc .* Rc, blk, S)
    Pm = _pmin.(R, 0.0)
    # seit 1.6.5 (CR2-P-2): Totalverluste (<= -1) je Block gezählt, log1p ohne sie; bei "geometric" Zähler im 5. Block
    tl = R .<= -1
    Bd = _rowsum(Pm .* Pm, blk, S)
    Bl = _rowsum(any(tl) ? _log1p_w(ifelse.(tl, 0.0, R)) : _log1p_w(R), blk, S)
    Bc = metric == "geometric" ? _rowsum(Float64.(tl), blk, S) : _rowsum(Rc, blk, S)
    T1, T2, Td, Tl, Tc = _colsums(B1), _colsums(B2), _colsums(Bd), _colsums(Bl), _colsums(Bc)
    combos = _combn(S, S ÷ 2)
    C_all = size(combos, 2)
    # seit 1.6.5 (E-T2-2, Entscheidung 196): Zufallsauswahl von n_splits Aufteilungen ohne Zurücklegen
    if n_splits !== nothing && n_splits < C_all
        st = SL.SLib.main_stream(seed, fn)
        pick = sort(Int.(SL.SLib.sample(C_all, Int(n_splits); stream = st)))
        combos = combos[:, pick]
    end
    C = size(combos, 2); half = bl * S / 2
    # je Aufteilung im Kern (core/research_core_impl.h, pbo_cscv; bis 1.4.3 hier in Julia)
    lam, isb, oosb, oosm = SL.DependenceCore.pbo_cscv((B1, B2, Bd, Bl, Bc), (T1, T2, Td, Tl, Tc), combos, half, metric, S, N)
    nok = count(i -> !isnan(isb[i]) && !isnan(oosb[i]), eachindex(isb))
    # seit 1.6.5 (CR2-P-3): ohne zwei gültige Paare keine Regression
    intercept, slope = nok >= 2 ? _lm_coef(isb, oosb) : (NA, NA)
    # seit 1.6.5 (CR2-P-1): PBO und Verlustanteil über die Aufteilungen mit Kennzahl, Warnung mit deren Zahl
    good = .!isnan.(lam)
    nbad = count(!, good)
    nbad > 0 && @warn SimLev.chk_msg("b2.pbo_ohne", fn, nbad, C)
    out = SL.RList("pbo" => any(good) ? _mean_lgl([v <= 0 for v in lam[good]]) : NA, "lambda" => lam, "is_best" => isb,
                    "oos_best" => oosb, "oos_median" => oosm, "slope" => slope, "intercept" => intercept,
                    "prob_loss" => any(good) ? _mean_lgl([v < 0 for v in oosb[good]]) : NA, "S" => S, "n_combos" => C,
                    "n_points" => N, "n_obs" => bl * S, "metric" => metric, "frequency" => frequency,
                    "ppy" => rr.ppy; class = "SimLevPBO")
    C < C_all && (out["n_combos_all"] = C_all)
    return out
end

function _print_pbo(io::IO, x)
    print(io, "Probability of Backtest Overfitting (PBO, CSCV)\n")
    print(io, _spf("  %d Punkte, %d Beobachtungen (%s), S = %d Blöcke, %d Aufteilungen, Kennzahl %s\n",
                   x["n_points"], x["n_obs"], x["frequency"], x["S"], x["n_combos"], x["metric"]))
    if haskey(x, "n_combos_all")
        pb = Float64(x["pbo"])
        print(io, _spf("  Zufallsauswahl: %d von %d Aufteilungen (Standardfehler der PBO etwa %.3f)\n", x["n_combos"],
                       x["n_combos_all"], sqrt(pb * (1 - pb) / x["n_combos"])))
    end
    print(io, _spf("  PBO:                              %.1f %%\n", 100 * x["pbo"]))
    print(io, _spf("  Median-Logit lambda:              %.2f\n", _median(x["lambda"]; na_rm = true)))
    print(io, _spf("  Leistungsabfall (Steigung OOS~IS): %.2f\n", x["slope"]))
    print(io, _spf("  OOS-Verlustwahrscheinlichkeit:    %.1f %%\n", 100 * x["prob_loss"]))
    ob = Float64.(collect(x["oos_best"])); om = Float64.(collect(x["oos_median"]))
    print(io, _spf("  Gewählter Punkt OOS vor Median:   %.1f %%\n",
                   100 * _mean_lgl(Bool[a > b for (a, b) in zip(ob, om) if !(isnan(a) || isnan(b))])))
    N = Int(x["n_points"])
    print(io, _spf("  Lesart: PBO nahe 0 = Auswahl trägt, um %.0f %% = Zufall%s, darüber = Auswahl schadet.\n",
                   100 * (N + N % 2) / (2 * N), isodd(N) ? " (ungerade Punktezahl: (N + 1) / (2N))" : ""))
    nothing
end

function _plot_pbo(x; kw...)
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
    return (_res_finish(f), data)
end

# ═════════════════════════════════════════════════════════════════════════════
# PSR / DSR
# ═════════════════════════════════════════════════════════════════════════════

"""
    sharpe_probabilistic(r; benchmark = 0, ppy = 52)

Probabilistic Sharpe Ratio.

Wahrscheinlichkeit, dass die wahre Sharpe Ratio über `benchmark` liegt, unter Berücksichtigung von
Stichprobenlänge, Schiefe und Wölbung: PSR = Φ(((SR - SR^*)√(T-1))/(√(1 - γ_3 SR + (γ_4 - 1)/(4)SR^2))) Dabei
sind SR (Mittelwert / Standardabweichung) und SR^* Sharpe Ratios je Periode, T die Anzahl Renditen, γ_3 die
Schiefe und γ_4 die Wölbung (nicht Exzess). Eingabe ist ein Renditevektor; für ein Ergebnis von `simulation()`
z. B. `v <- result_index(res)\$value; r <- v[-1] / v[-length(v)] - 1`.

# Argumente
- `r`: Numerischer Vektor einfacher Periodenrenditen als Anteil (0.01 = 1 %); nicht endliche Werte werden
  entfernt. Ein risikoloser Zins wird nicht abgezogen.
  Seit 1.6.4 mindestens zwei endliche Werte, die nicht alle gleich sind (sonst Fehler).
- `benchmark`: Vergleichs-Sharpe-Ratio SR^* p. a. (Standard 0); intern durch √(ppy) geteilt.
- `ppy`: Perioden je Jahr der Renditen in `r` (Standard 52 = Wochenrenditen; z. B. 252 für Handelstage, 12 für
  Monate). Wird nicht geschätzt und dient nur der Umrechnung von `benchmark`.

# Rückgabe
Eine Zahl: Wahrscheinlichkeit als Anteil (0 bis 1).

# Literatur
Bailey, D. H. & Lopez de Prado, M. (2012). The Sharpe ratio efficient frontier. Journal of Risk 15(2), 3-44.

# Beispiel
```julia
using SimLev, Random
r = 0.002 .+ 0.02 .* randn(MersenneTwister(1), 520)   # 10 Jahre Wochenrenditen
println(sharpe_probabilistic(r; benchmark = 0, ppy = 52))
```
"""
function sharpe_probabilistic(r; benchmark = 0, ppy = 52)
    fn = "sharpe_probabilistic"
    chk_nofactor(r, fn, "r")
    r = SL.DataPrep._e5_numvec(r, fn, "r")
    benchmark = chk_num1(benchmark, fn, "benchmark")
    ppy = chk_num1(ppy, fn, "ppy"; lo = 0, lo_open = true)
    rf = filter(isfinite, _tofloat(r isa AbstractVector ? r : [r]))
    (length(rf) < 2 || !(SL.r_sd(rf) > 0)) && chk_stop("e5.renditen_kurz", fn, "r")   # seit 1.6.4 (B-016, B-041)
    return _of_psr(r, benchmark, ppy)
end

"PSR ohne Prüfung (für `sharpe_deflated`)."
function _of_psr(r, benchmark, ppy)
    v = _tofloat(r isa AbstractVector ? r : [r])
    v = filter(isfinite, v)
    n = length(v)
    mu = SL.r_mean(v); sd = SL.r_sd(v)
    sr = mu / sd
    sr0 = Float64(benchmark) / sqrt(Float64(ppy))
    z = (v .- mu) ./ sd
    g3 = SL.r_mean(Float64[SL.r_pow(e, 3.0) for e in z])
    g4 = SL.r_mean(Float64[SL.r_pow(e, 4.0) for e in z])
    den = 1 - g3 * sr + (g4 - 1) / 4 * (sr * sr)
    den = isnan(den) ? den : max(den, 1e-12)
    return Float64(SL.SLib.pnorm((sr - sr0) * sqrt(Float64(n - 1)) / sqrt(den)))
end

"""
    sharpe_deflated(x; id = nothing, n_trials = nothing, effective = true,
                    frequency = "week", dates = nothing, risk_free = 0)

Deflated Sharpe Ratio.

Korrigiert die Sharpe Ratio des besten Punkts einer Suche um die Zahl der Versuche: Die Nullhypothese ist
nicht SR = 0, sondern die Sharpe Ratio, die man als Maximum aus N wertlosen Versuchen erwarten würde, SR_0 =
√(V[SR_n])((1-γ)Φ^-1(1 - 1/N) + γ Φ^-1(1 - 1/(N e))) (γ Euler-Mascheroni). Weil die Punkte einer Suche stark
korreliert sind, wird standardmäßig eine effektive Versuchsanzahl N_eff = barρ + (1 - barρ) N aus der
mittleren paarweisen Korrelation verwendet (mindestens 1; bei negativer mittlerer Korrelation N). V[SR_n] ist
die Varianz der Sharpe Ratios je Periode über alle Punkte. PSR und DSR werden mit `sharpe_probabilistic()`
berechnet. Spalten ohne Schwankung (Standardabweichung <= 1e-10 je Periode, z. B. ein Punkt, der nur Geldmarkt
mit festem Zins hält) haben keine definierte Sharpe Ratio und werden mit Warnung ausgeschlossen.

# Argumente
- `x`: Renditequelle wie bei `overfit_pbo()`: `SimLevParamSearch` aus `param_search()` mit gespeicherten
  Renditen oder numerische Renditematrix bzw. Tabelle (RFrame) nur aus numerischen Spalten (Zeilen = Perioden,
  Spalten = Punkte, einfache Renditen als Anteil). Bei `print()`: Objekt der Klasse `SimLevDSR`.
- `id`: Zu prüfender Punkt: bei `SimLevParamSearch` die `id` aus `x["results"]`, bei einer Matrix die
  Spaltennummer der ursprünglichen Matrix. `nothing` (Standard) = Punkt mit der höchsten Sharpe Ratio.
  Seit 1.6.4 eine ganze Zahl.
- `n_trials`: Versuchsanzahl N (positive Zahl, überschreibt die Schätzung), z. B. wenn vorher schon andere
  Suchen gelaufen sind. `nothing` (Standard) = aus `x` geschätzt (siehe `effective`).
  Seit 1.6.4 eine einzelne endliche Zahl > 0.
- `effective`: Logisch. `true` (Standard) = effektive Versuchsanzahl N_eff; `false` = Anzahl gültiger Spalten.
- `frequency`: Periodenlänge der Auswertung: `"week"` (Standard), `"day"` oder `"month"`. Mit Datum (bei
  `SimLevParamSearch` immer, bei Matrizen über `dates`) werden die Tagesrenditen geometrisch zu ISO-Wochen
  bzw. Kalendermonaten verkettet. Ohne Datum wird nicht aggregiert; die Zeilen gelten dann als Perioden dieser
  Frequenz (wichtig für `ppy`). Achtung: Eine Matrix von Tagesrenditen ohne `dates` braucht `frequency =
  "day"`; mit dem Standard `"week"` wird mit 52 statt 252 Perioden je Jahr annualisiert (betrifft
  annualisierte Sharpe Ratios und `risk_free`).
- `dates`: Datum je Zeile von `x` (Date oder umwandelbar), nur bei Matrix-Eingabe; `nothing` (Standard) =
  keine Aggregation. Bei `SimLevParamSearch` wird `x["dates"]` verwendet.
- `risk_free`: Risikoloser Zins in Prozent p. a. (2 = 2 %, Standard 0); wird als `risk_free / 100 / ppy` von
  jeder Periodenrendite abgezogen. `ppy` (Perioden je Jahr) wird aus dem Datum geschätzt: (Anzahl Perioden -
  1) / (Zeitspanne in Tagen / 365.25); ohne Datum 252 (`"day"`), 52 (`"week"`) bzw. 12 (`"month"`).
- `rho_method`: Rechenweg der mittleren paarweisen Korrelation barρ: `"cor"` (Standard; `nothing` = `"cor"`) =
  Mittel des oberen Dreiecks der vollen Korrelationsmatrix (Rechenzeit wie T N^2); `"linear"` = (‖Σ_j z_j‖^2 -
  N) / (N (N - 1)) mit den zentrierten und auf Länge 1 skalierten Spalten z_j (Rechenzeit wie T N).
  Mathematisch gleich; `rho`, `n_eff`, `n_trials`, `sr0` und `dsr` weichen in den letzten Stellen ab (in R,
  Python und Julia gleich). Mit nicht endlichen Renditen rechnet auch `"linear"` über die Korrelationsmatrix.
  Seit 1.6.4.

# Rückgabe
Objekt der Klasse `SimLevDSR`, eine Liste mit `id` (geprüfter Punkt), `sharpe` (seine Sharpe Ratio p. a.),
`sr0` (erwartetes Maximum ohne Können, p. a.), `psr` (Wahrscheinlichkeit SR > 0, Anteil), `dsr`
(Wahrscheinlichkeit SR > `sr0`, Anteil), `n_trials` (verwendete Versuchsanzahl), `n_points` (Anzahl Spalten),
`n_eff`, `rho` (mittlere paarweise Korrelation), `var_sr` (Varianz der Sharpe Ratios, annualisiert: Varianz je
Periode mal `ppy`), `n_obs` (Anzahl Perioden) und `frequency`. Annualisiert wird mit √(ppy); `ppy` wird wie
unter `risk_free` beschrieben bestimmt.

# Literatur
Bailey, D. H. & Lopez de Prado, M. (2014). The deflated Sharpe ratio. Journal of Portfolio Management 40(5),
94-107.

# Beispiel
```julia
using SimLev, Random
R = 2e-4 .+ 0.01 .* randn(MersenneTwister(1), 2000, 20)   # 20 Zufallsstrategien
println(sharpe_deflated(R; frequency = "day"))
```
"""
function sharpe_deflated(x; id = nothing, n_trials = nothing, effective = true, frequency = nothing,
                         dates = nothing, risk_free = 0, rho_method = nothing, expected_max = nothing)
    x = SimLev.as_rframe(x)
    fn = "sharpe_deflated"
    expected_max = _e5_match_arg(expected_max, ("exact", "bailey"), fn, "expected_max")   # seit 1.6.5 (CR2-K-2)
    frequency = _e5_match_arg(frequency, ("week", "day", "month"), fn, "frequency")
    rho_method = _e5_match_arg(rho_method, ("cor", "linear"), fn, "rho_method")   # seit 1.6.4 (B-075, Entscheidung 92)
    id = chk_int1(id, fn, "id"; lo = 1, null_ok = true)   # seit 1.6.4 (B-007)
    n_trials = chk_num1(n_trials, fn, "n_trials"; lo = 0, lo_open = true, null_ok = true)
    effective = chk_bool1(effective, fn, "effective")
    risk_free = chk_num1(risk_free, fn, "risk_free")
    rr = _of_drop_flat(_rr(x, frequency, dates, risk_free, fn), "sharpe_deflated")
    R = rr.R
    N = size(R, 2)
    sr = _of_col_metric(R, "sharpe")
    j = if id === nothing
        _which_max(sr)
    else
        jj = findfirst(==(Float64(id)), Float64.(rr.cols))
        jj === nothing && SimLev.chk_stop("rs.id_punkt", fn)
        jj
    end
    rho = if N > 1 && rho_method == "linear" && all(isfinite, R)
        _of_rho_linear(Matrix{Float64}(R))
    elseif N > 1
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
    # seit 1.6.5 (CR2-K-2, Entscheidung 189): exaktes erwartetes Maximum (Kern), Näherung nach Bailey & López de
    # Prado (2014) mit expected_max = "bailey"
    e_max() = expected_max == "exact" ? SL.SignalsCore.research_vec(1, [Float64(Nt)], Float64[], 1)[1] :
              ((1 - g) * SL.SLib.qnorm(1 - 1 / Nt) + g * SL.SLib.qnorm(1 - 1 / (Nt * SL.RLibm.exp(1.0))))
    sr0 = (Nt > 1 && v > 0) ? sqrt(v) * e_max() : 0.0
    r = R[:, j]
    sq = sqrt(rr.ppy)
    return SL.RList("id" => rr.cols[j], "sharpe" => sr[j] * sq, "sr0" => sr0 * sq,
                    "psr" => _of_psr(r, 0, rr.ppy),
                    "dsr" => _of_psr(r, sr0 * sq, rr.ppy),
                    "n_trials" => Nt, "n_points" => N, "n_eff" => n_eff, "rho" => rho, "var_sr" => v * rr.ppy,
                    "n_obs" => size(R, 1), "frequency" => frequency, "expected_max" => expected_max; class = "SimLevDSR")
end

# Mittlere paarweise Pearson-Korrelation der Spalten von R (endlich, N >= 2) in O(T N) (seit 1.6.4, B-075; R
# `.of_rho_linear`, dieselben Kerne in derselben Folge): (Σ_t (Σ_j z_tj)^2 - N) / (N (N - 1)), z_j zentriert (colMeans)
# und auf Länge 1 skaliert (√colSums(C .* C)); Summen in long double wie colSums/rowSums/sum
function _of_rho_linear(R::Matrix{Float64})
    N = size(R, 2)
    C = R .- reshape(SL._ld_colsums(R; mean = true), 1, :)
    Z = C ./ reshape(sqrt.(SL._ld_colsums(C .* C)), 1, :)
    u = SL._ld_rowsums(Z)
    return (SL.r_sum(u .* u) - N) / (Float64(N) * (N - 1))
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

Walk-Forward-Auswahl.

Wählt in rollierenden Trainingsfenstern den besten Punkt einer Parametersuche (oder das beste Plateau) und
verkettet dessen Renditen im jeweils folgenden Testfenster. So entsteht eine Out-of-Sample-Reihe, die nur
Informationen nutzt, die zum Entscheidungszeitpunkt vorlagen. Verglichen wird mit dem nachträglich besten
Punkt (Rückschau) und mit dem Durchschnitt aller Punkte (zufällige Wahl).

# Argumente
- `x`: `SimLevParamSearch` aus `param_search()` mit gespeicherten Renditen (`keep_returns = "day"`).
  Renditematrizen oder Listen von Ergebnissen werden nicht angenommen, weil Parameterwerte (und bei `select =
  "plateau"` der Suchraum) gebraucht werden. Bei `print()`/`plot()`: Objekt der Klasse `SimLevWalkForward`.
- `train`, `test`, `step`: Länge des Trainingsfensters, Länge des Testfensters und Vorschub der Fenster,
  jeweils in Jahren (Standard 5, 1 und `step = test`); intern in ganze Monate umgerechnet (`round(12 *
  Jahre)`; Fenstergrenzen = Startdatum plus Monate, auf das Monatsende begrenzt, z. B. 31.01. + 1 Monat =
  29.02.). Mit `step < test` überlappen die Testfenster; in `series` und `summary` zählt jeder Tag dann nur
  einmal, für das jüngste Fenster, dessen Test schon begonnen hat (die Kennzahlen in `windows` beziehen sich
  auf das ganze Testfenster). Mit `step > test` entstehen Lücken zwischen den Testfenstern; sie fehlen in
  `series` und zählen nicht als Zeit.
  Seit 1.6.4 je eine Zahl, die gerundet mindestens einen Monat ergibt (12 * Jahre >= 1), höchstens 100 Jahre.
- `anchored`: Logisch. `false` (Standard) = rollierendes Trainingsfenster der Länge `train`; `true` = Training
  beginnt immer am ersten Tag (expandierendes Fenster).
- `metric`: Auswahl- und Bewertungskennzahl, je Fenster aus den Tagesrenditen: `"sharpe"` (Standard),
  `"sortino"`, `"geometric"` oder `"mean"` (Definitionen wie bei `overfit_pbo()`, je Tag, nicht annualisiert;
  höher = besser).
- `select`: `"best"` (Standard): Punkt mit der höchsten Trainings-Kennzahl; `"plateau"`: Punkt mit dem
  höchsten Mittel der Trainings-Kennzahl über seine Nachbarschaft (Nachbarn wie in `param_plateau()` mit
  `radius = 1` bzw. `k = 5`).
- `risk_free`: Risikoloser Zins in Prozent p. a. (2 = 2 %, Standard 0); wird als `risk_free / 100 / ppy` von
  jeder Tagesrendite abgezogen, `ppy` = (Anzahl Tage - 1) / (Zeitspanne in Tagen / 365.25). Wirkt auch auf
  `series` und die CAGR in `summary` (dann Ueberrenditen).

# Rückgabe
Objekt der Klasse `SimLevWalkForward`, eine Liste mit

- `windows`: Tabelle (RFrame) je Testfenster: `train_start`, `test_start`, `test_end` (Date), `id` (gewählter
  Punkt), eine Spalte je Parameter, `is_metric` und `oos_metric` (Kennzahl im Trainings- bzw. Testfenster),
  `oos_rank` (Rang des gewählten Punkts im Testfenster als Anteil, (Rang - 0.5) / Anzahl Punkte; nahe 1 =
  bester, 0.5 = Zufall), `oos_return` (Rendite des gewählten Punkts im Testfenster, Anteil) und `oos_average`
  (mittlere Rendite aller Punkte im Testfenster, Anteil).
- `series`: Tabelle (RFrame) mit `date` und den Wachstumsindizes (Startwert 1 vor dem ersten Testtag)
  `walk_forward` (verkettete gewählte Punkte), `hindsight` (Punkt mit dem höchsten Endwert über alle Testtage)
  und `average` (täglich gleichgewichteter Durchschnitt aller Punkte).
- `summary`: benannter Vektor `cagr_walk_forward`, `cagr_hindsight`, `cagr_average` (CAGR über die Testtage,
  Anteil p. a.; annualisiert über die von den Testtagen überdeckte Zeit, d. h. die Summe der Abstände jedes
  Testtags zum vorherigen Datentag ohne den ersten Testtag - bei lückenlosen Testfenstern die Spanne vom
  ersten bis zum letzten Testtag), `mean_oos_rank`, `efficiency` (mittlere OOS- durch mittlere IS-Kennzahl)
  und `switches` (Anzahl Wechsel des gewählten Punkts).
- `hindsight_id`, `metric`, `select`, `train`, `test`, `anchored`, `params`: Rückschau-Punkt und
  Einstellungen.

# Details
Gerechnet wird auf den täglichen Renditen der Suche (keine Aggregation). Das erste Trainingsfenster beginnt am
ersten Tag der gespeicherten Renditen; die Fenster rücken um `step` vor, bis das Testfenster am oder nach dem
letzten Tag beginnen würde oder ein Fenster zu kurz ist (weniger als 20 Trainings- oder 5 Testtage). Das
letzte Testfenster kann kürzer als `test` sein.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 3000
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
d["A"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.011 .* randn(rng, n))
st = create_strategy(A = asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell"))
ps = param_search(d, p -> (strategy = st, signal = df -> signal_sma(df["A"]; n = p["n"], band = p["band"])),
                  param_space(n = [50, 100, 200], band = [0, 2]); burn_in = 250)
wf = overfit_walk_forward(ps; train = 3, test = 1)
println(wf["summary"])
```
"""
function overfit_walk_forward(x; train = 5, test = 1, step = nothing, anchored = false, metric = nothing,
                      select = nothing, risk_free = 0, correlation = nothing)
    x = SimLev.as_rframe(x)
    step === nothing && (step = test)
    fn = "overfit_walk_forward"
    metric = _e5_match_arg(metric, ("sharpe", "sortino", "geometric", "mean"), fn, "metric")
    select = _e5_match_arg(select, ("best", "plateau"), fn, "select")
    correlation = _e5_match_arg(correlation, ("spearman", "kendall", "pearson"), fn, "correlation")   # seit 1.6.5 (W1)
    (_is_ps(x) && get(x, "returns", nothing) !== nothing) || chk_stop("ut2.ps_renditen", "overfit_walk_forward")
    # seit 1.6.4: Jahre, die gerundet mindestens einen Monat ergeben, höchstens 100 Jahre (B-006: step = 0 lief endlos)
    vals = Dict{String,Any}()
    for (a, v) in (("train", train), ("test", test), ("step", step))
        chk_nofactor(v, fn, a)
        v = chk_scalar(v)
        (v isa Real && !(v isa Bool) && isfinite(Float64(v)) && _r_round(12 * Float64(v)) >= 1) ||
            chk_stop("e5.jahre_monat", fn, a)
        chk_max(v, 100, fn, a)
        vals[a] = v
    end
    train, test, step = vals["train"], vals["test"], vals["step"]
    anchored = chk_bool1(anchored, fn, "anchored")
    risk_free = chk_num1(risk_free, fn, "risk_free")
    rr = _rr(x, "day", nothing, risk_free, fn)
    R = rr.R; d = rr.dates
    dn = Float64[_days(v) for v in d]
    nb = select == "plateau" ? SL.ParamSearch._ps_neighbours(x) : nothing
    t0 = d[1]; last = d[end]
    win = Vector{Any}()
    k = 0
    res = x["results"]
    n_res = SL.nrow(res)
    n_flat = 0; n_val = 0
    tl_pts = Set{Int}()
    # seit 1.6.5 (CR2-D-7, K16): Überrendite unter -1 bei "geometric" mit eigener Warnung statt "NaNs produced"
    function cm(rows)
        Rw = R[rows, :]
        if metric == "geometric" && any(v -> v < -1, Rw)
            for c in 1:size(Rw, 2)
                any(v -> v < -1, view(Rw, :, c)) && push!(tl_pts, rr.cols[c])
            end
            return _quiet(() -> _of_col_metric(Rw, metric))
        end
        return _of_col_metric(Rw, metric)
    end
    while true
        ts = _add_m(t0, 12 * (train + k * step))
        ts >= last && break
        tr = anchored ? t0 : _add_m(t0, 12 * k * step)
        te = _add_m(t0, 12 * (train + k * step + test))
        is_rows = findall(v -> v >= tr && v < ts, d)
        oos_rows = findall(v -> v >= ts && v < te, d)
        (length(is_rows) < 20 || length(oos_rows) < 5) && break
        m_is = cm(is_rows)
        score = m_is
        if select == "plateau"
            full = fill(NA, n_res)
            full[rr.cols] = m_is
            score = Float64[SL.r_mean(full[nb[cid]]; na_rm = true) for cid in rr.cols]
        end
        # seit 1.6.5 (CR2-W2-1): Auswahl und Rang mit Toleranz
        j = _of_which_max_tol(score)
        j === nothing && chk_stop("b2.wf_keine_kennzahl", fn, string(d[is_rows[1]]))
        m_oos = cm(oos_rows)
        if metric in ("sharpe", "sortino")
            n_flat += count(isnan, m_is) + count(isnan, m_oos); n_val += 2 * length(m_is)
        end
        Ro = R[oos_rows, :]
        okp = .!(isnan.(m_is) .| isnan.(m_oos))
        push!(win, (train_start = d[is_rows[1]], test_start = d[oos_rows[1]], test_end = d[oos_rows[end]],
                    id = rr.cols[j], is_metric = m_is[j], oos_metric = m_oos[j],
                    oos_rank = _of_rank_tol(m_oos, j),
                    oos_return = SL._geo_ret(Ro[:, j]),
                    oos_average = SL.r_mean(Float64[SL._geo_ret(Ro[:, c]) for c in 1:size(Ro, 2)]),
                    wfc = _of_wfc(m_is, m_oos, correlation),
                    oos_positive = _mean_lgl(Bool[v > 0 for v in m_oos if !isnan(v)]),
                    is_pos_oos_neg = _mean_lgl(Bool[m_is[i] > 0 && m_oos[i] < 0 for i in eachindex(m_is) if okp[i]])))
        k += 1
    end
    isempty(win) && SimLev.chk_stop("rs.wf_kurz", fn)
    n_flat > 0 && @warn SimLev.chk_msg("b2.wf_flach", fn, n_flat, n_val)
    isempty(tl_pts) || @warn SimLev.chk_msg("b2.wf_totalverlust", fn, sort!(collect(tl_pts)))
    params = _strs(x["params"])
    ids = Int[w.id for w in win]
    W = SL.RFrame("train_start" => Date[w.train_start for w in win], "test_start" => Date[w.test_start for w in win],
                  "test_end" => Date[w.test_end for w in win], "id" => ids)
    for p in params
        W[p] = res[p][ids]
    end
    for nm in (:is_metric, :oos_metric, :oos_rank, :oos_return, :oos_average, :wfc, :oos_positive, :is_pos_oos_neg)
        W[String(nm)] = Float64[getfield(w, nm) for w in win]
    end
    nW = length(win)
    seg = Vector{Vector{Int}}()
    for i in 1:nW
        a, b = win[i].test_start, win[i].test_end   # vorab binden: win ist Vector{Any} (seit 1.5.2)
        r = findall(v -> v >= a && v <= b, d)
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
    ann(r) = SL._geo_ann(r, yrs)
    avg = _rowmeans(span)
    series = SL.RFrame("date" => d[rows], "walk_forward" => _cumprod(1 .+ wf), "hindsight" => _cumprod(1 .+ span[:, hind]),
                       "average" => _cumprod(1 .+ avg))
    mna(v) = SL.r_mean(Float64[z for z in v if !isnan(z)])          # mean(v, na.rm = TRUE)
    wv = Float64[z for z in W["wfc"] if !isnan(z)]
    smry = SL.RVector([ann(wf), ann(span[:, hind]), ann(avg), mna(W["oos_rank"]),
                       mna(W["oos_metric"]) / mna(W["is_metric"]), Float64(count(ids[2:end] .!= ids[1:end-1])),
                       isempty(wv) ? NA : SL.r_mean(wv), isempty(wv) ? NA : _median(wv)];
                      names = ["cagr_walk_forward", "cagr_hindsight", "cagr_average", "mean_oos_rank", "efficiency", "switches",
                               "mean_wfc", "median_wfc"])
    return SL.RList("windows" => W, "series" => series, "summary" => smry, "hindsight_id" => rr.cols[hind],
                    "metric" => metric, "select" => select, "train" => train, "test" => test, "anchored" => anchored,
                    "params" => params, "correlation" => correlation; class = "SimLevWalkForward")
end

# Hilfen seit 1.6.5 (CR2-W2-1, lit1 W1): Vergleich mit Toleranz (_near_eq aus sensitivity.jl, Paket B1:
# |a - b| <= 1e-12 * max(1, |a|, |b|); seit Paket B2b dieselbe Funktion wie in R und Python, das Modul Sensitivity
# wird erst nach Overfitting geladen, der Zugriff geschieht beim Aufruf), Auswahl des ersten Punkts am Höchstwert,
# Rang mit Toleranz, WFC
_of_near_eq(a::Float64, b::Float64) = SimLev.Sensitivity._near_eq(a, b)
function _of_which_max_tol(v)
    ok = findall(z -> !isnan(z), v)
    isempty(ok) && return nothing
    mx = maximum(v[ok])
    return ok[findfirst(z -> _of_near_eq(z, mx), v[ok])]
end
function _of_rank_tol(v, j)
    isnan(v[j]) && return NA
    u = Float64[z for z in v if !isnan(z)]
    e = Bool[_of_near_eq(z, v[j]) for z in u]
    return (count(i -> !e[i] && u[i] < v[j], eachindex(u)) + (count(e) + 1) / 2 - 0.5) / length(u)
end
function _of_wfc(a, b, method)
    ok = .!(isnan.(a) .| isnan.(b))
    a = Float64.(a[ok]); b = Float64.(b[ok])
    (length(a) < 3 || length(unique(a .+ 0.0)) < 2 || length(unique(b .+ 0.0)) < 2) && return NA
    c = SL.RStats.cor(a, b; method = method)
    return Float64(c isa AbstractArray ? first(c) : c)
end

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
    if haskey(x, "correlation")   # seit 1.6.5 (lit1 W1, Entscheidung 192)
        print(io, _spf("Walk-Forward-Korrelation IS/OOS (%s) Mittel %.2f, Median %.2f\n", x["correlation"],
                       s["mean_wfc"], s["median_wfc"]))
    end
    nothing
end

function _plot_wf(x; kw...)
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
    return (_res_finish(f), data)
end

# ═════════════════════════════════════════════════════════════════════════════
# Bootstrap der besten Punkte
# ═════════════════════════════════════════════════════════════════════════════

"""
    param_bootstrap(x, data, config; ids = nothing, top = 5, by = "objective",
                    map = nothing, include = RList(), kwargs...)

Beste Punkte einer Parametersuche auf Bootstrap-Pfaden prüfen.

Baut für die `top` besten Punkte (nach Zielgröße oder Plateau) die Strategie-Spezifikationen mit dem `builder`
der Suche und wertet sie gemeinsam mit `bootstrap_study()` auf denselben Pfaden aus. Der `builder` muss mit
den Spaltennamen der Pfade arbeiten (Indizes, Hebelprodukte, Zusatzreihen aus `config`); abweichende Namen
lassen sich über `map` in der Spezifikation abbilden.

# Argumente
- `x`: `SimLevParamSearch` aus `param_search()` (verwendet werden `results`, `builder`, `sim_args` und
  `burn_in`; gespeicherte Renditen sind nicht nötig).
- `data`: Historie für die Pfaderzeugung: Tabelle (RFrame) oder Matrix mit den Spalten aus `config`, Format
  wie bei `bootstrap()`.
- `config`: Konfiguration aus `bootstrap_config()`.
- `ids`: Ganzzahliger Vektor von `id`-Werten aus `x["results"]`; `nothing` (Standard) = die `top` besten
  Punkte nach `by`.
  Seit 1.6.4 nur vorhandene id-Werte ohne Doppel.
- `top`: Anzahl bester Punkte (ganze Zahl, Standard 5); nur ohne `ids`.
  Seit 1.6.4 ganze Zahl >= 1.
- `by`: Rangfolge für `top`: `"objective"` (Standard, Zielgröße der Suche) oder `"plateau"` (`plateau_mean`
  aus `param_plateau()`); Richtung nach `x["maximize"]`, Punkte mit `NA` entfallen.
- `map`: Benannter Zeichenvektor von Spalten-Aliasen, die jeder Spezifikation hinzugefügt werden, z. B. `(letf
  = "eu_l2",)`, wenn die Strategie in der Suche auf die Spalte `letf` zugreift und im Pfad das Hebelprodukt
  `eu_l2` heißt. `nothing` (Standard) = keine.
- `include`: Weitere Strategien als benannte Liste im Format von `strategies` in `bootstrap_study()`, z. B.
  ein Buy-and-Hold (Standard: keine).
- `kwargs...`: Weitere Argumente für `bootstrap_study()`, z. B. `method`, `n` (Anzahl Pfade), `params`,
  `seed`, `cores`, `progress`, `sim_args`, `burn_in`.
  Seit 1.6.4 nur Argumente von bootstrap_study(); unbekannte oder doppelte Namen sind ein Fehler.

# Rückgabe
Objekt der Klasse `SimLevBootstrapStudy` (siehe `bootstrap_study()`); die Strategien heißen `p<id>` (plus die
Namen aus `include`). Attribut `param_ids`: benannter Vektor Strategiename -> `id`.

# Details
Die Signalfunktion der Spezifikation wird je Pfad neu berechnet; ein `data`-Element der Spezifikation
(Funktion `df -> df`, siehe `param_search()`) wertet `bootstrap_study()` nicht aus. `sim_args` und `burn_in`
werden aus der Suche übernommen, lassen sich aber über `...` überschreiben.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(2); n = 1500
h = RFrame("us" => 1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n), "us" => 100 .* cumprod([1; h["us"]]))
st = create_strategy(us = asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell"))
ps = param_search(d, p -> (strategy = st, signal = df -> signal_sma(df["us"]; n = p["n"])),
                  param_space(n = [20, 50, 100]); burn_in = 100)
bs = param_bootstrap(ps, h, bootstrap_config((us = "us",)); top = 2, method = "stationary", n = 3,
                     params = (L = 50,), seed = 1, progress = false)
println(bs["results"])
```
"""
function param_bootstrap(x, data, config; ids = nothing, top = 5, by = nothing, map = nothing,
                         include = nothing, kwargs...)
    data = SimLev.as_rframe(data)
    fn = "param_bootstrap"
    by = _e5_match_arg(by, ("objective", "plateau"), fn, "by")
    _is_ps(x) || SimLev.chk_stop("klasse", "param_bootstrap", "x", "param_search()")
    res = x["results"]
    # seit 1.6.4 (K42 E5): ids ganze Zahlen aus x$results$id ohne Doppel (B-007, B-045), top ganze Zahl >= 1,
    # map benannter Zeichenvektor, include benannte Liste, kwargs nur Argumente von bootstrap_study() (Entscheidung 21)
    if ids !== nothing
        chk_nofactor(ids, fn, "ids")
        iv = ids isa Union{AbstractVector,Tuple} ? collect(Any, ids) : Any[ids]
        known = Set(Float64[_f64(v) for v in res["id"]])
        (!isempty(iv) && all(v -> v isa Real && !(v isa Bool) && isfinite(Float64(v)) && Float64(v) in known, iv) &&
         length(unique(Float64.(iv))) == length(iv)) || chk_stop("e5.ids", fn)
    end
    top = chk_int1(top, fn, "top"; lo = 1)
    if map !== nothing
        chk_nofactor(map, fn, "map")
        mk = _kv(map)
        (!isempty(mk) && all(p -> !isempty(p.first) && p.second isa AbstractString && !isempty(p.second), mk)) ||
            chk_stop("e5.map", fn)
    end
    (include === nothing || (_islistlike(include) && all(p -> !isempty(p.first), _kv(include)))) ||
        chk_stop("e2.benannt", fn, "include")
    chk_dots(collect(keys(kwargs)), _pb_args(), fn; taken = ["data", "config", "strategies"])
    if ids === nothing
        v = by == "plateau" ? SL.ParamSearch.param_plateau(x)["plateau_mean"] : res[String(x["objective"])]
        o = _order(_tofloat(v); decreasing = get(x, "maximize", nothing) === true, na_last = nothing)
        ids = res["id"][o[1:min(Int(top), length(o))]]
    end
    ids = Int[Int(i) for i in (ids isa AbstractVector ? ids : [ids])]
    params = _strs(x["params"])
    # seit 1.6.5 (CR2-F-4, K35): ein Name aus include, der für einen Suchpunkt vergeben ist, ist ein Fehler
    incl_names = String[p.first for p in _kv(include)]
    for i in ids
        "p$i" in incl_names && chk_stop("b2.pb_include", fn, "p$i")
    end
    specs = Pair{String,Any}[]
    for i in ids
        p = SL.RList((pn => res[pn][i] for pn in params)...)
        sp = _as_rlist(SL.ParamSearch._as_spec(x["builder"](p)))
        sp = copy(sp)
        if map !== nothing
            # seit 1.6.5 (CR2-F-3, K18): map ersetzt gleiche Aliase der Suche (ohne doppelte Namen)
            mk = Pair{String,Any}[p for p in _kv(get(sp, "map", nothing))]
            for p in _kv(map)
                k = findfirst(q -> q.first == p.first, mk)
                k === nothing ? push!(mk, p) : (mk[k] = p)
            end
            sp["map"] = SL.RVector(String[string(p.second) for p in mk]; names = String[p.first for p in mk])
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

"Argumente, die `param_bootstrap()` über kwargs an `bootstrap_study()` weitergibt (R `.pb_args`)."
_pb_args() = unique(String[string(k) for m in methods(SL.Bootstrap.bootstrap_study) for k in Base.kwarg_decl(m)
                           if !(string(k) in ("data", "config", "strategies")) && !endswith(string(k), "...")])

# Attribut `param_ids` (R: attr(st, "param_ids")) in `attrs` des Ergebnisses (RList, RFrame, RVector; seit 1.6.4 auch
# RList, B-108: bis 1.6.3 hielt eine globale Tabelle nach Objektidentität jedes Studienergebnis fest). Andere Typen
# wie bisher über die Tabelle. Abfrage über `param_ids(st)`.
const _PARAM_IDS = IdDict{Any,Any}()
const _PARAM_IDS_LOCK = ReentrantLock()
_has_attrs(st) = st isa SL.RList || st isa SL.RFrame || st isa SL.RVector
function _set_param_ids!(st, pid)
    if _has_attrs(st)
        SL.attrs(st)["param_ids"] = pid
    else
        lock(() -> (_PARAM_IDS[st] = pid), _PARAM_IDS_LOCK)
    end
    st
end
"Attribut `param_ids` eines Ergebnisses von [`param_bootstrap`](@ref) (Strategiename → id)."
param_ids(st) = _has_attrs(st) ? get(SL.attrs(st), "param_ids", nothing) : lock(() -> get(_PARAM_IDS, st, nothing), _PARAM_IDS_LOCK)

# ═════════════════════════════════════════════════════════════════════════════
# Haircut
# ═════════════════════════════════════════════════════════════════════════════

"""
    sharpe_haircut(x; n_obs = nothing, n_tests = nothing, frequency = "week",
                   dates = nothing, risk_free = 0, ppy = 52)

Sharpe-Ratio-Abschlag für Mehrfachtests (Harvey & Liu 2015).

Wandelt die Sharpe Ratio jedes Punkts einer Suche (oder gegebene Sharpe Ratios) in einen t-Wert und p-Wert,
korrigiert die p-Werte für die Zahl der Versuche (Bonferroni, Holm, Benjamini-Hochberg-Yekutieli) und rechnet
sie in eine "abgeschlagene" Sharpe Ratio zurück: SR^adj = Φ^-1(1 - p^adj/2) / √(T). Der Abschlag 1 - SR^adj/SR
zeigt, wie viel der gemessenen Sharpe Ratio die Suche selbst erklärt.

# Argumente
- `x`: Eingabe: `SimLevParamSearch` aus `param_search()` mit gespeicherten Renditen, numerische Renditematrix
  bzw. Tabelle (RFrame) nur aus numerischen Spalten (Zeilen = Perioden, Spalten = Punkte, einfache Renditen
  als Anteil; wie bei `overfit_pbo()`) oder numerischer Vektor annualisierter Sharpe Ratios (dann `n_obs` und
  `ppy` angeben).
- `n_obs`: Anzahl Perioden T, auf denen die Sharpe Ratios beruhen (Perioden der Länge, die `ppy` beschreibt);
  nur und zwingend bei Vektor-Eingabe. Sonst die Zeilenzahl nach Aggregation.
  Seit 1.6.4 ganze Zahl >= 1; die Sharpe Ratios in x müssen endlich sein.
- `n_tests`: Gesamtzahl der Versuche M (ganze Zahl). `nothing` (Standard) = Anzahl Sharpe Ratios bzw. Punkte;
  bei früheren Suchen entsprechend höher ansetzen (fehlende Versuche gehen mit p = 1 in die Korrektur ein).
  Seit 1.6.4 ganze Zahl von 1 bis 10^8, mindestens die Anzahl Sharpe Ratios bzw. Punkte (sonst ein Fehler).
- `frequency`, `dates`, `risk_free`: Aggregation, Datum und risikoloser Zins (Prozent p. a.) wie bei
  `overfit_pbo()`; nur bei Suche oder Matrix.
- `ppy`: Perioden je Jahr, nur bei Vektor-Eingabe (Standard 52 = Wochen). Bei Suche oder Matrix wird es wie
  bei `overfit_pbo()` bestimmt (aus dem Datum geschätzt, sonst 252/52/12 je `frequency`).

# Rückgabe
Tabelle (RFrame) je Punkt, absteigend nach `sharpe` sortiert, mit `id` (Punkt bzw. Spaltennummer; bei Vektoren
die Position), `sharpe` (p. a.), `t`, `p` und für jedes Verfahren `bonferroni`, `holm` und `bhy`
(Benjamini-Hochberg-Yekutieli) die Spalten `p_<verfahren>` (angepasster p-Wert), `sharpe_<verfahren>`
(abgeschlagene Sharpe Ratio p. a.) und `haircut_<verfahren>` (Abschlag als Anteil; `NA` bei `sharpe = 0`).
Attribute `n_tests` und `n_obs`.

# Details
Der t-Wert ist SR √(T) mit der Sharpe Ratio je Periode und T Perioden, der p-Wert zweiseitig
(Normalverteilung). Die abgeschlagene Sharpe Ratio je Periode wird mit √(ppy) annualisiert und erhält das
Vorzeichen von SR. Bei Renditen werden Spalten ohne Schwankung (Standardabweichung <= 1e-10 je Periode) mit
Warnung ausgeschlossen (Sharpe Ratio nicht definiert).

# Literatur
Harvey, C. R. & Liu, Y. (2015), Backtesting, Journal of Portfolio Management 42(1), 13-28.

# Beispiel
```julia
using SimLev
println(sharpe_haircut([1, 0.5]; n_obs = 520, n_tests = 50, ppy = 52))
```
"""
function sharpe_haircut(x; n_obs = nothing, n_tests = nothing, frequency = nothing, dates = nothing,
                        risk_free = 0, ppy = 52, distribution = nothing)
    x = SimLev.as_rframe(x)
    fn = "sharpe_haircut"
    frequency = _e5_match_arg(frequency, ("week", "day", "month"), fn, "frequency")
    distribution = _e5_match_arg(distribution, ("t", "normal"), fn, "distribution")   # seit 1.6.5 (Entscheidung 190)
    # seit 1.6.4: n_tests ganze Zahl von 1 bis 10^8 (Entscheidung 16; C-017), Sharpe Ratios endlich, n_obs ganze Zahl
    if n_tests !== nothing
        n_tests = chk_int1(n_tests, fn, "n_tests"; lo = 1)
        chk_max(n_tests, 1e8, fn, "n_tests")
    end
    risk_free = chk_num1(risk_free, fn, "risk_free")
    isvec = (x isa AbstractVector && !(x isa SL.RFrame) && !(x isa SL.RFmt.RFactor) && _isnumvec(x)) ||
            (x isa Real && !(x isa Bool))
    if isvec
        all(isfinite, _tofloat(x isa AbstractVector ? x : [x])) || chk_stop("e2.zahlen_endlich", fn, "x")
        n_obs === nothing && SimLev.chk_stop("fehlt", fn, "n_obs")
        n_obs = chk_int1(n_obs, fn, "n_obs"; lo = 1)
        ppy = chk_num1(ppy, fn, "ppy"; lo = 0, lo_open = true)
        sr = _tofloat(x isa AbstractVector ? x : [x]) ./ sqrt(Float64(ppy))
        Tn = n_obs
        ids = collect(1:length(sr))
        ppy = Float64(ppy)
    else
        rr = _of_drop_flat(_rr(x, frequency, dates, risk_free, fn), "sharpe_haircut")
        sr = _of_col_metric(rr.R, "sharpe")
        Tn = size(rr.R, 1)
        ppy = rr.ppy
        ids = rr.cols
    end
    # seit 1.6.4 (K43 T2-N7) mindestens so viele Tests wie Sharpe Ratios (bis dahin still durch deren Zahl ersetzt, das
    # Attribut n_tests nannte den angegebenen Wert)
    n_tests !== nothing && n_tests < length(sr) && chk_stop("ut2.n_tests", fn)
    M = n_tests !== nothing ? n_tests : length(sr)
    # seit 1.6.5 (Entscheidung 190): Standard t-Verteilung mit T - 1 Freiheitsgraden in beiden Richtungen
    distribution == "t" && Tn < 2 && chk_stop("b2.haircut_t", fn)
    nu = distribution == "t" ? Float64(Tn - 1) : Inf
    tstat = sr .* sqrt(Float64(Tn))
    p = distribution == "t" ? 2 .* SL.SLib.pt(Float64[-abs(t) for t in tstat], nu) :
                              2 .* SL.SLib.pnorm(Float64[-abs(t) for t in tstat])
    function back(pa)                                   # oberes Ende
        q = Float64[min(a, 1) / 2 for a in pa]
        q = distribution == "t" ? SL.SLib.qt(q, nu; lower_tail = false) : SL.SLib.qnorm(q; lower_tail = false)
        return _sign.(sr) .* q ./ sqrt(Float64(Tn)) .* sqrt(ppy)
    end
    # seit 1.6.5 (CR2-I-2): wo p unterläuft (p < 1e-290), im Log-Maßstab über die Kerne tail_logp/tail_logp_inv
    low = p .< 1e-290
    lp = SL.RLibm.log.(p)
    any(low) && (lp[low] = SL.RLibm.log(2.0) .+ SL.SignalsCore.research_vec(6, abs.(tstat[low]), [nu], count(low)))
    sh = sr .* sqrt(ppy)
    out = SL.RFrame("id" => ids, "sharpe" => sh, "t" => tstat, "p" => p)
    for (nm, m) in (("bonferroni", "bonferroni"), ("holm", "holm"), ("bhy", "BY"))
        pa = _of_p_adjust(p, m, M); sa = back(pa)
        if any(low)
            lpa = _of_p_adjust_log(lp, m, M)
            sa[low] = _sign.(sr[low]) .* SL.SignalsCore.research_vec(7, lpa[low] .- SL.RLibm.log(2.0), [nu], count(low)) ./
                      sqrt(Float64(Tn)) .* sqrt(ppy)
        end
        out["p_" * nm] = pa
        out["sharpe_" * nm] = sa
        out["haircut_" * nm] = Float64[isnan(s) ? NA : s != 0 ? 1 - a / s : NA for (a, s) in zip(sa, sh)]
    end
    o = _order(-sh)
    res = SL.rows(out, o)
    SL.attrs(res)["n_tests"] = M
    SL.attrs(res)["n_obs"] = Tn
    SL.attrs(res)["distribution"] = distribution
    return res
end

# p.adjust(p, method, n = M) ohne die bis 1.6.4 aufgefüllten Tests (CR2-I-1; R .of_p_adjust): BY-Faktor
# q = sum(1 / (1:M)) aus dem Kern; Bit für Bit wie stats::p.adjust über die aufgefüllten Werte
function _of_p_adjust(p::Vector{Float64}, method, M)
    lp = length(p)
    M <= 1 && return copy(p)
    method == "bonferroni" && return Float64[min(1.0, M * v) for v in p]
    out = Vector{Float64}(undef, lp)
    if method == "holm"
        o = _order(p)
        v = accumulate(max, Float64[(M - i + 1) * p[o[i]] for i in 1:lp])
    else
        o = _order(p; decreasing = true)
        q = SL.SignalsCore.research_vec(2, [Float64(M)], Float64[], 1)[1]
        v = accumulate(min, Float64[q * M / (lp - k + 1) * p[o[k]] for k in 1:lp])
    end
    out[o] = min.(1.0, v)
    return out
end
# dasselbe im Log-Maßstab (für unterlaufende p, CR2-I-2): log der angepassten p-Werte, höchstens 0
function _of_p_adjust_log(lp::Vector{Float64}, method, M)
    n = length(lp)
    M <= 1 && return copy(lp)
    method == "bonferroni" && return Float64[min(0.0, SL.RLibm.log(Float64(M)) + v) for v in lp]
    out = Vector{Float64}(undef, n)
    if method == "holm"
        o = _order(lp)
        v = accumulate(max, Float64[SL.RLibm.log(Float64(M - i + 1)) + lp[o[i]] for i in 1:n])
    else
        o = _order(lp; decreasing = true)
        q = SL.SignalsCore.research_vec(2, [Float64(M)], Float64[], 1)[1]
        v = accumulate(min, Float64[SL.RLibm.log(q * M / (n - k + 1)) + lp[o[k]] for k in 1:n])
    end
    out[o] = min.(0.0, v)
    return out
end

function __init__()
    SL.register_print!("SimLevPBO", _print_pbo)
    SL.register_plot!("SimLevPBO", SL._plot_method(_plot_pbo, "SimLevPBO"))
    SL.register_print!("SimLevDSR", _print_dsr)
    SL.register_print!("SimLevWalkForward", _print_wf)
    SL.register_plot!("SimLevWalkForward", SL._plot_method(_plot_wf, "SimLevWalkForward"))
end

end # module
