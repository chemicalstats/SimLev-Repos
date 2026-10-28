# Dependence – Port von r/R/dependence.R (Vorlage python/simlev/dependence.py)
#
#   dependence_analysis()   Korrelationen (Pearson, Spearman, Kendall), empirische
#                           Tail-Abhängigkeit, Exceedance-Korrelationen, Copula-Fits,
#                           rollierende Korrelation, DCC(1,1), bedingte Analyse nach
#                           Regimen von Drittvariablen mit Block-Bootstrap
#   copula_fit()            Gauss, t, Clayton, Gumbel, Frank inkl. Rotationen
#   tail_dependence()       empirische Tail-Koeffizienten und Exceedance-Korrelationen
#   dependence_dcc()               DCC(1,1) nach Engle (2002)
#   quantile_regression()          lineare Quantilsregression (exakt, mit Optimalitätsnachweis)
#   tail_regression()       Renditequantile in Abhängigkeit von Drittvariablen
#   tail_covar()        CoVaR / Delta-CoVaR (Adrian & Brunnermeier 2016)
#   dependence_validate()   erhalten Bootstrap-Pfade die Abhängigkeitsstruktur?
#   regime_subset()         Zeilen eines Regimes für Stress-Bootstraps
#
# Drittvariablen gehen immer verzögert ein: Die Rendite der Periode t wird dem
# Zustand zugeordnet, der am Ende der Periode t - 1 bekannt war.
#
# Bedingungen als Text (`regime_subset(condition = "infl >= 4 & us > 1")`,
# `view_prob(expr)` in Scenarios) werden wie in R über den Spalten ausgewertet,
# siehe `_eval_condition`.
module Dependence

import ..SimLev
using ..SimLev: _grid_bars!, _grid_lines!, _grid_scatter!, _grid_svg
using Dates
using Printf

export copula_fit, tail_dependence, dependence_dcc, dependence_analysis, quantile_regression, tail_regression,
       tail_covar, dependence_validate, regime_subset

const _NA = SimLev.NA
const RFrame = SimLev.RFrame
const RList = SimLev.RList
const RVector = SimLev.RVector
const NamedMat = SimLev.NamedMat

# ═════════════════════════════════════════════════════════════════════════════
# Aufrufe gemeinsamer Bausteine (andere Bearbeiter; erst beim Aufruf aufgelöst)
# ═════════════════════════════════════════════════════════════════════════════

"Ruft `f` mit Positionsargumenten `req..., opt...` auf, sonst mit `opt` als Schlüsselwörtern."
function _flex(f, req::Tuple, opt::NamedTuple = NamedTuple(), kw::NamedTuple = NamedTuple())
    args = (req..., values(opt)...)
    if hasmethod(f, Tuple{map(typeof, args)...}, keys(kw))
        return f(args...; kw...)
    end
    return f(req...; opt..., kw...)
end

"Element `k` eines Ergebnisses (RList, Dict, NamedTuple, Objekt mit Feld)."
function _el(o, k::AbstractString)
    o isa NamedTuple && return getfield(o, Symbol(k))
    o isa AbstractDict && return haskey(o, k) ? o[k] : o[Symbol(k)]
    o isa RVector && return o[k]
    return getproperty(o, Symbol(k))
end
_has(o, k::AbstractString) = o isa NamedTuple ? haskey(o, Symbol(k)) :
                              o isa AbstractDict ? (haskey(o, k) || (o isa Dict{Symbol} && haskey(o, Symbol(k)))) :
                              o isa RVector ? haskey(o, k) : hasproperty(o, Symbol(k))

_to_date(x, what) = _flex(SimLev.DataPrep._to_date, (x,), (what = String(what),))
_match_arg(arg, choices) = SimLev.DataPrep._match_arg(arg isa Tuple ? collect(arg) : arg, collect(choices))
_fill_na(x, method; keep_leading = false) =
    _fvec(_flex(SimLev.Backcast._fill_na, (x,), (method = method,), (keep_leading = keep_leading,)))
_roll_var(x, n) = _fvec(SimLev.Signals._roll_var(x, n))
_roll_cov(x, y, n) = _fvec(SimLev.Signals._roll_cov(x, y, n))
_roll_mean(x, n) = _fvec(SimLev.Signals._roll_mean(x, n))
_with_rng_restore(fn, seed) = SimLev.Bootstrap._with_rng_restore(fn; seed = seed)
_boot_idx_stationary(n_src, n_out, L) = Vector{Int}(SimLev.BootstrapCore.boot_idx_stationary(n_src, n_out, L))
_pw_block_stationary(x) = Float64(_el(SimLev.Bootstrap._pw_block(x), "stationary"))

_errmsg(e) = e isa ErrorException ? e.msg : sprint(showerror, e)

"R-`message()`: Text mit Zeilenumbruch auf `stderr`."
message(text) = (io = SimLev.RParallel.r_stderr(); println(io, text); flush(io); nothing)

"Warnungen unterdrücken (`suppressWarnings`)."
_quietly(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())

# ── Statistik-Bausteine (RStats, RNmath, RLinalg, RFmt, RLibm) ─────────────

_quantile(x, probs; na_rm = false) =
    _fvec(_flex(SimLev.RStats.quantile, (_fvec(x),), (probs = _fvec(probs),), (na_rm = na_rm, names = false)))
_q1(x, p; na_rm = false) = _quantile(x, [Float64(p)]; na_rm = na_rm)[1]
_cor_raw(x, y = nothing; method = "pearson") =
    y === nothing ? _flex(SimLev.RStats.cor, (x,), NamedTuple(), (method = method,)) :
                    _flex(SimLev.RStats.cor, (x,), (y = y,), (method = method,))
_cor1(x, y; method = "pearson") = _fvec(_cor_raw(_fvec(x), _fvec(y); method = method))[1]
_cormat(X; method = "pearson") = _fmat(_cor_raw(_fmat(X); method = method))
_median(x; na_rm = false) = Float64(SimLev.RStats.median(_fvec(x); na_rm = na_rm))
function _optimize(f, lower, upper)
    o = SimLev.RStats.optimize(f, [Float64(lower), Float64(upper)])
    Float64(_el(o, "minimum")), Float64(_el(o, "objective"))
end
function _optim_nm(par, fn, maxit, reltol)
    o = _flex(SimLev.RStats.optim, (_fvec(par), fn), NamedTuple(),
              (method = "Nelder-Mead", control = Dict{String,Any}("maxit" => maxit, "reltol" => reltol)))
    _fvec(_el(o, "par")), Float64(_el(o, "value"))
end
_qnorm(p) = SimLev.RNmath.qnorm(Float64(p))
_qt(p, df) = SimLev.RNmath.qt(Float64(p), Float64(df))
_pt(q, df) = SimLev.RNmath.pt(Float64(q), Float64(df))
_lgamma(x) = Float64(SimLev.RNmath.lgammafn(Float64(x)))
_plogis(x) = Float64(SimLev.RNmath.plogis(Float64(x)))
_qlogis(p) = Float64(SimLev.RNmath.qlogis(Float64(p)))
_log(x::Real) = SimLev.RLibm.log(Float64(x))
_exp(x::Real) = SimLev.RLibm.exp(Float64(x))
_matprod(A, B) = _fmat(SimLev.RLinalg.matprod(_fmat(A), B isa AbstractVector ? reshape(_fvec(B), :, 1) : _fmat(B)))
_matvec(A, b) = vec(_matprod(A, reshape(_fvec(b), :, 1)))

"`sprintf` für einen Satz Skalare (über RFmt)."
function _sprintf(fmt::AbstractString, args...)
    r = SimLev.RFmt.sprintf(fmt, args...)
    r isa AbstractString ? String(r) : String(first(r))
end
"`sprintf` vektorisiert (R-Recycling über die längste Eingabe)."
function _sprintf_vec(fmt::AbstractString, args...)
    vs = [a isa AbstractVector ? a : [a] for a in args]
    n = isempty(vs) ? 1 : maximum(length, vs)
    any(v -> length(v) == 0, vs) && return String[]
    String[_sprintf(fmt, (v[(i-1)%length(v)+1] for v in vs)...) for i in 1:n]
end
"`paste(format(x), collapse = \", \")` (R's `format` über RFmt)."
function _fmt1(x)
    x === nothing && return ""
    x isa Tuple && (x = collect(x))
    r = SimLev.RFmt.format(x)
    r isa AbstractString && return String(r)
    join(String.(collect(r)), ", ")
end
_date_str(d) = d === missing ? "NA" : Dates.format(d isa Date ? d : SimLev.from_days(Int(d)), "yyyy-mm-dd")
_signif_str(x) = _fmt1(Float64(SimLev.RFmt.signif(Float64(x), 3)))
_r_round(x::Real) = Float64(SimLev.RFmt.r_round(Float64(x)))
_r_round(x::AbstractArray, d) = map(v -> Float64(SimLev.RFmt.r_round(Float64(v), d)), x)

# ═════════════════════════════════════════════════════════════════════════════
# Kleine R-Hilfen (base-Semantik)
# ═════════════════════════════════════════════════════════════════════════════

_fmat(X::NamedMat) = Matrix{Float64}(X.data)
_fmat(X::AbstractMatrix) = Matrix{Float64}(X)
_fmat(X::AbstractVector) = reshape(_fvec(X), :, 1)
_fmat(X::Real) = fill(Float64(X), 1, 1)
_fmat(X::RFrame) = isempty(X.cols) ? zeros(SimLev.nrow(X), 0) : reduce(hcat, [_fvec(c) for c in X.cols])
_fvec(x::AbstractVector{Float64}) = Vector{Float64}(x)
_fvec(x::RVector) = _fvec(x.values)
_fvec(x::AbstractVector) = Float64[_num1(v) for v in x]
_fvec(x::AbstractMatrix) = _fvec(vec(x isa NamedMat ? x.data : x))
_fvec(x::Tuple) = _fvec(collect(x))
_fvec(x::Real) = [Float64(x)]
_fvec(::Nothing) = Float64[]
_fvec(::Missing) = [_NA]
_num1(v::Real) = Float64(v)
_num1(::Missing) = _NA
_num1(::Nothing) = _NA
_num1(v::Date) = Float64(SimLev.to_days(v))
function _num1(v::AbstractString)
    x = tryparse(Float64, strip(v))
    x === nothing ? _NA : x
end
_num1(v) = _NA

"`as.numeric(x)` (nicht Zahlen → NA)."
_num(x) = _fvec(x)

"R `min()` (NA vor NaN, sonst NaN pflanzt sich fort; leer = Inf)."
function _rmin(xs...)
    vals = Float64[v for x in xs for v in _fvec(x)]
    isempty(vals) && return Inf
    _rnan(vals) !== nothing && return _rnan(vals)
    minimum(vals)
end
"R `max()`."
function _rmax(xs...)
    vals = Float64[v for x in xs for v in _fvec(x)]
    isempty(vals) && return -Inf
    _rnan(vals) !== nothing && return _rnan(vals)
    maximum(vals)
end
function _rnan(vals)
    r = nothing
    for v in vals
        if isnan(v)
            SimLev.isna_strict(v) && return v
            r = v
        end
    end
    r
end

"`pmax(a, b)` für Vektor und Skalar (R-Regeln: NaN in `b` gewinnt, NaN in `a` bleibt)."
_pmax(a::AbstractVector, b::Real) = Float64[(b > v || isnan(b)) ? Float64(b) : v for v in a]

"`rank(x, ties.method = \"average\")` (`RStats.r_rank`, -0 und 0 gleichrangig)."
function _rank_avg(x)
    r = SimLev.RStats.r_rank(_fvec(x))
    Float64[Float64(t) for t in (r isa RVector ? r.values : r isa AbstractVector ? r : [r])]
end

"Pseudo-Beobachtungen (Ränge / (n + 1))."
_pobs(x) = (v = _fvec(x); _rank_avg(v) ./ (length(v) + 1))

"`combn(k, 2)` als Liste von (i, j) in R-Reihenfolge."
_combn2(k::Integer) = [(i, j) for i in 1:k for j in (i+1):k]

"`colMeans` (long-double-Summe / n)."
function _colmeans(X)
    X = _fmat(X)
    n = size(X, 1)
    out = zeros(size(X, 2))
    for j in 1:size(X, 2)
        s = SimLev.F80(0.0)
        for i in 1:n
            s = s + SimLev._ldq(X[i, j])
        end
        out[j] = Float64(s / SimLev.F80(n))
    end
    out
end

"`colSums` (long double)."
function _colsums(X)
    X = _fmat(X)
    Float64[SimLev.r_sum(view(X, :, j)) for j in 1:size(X, 2)]
end
"`rowSums` (long double)."
function _rowsums(X)
    X = _fmat(X)
    size(X, 2) == 0 && return zeros(size(X, 1))
    _fvec(SimLev.r_rowsums([X[:, j] for j in 1:size(X, 2)]))
end

"`scale(x)[, 1]` für einen Vektor."
function _scale1(x)
    x = _fvec(x)
    xc = x .- _colmeans(x)[1]
    v = filter(!isnan, xc)
    s = sqrt(SimLev.r_sum(v .* v) / max(1, length(v) - 1))
    xc ./ s
end

"Stabile Reihenfolge wie `order()` (NA/NaN zuletzt, -0 == 0)."
_order(v) = sortperm(_fvec(v); alg = Base.Sort.DEFAULT_STABLE,
                     lt = (a, b) -> isnan(b) ? !isnan(a) : (!isnan(a) && a < b))

_isna_el(v) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))
"`complete.cases` über Spalten."
function _complete_rows(cols...)
    isempty(cols) && return Bool[]
    ok = trues(length(cols[1]))
    for c in cols, i in eachindex(ok)
        _isna_el(c[i]) && (ok[i] = false)
    end
    collect(ok)
end

function _days(d)
    Float64[v === missing ? _NA : Float64(SimLev.to_days(v)) for v in (d isa AbstractVector ? d : [d])]
end

"`seq(a, b, length.out = n)` (seq.default)."
function _seq_len_out(a::Float64, b::Float64, n::Int)
    n == 1 && return [a]
    n == 2 && return [a, b]
    a == b && return fill(a, n)
    n1 = n - 1
    by = (b - a) / n1
    vcat([a], [a + i * by for i in 1:(n1-1)], [b])
end

"`seq.int(a, b, length.out = n)` (C-Code aus seq.c)."
function _seq_int_len_out(a::Float64, b::Float64, n::Int)
    out = zeros(n)
    n > 0 && (out[1] = a)
    n > 1 && (out[n] = b)
    if n > 2
        by = (b - a) / Float64(n - 1)
        for i in 1:(n-2)
            out[i+1] = i < div(n, 2) ? a + Float64(i) * by : b - Float64(n - 1 - i) * by
        end
    end
    out
end

"`.bincode` (Intervallnummern 1..; 0 = NA)."
function _bincode(x, breaks; right = true, include_lowest = false)
    x = _fvec(x); br = _fvec(breaks)
    nb1 = length(br) - 1
    lft = !right
    code = zeros(Int, length(x))
    for (i, xi) in enumerate(x)
        isnan(xi) && continue
        lo, hi = 0, nb1
        (xi < br[lo+1] || br[hi+1] < xi || (xi == br[(lft ? hi : lo)+1] && !include_lowest)) && continue
        while hi - lo >= 2
            new = div(hi + lo, 2)
            if xi > br[new+1] || (lft && xi == br[new+1])
                lo = new
            else
                hi = new
            end
        end
        code[i] = lo + 1
    end
    code
end

"`cut(x, k, labels = FALSE)` mit einer Intervallanzahl `k`."
function _cut_n(x, k::Integer)
    x = _fvec(x)
    nb = Int(k + 1)
    fin = filter(!isnan, x)
    rx = (minimum(fin), maximum(fin))
    dx = rx[2] - rx[1]
    if dx == 0
        dx = rx[1] != 0 ? abs(rx[1]) : 1.0
        br = _seq_int_len_out(rx[1] - dx / 1000, rx[2] + dx / 1000, nb)
    else
        br = _seq_int_len_out(rx[1], rx[2], nb)
        br[1] = rx[1] - dx / 1000
        br[nb] = rx[2] + dx / 1000
    end
    _bincode(x, br; right = true)
end

"Matrix und Spaltennamen (`as.matrix`)."
function _as_matrix(X)
    X isa NamedMat && return _fmat(X), X.colnames
    X isa RFrame && return _fmat(X), names(X)
    X isa AbstractMatrix && return _fmat(X), nothing
    return _fmat(X), nothing
end

_as_names(::Nothing) = String[]
_as_names(x::AbstractString) = [String(x)]
_as_names(x::Symbol) = [String(x)]
_as_names(x) = String[string(v) for v in x]

"Datenrahmen aus RFrame, NamedTuple oder Dict."
_as_frame(data::RFrame) = data
_as_frame(data::NamedTuple) = RFrame((String(k) => v for (k, v) in pairs(data))...)
_as_frame(data::AbstractDict) = RFrame((String(k) => v for (k, v) in data)...)
_as_frame(data::AbstractVector{<:Pair}) = (f = SimLev.as_rframe(data); f isa RFrame ? f : error("data.frame mit Spalte 'date' erwartet."))
_as_frame(data) = error("data.frame mit Spalte 'date' erwartet.")
_is_frame(x) = x isa RFrame || x isa NamedTuple || (x isa AbstractDict && !(x isa RList)) || (x isa AbstractVector{<:Pair} && SimLev.as_rframe(x) isa RFrame)

_getopt(x::Nothing, k) = nothing
_getopt(x::NamedTuple, k) = haskey(x, Symbol(k)) ? getfield(x, Symbol(k)) : nothing
_getopt(x::AbstractDict, k) = haskey(x, k) ? x[k] : (haskey(x, Symbol(k)) ? x[Symbol(k)] : nothing)
_getopt(x, k) = nothing

# ═════════════════════════════════════════════════════════════════════════════
# Renditen und Pseudo-Beobachtungen
# ═════════════════════════════════════════════════════════════════════════════

"""
    _dep_sort_dates(data, what = "data")

Zeilen nach Datum ordnen (`.dep_sort_dates`): fehlende oder doppelte Daten sind
ein Fehler, unsortierte Zeilen werden mit Hinweis aufsteigend sortiert; `date`
wird per `DataPrep._to_date` in `Date` gewandelt.
"""
function _dep_sort_dates(data, what::AbstractString = "data")
    data = copy(_as_frame(data))
    d = _to_date(data["date"], "$what: Spalte 'date'")
    d = collect(d)
    data["date"] = d
    na = findall(v -> v === missing, d)
    if !isempty(na)
        error("$what: Spalte 'date' enthält fehlende Daten (Zeile $(join(string.(first(na, 5)), ", "))).")
    end
    days = _days(d)
    if length(unique(days)) < length(days)
        seen = Set{Float64}(); dset = Set{Float64}(); dup = Float64[]
        for v in days
            if v in seen && !(v in dset)
                push!(dup, v); push!(dset, v)
            end
            push!(seen, v)
        end
        txt = join([_date_str(SimLev.from_days(Int(v))) for v in first(dup, 5)], ", ")
        more = length(dup) > 5 ? " und $(length(dup) - 5) weitere" : ""
        error("$what: doppelte Daten in 'date' ($txt$more); erwartet ist eine Zeile je Datum.")
    end
    if any(i -> days[i+1] < days[i], 1:(length(days)-1))
        message("$what: Zeilen sind nicht nach 'date' sortiert und werden aufsteigend sortiert.")
        data = SimLev.rows(data, sortperm(days))
    end
    data
end

"Kursspalte prüfen: vorhandene Werte müssen positiv und endlich sein (`.dep_check_prices`)."
function _dep_check_prices(v, a, d)
    v = _fvec(v)
    bad = findall(x -> !isnan(x) && (!isfinite(x) || x <= 0), v)
    if !isempty(bad)
        dd = d isa AbstractVector ? d[bad[1]] : d
        more = length(bad) > 1 ? " und $(length(bad) - 1) weitere Werte" : ""
        error("Kursspalte '$a': Kurse müssen positiv und endlich sein, gefunden $(_fmt1(v[bad[1]])) am " *
              "$(_date_str(dd))$more (fehlende Kurse als NA angeben).")
    end
    v
end

function _isoweek_key(d::Date)
    th = d + Day(4 - Dates.dayofweek(d))
    Dates.year(th) * 100 + Dates.week(d)
end

"Periodenenden: letzte Zeile je ISO-Woche (`%G-%V`) bzw. Monat (`%Y-%m`)."
function _period_ends(d::AbstractVector, frequency)
    nr = length(d)
    frequency == "day" && return collect(1:nr)
    key = frequency == "week" ? [_isoweek_key(x) for x in d] : [Dates.year(x) * 100 + Dates.month(x) for x in d]
    [i for i in 1:nr if i == nr || key[i+1] != key[i]]
end

"""
    _dep_returns(data, assets, conditions = nothing, frequency = "week"; drop_flat = true)

Periodenrenditen (log) und verzögerte Zustandsvariablen (`.dep_returns`).
"""
function _dep_returns(data, assets, conditions = nothing, frequency = "week"; drop_flat::Bool = true)
    (_is_frame(data) && haskey(_as_frame(data), "date")) || error("data.frame mit Spalte 'date' erwartet.")
    data = _as_frame(data)
    assets = _as_names(assets)
    conditions = _as_names(conditions)
    miss = [c for c in unique(vcat(assets, conditions)) if !haskey(data, c)]
    isempty(miss) || error("Spalten fehlen: $(join(miss, ", "))")
    data = _dep_sort_dates(data)
    d = collect(data["date"])
    nr = length(d)
    ends = _period_ends(d, frequency)
    V = zeros(nr, length(assets))
    for (j, a) in enumerate(assets)
        V[:, j] = _fill_na(_dep_check_prices(_num(data[a]), a, d), "locf"; keep_leading = true)
    end
    V = V[ends, :]
    m = size(V, 1)
    R = zeros(max(m - 1, 0), length(assets))
    for j in 1:length(assets), i in 1:(m-1)
        R[i, j] = _log(V[i+1, j]) - _log(V[i, j])
    end
    dates = m >= 1 ? d[ends][2:end] : Date[]
    cols = Pair{String,Any}["date" => Vector{Date}(dates)]
    for (j, a) in enumerate(assets)
        push!(cols, a => R[:, j])
    end
    for cn in conditions
        cv = _fill_na(_num(data[cn]), "locf"; keep_leading = true)[ends]
        push!(cols, cn => cv[1:end-1])
    end
    ok = Bool[!any(isnan, view(R, i, :)) for i in 1:size(R, 1)]
    if drop_flat && frequency == "day"
        ok = ok .& Bool[count(x -> abs(x) > 0, view(R, i, :)) > 0 for i in 1:size(R, 1)]
    end
    out = RFrame(cols...; nrow = size(R, 1))
    SimLev.rows(out, findall(ok))
end

"""
    _kendall(x, y = nothing)

Kendalls Tau-b; für eine Matrix die Korrelationsmatrix (`.kendall`). Bei nicht
endlichen Werten wie `stats::cor(method = "kendall")`.
"""
function _kendall(x, y = nothing)
    if y === nothing && (x isa AbstractMatrix || x isa RFrame)
        A, nm = _as_matrix(x)
        if !all(isfinite, A)
            r = _cor_raw(x isa RFrame ? NamedMat(A; colnames = nm) : x; method = "kendall")
            return r
        end
        k = size(A, 2)
        M = zeros(k, k)
        for i in 1:k
            M[i, i] = 1.0
        end
        for i in 1:(k-1), j in (i+1):k
            M[i, j] = M[j, i] = SimLev.DependenceCore.kendall_tau_core(A[:, i], A[:, j])
        end
        return nm === nothing ? M : NamedMat(M; rownames = nm, colnames = nm)
    end
    xa = _num(x); ya = _num(y)
    (!all(isfinite, xa) || !all(isfinite, ya)) && return _cor1(xa, ya; method = "kendall")
    SimLev.DependenceCore.kendall_tau_core(xa, ya)
end

# ═════════════════════════════════════════════════════════════════════════════
# Copulas
# ═════════════════════════════════════════════════════════════════════════════

function _fam_parts(family::AbstractString)
    rot = replace(family, r"^[a-z]+_?" => ""; count = 1)
    base = replace(family, r"_.*$" => ""; count = 1)
    base, rot
end

"Log-Dichte einer Copula (Summe), Familien inkl. Rotationen (`.cop_ll`)."
function _cop_ll(family::AbstractString, par, u, v)
    base, rot = _fam_parts(family)
    u = _fvec(u); v = _fvec(v)
    par = _fvec(par)
    if rot == "180"
        u = 1 .- u; v = 1 .- v
    elseif rot == "90"
        u = 1 .- u
    elseif rot == "270"
        v = 1 .- v
    end
    lg = SimLev.RLibm.log; l1p = SimLev.RLibm.log1p; em1 = SimLev.RLibm.expm1
    pw = SimLev.r_pow
    if base == "gaussian"
        r = par[1]
        x = _qnorm.(u); y = _qnorm.(v)
        r2 = r * r
        c = -0.5 * lg(1 - r2)
        ll = c .- (r2 .* (x .* x .+ y .* y) .- 2 .* r .* x .* y) ./ (2 * (1 - r2))
    elseif base == "t"
        r, nu = par[1], par[2]
        x = _qt.(u, nu); y = _qt.(v, nu)
        r2 = r * r
        c0 = _lgamma((nu + 2) / 2) + _lgamma(nu / 2) - 2 * _lgamma((nu + 1) / 2) - 0.5 * lg(1 - r2)
        ll = c0 .- (nu + 2) / 2 .* l1p.((x .* x .- 2 .* r .* x .* y .+ y .* y) ./ (nu * (1 - r2))) .+
             (nu + 1) / 2 .* (l1p.(x .* x ./ nu) .+ l1p.(y .* y ./ nu))
    elseif base == "clayton"
        th = par[1]
        ll = l1p(th) .- (1 + th) .* (lg.(u) .+ lg.(v)) .- (2 + 1 / th) .* lg.(pw.(u, -th) .+ pw.(v, -th) .- 1)
    elseif base == "gumbel"
        th = par[1]
        a = .-lg.(u); b = .-lg.(v)
        A = pw.(a, th) .+ pw.(b, th)
        A1 = pw.(A, 1 / th)
        ll = .-A1 .+ a .+ b .+ (th - 1) .* (lg.(a) .+ lg.(b)) .+ (2 / th - 2) .* lg.(A) .+ l1p.((th - 1) ./ A1)
    elseif base == "frank"
        th = par[1]
        abs(th) < 1e-8 && return 0.0
        e1 = -em1(-th)
        ll = lg(th * e1) .- th .* (u .+ v) .- 2 .* lg.(abs.(e1 .- (.-em1.(-th .* u)) .* (.-em1.(-th .* v))))
    else
        error("Unbekannte Copula-Familie '$family'.")
    end
    s = SimLev.r_sum(ll)
    isfinite(s) ? s : -1e10
end

"Tail-Koeffizienten einer Copula (unten, oben) als benannter Vektor (`.cop_lambda`)."
function _cop_lambda(family::AbstractString, par)
    base, rot = _fam_parts(family)
    par = _fvec(par)
    lam = if base in ("gaussian", "frank")
        [0.0, 0.0]
    elseif base == "t"
        rho, nu = par[1], par[2]
        v = 2 * _pt(-sqrt((nu + 1) * (1 - rho) / (1 + rho)), nu + 1)
        [v, v]
    elseif base == "clayton"
        [SimLev.r_pow(2.0, -1 / par[1]), 0.0]
    elseif base == "gumbel"
        [0.0, 2 - SimLev.r_pow(2.0, 1 / par[1])]
    else
        Float64[]
    end
    rot == "180" && (lam = reverse(lam))
    rot in ("90", "270") && (lam = [0.0, 0.0])
    RVector(lam; names = ["lower", "upper"][1:length(lam)])
end

function _finite_pairs(x, y)
    x = _num(x); y = _num(y)
    ok = isfinite.(x) .& isfinite.(y)
    x[ok], y[ok]
end

_len(x) = x === nothing ? 0 : x isa AbstractString ? 1 : x isa Union{AbstractVector,Tuple} ? length(x) : 1

"""
    copula_fit(x, y, families = nothing)

Copulas an zwei Reihen anpassen (Pseudo-ML auf Rängen, Auswahl per AIC).
`families`: `"gaussian"`, `"t"`, `"clayton"`, `"gumbel"`, `"frank"`, Clayton und
Gumbel optional mit Rotation `"_90"`, `"_180"`, `"_270"`; `nothing` = Auswahl
nach dem Vorzeichen von Kendalls Tau. Ergebnis: `RFrame` je Familie
(aufsteigend nach AIC) mit `family`, `par1`, `par2`, `loglik`, `aic`, `bic`,
`lambda_lower`, `lambda_upper`; `attrs(out)["tau"]`, `attrs(out)["n"]`.
"""
function copula_fit(x, y, families_pos = nothing; families = families_pos)
    lx, ly = _len(x), _len(y)
    lx != ly && error("copula_fit: x und y müssen gleich lang sein ($lx bzw. $ly Werte).")
    x, y = _finite_pairs(x, y)
    n = length(x)
    n < 20 && error("copula_fit: mindestens 20 Beobachtungen nötig.")
    if families !== nothing
        families = _as_names(families)
        bad = String[]
        for f in families
            base = replace(f, r"_.*$" => ""; count = 1)
            rot = occursin("_", f) ? replace(f, r"^[^_]*_" => ""; count = 1) : ""
            if !(base in ("gaussian", "t", "clayton", "gumbel", "frank")) || !(rot in ("", "90", "180", "270")) ||
               (base in ("gaussian", "t", "frank") && rot != "")
                push!(bad, f)
            end
        end
        isempty(bad) || error("copula_fit: unbekannte Familie $(join(["'$b'" for b in bad], ", ")); erlaubt sind gaussian, t, " *
                              "frank sowie clayton und gumbel mit optionaler Rotation _90, _180 oder _270.")
    end
    u = _pobs(x); v = _pobs(y)
    tau = _kendall(x, y)
    isfinite(tau) || error("copula_fit: x oder y ist konstant (keine Rangstreuung); keine Copula schätzbar.")
    if families === nothing
        families = tau >= 0 ? ["gaussian", "t", "clayton", "gumbel", "frank", "clayton_180", "gumbel_180"] :
                              ["gaussian", "t", "frank", "clayton_90", "clayton_270", "gumbel_90", "gumbel_270"]
    end
    rho0 = SimLev.RLibm.sin(pi * tau / 2)
    fam_c = String[]; p1 = Float64[]; p2 = Float64[]; llk = Float64[]; aic = Float64[]; bic = Float64[]
    ll_ = Float64[]; lu_ = Float64[]
    for fam in families
        base = split(fam, "_"; limit = 2)[1]
        f(p) = -_cop_ll(fam, p, u, v)
        if base == "gaussian"
            mn, ob = _optimize(r -> f([r]), -0.995, 0.995)
            par, nll, k = [mn, _NA], ob, 1
        elseif base == "t"
            st = [SimLev.RLibm.atanh(max(min(rho0, 0.95), -0.95)), _log(6.0)]
            p_, val = _optim_nm(st, th -> f([SimLev.RLibm.tanh(th[1]), 2 + _exp(th[2])]), 500, 1e-10)
            nu = min(2 + _exp(p_[2]), 500.0)
            par, nll, k = [SimLev.RLibm.tanh(p_[1]), nu], val, 2
        elseif base == "clayton"
            mn, ob = _optimize(lt -> f([_exp(lt)]), _log(1e-4), _log(60.0))
            par, nll, k = [_exp(mn), _NA], ob, 1
        elseif base == "gumbel"
            mn, ob = _optimize(lt -> f([1 + _exp(lt)]), _log(1e-5), _log(60.0))
            par, nll, k = [1 + _exp(mn), _NA], ob, 1
        else
            mn, ob = _optimize(th -> f([th]), -60.0, 60.0)
            par, nll, k = [mn, _NA], ob, 1
        end
        lam = _cop_lambda(fam, par)
        push!(fam_c, fam); push!(p1, par[1]); push!(p2, par[2]); push!(llk, -nll)
        push!(aic, 2 * k + 2 * nll); push!(bic, _log(Float64(n)) * k + 2 * nll)
        push!(ll_, lam[1]); push!(lu_, lam[2])
    end
    o = _order(aic)
    out = RFrame("family" => fam_c[o], "par1" => p1[o], "par2" => p2[o], "loglik" => llk[o], "aic" => aic[o],
                 "bic" => bic[o], "lambda_lower" => ll_[o], "lambda_upper" => lu_[o])
    SimLev.attrs(out)["tau"] = tau
    SimLev.attrs(out)["n"] = n
    out
end

_isnumvec(q) = (q isa Real && !(q isa Bool)) || (q isa AbstractVector && all(v -> v isa Real && !(v isa Bool), q)) ||
               (q isa Tuple && all(v -> v isa Real && !(v isa Bool), q))

"""
    tail_dependence(x, y, q = [0.01, 0.025, 0.05, 0.10, 0.20])

Empirische Tail-Abhängigkeit (`lower`, `upper`) und Exceedance-Korrelationen
(`exceed_lower`, `exceed_upper`) je Wert von `q`; `RFrame`.
"""
function tail_dependence(x, y, q_pos = [0.01, 0.025, 0.05, 0.10, 0.20]; q = q_pos)
    lx, ly = _len(x), _len(y)
    lx != ly && error("tail_dependence: x und y müssen gleich lang sein ($lx bzw. $ly Werte).")
    qv = q isa AbstractVector || q isa Tuple ? collect(q) : [q]
    if !_isnumvec(q) || isempty(qv) || any(v -> !isfinite(Float64(v)) || v <= 0 || v >= 1, qv)
        error("tail_dependence: q muss aus Anteilen echt zwischen 0 und 1 bestehen (erhalten: $(_fmt1(q))).")
    end
    qa = Float64.(qv)
    x, y = _finite_pairs(x, y)
    n = length(x)
    n < 2 && error("tail_dependence: mindestens zwei Paare mit endlichen Werten nötig.")
    u = _pobs(x); v = _pobs(y)
    ec(s) = (count(s) >= 8 && SimLev.r_sd(x[s]) > 0 && SimLev.r_sd(y[s]) > 0) ? _cor1(x[s], y[s]) : _NA
    lower = Float64[]; upper = Float64[]; el_ = Float64[]; eu_ = Float64[]; nl = Int[]; nu = Int[]
    for p in qa
        lo = (u .<= p) .& (v .<= p)
        hi = (u .> 1 - p) .& (v .> 1 - p)
        el = (x .<= _q1(x, p)) .& (y .<= _q1(y, p))
        eh = (x .>= _q1(x, 1 - p)) .& (y .>= _q1(y, 1 - p))
        push!(lower, count(lo) / (n * p)); push!(upper, count(hi) / (n * p))
        push!(el_, ec(el)); push!(eu_, ec(eh)); push!(nl, count(lo)); push!(nu, count(hi))
    end
    RFrame("q" => qa, "lower" => lower, "upper" => upper, "exceed_lower" => el_, "exceed_upper" => eu_,
           "n_lower" => nl, "n_upper" => nu)
end

# ═════════════════════════════════════════════════════════════════════════════
# DCC
# ═════════════════════════════════════════════════════════════════════════════

"""
    dependence_dcc(R)

DCC(1,1) (Engle 2002) für eine Renditematrix (mindestens zwei Spalten, 100
Zeilen). Ergebnis: RList `a`, `b`, `loglik`, `correlation` (Zeit × Paare),
`pairs`, `garch`, `z`, `Qbar`.
"""
function dependence_dcc(R)
    Rm, nm = _as_matrix(R)
    (size(Rm, 2) < 2 || size(Rm, 1) < 100) && error("dependence_dcc: mindestens zwei Reihen und 100 Beobachtungen.")
    nm === nothing && (nm = ["V$j" for j in 1:size(Rm, 2)])
    g = [SimLev.Bootstrap._fit_garch11(Rm[:, j]; quiet = true) for j in 1:size(Rm, 2)]
    Z = reduce(hcat, [_fvec(_el(gi, "z")) for gi in g])
    flat = [nm[j] for j in 1:size(Z, 2) if SimLev.r_sd(Z[:, j]) == 0]
    isempty(flat) || error("dependence_dcc: Reihe $(join(["'$f'" for f in flat], ", ")) ist konstant; keine Korrelation schätzbar.")
    Qb = _cormat(Z)
    ev = _fvec(_el(_flex(SimLev.RLinalg.eigen, (Qb,), NamedTuple(), (symmetric = true, only_values = true)), "values"))
    if _rmin(ev) < 1e-8
        C0 = copy(Qb)
        for i in 1:size(C0, 1)
            C0[i, i] = 0.0
        end
        ab = abs.(C0)
        mx = _rmax(ab)
        ci = CartesianIndices(ab)[findfirst(==(mx), vec(ab))]
        i0, j0 = ci[1], ci[2]
        error("dependence_dcc: Korrelationsmatrix der standardisierten Residuen ist singulär (z. B. '$(nm[i0])' und '$(nm[j0])': " *
              "Korrelation $(_sprintf("%.6f", Qb[i0, j0]))); DCC nicht schätzbar. Doppelte bzw. linear abhängige Reihen entfernen.")
    end
    par(th) = (s = 0.999 * _plogis(th[1]); a = s * _plogis(th[2]); (a, s - a))
    f(th) = (p = par(th); SimLev.DependenceCore.dcc_filter(Z, p[1], p[2], Qb, false)["nll"])
    st = [_qlogis(0.98 / 0.999), _qlogis(0.03 / 0.98)]
    opar, oval = _optim_nm(st, f, 2000, 1e-10)
    a, b = par(opar)
    fl = SimLev.DependenceCore.dcc_filter(Z, a, b, Qb, true)
    fl["ok"] === true || error("dependence_dcc: bedingte Korrelationsmatrix nicht positiv definit; DCC nicht schätzbar.")
    pn = ["$(nm[i]) ~ $(nm[j])" for (i, j) in _combn2(length(nm))]
    C = NamedMat(fl["R"]; colnames = pn)
    garch = RFrame("series" => nm, "alpha" => Float64[_el(gi, "alpha") for gi in g],
                   "beta" => Float64[_el(gi, "beta") for gi in g], "method" => String[string(_el(gi, "method")) for gi in g])
    RList("a" => a, "b" => b, "loglik" => -oval, "correlation" => C, "pairs" => pn, "garch" => garch, "z" => Z, "Qbar" => Qb)
end

# ═════════════════════════════════════════════════════════════════════════════
# Bedingte Analyse
# ═════════════════════════════════════════════════════════════════════════════

"""
    _dep_regimes(cv, breaks = nothing, n_regimes = 3) -> (code, labels, breaks)

Regime aus einer Zustandsvariable (`.dep_regimes`): Kategorien-Codes (1..; 0 = NA),
Beschriftungen und Grenzen.
"""
function _dep_regimes(cv, breaks = nothing, n_regimes = 3)
    cv = _fvec(cv)
    if breaks === nothing
        qs = _quantile(cv, _seq_len_out(0.0, 1.0, Int(n_regimes) + 1); na_rm = true)
        inner = qs[2:end-1]
        u = sort(unique(filter(isfinite, cv)))
        br = Float64[]
        if length(u) >= 2 && !isempty(inner)
            u1 = u[2:end]
            b = Float64[]
            for q in inner
                w = findfirst(>=(q), u1)
                push!(b, w === nothing ? _NA : u1[w])
            end
            vals = [inner[i] > u[1] ? inner[i] : b[i] for i in eachindex(inner)]
            seen = Any[]
            for (i, bi) in enumerate(b)
                key = isnan(bi) ? "NA" : bi
                key in seen && continue
                push!(seen, key)
                push!(br, vals[i])
            end
        end
        breaks = vcat([-Inf], br, [Inf])
    else
        breaks = _fvec(breaks)
    end
    lab = String[]
    for i in 1:(length(breaks)-1)
        a, b = breaks[i], breaks[i+1]
        if !isfinite(a)
            push!(lab, "< $(_signif_str(b))")
        elseif !isfinite(b)
            push!(lab, ">= $(_signif_str(a))")
        else
            push!(lab, "$(_signif_str(a)) bis $(_signif_str(b))")
        end
    end
    length(unique(breaks)) < length(breaks) && error("'breaks' are not unique")
    code = _bincode(cv, sort(breaks); right = false)
    code, lab, breaks
end

"""
    _dep_reg_cor(X, reg, nlev, pairs; rank = false)

Korrelationen je Regime (Codes `reg` = 1..nlev) für alle Paare → Matrix Paare × Regime.
"""
function _dep_reg_cor(X, reg, nlev::Integer, pairs; rank::Bool = false)
    X = _fmat(X)
    out = fill(_NA, length(pairs), nlev)
    for li in 1:nlev
        s = findall(==(li), reg)
        length(s) < 10 && continue
        Y = X[s, :]
        if rank
            Y = reduce(hcat, [_rank_avg(Y[:, j]) for j in 1:size(Y, 2)])
        end
        C = _quietly(() -> _cormat(Y))
        for (p, (i, j)) in enumerate(pairs)
            out[p, li] = C[i, j]
        end
    end
    out
end

"`do.call(rbind, <Liste von RFrames>)` (gleiche Spalten)."
function _rbind(dfs; rownames = nothing)
    isempty(dfs) && return nothing
    nms = names(dfs[1])
    cols = Pair{String,Any}[]
    for k in nms
        push!(cols, k => reduce(vcat, [collect(df[k]) for df in dfs]))
    end
    RFrame(cols...; rownames = rownames, nrow = sum(SimLev.nrow, dfs))
end

function _rbind_named(dfs, nms)
    rn = String[]
    for (nm, df) in zip(nms, dfs)
        if SimLev.nrow(df) == 1
            push!(rn, nm)
        else
            append!(rn, ["$nm.$k" for k in 1:SimLev.nrow(df)])
        end
    end
    _rbind(dfs; rownames = rn)
end

_sub1(a) = isempty(a) ? _NA : Float64(a[1])

function _pval(dd)
    dd = filter(isfinite, _fvec(dd))
    isempty(dd) && return NaN
    a = SimLev.r_mean_int(Int.(dd .<= 0))
    b = SimLev.r_mean_int(Int.(dd .>= 0))
    _rmin(1.0, 2 * _rmin(a, b))
end

"""
    dependence_analysis(data, assets; conditions = nothing, frequency = "week",
                        quantiles = [0.05, 0.10], breaks = nothing, n_regimes = 3,
                        window = nothing, dcc = true, copulas = true, B = 499,
                        block = nothing, tail_q = 0.10, seed = nothing)

Abhängigkeitsanalyse mit Tail-Risiko und Drittvariablen (Klasse `SimLevDependence`).
`breaks`: Dict/NamedTuple/RList mit Grenzen je Zustandsvariable.
"""
function dependence_analysis(data, assets; conditions = nothing, frequency = ("week", "day", "month"),
                             quantiles = [0.05, 0.10], breaks = nothing, n_regimes = 3, window = nothing,
                             dcc::Bool = true, copulas::Bool = true, B = 499, block = nothing, tail_q = 0.10,
                             seed = nothing)
    data = SimLev.as_rframe(data)
    frequency = _match_arg(frequency, ("week", "day", "month"))
    assets = _as_names(assets)
    length(assets) < 2 && error("dependence_analysis: mindestens zwei Anlagen.")
    conditions = conditions === nothing ? nothing : _as_names(conditions)
    rd = _dep_returns(data, assets, conditions, frequency)
    X = reduce(hcat, [_fvec(rd[a]) for a in assets])
    n = size(X, 1)
    n < 30 && error("dependence_analysis: nur $n Perioden.")
    dd = _days(rd["date"])
    ppy = (n - 1) / ((dd[n] - dd[1]) / 365.25)
    window === nothing && (window = max(10.0, _r_round(ppy)))
    quantiles = _fvec(quantiles)
    pear = _cormat(X); spear = _cormat(X; method = "spearman"); kend = _fmat(_kendall(X))
    nmat(M) = NamedMat(M; rownames = assets, colnames = assets)
    cors = RList("pearson" => nmat(pear), "spearman" => nmat(spear), "kendall" => nmat(kend))
    pidx = _combn2(length(assets))
    pn = ["$(assets[i]) ~ $(assets[j])" for (i, j) in pidx]
    tails = RFrame[]
    for (k, (i, j)) in enumerate(pidx)
        td = tail_dependence(X[:, i], X[:, j], quantiles)
        push!(tails, RFrame(vcat(["pair"], names(td)), vcat(Any[fill(pn[k], SimLev.nrow(td))], Any[td[c] for c in names(td)])))
    end
    cops = nothing
    if copulas
        cops = RList()
        for (k, (i, j)) in enumerate(pidx)
            cops[pn[k]] = copula_fit(X[:, i], X[:, j])
        end
    end
    ptab = RFrame("pair" => pn, "pearson" => [pear[i, j] for (i, j) in pidx], "spearman" => [spear[i, j] for (i, j) in pidx],
                  "kendall" => [kend[i, j] for (i, j) in pidx])
    for q in quantiles
        qn = _sprintf("%g", q)
        ptab["lambda_lower_" * qn] = Float64[t["lower"][findfirst(==(q), t["q"])] for t in tails]
        ptab["lambda_upper_" * qn] = Float64[t["upper"][findfirst(==(q), t["q"])] for t in tails]
    end
    if cops !== nothing
        cl = collect(values(cops))
        ptab["copula"] = String[c["family"][1] for c in cl]
        ptab["copula_lambda_lower"] = Float64[c["lambda_lower"][1] for c in cl]
        ptab["copula_lambda_upper"] = Float64[c["lambda_upper"][1] for c in cl]
        ptab["t_rho"] = Float64[c["par1"][findfirst(==("t"), c["family"])] for c in cl]
        ptab["t_nu"] = Float64[c["par2"][findfirst(==("t"), c["family"])] for c in cl]
    end
    roll = nothing
    if n > window
        roll = RFrame("date" => collect(rd["date"]))
        for (k, (i, j)) in enumerate(pidx)
            x = X[:, i]; y = X[:, j]
            cv = _roll_cov(x, y, window); vx = _roll_var(x, window); vy = _roll_var(y, window)
            roll[pn[k]] = cv ./ sqrt.(_pmax(vx .* vy, 1e-300))
        end
    end
    dc = nothing
    if dcc && n >= 100
        dc = try
            dependence_dcc(NamedMat(X; colnames = assets))
        catch e
            e isa InterruptException && rethrow()
            message("DCC nicht geschätzt: " * _errmsg(e))
            nothing
        end
    end
    cond = diffs = regimes = nothing
    diff_names = String[]
    if conditions !== nothing && !isempty(conditions)
        if block === nothing
            bl = Float64[]
            for (i, j) in pidx
                x = _scale1(X[:, i]); y = _scale1(X[:, j])
                push!(bl, _pw_block_stationary(x .* y))
            end
            block = _rmin(_rmax(2.0, _rmax(bl)), n / 10)
        end
        cond = RList(); diffs = RFrame[]; regimes = RList()
        for cn in conditions
            cv = _fvec(rd[cn])
            keep = findall(isfinite, cv)
            if length(keep) < 30
                @warn "Zustand '$cn': zu wenige Beobachtungen."
                continue
            end
            code, lv, _ = _dep_regimes(cv[keep], _getopt(breaks, cn), n_regimes)
            Xk = X[keep, :]
            cvk = cv[keep]
            nlv = length(lv)
            nna = count(==(0), code)
            ms = Float64[SimLev.r_mean(vcat(cvk[code .== li], fill(_NA, nna))) for li in 1:nlv]
            regimes[cn] = RFrame("regime" => lv, "n" => Int[count(==(li), code) for li in 1:nlv], "mean_state" => ms;
                                 rownames = lv)
            rows = Dict{String,Any}[]
            for (k, (i, j)) in enumerate(pidx), (li, l) in enumerate(lv)
                s = findall(==(li), code)
                x = Xk[s, i]; y = Xk[s, j]
                td = length(s) >= 20 ? tail_dependence(x, y, tail_q) : nothing
                kt = length(s) >= 2 ? _kendall(x, y) : _NA
                fams = (length(s) >= 2 && kt < 0) ? ["t", "gaussian", "clayton_90", "clayton_270"] :
                                                     ["t", "gaussian", "clayton", "gumbel"]
                tc = nothing
                if copulas && length(s) >= 40
                    tc = try
                        copula_fit(x, y, fams)
                    catch e
                        e isa InterruptException && rethrow()
                        nothing
                    end
                end
                ti = tc === nothing ? nothing : findfirst(==("t"), tc["family"])
                push!(rows, Dict{String,Any}(
                    "pair" => pn[k], "regime" => l, "n" => length(s),
                    "vol_1" => SimLev.r_sd(x) * sqrt(ppy), "vol_2" => SimLev.r_sd(y) * sqrt(ppy),
                    "pearson" => length(s) >= 10 ? _cor1(x, y) : _NA,
                    "spearman" => length(s) >= 10 ? _cor1(x, y; method = "spearman") : _NA,
                    "kendall" => length(s) >= 10 ? _kendall(x, y) : _NA,
                    "lambda_lower" => td !== nothing ? td["lower"][1] : _NA,
                    "lambda_upper" => td !== nothing ? td["upper"][1] : _NA,
                    "exceed_lower" => td !== nothing ? td["exceed_lower"][1] : _NA,
                    "t_rho" => ti !== nothing ? tc["par1"][ti] : _NA,
                    "t_nu" => ti !== nothing ? tc["par2"][ti] : _NA,
                    "copula" => tc !== nothing ? tc["family"][1] : missing,
                    "copula_lambda_lower" => tc !== nothing ? tc["lambda_lower"][1] : _NA))
            end
            cnames = ["pair", "regime", "n", "vol_1", "vol_2", "pearson", "spearman", "kendall", "lambda_lower",
                      "lambda_upper", "exceed_lower", "t_rho", "t_nu", "copula", "copula_lambda_lower"]
            ct = RFrame((c => (c == "copula" ? Union{Missing,String}[r[c] for r in rows] :
                               c in ("pair", "regime") ? String[r[c] for r in rows] :
                               c == "n" ? Int[r[c] for r in rows] : Float64[r[c] for r in rows]) for c in cnames)...)
            if B > 0 && nlv >= 2
                nk = size(Xk, 1)
                boot = _with_rng_restore(seed) do
                    res = Any[]
                    for _b in 1:Int(B)
                        idx = _boot_idx_stationary(nk, nk, block)
                        Xb = Xk[idx, :]; rb = code[idx]
                        push!(res, (_dep_reg_cor(Xb, rb, nlv, pidx), _dep_reg_cor(Xb, rb, nlv, pidx; rank = true)))
                    end
                    res
                end
                bp = cat([b[1] for b in boot]...; dims = 3)
                bs = cat([b[2] for b in boot]...; dims = 3)
                nr = SimLev.nrow(ct)
                hi_ = fill(_NA, nr); lo_ = fill(_NA, nr)
                for r in 1:nr
                    i = findfirst(==(ct["pair"][r]), pn); j = findfirst(==(ct["regime"][r]), lv)
                    qv = _quantile(bp[i, j, :], [0.05, 0.95]; na_rm = true)
                    lo_[r] = qv[1]; hi_[r] = qv[2]
                end
                ct["pearson_hi"] = hi_
                ct["pearson_lo"] = lo_
                last = lv[end]; first_ = lv[1]
                dl = RFrame[]
                for i in eachindex(pn)
                    mp = ct["pair"] .== pn[i]
                    est_p = _sub1(ct["pearson"][mp .& (ct["regime"] .== last)]) - _sub1(ct["pearson"][mp .& (ct["regime"] .== first_)])
                    est_s = _sub1(ct["spearman"][mp .& (ct["regime"] .== last)]) - _sub1(ct["spearman"][mp .& (ct["regime"] .== first_)])
                    dp = bp[i, nlv, :] .- bp[i, 1, :]
                    ds = bs[i, nlv, :] .- bs[i, 1, :]
                    push!(dl, RFrame("pair" => [pn[i]], "condition" => [cn], "from" => [first_], "to" => [last],
                                     "diff_pearson" => [est_p], "lo_pearson" => [_q1(dp, 0.025; na_rm = true)],
                                     "hi_pearson" => [_q1(dp, 0.975; na_rm = true)], "p_pearson" => [_pval(dp)],
                                     "diff_spearman" => [est_s], "lo_spearman" => [_q1(ds, 0.025; na_rm = true)],
                                     "hi_spearman" => [_q1(ds, 0.975; na_rm = true)], "p_spearman" => [_pval(ds)]))
                end
                push!(diffs, _rbind(dl))
                push!(diff_names, cn)
            end
            cond[cn] = ct
        end
    end
    out = RList(; class = ["SimLevDependence"])
    out["returns"] = rd
    out["assets"] = assets
    out["conditions"] = conditions
    out["frequency"] = frequency
    out["ppy"] = ppy
    out["correlation"] = cors
    out["pairs"] = ptab
    out["tail"] = _rbind(tails)
    out["copulas"] = cops
    out["rolling"] = roll
    out["window"] = window
    out["dcc"] = dc
    out["conditional"] = cond
    out["regimes"] = regimes
    out["differences"] = (diffs === nothing || isempty(diffs)) ? nothing : _rbind_named(diffs, diff_names)
    out["block"] = block
    out["B"] = B
    out["tail_q"] = tail_q
    out
end

# ── Druck ────────────────────────────────────────────────────────────────

"Matrix mit dimnames wie `print(m)` (über RFmt)."
function _print_matrix(M, rn, cn)
    s = _flex(SimLev.RFmt.print_matrix, (NamedMat(M; rownames = rn, colnames = cn),))
    String(s)
end
"data.frame wie `print(df, row.names = FALSE)` (über RFmt)."
_print_df(df; types = nothing) = String(types === nothing ?
    SimLev.RFmt.print_data_frame(df; row_names = false) : SimLev.RFmt.print_data_frame(df; row_names = false, types = types))

_ln(io, s) = (print(io, s); endswith(s, "\n") || print(io, "\n"))

function _print_dependence(io::IO, x)
    rd = x["returns"]
    d = rd["date"]; nr = SimLev.nrow(rd)
    print(io, "SimLev Abhängigkeitsanalyse: $nr Perioden ($(x["frequency"])), $(_date_str(d[1])) bis $(_date_str(d[nr]))\n\n")
    print(io, "Korrelation (Pearson unten links, Kendall oben rechts)\n")
    P = x["correlation"]["pearson"]; K = _fmat(x["correlation"]["kendall"])
    M = _fmat(P)
    for j in 1:size(M, 2), i in 1:(j-1)
        M[i, j] = K[i, j]
    end
    _ln(io, _print_matrix(_r_round(M, 3), P.rownames, P.colnames))
    p = x["pairs"]
    print(io, "\nTail-Abhängigkeit je Paar\n")
    qs = [c for c in names(p) if startswith(c, "lambda_lower_")]
    y = RFrame("Paar" => collect(p["pair"]), "Kendall" => _sprintf_vec("%.3f", _fvec(p["kendall"])))
    for k in qs
        q = k[length("lambda_lower_")+1:end]
        y["lamL $q"] = _sprintf_vec("%.2f", _fvec(p[k]))
        y["lamU $q"] = _sprintf_vec("%.2f", _fvec(p[replace(k, "lower" => "upper"; count = 1)]))
    end
    if haskey(p, "copula")
        y["Copula"] = collect(p["copula"])
        y["Cop. lamL"] = _sprintf_vec("%.2f", _fvec(p["copula_lambda_lower"]))
        y["Cop. lamU"] = _sprintf_vec("%.2f", _fvec(p["copula_lambda_upper"]))
        y["t: rho/nu"] = _sprintf_vec("%.2f / %.1f", _fvec(p["t_rho"]), _fvec(p["t_nu"]))
    end
    _ln(io, _print_df(y))
    print(io, "  (Unabhängigkeit: lam(q) ~ q; Gauß-Abhängigkeit: lam -> 0 für kleine q)\n")
    dc = x["dcc"]
    if dc !== nothing
        C = _fmat(dc["correlation"])
        last = C[size(C, 1), :]
        txt = join(_sprintf_vec("%s %.2f", collect(dc["pairs"]), last), ", ")
        print(io, "\n" * _sprintf("DCC(1,1): a = %.4f, b = %.4f (Persistenz %.4f); Korrelation zuletzt: %s",
                                  dc["a"], dc["b"], dc["a"] + dc["b"], txt) * "\n")
    end
    diffs = x["differences"]
    cnd = x["conditional"]
    if cnd !== nothing
        for cn in keys(cnd)
            ct = cnd[cn]
            print(io, "\nBedingt auf '$cn' (Zustand am Ende der Vorperiode)\n")
            z = RFrame("Paar" => collect(ct["pair"]), "Regime" => collect(ct["regime"]), "n" => collect(ct["n"]),
                       "Pearson" => _sprintf_vec("%.2f", _fvec(ct["pearson"])))
            z["90%-KI"] = haskey(ct, "pearson_lo") ? _sprintf_vec("[%.2f, %.2f]", _fvec(ct["pearson_lo"]), _fvec(ct["pearson_hi"])) :
                                                     fill("", SimLev.nrow(ct))
            z["Kendall"] = _sprintf_vec("%.2f", _fvec(ct["kendall"]))
            z["lamL $(_sprintf("%g", x["tail_q"]))"] = _sprintf_vec("%.2f", _fvec(ct["lambda_lower"]))
            z["t-rho"] = _sprintf_vec("%.2f", _fvec(ct["t_rho"]))
            z["Copula"] = collect(ct["copula"])
            _ln(io, _print_df(z; types = Dict("Copula" => "character")))
            if diffs !== nothing
                for r in findall(==(cn), diffs["condition"])
                    print(io, _sprintf("  %s: Pearson %s -> %s: %+.2f [%+.2f, %+.2f], p = %.3f; Spearman %+.2f, p = %.3f",
                                       diffs["pair"][r], diffs["from"][r], diffs["to"][r], diffs["diff_pearson"][r],
                                       diffs["lo_pearson"][r], diffs["hi_pearson"][r], diffs["p_pearson"][r],
                                       diffs["diff_spearman"][r], diffs["p_spearman"][r]) * "\n")
                end
            end
        end
    end
    if diffs !== nothing
        print(io, _sprintf("  (stationärer Block-Bootstrap, B = %d, mittlere Blocklänge %.1f Perioden)", Int(x["B"]),
                           Float64(x["block"])) * "\n")
    end
    nothing
end

# ═════════════════════════════════════════════════════════════════════════════
# Quantilsregression, Tail-Regression, CoVaR
# ═════════════════════════════════════════════════════════════════════════════

function _qr_rank_pivot_coef(Xm, y)
    qx = _flex(SimLev.RLinalg.qr, (Xm,))
    rank = Int(_el(qx, "rank"))
    piv = Int.(_fvec(_el(qx, "pivot")))
    qx, rank, piv
end
_qr_coef(qx, y) = _fvec(SimLev.RLinalg.qr_coef(qx, _fvec(y)))

_is_numcol(c) = eltype(c) <: Union{Missing,Real} && !(eltype(c) <: Union{Missing,Bool}) && !(eltype(c) === Missing) ||
                (eltype(c) === Any && all(v -> v === missing || (v isa Real && !(v isa Bool)), c))
_is_numeric(x) = x isa Real && !(x isa Bool) || (x isa AbstractArray && _is_numcol(x isa NamedMat ? x.data : vec(x)))

"""
    quantile_regression(y, X = nothing, tau = 0.5; intercept = true, tol = 1e-10, maxit = 2000)

Lineare Quantilsregression (exakte Lösung mit Optimalitätsnachweis). `X`:
Vektor, Matrix, `NamedMat` oder `RFrame` (ohne Konstante); `nothing` = nur
Konstante. Ergebnis: benannter Vektor der Koeffizienten.
"""
function quantile_regression(y, X_pos = nothing, tau_pos = 0.5; X = X_pos, tau = tau_pos, intercept::Bool = true, tol = 1e-10, maxit = 2000)
    tv = tau isa AbstractVector || tau isa Tuple ? collect(tau) : [tau]
    if length(tv) != 1 || !(tv[1] isa Real) || tv[1] isa Bool || !isfinite(Float64(tv[1])) || tv[1] <= 0 || tv[1] >= 1
        error("quantile_regression: tau muss eine Zahl echt zwischen 0 und 1 sein (erhalten: $(_fmt1(tau))).")
    end
    tau = Float64(tv[1])
    _is_numeric(y isa RVector ? y.values : y) || error("quantile_regression: y muss numerisch sein.")
    y = _fvec(y)
    if X isa RFrame
        nn = [k for k in names(X) if !_is_numcol(X[k])]
        isempty(nn) || error("quantile_regression: Spalte(n) $(join(["'$c'" for c in nn], ", ")) von X nicht numerisch " *
                             "(Faktoren vorher z. B. mit model.matrix() in Indikatorspalten umwandeln).")
    end
    if X === nothing
        Xm = zeros(length(y), 0); nm = String[]
    else
        X isa RFrame || _is_numeric(X) || error("quantile_regression: X muss numerisch sein.")
        Xm, nm = _as_matrix(X)
        size(Xm, 1) != length(y) && error("quantile_regression: X hat $(size(Xm, 1)) Zeilen, y aber $(length(y)) Werte.")
        nm === nothing && (nm = ["x$j" for j in 1:size(Xm, 2)])
    end
    if intercept
        Xm = hcat(ones(length(y)), Xm)
        nm = vcat(["(Intercept)"], nm)
    end
    ok = [isfinite(y[i]) && all(isfinite, view(Xm, i, :)) for i in eachindex(y)]
    y = y[ok]; Xm = Xm[ok, :]
    p = size(Xm, 2)
    p == 0 && error("quantile_regression: keine Regressoren (X = NULL und intercept = FALSE).")
    length(y) < p && error("quantile_regression: $(length(y)) vollständige Beobachtungen für $p Koeffizienten.")
    qx, rank, piv = _qr_rank_pivot_coef(Xm, y)
    if rank < p
        bad = [nm[k] for k in piv[(rank+1):p]]
        error("quantile_regression: Regressoren linear abhängig ($(join(["'$b'" for b in bad], ", "))); doppelte oder konstante " *
              "Spalten entfernen (die Konstante ist bei intercept = TRUE schon enthalten).")
    end
    beta = _qr_coef(qx, y)
    sc = _rmax(SimLev.r_sd(y), 1e-12)
    beta, opt = SimLev.DependenceCore.quantile_reg_core(y, Xm, tau, beta, sc, Float64(tol), Int(maxit))
    opt === true || @warn "quantile_regression: Optimalität nicht nachgewiesen; Ergebnis ist eine Ecke mit nicht größerem " *
                          "Zielwert als die MM-Näherung (bzw. die MM-Näherung selbst, falls keine solche Ecke gefunden wurde)."
    RVector(beta; names = nm)
end

"`coef(lm(y ~ X))` mit Konstante in `X1` (lm.fit und qr.coef rechnen mit LINPACK dieselben Schritte)."
function _lm_coef(y, X1)
    qx = _flex(SimLev.RLinalg.qr, (X1,))
    _qr_coef(qx, y)
end

"""
    tail_regression(data, asset, drivers; quantiles = [0.05, 0.25, 0.5, 0.75, 0.95],
                    frequency = "week", B = 199, block = nothing, seed = nothing)

Renditequantile in Abhängigkeit von Drittvariablen (Klasse `SimLevTailRegression`).
"""
function tail_regression(data, asset, drivers; quantiles = [0.05, 0.25, 0.5, 0.75, 0.95],
                         frequency = ("week", "day", "month"), B = 199, block = nothing, seed = nothing)
    data = SimLev.as_rframe(data)
    frequency = _match_arg(frequency, ("week", "day", "month"))
    asset = String(asset)
    drivers = _as_names(drivers)
    quantiles = _fvec(quantiles)
    rd = _dep_returns(data, [asset], drivers, frequency)
    ok = _complete_rows((rd[c] for c in vcat([asset], drivers))...)
    all(ok) || (rd = SimLev.rows(rd, findall(ok)))
    y = 100 .* _fvec(rd[asset])
    X = isempty(drivers) ? zeros(length(y), 0) : reduce(hcat, [_fvec(rd[c]) for c in drivers])
    n = length(y)
    n < 30 && error("tail_regression: zu wenige Perioden.")
    p = size(X, 2) + 1
    XN = NamedMat(X; colnames = drivers)
    est = reduce(hcat, [_fvec(quantile_regression(y, XN, q)) for q in quantiles])
    est = reshape(est, p, length(quantiles))
    X1 = hcat(ones(n), X)
    terms = vcat(["(Intercept)"], drivers)
    nq = length(quantiles)
    se = fill(_NA, p, nq); lo = fill(_NA, p, nq); hi = fill(_NA, p, nq)
    n_failed = 0
    if B > 0
        block === nothing && (block = _rmin(_rmax(2.0, _pw_block_stationary(abs.(y .- SimLev.r_mean(y)))), n / 10))
        bs = _with_rng_restore(seed) do
            res = Matrix{Float64}[]
            for _b in 1:Int(B)
                idx = _boot_idx_stationary(n, n, block)
                yb = y[idx]; Xb = X1[idx, :]
                m = try
                    reduce(hcat, [SimLev.DependenceCore.quantile_reg_core(yb, Xb, quantiles[k], est[:, k],
                                                                         _rmax(SimLev.r_sd(yb), 1e-12), 1e-10, 2000)[1]
                                  for k in 1:nq])
                catch e
                    e isa SimLev.DependenceCore.QuantileRegError || rethrow()
                    fill(_NA, p, nq)
                end
                push!(res, reshape(m, p, nq))
            end
            res
        end
        n_failed = count(a -> any(isnan, a), bs)
        if n_failed == B
            @warn "tail_regression: keine der $(Int(B)) Bootstrap-Stichproben schätzbar (singuläre Regressoren); keine Standardfehler."
        elseif n_failed > 0
            @warn "tail_regression: $n_failed von $(Int(B)) Bootstrap-Stichproben nicht schätzbar (singuläre Regressoren, z. B. " *
                  "Treiber in der Stichprobe konstant); Standardfehler und Intervalle aus den übrigen $(Int(B) - n_failed)."
        end
        for i in 1:p, j in 1:nq
            v = Float64[a[i, j] for a in bs]
            se[i, j] = SimLev.r_sd(v; na_rm = true)
            lo[i, j] = _q1(v, 0.05; na_rm = true)
            hi[i, j] = _q1(v, 0.95; na_rm = true)
        end
    end
    coefs = RFrame("quantile" => repeat(quantiles; inner = length(terms)), "term" => repeat(terms, nq),
                   "estimate" => vec(est), "se" => vec(se), "lower" => vec(lo), "upper" => vec(hi))
    ols = RVector(_lm_coef(y, X1); names = terms)
    out = RList(; class = ["SimLevTailRegression"])
    out["coefficients"] = coefs
    out["ols"] = ols
    out["asset"] = asset
    out["drivers"] = drivers
    out["quantiles"] = quantiles
    out["n"] = n
    out["frequency"] = frequency
    out["B"] = B
    out["B_failed"] = n_failed
    out["block"] = block
    out["data"] = rd
    out
end

function _print_tail_regression(io::IO, x)
    fr = Dict("week" => "Woche", "day" => "Tag", "month" => "Monat")[x["frequency"]]
    print(io, "Quantilsregression: Rendite '$(x["asset"])' (% je $fr) auf verzögerte $(join(x["drivers"], ", ")); " *
              "$(Int(x["n"])) Perioden\n\n")
    cf = x["coefficients"]
    se = _fvec(cf["se"]); lo = _fvec(cf["lower"]); up = _fvec(cf["upper"])
    y = RFrame("Quantil" => _sprintf_vec("%g %%", 100 .* _fvec(cf["quantile"])), "Term" => collect(cf["term"]),
               "Koeffizient" => _sprintf_vec("%.4f", _fvec(cf["estimate"])),
               "SE" => [isnan(s) ? "" : _sprintf("%.4f", s) for s in se],
               "90%-KI" => [isnan(a) ? "" : _sprintf("[%.4f, %.4f]", a, b) for (a, b) in zip(lo, up)])
    _ln(io, _print_df(y))
    ols = x["ols"]
    print(io, "\nOLS (Mittelwert): $(join(_sprintf_vec("%s %.4f", ols.names, ols.values), ", "))\n")
    nothing
end

"""
    tail_covar(data, system, assets; state = nothing, q = 0.05, frequency = "week")

CoVaR und Delta-CoVaR (Adrian & Brunnermeier 2016), Klasse `SimLevCoVaR`.
"""
function tail_covar(data, system, assets; state = nothing, q = 0.05, frequency = ("week", "day", "month"))
    data = SimLev.as_rframe(data)
    frequency = _match_arg(frequency, ("week", "day", "month"))
    system = String(system)
    assets = _as_names(assets)
    state = state === nothing ? nothing : _as_names(state)
    cols = unique(vcat([system], assets))
    rd = _dep_returns(data, cols, state, frequency)
    ok = _complete_rows((rd[c] for c in names(rd))...)
    rd = SimLev.rows(rd, findall(ok))
    nr = SimLev.nrow(rd)
    M = state === nothing || isempty(state) ? nothing : reduce(hcat, [_fvec(rd[c]) for c in state])
    MN = M === nothing ? nothing : NamedMat(M; colnames = state)
    ys = 100 .* _fvec(rd[system])
    summ = RFrame[]; series = RFrame[]
    for a in assets
        xi = 100 .* _fvec(rd[a])
        bq = _fvec(quantile_regression(xi, MN, q)); bm = _fvec(quantile_regression(xi, MN, 0.5))
        Mi = M === nothing ? ones(nr, 1) : hcat(ones(nr), M)
        var_q = _matvec(Mi, bq); var_m = _matvec(Mi, bm)
        Xs = M === nothing ? NamedMat(reshape(xi, :, 1); colnames = ["xi"]) : NamedMat(hcat(xi, M); colnames = vcat(["xi"], state))
        bs = _fvec(quantile_regression(ys, Xs, q))
        covar = M !== nothing ? (bs[1] .+ bs[2] .* var_q) .+ _matvec(M, bs[3:end]) : (bs[1] .+ bs[2] .* var_q) .+ 0.0
        dcv = bs[2] .* (var_q .- var_m)
        push!(summ, RFrame("asset" => [a], "beta" => [bs[2]], "var" => [SimLev.r_mean(var_q)], "covar" => [SimLev.r_mean(covar)],
                           "delta_covar" => [SimLev.r_mean(dcv)], "delta_covar_min" => [_rmin(dcv)]))
        push!(series, RFrame("date" => collect(rd["date"]), "asset" => fill(a, nr), "var" => var_q, "covar" => covar,
                             "delta_covar" => dcv))
    end
    out = RList(; class = ["SimLevCoVaR"])
    out["summary"] = _rbind(summ)
    out["series"] = _rbind(series)
    out["system"] = system
    out["state"] = state
    out["q"] = q
    out["frequency"] = frequency
    out["n"] = nr
    out
end

function _print_covar(io::IO, x)
    st = x["state"]
    print(io, _sprintf("CoVaR (q = %g) für System '%s'%s; %d Perioden (%s), Werte in %% je Periode", x["q"], x["system"],
                       (st !== nothing && !isempty(st)) ? ", Zustand: $(join(st, ", "))" : "", Int(x["n"]), x["frequency"]) * "\n\n")
    s = x["summary"]
    y = RFrame("Anlage" => collect(s["asset"]), "beta" => _sprintf_vec("%.3f", _fvec(s["beta"])),
               "VaR Anlage" => _sprintf_vec("%.2f", _fvec(s["var"])), "CoVaR" => _sprintf_vec("%.2f", _fvec(s["covar"])),
               "Delta-CoVaR" => _sprintf_vec("%.2f", _fvec(s["delta_covar"])),
               "Delta-CoVaR min" => _sprintf_vec("%.2f", _fvec(s["delta_covar_min"])))
    _ln(io, _print_df(y))
    nothing
end

# ═════════════════════════════════════════════════════════════════════════════
# Bootstrap-Validierung und Stress-Regime
# ═════════════════════════════════════════════════════════════════════════════

"`rowsum(L[1:(k*agg), ], rep(1:k, each = agg))` (double-Akkumulation)."
function _rowsum_blocks(L, agg::Int, k::Int)
    L = _fmat(L)
    out = zeros(k, size(L, 2))
    for g in 1:k, j in 1:size(L, 2)
        s = 0.0
        for r in 1:agg
            s += L[(g-1)*agg+r, j]
        end
        out[g, j] = s
    end
    out
end

function _path_matrix(pth, idx_names)
    pth isa RFrame && return reduce(hcat, [_fvec(pth[a]) for a in idx_names])
    if pth isa NamedMat && pth.colnames !== nothing
        return reduce(hcat, [_fvec(pth[:, a]) for a in idx_names])
    end
    _fmat(pth)
end

"""
    dependence_validate(boot, data; agg = 5, q = 0.10, max_paths = 200)

Abhängigkeitsstruktur von Bootstrap-Pfaden (`bootstrap_result`) mit der
Historie vergleichen; `RFrame` mit `pair`, `metric`, `historical`, `median`,
`p05`, `p95`, `percentile`.
"""
function dependence_validate(boot, data; agg = 5, q = 0.10, max_paths = 200)
    data = SimLev.as_rframe(data)
    SimLev.inherits(boot, "bootstrap_result") || error("boot muss ein bootstrap_result sein.")
    cfg = boot["config"]
    idx_names = _as_names(_el(cfg, "index_names"))
    length(idx_names) < 2 && error("dependence_validate: mindestens zwei Indizes in der Konfiguration.")
    ret = _fmat(_el(SimLev.Bootstrap._extract_returns(data, cfg), "ret"))
    hist = SimLev.RLibm.log.(ret)
    agg = Int(agg)
    function aggr(L)
        k = div(size(L, 1), agg)
        k < 20 && error("Zu wenige Perioden nach Aggregation.")
        _rowsum_blocks(L, agg, k)
    end
    function stats_of(L)
        A = aggr(L)
        out = Float64[]
        for (i, j) in _combn2(size(A, 2))
            x = A[:, i]; y = A[:, j]
            td = tail_dependence(x, y, q)
            append!(out, [_kendall(x, y), _cor1(x, y), td["lower"][1], td["upper"][1], td["exceed_lower"][1]])
        end
        out
    end
    h = stats_of(hist)
    paths = collect(boot["paths"])
    paths = paths[1:min(length(paths), Int(max_paths))]
    cols = Vector{Float64}[]
    for pth in paths
        lg = SimLev.RLibm.log.(_path_matrix(pth, idx_names))
        push!(cols, stats_of(lg[2:end, :] .- lg[1:end-1, :]))
    end
    P = isempty(cols) ? zeros(length(h), 0) : reduce(hcat, cols)
    pr = ["$(idx_names[i]) ~ $(idx_names[j])" for (i, j) in _combn2(length(idx_names))]
    metrics = ["kendall", "pearson", "lambda_lower", "lambda_upper", "exceed_lower"]
    pct = Float64[]
    for i in eachindex(h)
        v = [Int(P[i, c] <= h[i]) for c in 1:size(P, 2) if !(isnan(P[i, c]) || isnan(h[i]))]
        push!(pct, SimLev.r_mean_int(v))
    end
    RFrame("pair" => repeat(pr; inner = 5), "metric" => repeat(metrics, length(pr)), "historical" => h,
           "median" => Float64[_median(P[i, :]; na_rm = true) for i in eachindex(h)],
           "p05" => Float64[_q1(P[i, :], 0.05; na_rm = true) for i in eachindex(h)],
           "p95" => Float64[_q1(P[i, :], 0.95; na_rm = true) for i in eachindex(h)],
           "percentile" => pct)
end

# ── Bedingungen als Text ─────────────────────────────────────────────────

"""
    _eval_condition(expr, data; env = Main)

Bedingung als Text über den Spalten von `data` auswerten (wie
`eval(parse(text = expr), data, parent.frame())` in R) mit dem gemeinsamen
Auswerter `SimLev.RExpr` (R-Syntax, Vorrang und NA-Logik wie in R); freie
Variablen aus `env`. Eine Julia-Funktion `f` wird als `f(data)` aufgerufen.
"""
function _eval_condition(expr, data; env = Main)
    expr isa Function && return expr(data)
    SimLev.RExpr.eval_r(String(expr), _as_frame(data); env = env)
end

"""
    regime_subset(data, condition; min_run = 1, env = Main)

Zeilen eines Regimes für Stress-Bootstraps. `condition`: logischer Vektor der
Länge `nrow(data)` (NA = FALSE) oder Ausdruck als Text in R-Syntax (z. B.
`"inflation >= 4 & zins < 2"`, siehe `_eval_condition`; freie Variablen aus
`env`). Ergebnis: Teilmenge von
`data`; `attrs(out)["episodes"]` mit `start`, `end`, `length` (und
`start_date`, `end_date`, falls `date` vorhanden).
"""
function regime_subset(data, condition; min_run = 1, env = Main)
    data = SimLev.as_rframe(data)
    data = _as_frame(data)
    cond = condition isa AbstractString ? SimLev.RExpr.as_logical(_eval_condition(condition, data; env = env)) :
           condition isa Function ? _eval_condition(condition, data; env = env) : condition
    cv = cond isa AbstractVector ? collect(cond) : [cond]
    c = Bool[(v === missing || v === nothing || (v isa AbstractFloat && isnan(v))) ? false : Bool(v != 0) for v in cv]
    length(c) != SimLev.nrow(data) && error("condition muss die Länge nrow(data) haben.")
    vals = Bool[]; lens = Int[]
    for v in c
        if !isempty(vals) && vals[end] == v
            lens[end] += 1
        else
            push!(vals, v); push!(lens, 1)
        end
    end
    ends = cumsum(lens); starts = ends .- lens .+ 1
    keep = vals .& (lens .>= min_run)
    any(keep) || error("regime_subset: keine Episode erfüllt condition und min_run.")
    idx = reduce(vcat, [collect(s:e) for (s, e) in zip(starts[keep], ends[keep])])
    out = SimLev.rows(data, idx)
    ep = RFrame("start" => starts[keep], "end" => ends[keep], "length" => lens[keep])
    if haskey(data, "date")
        d = collect(_to_date(data["date"], "regime_subset: data\$date"))
        ep["start_date"] = d[ep["start"]]
        ep["end_date"] = d[ep["end"]]
    end
    SimLev.attrs(out)["episodes"] = ep
    out
end

# ═════════════════════════════════════════════════════════════════════════════
# Grafiken (SVG)
# ═════════════════════════════════════════════════════════════════════════════

# Bausteine `_grid_*` (Stil Rastergrafiken) in svg.jl; nicht bitgleich zu R's Grafik,
# zeigen aber dieselben Daten. Die Zeichenfunktionen liefern `(svg, data)`.

"""
`plot.SimLevDependence` (SVG). Liefert `(svg, data)`; `data` je Panel: `rolling` (`date`, `rolling`
und mit DCC `dcc`), `tail` (`q`, `lower`, `upper`, `independence`), `conditional` (`regime`,
`pearson`, gegebenenfalls `pearson_lo`, `pearson_hi`, und `lambda_lower`), `scatter` (`u`, `v`).
Ohne rollierende Korrelation bzw. Drittvariable sind `rolling` bzw. `conditional` leer.
"""
function _plot_dependence(x; type = ("overview", "rolling", "tail", "conditional", "scatter"), pair = 1, condition = 1,
                          file = nothing, width = 900, height = 650)
    type = _match_arg(type, ("overview", "rolling", "tail", "conditional", "scatter"))
    pn = collect(x["pairs"]["pair"])
    i = pair isa AbstractString ? findfirst(==(pair), pn) : Int(pair)
    ab = split(pn[i], " ~ ")
    X = x["returns"]
    data = SimLev.RList()
    function p_roll(c, box)
        if x["rolling"] === nothing
            data["rolling"] = SimLev.RFrame("date" => Date[], "rolling" => Float64[])
            return
        end
        rl = x["rolling"]
        series = [(_days(rl["date"]), _fvec(rl[pn[i]]), "#2C6E9B", "rollierend")]
        d = SimLev.RFrame("date" => collect(Date, rl["date"]), "rolling" => copy(_fvec(rl[pn[i]])))
        if x["dcc"] !== nothing
            C = x["dcc"]["correlation"]
            push!(series, (_days(X["date"]), _fvec(C[:, pn[i]]), "#B5562B", "DCC"))
            d["dcc"] = copy(_fvec(C[:, pn[i]]))
        end
        data["rolling"] = d
        _grid_lines!(c, box, series; ylim = (-1.0, 1.0), hline = [(0.0, "grey")], dates = true,
                     title = "$(pn[i]): rollierend ($(Int(x["window"]))) und DCC", ylabel = "Korrelation")
    end
    function p_tail(c, box)
        qg = [0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5]
        td = tail_dependence(X[ab[1]], X[ab[2]], qg)
        lq = log10.(qg)
        series = [(lq, _fvec(td["lower"]), "#B5562B", "unten (gemeinsame Verluste)"),
                  (lq, _fvec(td["upper"]), "#2C6E9B", "oben (gemeinsame Gewinne)"),
                  (lq, qg, "#666666", "Unabhängigkeit")]
        hl = Tuple{Float64,String}[]
        if x["copulas"] !== nothing
            cp = x["copulas"][pn[i]]
            push!(hl, (cp["lambda_lower"][1], "#B5562B")); push!(hl, (cp["lambda_upper"][1], "#2C6E9B"))
        end
        _grid_lines!(c, box, series; ylim = (0.0, 1.0), hline = hl, points = true, xlabel = "Quantil q (log)",
                     title = "$(pn[i]): Tail-Abhängigkeit", xticks = [(log10(v), _sprintf("%g", v)) for v in (0.01, 0.05, 0.1, 0.5)])
        data["tail"] = SimLev.RFrame("q" => copy(qg), "lower" => copy(_fvec(td["lower"])), "upper" => copy(_fvec(td["upper"])),
                                     "independence" => copy(qg))
    end
    function p_cond(c, box)
        if x["conditional"] === nothing || length(x["conditional"]) == 0
            data["conditional"] = SimLev.RFrame("regime" => String[], "pearson" => Float64[], "lambda_lower" => Float64[])
            return
        end
        cn = condition isa AbstractString ? condition : collect(keys(x["conditional"]))[Int(condition)]
        ct = x["conditional"][cn]
        sel = findall(==(pn[i]), ct["pair"])
        lo = haskey(ct, "pearson_lo") ? _fvec(ct["pearson_lo"])[sel] : nothing
        hi = haskey(ct, "pearson_hi") ? _fvec(ct["pearson_hi"])[sel] : nothing
        _grid_bars!(c, box, collect(ct["regime"])[sel], _fvec(ct["pearson"])[sel]; lo = lo, hi = hi,
                    pts = _fvec(ct["lambda_lower"])[sel], ylim = (-1.0, 1.0), title = "$(pn[i]) nach '$cn'", ylabel = "Korrelation")
        d = SimLev.RFrame("regime" => String[string(v) for v in collect(ct["regime"])[sel]], "pearson" => _fvec(ct["pearson"])[sel])
        lo === nothing || (d["pearson_lo"] = lo)
        hi === nothing || (d["pearson_hi"] = hi)
        d["lambda_lower"] = _fvec(ct["lambda_lower"])[sel]
        data["conditional"] = d
    end
    function p_scatter(c, box)
        u = _pobs(X[ab[1]]); v = _pobs(X[ab[2]]); q = Float64(x["tail_q"])
        col = [(a <= q && b <= q) ? "#B5562B" : (a > 1 - q && b > 1 - q) ? "#2C6E9B" : "#A6A6A6" for (a, b) in zip(u, v)]
        _grid_scatter!(c, box, u, v, col; rects = [(0.0, 0.0, q, q, "#B5562B"), (1 - q, 1 - q, 1.0, 1.0, "#2C6E9B")],
                       xlabel = "Rang $(ab[1])", ylabel = "Rang $(ab[2])", title = "Pseudo-Beobachtungen")
        data["scatter"] = SimLev.RFrame("u" => collect(Float64, u), "v" => collect(Float64, v))
    end
    fns = Dict("rolling" => p_roll, "tail" => p_tail, "conditional" => p_cond, "scatter" => p_scatter)
    ks = type == "overview" ? ["rolling", "tail", "conditional", "scatter"] : [type]
    svg = _grid_svg(ks, k -> ((c, box) -> fns[k](c, box)); width = width, height = height).svg
    return (svg, data)
end

"""
`plot.SimLevTailRegression` (SVG). Liefert `(svg, data)`; `data` je Treiber (Schlüssel = Name des
Treibers): `quantile`, `estimate`, `lower`, `upper`.
"""
function _plot_tail_regression(x; file = nothing, width = 900, height = 400)
    drv = x["drivers"]
    data = SimLev.RList()
    svg = _grid_svg(collect(drv), dv -> function (c, box)
        cf = x["coefficients"]
        sel = findall(==(dv), cf["term"])
        qv = _fvec(cf["quantile"])[sel]; est = _fvec(cf["estimate"])[sel]
        lo = _fvec(cf["lower"])[sel]; hi = _fvec(cf["upper"])[sel]
        _grid_lines!(c, box, [(qv, est, "#2C6E9B", "Quantilsregression")]; band = all(isnan, lo) ? nothing : (qv, lo, hi),
                     hline = [(x["ols"][dv], "#B5562B"), (0.0, "grey")], points = true, xlabel = "Quantil",
                     ylabel = "Koeffizient", title = "$(x["asset"]): Effekt von $dv")
        data[String(dv)] = SimLev.RFrame("quantile" => qv, "estimate" => est, "lower" => lo, "upper" => hi)
    end; ncol = length(drv), width = width, height = height).svg
    return (svg, data)
end

"""
`plot.SimLevCoVaR` (SVG). Liefert `(svg, data)`; `data`: `delta_covar` (`asset`, `date`,
`delta_covar` in % je Periode wie in `series`; Zeilen je Anlage in Zeichenreihenfolge).
"""
function _plot_covar(x; file = nothing, width = 800, height = 450)
    s = x["series"]
    cols = ["#2C6E9B", "#B5562B", "#3E8E5A", "#8A5BA8", "#C49A2C"]
    a = unique(s["asset"])
    series = [(_days(s["date"][s["asset"] .== aj]), _fvec(s["delta_covar"])[s["asset"] .== aj], cols[(j-1)%5+1], aj)
              for (j, aj) in enumerate(a)]
    svg = _grid_svg(["x"], _ -> ((c, box) -> _grid_lines!(c, box, series; dates = true, ylabel = "Delta-CoVaR (%)",
                                                          title = _sprintf("Delta-CoVaR für '%s' (q = %g)", x["system"], x["q"])));
                    width = width, height = height).svg
    sa = String[string(v) for v in s["asset"]]
    data = SimLev.RList("delta_covar" => SimLev.RFrame(
        "asset" => vcat([sa[sa .== aj] for aj in a]...),
        "date" => vcat([collect(Date, s["date"])[sa .== aj] for aj in a]...),
        "delta_covar" => vcat([_fvec(s["delta_covar"])[sa .== aj] for aj in a]...)))
    return (svg, data)
end

function __init__()
    SimLev.register_print!("SimLevDependence", _print_dependence)
    SimLev.register_print!("SimLevTailRegression", _print_tail_regression)
    SimLev.register_print!("SimLevCoVaR", _print_covar)
    SimLev.register_plot!("SimLevDependence", SimLev._plot_method(_plot_dependence, "SimLevDependence"))
    SimLev.register_plot!("SimLevTailRegression", SimLev._plot_method(_plot_tail_regression, "SimLevTailRegression"))
    SimLev.register_plot!("SimLevCoVaR", SimLev._plot_method(_plot_covar, "SimLevCoVaR"))
end

end # module
