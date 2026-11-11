# Dependence – Gegenstück zu r/R/dependence.R und python/simlev/dependence.py
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
using ..SimLev: _match_arg   # util.jl (seit 1.6.1 eine Fassung)
using ..SimLev: _grid_bars!, _grid_lines!, _grid_scatter!, _grid_svg
using Dates

export copula_fit, tail_dependence, dependence_dcc, dependence_analysis, quantile_regression, tail_regression,
       tail_covar, dependence_validate, regime_subset

const _NA = SimLev.NA
const RFrame = SimLev.RFrame
const RList = SimLev.RList
const RVector = SimLev.RVector
const NamedMat = SimLev.NamedMat

# ═════════════════════════════════════════════════════════════════════════════
# Eingabeprüfung Abhängigkeit, Regime, Optimierung, Backcast, Szenarien (seit 1.6.4, K42 E4; Hilfen in
# pruefen.jl, Bausteine e4.* der Tabelle eingabe). Gegenstücke in dependence.R und dependence.py.
# ═════════════════════════════════════════════════════════════════════════════

using ..SimLev: chk_bool1, chk_cols, chk_col_nofactor, chk_df, chk_fmt, chk_int1, chk_max, chk_msg, chk_name1, chk_nofactor,
                chk_num1, chk_scalar, chk_stop


_e4_isfactor(@nospecialize(x)) = x isa SimLev.RFmt.RFactor
_e4_isna(@nospecialize(v)) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))
_e4_numscalar(@nospecialize(v)) = v isa Real && !(v isa Bool)
_e4_col(@nospecialize(data), nm) = data isa RFrame ? data[nm] : error("data")

"""Vektor nicht leerer Namen (Spalten) ohne NA und ohne doppelte, mindestens einer; mit `no_date` nicht `"date"` (R
`.e4_names`). Ergebnis als `Vector{String}`."""
function _e4_names(@nospecialize(x), fn, arg; null_ok::Bool = false, no_date::Bool = true)
    x === nothing && null_ok && return nothing
    chk_nofactor(x, fn, arg)                                   # Entscheidung 15
    v = x isa Union{AbstractString,Symbol} ? Any[x] : x isa Union{AbstractVector,Tuple} ? Any[e for e in x] : nothing
    (v === nothing || isempty(v) || !all(c -> (c isa AbstractString || c isa Symbol) && !isempty(string(c)), v)) &&
        chk_stop("e3.namen", fn, arg)
    out = String[string(c) for c in v]
    length(unique(out)) < length(out) && chk_stop("e2.doppelt", fn, arg)   # B-052
    no_date && "date" in out && chk_stop("e4.date", fn, arg)   # B-052, B-055
    return out
end

"""Numerischer Vektor (keine Matrix, Tabelle, kein Text, keine Wahrheitswerte, kein Faktor); NA erlaubt; eine
einzelne Zahl zählt als Vektor der Länge 1 (R `.e4_vec`)."""
function _e4_vec(@nospecialize(x), fn, arg)
    chk_nofactor(x, fn, arg)
    xv = x isa RVector ? x.values : x isa Tuple ? collect(Any, x) : x
    ok = _e4_numscalar(xv) || (xv isa AbstractVector && !(xv isa AbstractMatrix) && !isempty(xv) &&
                               all(v -> _e4_numscalar(v) || _e4_isna(v), xv) && any(_e4_numscalar, xv))
    ok || chk_stop("zahlen", fn, arg)
    return x
end

"""Zahlenspalte (kein Faktor, kein Text, keine Wahrheitswerte); eine Spalte nur aus NA gilt als Zahlenspalte
(Entscheidung 14; R `.e4_numcol`)."""
function _e4_numcol(@nospecialize(data), col, fn)
    v = _e4_col(data, col)
    v isa SimLev.RFmt.RFactor && chk_stop("spalte_faktor", fn, col)   # Entscheidung 15, B-009
    k, a = SimLev._column(v)
    k == :factor && chk_stop("spalte_faktor", fn, col)
    (k == :numeric || all(_e4_isna, a)) || chk_stop("spalte_typ", fn, col, chk_msg("typ.numerisch"))
    return data
end

"""Kursdaten: Tabelle (Entscheidung 6) mit Spalte `date` (kein Faktor) und den Zahlenspalten `cols` (R `.e4_data`;
B-015, B-040)."""
function _e4_data(@nospecialize(data), cols, fn)
    chk_df(data, fn, "data")
    chk_cols(data, vcat(["date"], collect(String, cols)), fn)
    chk_col_nofactor(data, "date", fn)
    for k in cols
        _e4_numcol(data, k, fn)
    end
    return data
end

"Keine gemeinsame Spalte in `a` und `b` (B-013; R `.e4_disjoint`)."
function _e4_disjoint(a, b, fn, arg_a, arg_b)
    (a === nothing || b === nothing) && return a
    isempty(intersect(a, b)) || chk_stop("e4.gemeinsam", fn, arg_a, arg_b)
    return a
end

"Anzahl: ganze Zahl ≥ lo, höchstens hi (Entscheidung 16 sinngemäß; R `.e4_count`). Ergebnis: Einzelwert."
function _e4_count(@nospecialize(x), fn, arg; lo = 1, hi = SimLev.SL_MAX_N, null_ok::Bool = false)
    x = chk_scalar(x)
    x === nothing && null_ok && return x
    chk_int1(x, fn, arg; lo = lo)
    chk_max(x, hi, fn, arg)
    return x
end

"Vektor von Anteilen echt zwischen 0 und 1 ohne doppelte Werte (B-054; R `.e4_probs`). Ergebnis: `Vector{Float64}`."
function _e4_probs(@nospecialize(x), fn, arg)
    chk_nofactor(x, fn, arg)
    xv = x isa RVector ? x.values : x isa Tuple ? collect(Any, x) : x
    ok = _e4_numscalar(xv) || (xv isa AbstractVector && !(xv isa AbstractMatrix) && !isempty(xv) && all(_e4_numscalar, xv))
    a = ok ? Float64[Float64(v) for v in (xv isa AbstractVector ? xv : [xv])] : Float64[]
    (ok && all(isfinite, a) && all(v -> 0 < v < 1, a) && length(unique(a)) == length(a)) || chk_stop("e4.anteile", fn, arg)
    return a
end

"""breaks: `nothing` oder nach Spalten aus `conditions` benannte Liste (Dict, NamedTuple, Paare) streng steigender
Zahlengrenzen ohne NA (Länge ≥ 2; B-014; R `.e4_breaks`)."""
function _e4_breaks(@nospecialize(breaks), conditions, fn)
    breaks === nothing && return breaks
    pr = breaks isa NamedTuple ? [String(k) => v for (k, v) in pairs(breaks)] :
         breaks isa AbstractDict ? [string(k) => v for (k, v) in breaks] :
         breaks isa AbstractVector{<:Pair} ? [string(p.first) => p.second for p in breaks] : nothing
    (pr === nothing || any(p -> isempty(p.first), pr) || length(unique(first.(pr))) < length(pr)) && chk_stop("e4.breaks", fn)
    for (k, b) in pr
        (conditions !== nothing && k in conditions) || chk_stop("e4.breaks_name", fn, k)
        ok = !_e4_isfactor(b) && (b isa AbstractVector && !(b isa AbstractMatrix)) && length(b) >= 2 &&
             all(_e4_numscalar, b) && all(v -> !isnan(Float64(v)), b) && all(i -> Float64(b[i]) > Float64(b[i-1]), 2:length(b))
        ok || chk_stop("e4.breaks", fn)
    end
    return breaks
end

"Auswahl als Name aus `nm` oder ganze Zahl 1 bis length(nm) (B-007; R `.e4_pick`). Ergebnis: Einzelwert."
function _e4_pick(@nospecialize(v), nm, fn, arg)
    v = chk_scalar(v)
    if v isa AbstractString
        v in nm || chk_stop("auswahl", fn, arg, join(("\"$c\"" for c in nm), ", "))
    else
        chk_int1(v, fn, arg; lo = 1, hi = length(nm))
    end
    return v
end

"""Bedingung als Wahrheitswerte wie R `as.logical` (Text "TRUE"/"FALSE" usw., Zahlen ungleich 0 = wahr, anderer Text
NA), NA = false (mildere Regel bis zur Antwort auf Frage F1, B-008); Faktor, Datum, Matrix und andere Objekte sind ein
Fehler (R `.e4_cond`). Ergebnis: `Vector{Bool}`."""
function _e4_cond(@nospecialize(cond), fn)
    _e4_isfactor(cond) && chk_stop("e4.bedingung", fn)
    cv = cond isa RVector ? cond.values : cond
    cv isa AbstractMatrix && chk_stop("e4.bedingung", fn)
    cv = cv isa AbstractVector ? cv : Any[cv]
    out = falses(length(cv))
    for (i, v) in enumerate(cv)
        _e4_isna(v) && continue
        if v isa Bool
            out[i] = v
        elseif _e4_numscalar(v)
            out[i] = Float64(v) != 0.0
        elseif v isa AbstractString
            v in ("T", "TRUE", "true", "True", "F", "FALSE", "false", "False") ||
                chk_stop("e4.bedingung_text", fn)              # Entscheidung 68: nicht lesbarer Text ist ein Fehler
            out[i] = v in ("T", "TRUE", "true", "True")
        else
            chk_stop("e4.bedingung", fn)
        end
    end
    return Vector{Bool}(out)
end

# ═════════════════════════════════════════════════════════════════════════════
# Aufrufe gemeinsamer Bausteine (andere Bearbeiter; erst beim Aufruf aufgelöst)
# ═════════════════════════════════════════════════════════════════════════════

"Element `k` eines Ergebnisses (RList, Dict, NamedTuple, Objekt mit Feld)."
function _el(o, k::AbstractString)
    o isa NamedTuple && return getfield(o, Symbol(k))
    o isa AbstractDict && return haskey(o, k) ? o[k] : o[Symbol(k)]
    o isa RVector && return o[k]
    return getproperty(o, Symbol(k))
end

_to_date(x, what) = SimLev.DataPrep._to_date(x, String(what))
_fill_na(x, method; keep_leading = false) =
    _fvec(SimLev.Backcast._fill_na(x, method; keep_leading = keep_leading))
_roll_var(x, n) = _fvec_r(SimLev.Signals._roll_var(x, n))
_roll_cov(x, y, n) = _fvec_r(SimLev.Signals._roll_cov(x, y, n))
_roll_mean(x, n) = _fvec_r(SimLev.Signals._roll_mean(x, n))
"Zufall der C-Bibliothek slc."
_SL() = SimLev.SLib
_boot_idx_stationary(n_src, n_out, L, stream) = Vector{Int}(SimLev.SLib.boot_idx_stationary(n_src, n_out, L; stream = stream))
_pw_block_stationary(x) = Float64(_el(SimLev.Bootstrap._pw_block(x), "stationary"))

_errmsg(e) = e isa ErrorException ? e.msg : sprint(showerror, e)

"R-`message()`: Text mit Zeilenumbruch auf `stderr`."
const message = SimLev.DataPrep.message   # seit 1.6.3 eine Fassung

"Warnungen unterdrücken (`suppressWarnings`)."
const _quietly = SimLev.Bootstrap._quiet   # seit 1.6.3 eine Fassung

# ── Statistik-Bausteine (RStats, RLinalg, RFmt, RLibm, SLib) ──────────────

_quantile(x, probs; na_rm = false) =
    _fvec_r(SimLev.RStats.quantile(_fvec_r(x), _fvec_r(probs); na_rm = na_rm, names = false))
_q1(x, p; na_rm = false) = _quantile(x, [Float64(p)]; na_rm = na_rm)[1]
_cor_raw(x, y = nothing; method = "pearson") =
    y === nothing ? SimLev.RStats.cor(x; method = method) : SimLev.RStats.cor(x, y; method = method)
_cor1(x, y; method = "pearson") = _fvec_r(_cor_raw(_fvec_r(x), _fvec_r(y); method = method))[1]
_cormat(X; method = "pearson") = _fmat_r(_cor_raw(_fmat_r(X); method = method))
_median(x; na_rm = false) = Float64(SimLev.RStats.median(_fvec_r(x); na_rm = na_rm))
function _optimize(f, lower, upper)
    o = SimLev.RStats.optimize(f, [Float64(lower), Float64(upper)])
    Float64(_el(o, "minimum")), Float64(_el(o, "objective"))
end
# Verteilungen der C-Bibliothek slc, wie .sl_qnorm usw. in R; Zahl oder Feld
_f64a(x) = x isa AbstractArray ? Float64.(x) : Float64(x)
_qnorm(p) = SimLev.SLib.qnorm(_f64a(p))
_qt(p, df) = SimLev.SLib.qt(_f64a(p), Float64(df))
_pt(q, df) = SimLev.SLib.pt(_f64a(q), Float64(df))
_lgamma(x) = Float64(SimLev.SLib.lgamma(Float64(x)))
_log(x::Real) = SimLev.RLibm.log(Float64(x))
_exp(x::Real) = SimLev.RLibm.exp(Float64(x))
"`A %m% B` (slc-Matrixprodukt); Vektor B als Spalte."
_matprod(A, B) = _fmat_r(SimLev.SLib.matmul(_fmat_r(A), B isa AbstractVector ? reshape(_fvec_r(B), :, 1) : _fmat_r(B)))
_matvec(A, b) = vec(_matprod(A, reshape(_fvec_r(b), :, 1)))

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
function _signif_str(x, dg::Int = 3)
    v = Float64(SimLev.RFmt.signif(Float64(x), dg))
    dg <= 7 && return _fmt1(v)
    r = SimLev.RFmt.format(v; digits = dg)
    r isa AbstractString ? String(r) : join(String.(collect(r)), ", ")
end
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
# seit 1.6.4 (B-105): wie _fvec/_fmat, aber ohne Kopie, wenn die Eingabe schon ein Vector{Float64} bzw. Matrix{Float64}
# ist. Nur, wo das Ergebnis sicher nur gelesen wird (nicht verändert, nicht zurückgegeben oder gespeichert) oder ein
# frisch berechnetes Feld ist, auf das sonst niemand verweist; sonst _fvec/_fmat (Kopie). Gleiche Werte.
_fvec_r(x::Vector{Float64}) = x
_fvec_r(x) = _fvec(x)
_fmat_r(X::Matrix{Float64}) = X
_fmat_r(X::NamedMat) = X.data isa Matrix{Float64} ? X.data : _fmat(X)
_fmat_r(X::AbstractVector) = reshape(_fvec_r(X), :, 1)
_fmat_r(X) = _fmat(X)
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
    vals = Float64[v for x in xs for v in _fvec_r(x)]
    isempty(vals) && return Inf
    _rnan(vals) !== nothing && return _rnan(vals)
    # seit 1.6.5 (CR2-X40-1) erstes Extrem wie R und Python (bei +0 und -0 das erste; Julia ordnet -0 < +0)
    m = vals[1]
    for v in vals
        v < m && (m = v)
    end
    m
end
"R `max()`."
function _rmax(xs...)
    vals = Float64[v for x in xs for v in _fvec_r(x)]
    isempty(vals) && return -Inf
    _rnan(vals) !== nothing && return _rnan(vals)
    # seit 1.6.5 (CR2-X40-1) erstes Extrem wie R und Python (bei +0 und -0 das erste; Julia ordnet -0 < +0)
    m = vals[1]
    for v in vals
        v > m && (m = v)
    end
    m
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
    r = SimLev.RStats.r_rank(_fvec_r(x))
    Float64[Float64(t) for t in (r isa RVector ? r.values : r isa AbstractVector ? r : [r])]
end

"Pseudo-Beobachtungen (Ränge / (n + 1))."
_pobs(x) = (v = _fvec_r(x); _rank_avg(v) ./ (length(v) + 1))

"`combn(k, 2)` als Liste von (i, j) in R-Reihenfolge."
_combn2(k::Integer) = [(i, j) for i in 1:k for j in (i+1):k]

"`colMeans` (long-double-Summe / n; C-Kern)."
_colmeans(X) = (A = _fmat_r(X); SimLev._ld_colsums(A; mean = true))

"`colSums` (long double)."
function _colsums(X)
    X = _fmat_r(X)
    Float64[SimLev.r_sum(view(X, :, j)) for j in 1:size(X, 2)]
end
"`rowSums` (long double)."
function _rowsums(X)
    X = _fmat_r(X)
    size(X, 2) == 0 && return zeros(size(X, 1))
    _fvec_r(SimLev.r_rowsums([X[:, j] for j in 1:size(X, 2)]))
end

"`scale(x)[, 1]` für einen Vektor."
function _scale1(x)
    x = _fvec_r(x)
    xc = x .- _colmeans(x)[1]
    v = filter(!isnan, xc)
    s = sqrt(SimLev.r_sum(v .* v) / max(1, length(v) - 1))
    xc ./ s
end

"Stabile Reihenfolge wie `order()` (NA/NaN zuletzt, -0 == 0)."
_order(v) = sortperm(_fvec_r(v); alg = Base.Sort.DEFAULT_STABLE,
                     lt = (a, b) -> isnan(b) ? !isnan(a) : (!isnan(a) && a < b))

const _isna_el = SimLev._isna   # r/rnum.jl (seit 1.6.3)
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

"""`seq.int(a, b, length.out = n)` wie R (seit 1.6.5 Kern `sl_r_seq_len` über `RStats.seq_len_out`; bis 1.6.4 eigene
Fassung mit `b - (n - 1 - i) by` ab der Mitte, 1 ulp anders, CR2-X26-1)."""
_seq_len_core(a::Float64, b::Float64, n::Int) = collect(Float64, _asv(SimLev.RStats.seq_len_out(a, b, n)))
_asv(x) = x isa Real ? [Float64(x)] : x

"`.bincode` (Intervallnummern 1..; 0 = NA; seit 1.6.0 C-Kern sl_r_bincode)."
_bincode(x, breaks; right = true, include_lowest = false) =
    SimLev._rb_bincode(collect(Float64, _fvec_r(x)), collect(Float64, _fvec_r(breaks)), right, include_lowest)

"`cut(x, k, labels = FALSE)` mit einer Intervallanzahl `k`."
function _cut_n(x, k::Integer)
    x = _fvec_r(x)
    nb = Int(k + 1)
    fin = filter(!isnan, x)
    rx = (minimum(fin), maximum(fin))
    dx = rx[2] - rx[1]
    if dx == 0
        dx = rx[1] != 0 ? abs(rx[1]) : 1.0
        br = _seq_len_core(rx[1] - dx / 1000, rx[2] + dx / 1000, nb)
    else
        br = _seq_len_core(rx[1], rx[2], nb)
        br[1] = rx[1] - dx / 1000
        br[nb] = rx[2] + dx / 1000
    end
    _bincode(x, br; right = true)
end

"Matrix und Spaltennamen (`as.matrix`)."
function _as_matrix(X)
    # seit 1.6.4 ohne Kopie (B-105): alle Aufrufer (_kendall, dependence_dcc, quantile_regression) lesen nur
    X isa NamedMat && return _fmat_r(X), X.colnames
    X isa RFrame && return _fmat(X), names(X)
    X isa AbstractMatrix && return _fmat_r(X), nothing
    return _fmat_r(X), nothing
end

_as_names(::Nothing) = String[]
_as_names(x::AbstractString) = [String(x)]
_as_names(x::Symbol) = [String(x)]
_as_names(x) = String[string(v) for v in x]

"Datenrahmen aus RFrame, NamedTuple oder Dict."
_as_frame(data::RFrame) = data
_as_frame(data::NamedTuple) = RFrame((String(k) => v for (k, v) in pairs(data))...)
_as_frame(data::AbstractDict) = RFrame((String(k) => v for (k, v) in data)...)
_as_frame(data::AbstractVector{<:Pair}) = (f = SimLev.as_rframe(data); f isa RFrame ? f : chk_stop("c.m_dep_returns"))
_as_frame(data) = chk_stop("c.m_dep_returns")
_is_frame(x) = x isa RFrame || x isa NamedTuple || (x isa AbstractDict && !(x isa RList)) || (x isa AbstractVector{<:Pair} && SimLev.as_rframe(x) isa RFrame)

_getopt(x::Nothing, k) = nothing
_getopt(x::NamedTuple, k) = haskey(x, Symbol(k)) ? getfield(x, Symbol(k)) : nothing
_getopt(x::AbstractDict, k) = haskey(x, k) ? x[k] : (haskey(x, Symbol(k)) ? x[Symbol(k)] : nothing)
# seit 1.6.5 (CR2-X4-1): Vektor von Paaren wie in _e4_breaks angenommen (bis 1.6.4 still übergangen)
function _getopt(x::AbstractVector{<:Pair}, k)
    for p in x
        string(p.first) == string(k) && return p.second
    end
    nothing
end
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
        chk_stop("c.m_dep_sort_dates", what, join(string.(first(na, 5)), ", "))
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
        chk_stop("c.m_dep_sort_dates_2", what, txt, more)
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
        # seit 1.6.4 ohne den Wert (Entscheidung 8), mit dem Datum als Ort in data
        error("Kursspalte '$a': Kurse müssen positiv und endlich sein, gefunden am " *
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

# Log-Renditen je Spalte (Funktionsgrenze: V hat in _dep_returns keinen ableitbaren Typ; log je Kurs einmal statt
# zweimal je Rendite; seit 1.6.1, gleiche Werte)
function _dep_logret(V::Matrix{Float64})
    m, k = size(V)
    LV = Matrix{Float64}(undef, m, k)
    for j in 1:k, i in 1:m
        LV[i, j] = _log(V[i, j])
    end
    R = zeros(max(m - 1, 0), k)
    for j in 1:k, i in 1:(m-1)
        R[i, j] = LV[i+1, j] - LV[i, j]
    end
    R
end

"""
    _dep_returns(data, assets, conditions = nothing, frequency = "week"; drop_flat = true)

Periodenrenditen (log) und verzögerte Zustandsvariablen (`.dep_returns`).
"""
function _dep_returns(data, assets, conditions = nothing, frequency = "week"; drop_flat::Bool = true)
    (_is_frame(data) && haskey(_as_frame(data), "date")) || chk_stop("c.m_dep_returns")
    data = _as_frame(data)
    assets = _as_names(assets)
    conditions = _as_names(conditions)
    miss = [c for c in unique(vcat(assets, conditions)) if !haskey(data, c)]
    isempty(miss) || error("Spalten fehlen: $(join(miss, ", "))")
    data = _dep_sort_dates(data)
    d = collect(data["date"])
    nr = length(d)
    ends = _period_ends(d, frequency)::Vector{Int}
    V = zeros(nr, length(assets))
    for (j, a) in enumerate(assets)
        V[:, j] = _fill_na(_dep_check_prices(_num(data[a]), a, d), "locf"; keep_leading = true)
    end
    V = V[ends, :]
    m = size(V, 1)
    R = _dep_logret(V)
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
    u = _fvec_r(u); v = _fvec_r(v)
    par = _fvec_r(par)
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
        x = _qnorm(u); y = _qnorm(v)
        ll = _cop_g_ll(r, x, y, x .* x, y .* y)
    elseif base == "t"                      # Hilfen _cop_t_c0, _cop_t_ll
        r, nu = par[1], par[2]
        x = _qt(u, nu); y = _qt(v, nu)
        ll = _cop_t_ll(r, nu, _cop_t_c0(nu), x, y, x .* x, y .* y,
                       (nu + 1) / 2 .* (l1p.(x .* x ./ nu) .+ l1p.(y .* y ./ nu)))
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
        # seit 1.6.5 (CR2-X7-1): Nenner ohne Auslöschung (R .cop_ll)
        ex = SimLev.RLibm.exp
        D = ex.(-th .* u) .* (.-em1.(-th .* v)) .+ ex.(-th .* v) .* (.-em1.(-th .* (1 .- v)))
        ll = lg(th * e1) .- th .* (u .+ v) .- 2 .* lg.(abs.(D))
    else
        error("Unbekannte Copula-Familie '$family'.")
    end
    s = SimLev.r_sum(ll)
    isfinite(s) ? s : -1e10
end

# Teile der Log-Dichten der Gauss- und t-Copula je Beobachtung (wie .cop_g_ll, .cop_t_ll in R), auch für die
# Profil-Likelihood in _cop_fit_t; x2 = x^2, y2 = y^2, B = (nu + 1)/2 (log1p(x^2/nu) + log1p(y^2/nu)).
function _cop_g_ll(r, x, y, x2, y2)
    r2 = r * r
    c = -0.5 * SimLev._log1mr2(r)
    c .- (r2 .* (x2 .+ y2) .- 2 .* r .* x .* y) ./ (2 * ((1 - r) * (1 + r)))
end
function _cop_t_ll(r, nu, c0, x, y, x2, y2, B)
    c = c0 - 0.5 * SimLev._log1mr2(r)
    c .- (nu + 2) / 2 .* SimLev.RLibm.log1p.((x2 .- 2 .* r .* x .* y .+ y2) ./ (nu * ((1 - r) * (1 + r)))) .+ B
end
"c0(nu) = lgamma((nu+2)/2) + lgamma(nu/2) - 2 lgamma((nu+1)/2); für nu > 64 asymptotisch (`.cop_t_c0`)."
function _cop_t_c0(nu)
    nu <= 64 && return _lgamma((nu + 2) / 2) + _lgamma(nu / 2) - 2 * _lgamma((nu + 1) / 2)
    a = nu / 2
    ia2 = 1 / (a * a)
    ((((31 / 9216 * ia2 - 17 / 7168) * ia2 + 1 / 320) * ia2 - 1 / 96) * ia2 + 1 / 4) / a
end
"t-Copula per Profil-Likelihood in nu (`.cop_fit_t`); Ergebnis [atanh rho, nu, -loglik]."
function _cop_fit_t(u, v)
    # seit 1.6.0 ganz im Kern (sl_tcop_fit, qt auf mehreren Threads); nur bei einer nicht endlichen Auswertung oder
    # einer Warnung von qt wie bisher hier (gleiche Meldungen)
    r = SimLev.SLib.tcop_fit(Vector{Float64}(_fvec_r(u)), Vector{Float64}(_fvec_r(v)))
    r === nothing || return r
    best = [0.0, Inf, Inf]
    function prof(nu)
        if isinf(nu)
            x = _fvec_r(_qnorm(u)); y = _fvec_r(_qnorm(v)); x2 = x .* x; y2 = y .* y
            g = th -> (s = SimLev.r_sum(_cop_g_ll(SimLev.RLibm.tanh(th), x, y, x2, y2)); isfinite(s) ? -s : 1e10)
        else
            x = _fvec_r(_qt(u, nu)); y = _fvec_r(_qt(v, nu)); x2 = x .* x; y2 = y .* y
            B = (nu + 1) / 2 .* (SimLev.RLibm.log1p.(x2 ./ nu) .+ SimLev.RLibm.log1p.(y2 ./ nu))
            c0 = _cop_t_c0(nu)
            g = th -> (s = SimLev.r_sum(_cop_t_ll(SimLev.RLibm.tanh(th), nu, c0, x, y, x2, y2, B)); isfinite(s) ? -s : 1e10)
        end
        o = SimLev.RStats.optimize(g, [-20.0, 20.0]; tol = 1e-10)
        mn = Float64(_el(o, "minimum")); ob = Float64(_el(o, "objective"))
        if ob < best[3]
            best[1] = mn; best[2] = nu; best[3] = ob
        end
        ob
    end
    nus = vcat([2 + 2.0^k for k in -4:12], Inf)
    K = length(nus)
    f = [prof(nu) for nu in nus]
    k = argmin(f)
    if k >= K - 1
        SimLev.RStats.optimize(s -> prof(s == 0 ? Inf : 1 / s), [0.0, 1 / nus[K - 2]]; tol = 1e-9)
    else
        lo = k == 1 ? _log(nus[1] - 2) - 30 : _log(nus[k - 1] - 2)
        SimLev.RStats.optimize(t2 -> prof(2 + _exp(t2)), [lo, _log(nus[k + 1] - 2)]; tol = 1e-6)
    end
    best
end

"Tail-Koeffizienten einer Copula (unten, oben) als benannter Vektor (`.cop_lambda`)."
function _cop_lambda(family::AbstractString, par)
    base, rot = _fam_parts(family)
    par = _fvec_r(par)
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

Passt mehrere bivariate Copula-Familien an zwei Reihen (z. B. Periodenrenditen zweier Anlagen) an und
vergleicht sie per AIC. Pseudo-Maximum-Likelihood auf Rängen (Genest, Ghoudi & Rivest 1995): Die Reihen werden
in Pseudo-Beobachtungen Rang / (n + 1) umgerechnet, die Ränder gehen also nicht ein. Familien: Gauß-, t-,
Clayton-, Gumbel- und Frank-Copula. Clayton und Gumbel erfassen asymmetrische Tails: Clayton die gemeinsamen
Abstürze (unterer Tail), Gumbel gemeinsame Anstiege; die um 180 Grad rotierten Varianten jeweils umgekehrt.
Bei negativer Abhängigkeit (z. B. Aktien und Anleihen in Deflationsphasen) werden die um 90/270 Grad rotierten
Varianten verwendet. Kendalls Tau wird intern in O(n log n) berechnet (gleiches Ergebnis wie
`stats::cor(method = "kendall")`).

# Argumente
- `x`, `y`: Numerische Vektoren gleicher Länge (z. B. Renditen; nur die Ränge zählen). Paare mit nicht
  endlichen Werten werden entfernt; mindestens 20 Paare nötig.
  Seit 1.6.4 nur Zahlenvektoren (keine Matrix, Liste, Wahrheitswerte, Faktor oder Text).
- `families`: Zeichenvektor der Familien: `"gaussian"`, `"t"`, `"clayton"`, `"gumbel"`, `"frank"`, jeweils
  optional mit Rotation `"_90"`, `"_180"` oder `"_270"` (z. B. `"clayton_180"`). `nothing` (Standard) =
  Auswahl nach dem Vorzeichen von Kendalls Tau: bei Tau >= 0 `gaussian`, `t`, `clayton`, `gumbel`, `frank`,
  `clayton_180`, `gumbel_180`; sonst `gaussian`, `t`, `frank`, `clayton_90`, `clayton_270`, `gumbel_90`,
  `gumbel_270`. Rotationen gibt es nur für `clayton` und `gumbel` (Gauß-, t- und Frank-Copula sind
  radialsymmetrisch); andere Namen sind ein Fehler, ebenso eine konstante Reihe.
  Seit 1.6.4 nicht leer.

# Rückgabe
Tabelle (RFrame) mit einer Zeile je Familie, aufsteigend nach AIC sortiert (erste Zeile = beste Familie):
`family`, `par1` (Korrelation bei Gauß/t, sonst θ), `par2` (Freiheitsgrade der t-Copula, höchstens 500; sonst
`NA`), `loglik`, `aic`, `bic`, `lambda_lower`, `lambda_upper` (implizite Tail-Koeffizienten der Copula,
Anteile 0 bis 1; für die um 90/270 Grad rotierten Familien 0). Attribute `tau` (Kendalls Tau) und `n` (Anzahl
Paare).

# Details
Die t-Copula wird über die Profil-Likelihood in den Freiheitsgraden ν geschätzt, weil die Likelihood in ν sehr
flach ist: für jedes ν eines Rasters (ν = 2 + 2^k, k = -4, …, 12, und ν = ∞, der Grenzfall Gauß-Copula) das
Maximum in der Korrelation, danach eine eindimensionale Suche um den besten Rasterpunkt. Liegt das Maximum bei
ν > 500 (auch ν = ∞), steht in `par2` 500; `loglik` gilt für das gefundene ν.
Die Gauß-Copula wird seit 1.6.5 wie die t-Copula über atanh ρ geschätzt (ohne die frühere Schranke |ρ| ≤ 0.995).
Die Log-Dichte der Frank-Copula rechnet seit 1.6.5 ohne Auslöschung (bis 1.6.4 blieb die Schätzung bei starker
positiver Abhängigkeit bei θ ≈ 37 stehen). Liegt der Parameter von Clayton, Gumbel oder Frank am Rand starker
Abhängigkeit des Suchbereichs (θ bis 60 bzw. ±60), gibt die Funktion einen Hinweis; Schätzung, Log-Likelihood und
AIC dieser Familie sind dann unzuverlässig. Ebenso seit 1.6.5 für Gauß und t bei nahezu vollständiger Abhängigkeit
(1 - |ρ| ≤ 1e-12, z. B. ein Index gegen seinen eigenen Hebelindex): die Log-Likelihood wächst dort unbeschränkt, ihr
Wert hängt nur von der Rundung ab und gewinnt den AIC-Vergleich ohne Aussage.

# Literatur
Genest, C., Ghoudi, K. & Rivest, L.-P. (1995), Biometrika 82(3); Joe, H. (2014), Dependence Modeling with
Copulas.

# Beispiel
```julia
using SimLev, Random
rng = MersenneTwister(1)
z = randn(rng, 1000, 2) * [1 0.6; 0 0.8]
w = sqrt.(sum(randn(rng, 1000, 4) .^ 2; dims = 2)[:, 1] ./ 4)
println(copula_fit(z[:, 1] ./ w, z[:, 2] ./ w))
```
"""
function copula_fit(x, y, families_pos = nothing; families = families_pos)
    _e4_vec(x, "copula_fit", "x"); _e4_vec(y, "copula_fit", "y")   # seit 1.6.4 (B-009, B-010, B-050)
    families === nothing || (families = _e4_names(families, "copula_fit", "families"; no_date = false))   # B-035
    lx, ly = _len(x), _len(y)
    lx != ly && chk_stop("c.m_copula_fit_4", lx, ly)
    x, y = _finite_pairs(x, y)
    n = length(x)
    n < 20 && chk_stop("c.m_copula_fit")
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
    isfinite(tau) || chk_stop("c.m_copula_fit_3")
    if families === nothing
        families = tau >= 0 ? ["gaussian", "t", "clayton", "gumbel", "frank", "clayton_180", "gumbel_180"] :
                              ["gaussian", "t", "frank", "clayton_90", "clayton_270", "gumbel_90", "gumbel_270"]
    end
    # Startwert rho0 entfällt (t-Copula per Profil-Likelihood, _cop_fit_t)
    fam_c = String[]; p1 = Float64[]; p2 = Float64[]; llk = Float64[]; aic = Float64[]; bic = Float64[]
    ll_ = Float64[]; lu_ = Float64[]
    for fam in families
        base = split(fam, "_"; limit = 2)[1]
        f(p) = -_cop_ll(fam, p, u, v)
        edge = false
        if base == "gaussian"               # seit 1.6.5 (E-T3-5) über atanh rho in [-20, 20]
            o = SimLev.RStats.optimize(th -> f([SimLev.RLibm.tanh(th)]), [-20.0, 20.0]; tol = 1e-10)
            mn, ob = Float64(_el(o, "minimum")), Float64(_el(o, "objective"))
            par, nll, k = [SimLev.RLibm.tanh(mn), _NA], ob, 1
            edge = 1 - abs(par[1]) <= 1e-12   # seit 1.6.5 (PRG2-4): |rho| bis auf 1e-12 an 1
        elseif base == "t"                  # Profil-Likelihood in nu
            o = _cop_fit_t(u, v)
            par, nll, k = [SimLev.RLibm.tanh(o[1]), min(o[2], 500.0)], o[3], 2
            edge = 1 - abs(par[1]) <= 1e-12   # PRG2-4
        elseif base == "clayton"
            mn, ob = _optimize(lt -> f([_exp(lt)]), _log(1e-4), _log(60.0))
            par, nll, k = [_exp(mn), _NA], ob, 1
            edge = mn > _log(60.0) - 1e-3 * (_log(60.0) - _log(1e-4))
        elseif base == "gumbel"
            mn, ob = _optimize(lt -> f([1 + _exp(lt)]), _log(1e-5), _log(60.0))
            par, nll, k = [1 + _exp(mn), _NA], ob, 1
            edge = mn > _log(60.0) - 1e-3 * (_log(60.0) - _log(1e-5))
        else
            mn, ob = _optimize(th -> f([th]), -60.0, 60.0)
            par, nll, k = [mn, _NA], ob, 1
            edge = abs(mn) > 60 - 1e-3 * 120
        end
        # seit 1.6.5 (CR2-X7-1): Parameter am Suchrand
        edge && message(SimLev.chk_msg("c.cop_rand", "copula_fit", fam, SimLev.RFmt.format(par[1]; digits = 6)))
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

Empirische Tail-Abhängigkeit und Exceedance-Korrelationen.

Misst für zwei Reihen (z. B. Periodenrenditen), wie oft extreme Werte gemeinsam auftreten, ohne ein
Copula-Modell anzunehmen: λ_L(q) = #{R_i ≤ q (n + 1), S_i ≤ q (n + 1)} / (n q) und λ_U(q) = #{n + 1 - R_i ≤
q (n + 1), n + 1 - S_i ≤ q (n + 1)} / (n q) mit den Rängen R_i, S_i (Mittel bei Bindungen; seit 1.6.5 beide
Ränder spiegelbildlich, bis 1.6.4 oben u_i > 1 - q mit u_i = R_i / (n + 1)). Unter Unabhängigkeit ist λ(q) ≈ q, bei
Gauß-Abhängigkeit fällt es für q → 0 gegen 0, bei echter Tail-Abhängigkeit bleibt es positiv. Die
Exceedance-Korrelation (Longin & Solnik 2001) ist die Pearson-Korrelation der Beobachtungen, in denen beide
Reihen höchstens auf ihrem empirischen q-Quantil (bzw. mindestens auf ihrem (1 - q)-Quantil) liegen.

# Argumente
- `x`, `y`: Numerische Vektoren gleicher Länge (z. B. Periodenrenditen). Paare mit nicht endlichen Werten
  werden entfernt.
  Seit 1.6.4 nur Zahlenvektoren (keine Matrix, Liste, Wahrheitswerte, Faktor oder Text).
- `q`: Numerischer Vektor von Tail-Wahrscheinlichkeiten als Anteil echt zwischen 0 und 1 (0.05 = die unteren
  bzw. oberen 5 % der Beobachtungen).

# Rückgabe
Tabelle (RFrame) mit einer Zeile je Wert von `q`: `q`, `lower`, `upper` (λ_L(q), λ_U(q)),
`exceed_lower`, `exceed_upper` (Exceedance-Korrelationen; `NA` bei weniger als 8 gemeinsamen Überschreitungen
oder Streuung 0), `n_lower`, `n_upper` (Anzahl der Paare, die gemeinsam im unteren bzw. oberen Tail liegen).

# Literatur
Longin, F. & Solnik, B. (2001), Journal of Finance 56(2).

# Beispiel
```julia
using SimLev, Random
rng = MersenneTwister(1); z = randn(rng, 2000)
println(tail_dependence(z .+ randn(rng, 2000), z .+ randn(rng, 2000), [0.05, 0.10]))
```
"""
function tail_dependence(x, y, q_pos = [0.01, 0.025, 0.05, 0.10, 0.20]; q = q_pos)
    _e4_vec(x, "tail_dependence", "x"); _e4_vec(y, "tail_dependence", "y")   # seit 1.6.4 (B-009, B-010, B-050)
    lx, ly = _len(x), _len(y)
    lx != ly && chk_stop("c.m_tail_dependence_3", lx, ly)
    chk_nofactor(q, "tail_dependence", "q")
    qv = q isa AbstractVector || q isa Tuple ? collect(q) : [q]
    if q isa AbstractMatrix || !_isnumvec(q) || isempty(qv) || any(v -> !isfinite(Float64(v)) || v <= 0 || v >= 1, qv)
        chk_stop("c.m_tail_dependence")   # seit 1.6.4 ohne Wert
    end
    qa = Float64.(qv)
    x, y = _finite_pairs(x, y)
    n = length(x)
    n < 2 && chk_stop("c.m_tail_dependence_2")
    u = _rank_avg(x); v = _rank_avg(y)                 # seit 1.6.5 Ränge (CR2-S-1)
    lower = Float64[]; upper = Float64[]; el_ = Float64[]; eu_ = Float64[]; nl = Int[]; nu = Int[]
    for p in qa
        r = _tail_dep_core(x, y, u, v, n, p)
        push!(lower, r[1]); push!(upper, r[2]); push!(el_, r[3]); push!(eu_, r[4]); push!(nl, r[5]); push!(nu, r[6])
    end
    RFrame("q" => qa, "lower" => lower, "upper" => upper, "exceed_lower" => el_, "exceed_upper" => eu_,
           "n_lower" => nl, "n_upper" => nu)
end

# Kern von tail_dependence für ein p auf endlichen Paaren (seit 1.6.4, B-064; R `.tail_dep_core`): je Reihe ein
# Quantilaufruf für p und 1 - p (dieselben Ordnungsstatistiken; die Quantile gehen nur in Vergleiche ein).
# Ergebnis (lower, upper, exceed_lower, exceed_upper, n_lower, n_upper).
function _tail_dep_core(x, y, u, v, n, p::Float64)
    ec(s) = (count(s) >= 8 && SimLev.r_sd(x[s]) > 0 && SimLev.r_sd(y[s]) > 0) ? _cor1(x[s], y[s]) : _NA
    # seit 1.6.5 (CR2-S-1): u, v Ränge, beide Ränder spiegelbildlich (R .tail_dep_core)
    cq = p * (n + 1) + 1e-7
    lo = (u .<= cq) .& (v .<= cq)
    hi = ((n + 1) .- u .<= cq) .& ((n + 1) .- v .<= cq)
    qx = _quantile(x, [p, 1 - p]); qy = _quantile(y, [p, 1 - p])
    el = (x .<= qx[1]) .& (y .<= qy[1])
    eh = (x .>= qx[2]) .& (y .>= qy[2])
    nl = count(lo); nh = count(hi)
    return (nl / (n * p), nh / (n * p), ec(el), ec(eh), nl, nh)
end

# tail_dependence(x, y, q)[lower, upper, exceed_lower] für ein mit chk_num1 geprüftes q in Schleifen
# (dependence_validate, dependence_analysis): gleiche Filterung und Meldung ohne RFrame (seit 1.6.4, B-064; R
# `.tail_dep_fun`); ein q, das dort nicht als Zahl in (0, 1) durchgeht, läuft wie bisher über tail_dependence.
function _tail_dep_fun(q)
    if !(q isa Real) || q isa Bool || !(isfinite(Float64(q)) && 0 < q < 1)
        return (x, y) -> (td = tail_dependence(x, y, q); (td["lower"][1], td["upper"][1], td["exceed_lower"][1]))
    end
    p = Float64(q)
    return function (x, y)
        x, y = _finite_pairs(x, y)
        n = length(x)
        n < 2 && chk_stop("c.m_tail_dependence_2")
        r = _tail_dep_core(x, y, _rank_avg(x), _rank_avg(y), n, p)
        (r[1], r[2], r[3])
    end
end

# ═════════════════════════════════════════════════════════════════════════════
# DCC
# ═════════════════════════════════════════════════════════════════════════════

"""
    dependence_dcc(R)

DCC(1,1)-Modell (Engle 2002).

Schätzt zeitvariable Korrelationen zwischen mehreren Renditereihen. Zweistufige Schätzung: univariate
GARCH(1,1) mit Konstante je Reihe (wie im Bootstrap: Maximum Likelihood unter Normalverteilung mit der
C-Bibliothek von SimLev, notfalls Momentschätzer), danach die Korrelationsdynamik der standardisierten
Residuen z_t: Q_t = (1 - a - b) Q̄ + a z_(t-1) z_(t-1)' + b Q_(t-1) mit Q_1 = Q̄ (Stichproben-Korrelation der
z_t) und a, b > 0, a + b < 0.999, per Quasi-Maximum-Likelihood (BFGS mit analytischem Gradienten, ganz in der
C-Bibliothek von SimLev). Die bedingte Korrelation ist R_t = diag(Q_t)^(-1/2) Q_t diag(Q_t)^(-1/2). Die Schätzung
ist deterministisch: Den früheren zufälligen Rückfall der GARCH-Stufe (gosolnp mit Startwert aus der Uhrzeit)
gibt es nicht mehr; die GARCH-Stufe meldet `method = "ml"` statt `"rugarch"`/`"optim"` (seit 1.0.0).

# Argumente
- `R`: Numerische Renditematrix oder Tabelle (RFrame) (Zeilen = Zeit, Spalten = Reihen; mindestens zwei
  Spalten und 100 Zeilen, keine fehlenden Werte). Die Einheit ist frei (z. B. Log-Renditen als Anteil); die
  Korrelationen hängen nicht davon ab. Spaltennamen werden übernommen (sonst `V1`, `V2`, ...). Konstante oder
  (nahezu) perfekt korrelierte Reihen (singuläre Korrelationsmatrix der standardisierten Residuen, kleinster
  Eigenwert unter 1e-8) sind ein Fehler. Grenze der Einheit: eine Reihe mit Varianz unter 1e-16 (Streuung unter
  1e-8, z. B. Renditen mal 1e-8) gilt als konstant; die geschätzten DCC-Parameter hängen in den letzten Stellen
  (etwa ab der 7.) von der Einheit ab.
  Seit 1.6.4 geprüft: nur Zahlen, alle endlich.

# Rückgabe
Liste mit `a`, `b` (DCC-Parameter), `loglik` (Korrelationsteil der Quasi-Log-Likelihood), `correlation`
(Matrix Zeit x Paare der bedingten Korrelationen R_t; Spaltennamen wie `pairs`), `pairs` (Paarnamen `"A ~
B"`), `garch` (Tabelle (RFrame) je Reihe: `series`, `alpha`, `beta`, `method` = Schätzweg der GARCH-Stufe:
`"ml"`, `"momente"` oder `"konstant"`), `z` (Matrix der standardisierten Residuen) und `Qbar`.

# Literatur
Engle, R. (2002), Journal of Business & Economic Statistics 20(3), 339-350.

# Beispiel
```julia
using SimLev, Random
rng = MersenneTwister(1)
a = 0.01 .* randn(rng, 500); b = 0.5 .* a .+ sqrt(0.75) .* 0.01 .* randn(rng, 500)
fit = dependence_dcc([a b])
println(fit["a"], " ", fit["b"])
```
"""
function dependence_dcc(R)
    # seit 1.6.4: nur Zahlen (Matrix oder Tabelle mit Zahlenspalten), endlich (Doku: keine fehlenden Werte)
    if R isa RFrame
        for k in names(R)
            _e4_numcol(R, k, "dependence_dcc")
        end
    elseif !(R isa NamedMat || (R isa AbstractMatrix && all(_e4_numscalar, R)))
        chk_stop("e4.matrix", "dependence_dcc")
    end
    Rm, nm = _as_matrix(R)
    all(isfinite, Rm) || chk_stop("e3.werte", "dependence_dcc", "R")
    (size(Rm, 2) < 2 || size(Rm, 1) < 100) && chk_stop("c.m_dependence_dcc")
    nm === nothing && (nm = ["V$j" for j in 1:size(Rm, 2)])
    g = [SimLev.Bootstrap._fit_garch11(Rm[:, j]; quiet = true) for j in 1:size(Rm, 2)]
    Z = reduce(hcat, [_fvec_r(_el(gi, "z")) for gi in g])
    flat = [nm[j] for j in 1:size(Z, 2) if SimLev.r_sd(Z[:, j]) == 0]
    isempty(flat) || error("dependence_dcc: Reihe $(join(["'$f'" for f in flat], ", ")) ist konstant; keine Korrelation schätzbar.")
    Qb = _cormat(Z)
    ev = _fvec_r(SimLev.SLib.eigen_sym(Qb; only_values = true)["values"])
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
    # Stufe 2 ganz in C (wie .sl_dcc_fit in R): deterministisch
    o = SimLev.SLib.dcc_fit(Z, Qb)
    a, b, oval = Float64(_el(o, "a")), Float64(_el(o, "b")), Float64(_el(o, "nll"))
    fl = SimLev.SLib.dcc_filter(Z, a, b, Qb, true)
    fl["ok"] === true || chk_stop("c.m_dependence_dcc_3")
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
    cv = _fvec_r(cv)
    if breaks === nothing
        qs = _quantile(cv, _seq_len_out(0.0, 1.0, Int(n_regimes) + 1); na_rm = true)
        inner = qs[2:end-1]
        u = sort(unique(filter(isfinite, cv) .+ 0.0))   # seit 1.6.4 (T3-N3) -0 wie 0 (R unique, numpy unique)
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
    # seit 1.6.5 (CR2-X4-2): so viele gültige Stellen (3 bis 15), dass die Grenzen verschieden lauten (R .dep_regimes)
    fb = Float64[v for v in breaks if isfinite(v)]
    dg = 3
    while dg < 15 && length(unique([_signif_str(v, dg) for v in fb])) < length(fb)
        dg += 1
    end
    lab = String[]
    for i in 1:(length(breaks)-1)
        a, b = breaks[i], breaks[i+1]
        if !isfinite(a)
            push!(lab, "< $(_signif_str(b, dg))")
        elseif !isfinite(b)
            push!(lab, ">= $(_signif_str(a, dg))")
        else
            push!(lab, "$(_signif_str(a, dg)) bis $(_signif_str(b, dg))")
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
    X = _fmat_r(X)
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
    dd = filter(isfinite, _fvec_r(dd))
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

Abhängigkeitsanalyse mit Tail-Risiko und Drittvariablen.

Untersucht die Abhängigkeit zwischen Anlagen (Kursreihen) über die reine Korrelation hinaus:
Rangkorrelationen, empirische Tail-Abhängigkeit, Exceedance-Korrelationen, die am besten passende Copula je
Paar, rollierende Korrelation und DCC. Mit `conditions` wird zusätzlich gefragt, wie sich die Abhängigkeit mit
dem Zustand von Drittvariablen ändert - etwa die Aktien-Anleihen-Korrelation bei hoher gegenüber niedriger
Inflation oder bei steigenden gegenüber fallenden Zinsen. Unterschiede zwischen Regimen werden mit einem
stationären Block-Bootstrap abgesichert (Standardtests unterschätzen bei autokorrelierten Reihen die
Unsicherheit).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Klasse Date oder in Date umwandelbar), Kursspalten (Kursniveaus,
  keine Renditen) und Zustandsspalten (z. B. mit `series_align()` und `series_align_macro()` vorbereitet).
- `assets`: Zeichenvektor der Kursspalten (mindestens zwei).
  Seit 1.6.4 ohne doppelte Namen und ohne 'date'.
- `conditions`: Zeichenvektor der Zustandsspalten (Drittvariablen, in ihrer eigenen Einheit); gehen um eine
  Periode verzögert ein. `nothing` (Standard) = keine bedingte Analyse.
  Seit 1.6.4 ohne doppelte Namen und keine Spalte aus assets.
- `frequency`: Renditefrequenz: `"week"` (Standard; ISO-Woche, vermeidet Effekte unterschiedlicher
  Handelszeiten), `"day"` oder `"month"`.
- `quantiles`: Numerischer Vektor von Tail-Wahrscheinlichkeiten als Anteil (Standard `[0.05, 0.10]`) für die
  Tail-Kennzahlen über die ganze Stichprobe (siehe `tail_dependence()`).
  Seit 1.6.4 echt zwischen 0 und 1, ohne doppelte Werte.
- `breaks`: Optional benannte Liste von Grenzen je Zustandsvariable in deren Einheit, z. B. `(inflation =
  [-Inf, 2, 4, Inf],)`; Intervalle links geschlossen, rechts offen. `nothing` (Standard) bzw. fehlender
  Eintrag = `n_regimes` gleich besetzte Quantilsgruppen.
  Seit 1.6.4 nur Namen aus conditions, Grenzen streng steigend ohne NA.
- `n_regimes`: Anzahl Regime ohne `breaks` (ganze Zahl, Standard 3: niedrig, mittel, hoch). Fallen
  Quantilsgrenzen zusammen oder bliebe eine Quantilsgruppe leer (diskrete Zustände wie 1/2 aus
  `regime_states()`), entstehen weniger Regime. Leere Regime aus vorgegebenen `breaks` erscheinen mit `n = 0`
  und `NA`-Kennzahlen.
- `window`: Fenster der rollierenden Pearson-Korrelation in Perioden der gewählten Frequenz. `nothing`
  (Standard) = Anzahl Perioden je Jahr (aus den Daten ermittelt, mindestens 10).
  Seit 1.6.4 eine ganze Zahl ≥ 1.
- `dcc`: Logisch: DCC(1,1) mit `dependence_dcc()` schätzen (nur bei mindestens 100 Perioden; Fehler werden als
  Meldung ausgegeben).
- `copulas`: Logisch: Copula-Fits mit `copula_fit()` je Paar (und je Regime ab 40 Perioden).
- `B`: Anzahl Bootstrap-Wiederholungen für die Regime-Vergleiche (ganze Zahl, Standard 499; 0 = aus).
  Seit 1.6.4 höchstens 10^8.
- `block`: Mittlere Blocklänge des stationären Bootstraps in Perioden. `nothing` (Standard) =
  Politis-White-Schätzung auf dem Produkt der standardisierten Renditen (Maximum über die Paare, begrenzt auf
  2 bis n / 10).
  Seit 1.6.4 eine Zahl ≥ 1.
- `tail_q`: Tail-Wahrscheinlichkeit als Anteil (Standard 0.10) für die Tail-Kennzahlen je Regime.
- `seed`: Startwert für den Bootstrap. Mit Startwert (ganze Zahl, |seed| < 2^53) ist das Ergebnis
  reproduzierbar und der Zufallszustand von SimLev bleibt unverändert; mit `nothing` wird genau einmal ein
  Startwert aus dem Zufallszustand von SimLev gezogen (siehe `simlev_seed()`), wiederholte Aufrufe liefern
  dann verschiedene Ergebnisse. `set.seed()` wirkt nicht.

# Rückgabe
Objekt der Klasse `SimLevDependence`, eine Liste mit

- returns: Tabelle (RFrame) mit `date` (Periodenende), den Log-Renditen der Anlagen (Anteile je Periode) und
  den verzögerten Zustandsvariablen.
- correlation: Liste der Matrizen `pearson`, `spearman`, `kendall`.
- pairs: Tabelle (RFrame) je Paar: `pair`, `pearson`, `spearman`, `kendall`, je Wert von `quantiles`
  `lambda_lower_`q und `lambda_upper_`q (z. B. `lambda_lower_0.05`); mit `copulas = true` zusätzlich `copula`
  (beste Familie nach AIC), `copula_lambda_lower`, `copula_lambda_upper`, `t_rho`, `t_nu` (Parameter der
  t-Copula).
- tail: Ergebnis von `tail_dependence()` je Paar (Spalte `pair`) und Quantil.
- copulas: Benannte Liste der `copula_fit()`-Tabellen je Paar oder `nothing`.
- rolling: Tabelle (RFrame) mit `date` und der rollierenden Korrelation je Paar (`nothing`, wenn die Historie
  nicht länger als `window` ist).
- dcc: Ergebnis von `dependence_dcc()` oder `nothing`.
- conditional: Liste je Zustandsvariable: Tabelle (RFrame) je Paar und Regime mit `n`, `vol_1`, `vol_2`
  (annualisierte Volatilität der Log-Renditen als Anteil), `pearson`, `spearman`, `kendall`, `lambda_lower`,
  `lambda_upper`, `exceed_lower` (bei `tail_q`), `t_rho`, `t_nu`, `copula`, `copula_lambda_lower` und mit
  Bootstrap `pearson_lo`, `pearson_hi` (90-%-Intervall).
- regimes: Liste je Zustandsvariable: `regime`, `n`, `mean_state` (mittlerer Zustand im Regime).
- differences: Tabelle (RFrame) (oder `nothing`): oberstes minus unterstes Regime je Paar und
  Zustandsvariable, `diff_pearson`, `diff_spearman` mit 95-%-Bootstrap-Intervall (`lo_`, `hi_`) und
  zweiseitigem p-Wert (`p_`).

sowie `assets`, `conditions`, `frequency`, `ppy` (Perioden je Jahr, aus den Daten), `window`, `block`, `B`,
`tail_q`. Methoden `print` und `plot`.

# Details
Renditen: Die Zeilen werden nach `date` sortiert (mit Hinweis, falls nötig; fehlende oder doppelte Daten sind
ein Fehler, ebenso Kurse <= 0 oder nicht endliche Kurse). Die Kurse werden je Anlage mit dem letzten Wert
fortgeschrieben (führende Lücken bleiben leer), auf die letzte vorhandene Zeile jeder Periode reduziert
(`"week"`: ISO-Woche, `"month"`: Kalendermonat, `"day"`: jede Zeile) und in Log-Renditen log(P_t / P_t-1)
(Anteile, keine Prozent) umgerechnet. Zeilen mit fehlenden Renditen entfallen; bei `"day"` auch Zeilen, in
denen alle Anlagen die Rendite 0 haben (z. B. Feiertage). Zustandsvariablen werden ebenfalls fortgeschrieben
und gehen mit ihrem Wert am Ende der Vorperiode ein.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1500
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
infl = 2 .+ cumsum(0.05 .* randn(rng, n))
e1 = randn(rng, n); e2 = randn(rng, n)
rho = ifelse.(infl .> 2, 0.5, -0.3)
d["stocks"] = 100 .* exp.(cumsum(0.01 .* e1))
d["bonds"] = 100 .* exp.(cumsum(0.005 .* (rho .* e1 .+ sqrt.(1 .- rho .^ 2) .* e2)))
d["inflation"] = infl
da = dependence_analysis(d, ["stocks", "bonds"]; conditions = "inflation", B = 19, seed = 1)
println(da["correlation"])
```
"""
function dependence_analysis(data, assets; conditions = nothing, frequency = ("week", "day", "month"),
                             quantiles = [0.05, 0.10], breaks = nothing, n_regimes = 3, window = nothing,
                             dcc = true, copulas = true, B = 499, block = nothing, tail_q = 0.10,
                             seed = nothing)
    frequency = _match_arg(frequency, ("week", "day", "month"))
    fn = "dependence_analysis"                                 # seit 1.6.4 vor der Rechnung (K42 E4)
    assets = _e4_names(assets, fn, "assets")
    length(assets) < 2 && error("dependence_analysis: mindestens zwei Anlagen.")
    conditions = _e4_names(conditions, fn, "conditions"; null_ok = true)
    _e4_disjoint(assets, conditions, fn, "assets", "conditions")   # B-013
    _e4_data(data, conditions === nothing ? assets : vcat(assets, conditions), fn)
    data = SimLev.as_rframe(data)
    quantiles = _e4_probs(quantiles, fn, "quantiles")          # B-054
    _e4_breaks(breaks, conditions, fn)                         # B-014
    n_regimes = _e4_count(n_regimes, fn, "n_regimes")          # B-032
    window = _e4_count(window, fn, "window"; null_ok = true)   # B-012
    dcc = chk_bool1(dcc, fn, "dcc")::Bool                      # B-051
    copulas = chk_bool1(copulas, fn, "copulas")::Bool
    B = _e4_count(B, fn, "B"; lo = 0)                          # B-011, B-032
    block = chk_num1(block, fn, "block"; lo = 1, null_ok = true)
    tail_q = chk_num1(tail_q, fn, "tail_q"; lo = 0, hi = 1, lo_open = true, hi_open = true)   # B-011
    rd = _dep_returns(data, assets, conditions, frequency)
    X = reduce(hcat, [_fvec_r(rd[a]) for a in assets])
    n = size(X, 1)
    n < 30 && error("dependence_analysis: nur $n Perioden.")
    dd = _days(rd["date"])
    ppy = (n - 1) / ((dd[n] - dd[1]) / 365.25)
    window === nothing && (window = max(10.0, _r_round(ppy)))
    quantiles = _fvec(quantiles)
    pear = _cormat(X); spear = _cormat(X; method = "spearman"); kend = _fmat_r(_kendall(X))
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
            # seit 1.6.5 (CR2-X51-1): Anlage ohne Schwankung -> klare Meldung (R dependence_analysis)
            flat = String[assets[j] for j in eachindex(assets) if !(SimLev.r_sd(X[:, j]) > 0)]
            isempty(flat) || chk_stop("c.dep_konstant", fn, join(["'" * a * "'" for a in flat], ", "))
            bl = Float64[]
            for (i, j) in pidx
                x = _scale1(X[:, i]); y = _scale1(X[:, j])
                push!(bl, _pw_block_stationary(x .* y))
            end
            block = _rmin(_rmax(2.0, _rmax(bl)), n / 10)
        end
        cond = RList(); diffs = RFrame[]; regimes = RList(); td_fun = _tail_dep_fun(tail_q)
        for cn in conditions
            cv = _fvec_r(rd[cn])
            keep = findall(isfinite, cv)
            if length(keep) < 30
                @warn chk_msg("c.m_dependence_analysis", cn)
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
                td = length(s) >= 20 ? td_fun(x, y) : nothing   # seit 1.6.4 ohne RFrame (B-064)
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
                    "lambda_lower" => td !== nothing ? td[1] : _NA,
                    "lambda_upper" => td !== nothing ? td[2] : _NA,
                    "exceed_lower" => td !== nothing ? td[3] : _NA,
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
                # seed = nothing -> einmal k aus G (beim ersten Bootstrap), dann je Zustand wie seed = k
                seed === nothing && (seed = _SL().next_seed())
                S = _SL().main_stream(seed, "dependence_analysis")
                boot = Any[]
                for _b in 1:Int(B)
                    idx = _boot_idx_stationary(nk, nk, block, S)
                    Xb = Xk[idx, :]; rb = code[idx]
                    push!(boot, (_dep_reg_cor(Xb, rb, nlv, pidx), _dep_reg_cor(Xb, rb, nlv, pidx; rank = true)))
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
    s = SimLev.RFmt.print_matrix(NamedMat(M; rownames = rn, colnames = cn))
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
    P = x["correlation"]["pearson"]; K = _fmat_r(x["correlation"]["kendall"])
    M = _fmat(P)
    for j in 1:size(M, 2), i in 1:(j-1)
        M[i, j] = K[i, j]
    end
    _ln(io, _print_matrix(_r_round(M, 3), P.rownames, P.colnames))
    p = x["pairs"]
    print(io, "\nTail-Abhängigkeit je Paar\n")
    qs = [c for c in names(p) if startswith(c, "lambda_lower_")]
    y = RFrame("Paar" => collect(p["pair"]), "Kendall" => _sprintf_vec("%.3f", _fvec_r(p["kendall"])))
    for k in qs
        q = k[length("lambda_lower_")+1:end]
        y["lamL $q"] = _sprintf_vec("%.2f", _fvec_r(p[k]))
        y["lamU $q"] = _sprintf_vec("%.2f", _fvec_r(p[replace(k, "lower" => "upper"; count = 1)]))
    end
    if haskey(p, "copula")
        y["Copula"] = collect(p["copula"])
        y["Cop. lamL"] = _sprintf_vec("%.2f", _fvec_r(p["copula_lambda_lower"]))
        y["Cop. lamU"] = _sprintf_vec("%.2f", _fvec_r(p["copula_lambda_upper"]))
        y["t: rho/nu"] = _sprintf_vec("%.2f / %.1f", _fvec_r(p["t_rho"]), _fvec_r(p["t_nu"]))
    end
    _ln(io, _print_df(y))
    print(io, "  (Unabhängigkeit: lam(q) ~ q; Gauß-Abhängigkeit: lam -> 0 für kleine q)\n")
    dc = x["dcc"]
    if dc !== nothing
        C = _fmat_r(dc["correlation"])
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
                       "Pearson" => _sprintf_vec("%.2f", _fvec_r(ct["pearson"])))
            z["90%-KI"] = haskey(ct, "pearson_lo") ? _sprintf_vec("[%.2f, %.2f]", _fvec_r(ct["pearson_lo"]), _fvec_r(ct["pearson_hi"])) :
                                                     fill("", SimLev.nrow(ct))
            z["Kendall"] = _sprintf_vec("%.2f", _fvec_r(ct["kendall"]))
            z["lamL $(_sprintf("%g", x["tail_q"]))"] = _sprintf_vec("%.2f", _fvec_r(ct["lambda_lower"]))
            z["t-rho"] = _sprintf_vec("%.2f", _fvec_r(ct["t_rho"]))
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

"OLS-Start über `.sl_lsfit` (Householder-QR): (Fit, Rang, Pivot)."
function _qr_rank_pivot_coef(Xm, y)
    qx = SimLev.SLib.lsfit(_fmat_r(Xm), _fvec_r(y))
    rank = Int(qx["rank"])
    piv = Int.(qx["pivot"])
    qx, rank, piv
end
_qr_coef(qx) = _fvec(qx["coefficients"])

_is_numcol(c) = eltype(c) <: Union{Missing,Real} && !(eltype(c) <: Union{Missing,Bool}) && !(eltype(c) === Missing) ||
                (eltype(c) === Any && all(v -> v === missing || (v isa Real && !(v isa Bool)), c))
_is_numeric(x) = x isa Real && !(x isa Bool) || (x isa AbstractArray && _is_numcol(x isa NamedMat ? x.data : vec(x)))

"""
    quantile_regression(y, X = nothing, tau = 0.5; intercept = true, tol = 1e-10, maxit = 2000)

Lineare Quantilsregression (exakte Lösung mit Optimalitätsnachweis).

Schätzt die Koeffizienten des bedingten τ-Quantils von `y` (Koenker & Bassett 1978), d. h. minimiert Σ_i
ρ_τ(y_i - x_i'β) mit ρ_τ(r) = r(τ - 1{r < 0}). Geliefert wird die exakte Lösung dieses linearen Programms mit
Optimalitätsnachweis (Ausnahme: entartete Fälle, siehe unten), berechnet in zwei Schritten (Kern in C++).
Seit 1.6.5 werden die Regressoren vorher zentriert (mit Konstante) und auf Standardabweichung 1 skaliert, die
Koeffizienten danach zurückgerechnet; so hängt das Ergebnis nicht von Einheit oder Niveau der Regressoren ab (bis
1.6.4 bei Indexständen oder Jahreszahlen Steigungen bis 85 % daneben, mit der Warnung "Optimalität nicht
nachgewiesen").

- MM-Algorithmus von Hunter & Lange (2000), ausgehend von der KQ-Lösung: iterativ gewichtete kleinste Quadrate
  mit β ← (X'WX)^(-1) (X'Wy + (τ - 1/2) X'1), W = diag(1 / (2(ε + |r_i|))) in vier Stufen mit ε = sd(y) mal 1e-2,
  1e-4, 1e-6, 1e-8.
- Ecken-Politur: Aus den p Beobachtungen mit den kleinsten Residuen der Näherung (linear unabhängig gewählt)
  wird die Ecke des linearen Programms berechnet, die diese Beobachtungen exakt interpoliert, und über die
  Subgradientenbedingung auf Optimalität geprüft (an entarteten Ecken wie unten per linearem Programm). Ist
  der Nachweis erbracht (nach jeder Stufe und alle 25 Iterationen geprüft), ist diese Ecke das Ergebnis.

Gelingt der Nachweis bis zur letzten Stufe nicht (z. B. bei τ nahe 0 oder 1, wenn die Näherung noch weit von
der Ecke entfernt ist), folgen von dieser Ecke aus Austauschschritten wie im Simplex-Verfahren von Barrodale &
Roberts (1974): Solange eine Kante der Ecke abwärts führt, wird entlang der steilsten bis zum Minimum
gegangen; die Zielfunktion fällt dabei streng. Ohne Abstiegskante wird die Optimalität exakt nachgewiesen; an
entarteten Ecken (weitere Residuen exakt 0, z. B. bei diskreten Regressoren, gerundeten Werten oder doppelten
Beobachtungen) über die Bedingung, dass 0 im Teildifferential liegt: Es muss λ_j ∈ [τ - 1, τ] für die
Beobachtungen mit Residuum 0 geben mit Σ_j λ_j x_j = -Σ_r_i ≠ 0 ψ_τ(r_i) x_i; geprüft als lineares
Zulässigkeitsproblem (Phase 1 des Simplex-Verfahrens mit beschränkten Variablen, gleiche Zeilen x_j
zusammengefasst). Scheitert der Nachweis, erscheint eine Warnung, und geliefert wird die gefundene Ecke,
sofern ihr Zielwert nicht größer ist als der der MM-Näherung, sonst die MM-Näherung. Ist die Lösung nicht
eindeutig (z. B. ohne Regressoren, wenn n * tau ganzzahlig ist), wird eine der optimalen Lösungen geliefert.

# Argumente
- `y`: Numerischer Vektor, Zielvariable (beliebige Einheit).
- `X`: Regressoren als numerischer Vektor, Matrix oder Tabelle (RFrame) (ohne Konstante). `nothing` (Standard)
  = nur Konstante, d. h. das empirische τ-Quantil von `y`. Zeilen mit nicht endlichen Werten in `y` oder `X`
  werden entfernt. Erwartet werden `length(y)` Zeilen, nur numerische Spalten (Faktoren vorher in
  Indikatorspalten umwandeln) und linear unabhängige Regressoren einschließlich der Konstante; sonst bricht
  die Funktion mit Fehler ab.
- `tau`: Quantil als Anteil, echt zwischen 0 und 1 (Standard 0.5 = Median-Regression).
- `intercept`: Logisch: Konstante aufnehmen (Standard `true`).
- `tol`: Konvergenzschwelle der MM-Stufen: Eine Stufe endet, wenn sich kein Koeffizient um mehr als `tol * (1
  + max|beta|)` ändert (in den ersten drei Stufen wird höchstens 1e-7 verlangt). Standard 1e-10.
  Seit 1.6.4 eine Zahl > 0.
- `maxit`: Höchstzahl der Iterationen je MM-Stufe (ganze Zahl, Standard 2000).
  Seit 1.6.4 höchstens 10^8.

# Rückgabe
Benannter numerischer Koeffizientenvektor in der Einheit von `y` je Einheit des Regressors: `"(Intercept)"`
(falls `intercept = true`) und je Spalte von `X` deren Name (sonst `x1`, `x2`, ...).

# Literatur
Koenker, R. & Bassett, G. (1978), Econometrica 46(1); Hunter, D. R. & Lange, K. (2000), Journal of
Computational and Graphical Statistics 9(1); Barrodale, I. & Roberts, F. D. K. (1974), Communications of the
ACM 17(6).

# Beispiel
```julia
using SimLev, Random
rng = MersenneTwister(1)
x = randn(rng, 500); y = 1 .+ 2 .* x .+ randn(rng, 500) .* (1 .+ abs.(x))
println(quantile_regression(y, x, 0.9))
```
"""
function quantile_regression(y, X_pos = nothing, tau_pos = 0.5; X = X_pos, tau = tau_pos, intercept = true, tol = 1e-10, maxit = 2000)
    tv = tau isa AbstractVector || tau isa Tuple ? collect(tau) : [tau]
    if length(tv) != 1 || !(tv[1] isa Real) || tv[1] isa Bool || !isfinite(Float64(tv[1])) || tv[1] <= 0 || tv[1] >= 1
        chk_stop("c.m_quantile_regression")   # seit 1.6.4 ohne Wert
    end
    tau = Float64(tv[1])
    (!_e4_isfactor(y) && !(y isa AbstractMatrix) && _is_numeric(y isa RVector ? y.values : y)) ||
        chk_stop("c.m_quantile_regression_2")   # seit 1.6.4 Vektor
    fn = "quantile_regression"
    _e4_isfactor(X) && chk_stop("faktor", fn, "X")             # Entscheidung 15
    intercept = chk_bool1(intercept, fn, "intercept")::Bool    # B-051
    tol = chk_num1(tol, fn, "tol"; lo = 0, lo_open = true)     # B-032
    maxit = _e4_count(maxit, fn, "maxit")                      # B-032
    y = _fvec_r(y)
    if X isa RFrame
        nn = [k for k in names(X) if !_is_numcol(X[k])]
        isempty(nn) || error("quantile_regression: Spalte(n) $(join(["'$c'" for c in nn], ", ")) von X nicht numerisch " *
                             "(Faktoren vorher z. B. mit model.matrix() in Indikatorspalten umwandeln).")
    end
    if X === nothing
        Xm = zeros(length(y), 0); nm = String[]
    else
        X isa RFrame || _is_numeric(X) || chk_stop("c.m_quantile_regression_4")
        Xm, nm = _as_matrix(X)
        size(Xm, 1) != length(y) && chk_stop("c.m_quantile_regression_8", size(Xm, 1), length(y))
        nm === nothing && (nm = ["x$j" for j in 1:size(Xm, 2)])
    end
    if intercept
        Xm = hcat(ones(length(y)), Xm)
        nm = vcat(["(Intercept)"], nm)
    end
    ok = [isfinite(y[i]) && all(isfinite, view(Xm, i, :)) for i in eachindex(y)]
    y = y[ok]; Xm = Xm[ok, :]
    p = size(Xm, 2)
    p == 0 && chk_stop("c.m_quantile_regression_5")
    length(y) < p && chk_stop("c.m_quantile_regression_9", length(y), p)
    qx, rank, piv = _qr_rank_pivot_coef(Xm, y)
    if rank < p
        bad = [nm[k] for k in piv[(rank+1):p]]
        error("quantile_regression: Regressoren linear abhängig ($(join(["'$b'" for b in bad], ", "))); doppelte oder konstante " *
              "Spalten entfernen (die Konstante ist bei intercept = TRUE schon enthalten).")
    end
    # seit 1.6.5 (K5, CR2-E-10): Regressoren zentrieren/skalieren, Koeffizienten zurückrechnen (R .qr_scale)
    Z, mq, sq = _qr_scale(Xm, intercept)
    beta = _qr_coef(_qr_rank_pivot_coef(Z, y)[1])
    sc = _rmax(SimLev.r_sd(y), 1e-12)
    g, opt = SimLev.DependenceCore.quantile_reg_core(y, Z, tau, beta, sc, Float64(tol), Int(maxit))
    opt === true || @warn "quantile_regression: Optimalität nicht nachgewiesen; Ergebnis ist eine Ecke mit nicht größerem " *
                          "Zielwert als die MM-Näherung (bzw. die MM-Näherung selbst, falls keine solche Ecke gefunden wurde)."
    RVector(_qr_unscale(Vector{Float64}(g), mq, sq, intercept); names = nm)
end

"`.qr_scale` (seit 1.6.5, K5): (Z, m, s) mit Z = (X - m) / s je Spalte außer der Konstanten."
function _qr_scale(X::AbstractMatrix, intercept::Bool)
    X = Matrix{Float64}(X)
    p = size(X, 2)
    m = zeros(p); s = ones(p); Z = copy(X)
    for j in 1:p
        intercept && j == 1 && continue
        v = X[:, j]
        intercept && (m[j] = SimLev.r_mean(v))
        sj = SimLev.r_sd(v)
        s[j] = (isfinite(sj) && sj > 0) ? sj : maximum(abs.(v))
        Z[:, j] = (v .- m[j]) ./ s[j]
    end
    Z, m, s
end

"`.qr_unscale`: Steigung g_j / s_j, Konstante g_0 - sum(g_j m_j / s_j)."
function _qr_unscale(g::Vector{Float64}, m, s, intercept::Bool)
    b = g ./ s
    intercept && length(b) > 1 && (b[1] = g[1] - SimLev.r_sum(b[2:end] .* m[2:end]))
    b
end

"`.sl_lsfit(X1, y)\$coefficients` (OLS mit Konstante in `X1`)."
_lm_coef(y, X1) = _fvec_r(SimLev.SLib.lsfit(_fmat_r(X1), _fvec_r(y))["coefficients"])

"""
    tail_regression(data, asset, drivers; quantiles = [0.05, 0.25, 0.5, 0.75, 0.95],
                    frequency = "week", B = 199, block = nothing, seed = nothing)

Renditequantile in Abhängigkeit von Drittvariablen (Quantilsregression).

Schätzt für mehrere Quantile, wie sich die Verteilung der Periodenrendite einer Anlage mit dem (verzögerten)
Zustand von Drittvariablen verschiebt (lineare Quantilsregression mit `quantile_regression()`, zum Vergleich
OLS für den Mittelwert). Ein negativer Koeffizient der Inflation im 5-%-Quantil heißt z. B.: Bei höherer
Inflation fallen die schlechten Perioden schlechter aus, auch wenn sich der Median kaum bewegt. Standardfehler
per stationärem Block-Bootstrap der Perioden.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Date), Kursspalte (Kursniveaus, keine Renditen) und
  Zustandsspalten.
- `asset`: Name der Kursspalte (Zeichenkette).
- `drivers`: Zeichenvektor der Zustandsspalten (Drittvariablen).
  Seit 1.6.4 mindestens einer, ohne doppelte Namen und nicht asset.
- `quantiles`: Numerischer Vektor der Quantile als Anteil (Standard `[0.05, 0.25, 0.5, 0.75, 0.95]`).
- `frequency`: Renditefrequenz: `"week"` (Standard, ISO-Woche), `"day"` oder `"month"`.
- `B`: Anzahl Bootstrap-Wiederholungen (ganze Zahl, Standard 199; 0 = keine Standardfehler und Intervalle).
  Seit 1.6.4 höchstens 10^8.
- `block`: Mittlere Blocklänge des stationären Bootstraps in Perioden. `nothing` (Standard) =
  Politis-White-Schätzung auf den absoluten Abweichungen der Rendite vom Mittel (begrenzt auf 2 bis n / 10).
- `seed`: Startwert für den Bootstrap. Mit Startwert (ganze Zahl, |seed| < 2^53) ist das Ergebnis
  reproduzierbar und der Zufallszustand von SimLev bleibt unverändert; mit `nothing` wird genau einmal ein
  Startwert aus dem Zufallszustand von SimLev gezogen (siehe `simlev_seed()`), wiederholte Aufrufe liefern
  dann verschiedene Ergebnisse. `set.seed()` wirkt nicht.

# Rückgabe
Objekt der Klasse `SimLevTailRegression` mit `coefficients` (Tabelle (RFrame): `quantile`, `term`, `estimate`,
`se` (Bootstrap-Standardabweichung), `lower`, `upper` (90-%-Bootstrap-Intervall, 5- und 95-%-Quantil);
Koeffizienten in Prozentpunkten Log-Rendite je Periode bzw. je Einheit des Treibers), `ols`
(OLS-Koeffizienten, gleiche Einheit), `data` (aufbereitete Perioden: `date`, Log-Rendite als Anteil,
verzögerte Treiber) sowie `asset`, `drivers`, `quantiles`, `n` (Anzahl Perioden), `frequency`, `B`, `B_failed`
(Anzahl Bootstrap-Stichproben, die nicht schätzbar waren, z. B. weil ein Treiber in der Stichprobe konstant
ist; sie fehlen in Standardfehlern und Intervallen, mit Warnung), `block`. Methoden `print` und `plot`.

# Details
Zielgröße ist die Log-Rendite der Periode in Prozent, 100 log(P_t / P_t-1); die Kurse werden wie in
`dependence_analysis()` aufbereitet (Fortschreiben fehlender Werte, letzte Zeile je ISO-Woche bzw. Monat). Die
Treiber gehen mit ihrem Wert am Ende der Vorperiode in ihrer eigenen Einheit ein.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1095
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["aktien"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["inflation"] = 2 .+ cumsum(0.05 .* randn(rng, n))
tr = tail_regression(d, "aktien", "inflation"; quantiles = [0.05, 0.5, 0.95], B = 49, seed = 1)
println(tr["coefficients"])
```
"""
function tail_regression(data, asset, drivers; quantiles = [0.05, 0.25, 0.5, 0.75, 0.95],
                         frequency = ("week", "day", "month"), B = 199, block = nothing, seed = nothing)
    frequency = _match_arg(frequency, ("week", "day", "month"))
    fn = "tail_regression"                                     # seit 1.6.4 vor der Rechnung (K42 E4, B-054)
    asset = String(chk_name1(asset, fn, "asset"))
    asset == "date" && chk_stop("e4.date", fn, "asset")
    drivers = _e4_names(drivers, fn, "drivers")
    _e4_disjoint([asset], drivers, fn, "asset", "drivers")     # B-013
    _e4_data(data, vcat([asset], drivers), fn)
    data = SimLev.as_rframe(data)
    quantiles = _e4_probs(quantiles, fn, "quantiles")
    B = _e4_count(B, fn, "B"; lo = 0)                          # B-032
    block = chk_num1(block, fn, "block"; lo = 1, null_ok = true)
    rd = _dep_returns(data, [asset], drivers, frequency)
    ok = _complete_rows((rd[c] for c in vcat([asset], drivers))...)
    all(ok) || (rd = SimLev.rows(rd, findall(ok)))
    y = 100 .* _fvec_r(rd[asset])
    X = isempty(drivers) ? zeros(length(y), 0) : reduce(hcat, [_fvec_r(rd[c]) for c in drivers])
    n = length(y)
    n < 30 && chk_stop("c.m_tail_regression")
    p = size(X, 2) + 1
    XN = NamedMat(X; colnames = drivers)
    est = reduce(hcat, [_fvec_r(quantile_regression(y, XN, q)) for q in quantiles])
    est = reshape(est, p, length(quantiles))
    X1 = hcat(ones(n), X)
    # seit 1.6.5 (K5): Bootstrap auf denselben zentrierten/skalierten Treibern (R tail_regression)
    Z1, mq, sq = _qr_scale(X1, true)
    g0 = copy(est)
    if p > 1
        for k in 1:size(est, 2)
            g0[2:end, k] = est[2:end, k] .* sq[2:end]
            g0[1, k] = est[1, k] + SimLev.r_sum(est[2:end, k] .* mq[2:end])
        end
    end
    terms = vcat(["(Intercept)"], drivers)
    nq = length(quantiles)
    se = fill(_NA, p, nq); lo = fill(_NA, p, nq); hi = fill(_NA, p, nq)
    n_failed = 0
    if B > 0
        block === nothing && (block = _rmin(_rmax(2.0, _pw_block_stationary(abs.(y .- SimLev.r_mean(y)))), n / 10))
        S = _SL().main_stream(seed, "tail_regression")                     # Hauptstrom
        bs = Matrix{Float64}[]
        for _b in 1:Int(B)
            idx = _boot_idx_stationary(n, n, block, S)
            yb = y[idx]; Xb = Z1[idx, :]
            m = try
                reduce(hcat, [_qr_unscale(Vector{Float64}(SimLev.DependenceCore.quantile_reg_core(yb, Xb, quantiles[k], g0[:, k],
                                                                     _rmax(SimLev.r_sd(yb), 1e-12), 1e-10, 2000)[1]), mq, sq, true)
                              for k in 1:nq])
            catch e
                e isa SimLev.DependenceCore.QuantileRegError || rethrow()
                fill(_NA, p, nq)
            end
            push!(bs, reshape(m, p, nq))
        end
        n_failed = count(a -> any(isnan, a), bs)
        if n_failed == B
            @warn chk_msg("c.m_tail_regression_2", Int(B))
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
    se = _fvec_r(cf["se"]); lo = _fvec_r(cf["lower"]); up = _fvec_r(cf["upper"])
    y = RFrame("Quantil" => _sprintf_vec("%g %%", 100 .* _fvec_r(cf["quantile"])), "Term" => collect(cf["term"]),
               "Koeffizient" => _sprintf_vec("%.4f", _fvec_r(cf["estimate"])),
               "SE" => [isnan(s) ? "" : _sprintf("%.4f", s) for s in se],
               "90%-KI" => [isnan(a) ? "" : _sprintf("[%.4f, %.4f]", a, b) for (a, b) in zip(lo, up)])
    _ln(io, _print_df(y))
    ols = x["ols"]
    print(io, "\nOLS (Mittelwert): $(join(_sprintf_vec("%s %.4f", ols.names, ols.values), ", "))\n")
    nothing
end

"""
    tail_covar(data, system, assets; state = nothing, q = 0.05, frequency = "week")

CoVaR und Delta-CoVaR (Adrian & Brunnermeier 2016).

Nach Adrian & Brunnermeier (2016): Wie weit verschiebt sich das `q`-Quantil der Rendite von `system` (z. B.
das Portfolio), wenn eine Anlage selbst in ihrem `q`-Quantil steht, gegenüber ihrem Median? Mit `state`
(Drittvariablen, verzögert) werden VaR und CoVaR zeitvariabel: X^sys_t = α + β X^i_t + γ' M_t-1 + ε (Quantil
q) Δ CoVaR_t = β (VaR^i_t(q) - VaR^i_t(0.5)) Dabei ist VaR^i_t(p) das per `quantile_regression()` geschätzte
(bei `state = nothing` konstante) p-Quantil der Rendite der Anlage, also eine Rendite mit Vorzeichen (Verluste
negativ), und CoVaR_t = α + β VaR^i_t(q) + γ' M_t-1. Renditen sind Log-Renditen der Periode in Prozent, 100
log(P_t / P_t-1), aufbereitet wie in `dependence_analysis()` (Fortschreiben fehlender Kurse, letzte Zeile je
ISO-Woche bzw. Monat); Zustandsvariablen gehen mit dem Wert am Ende der Vorperiode ein. Perioden mit fehlenden
Werten entfallen.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Date), Kursspalten (Kursniveaus, keine Renditen) und
  gegebenenfalls Zustandsspalten.
- `system`: Name der Kursspalte des Systems bzw. Portfolios (Zeichenkette).
- `assets`: Zeichenvektor der Kursspalten der einzelnen Anlagen.
- `state`: Optionaler Zeichenvektor der Zustandsspalten (in ihrer eigenen Einheit). `nothing` (Standard) =
  zeitkonstante Quantile.
  Seit 1.6.4 keine Spalte aus system oder assets.
- `q`: Quantil als Anteil (Standard 0.05 = 5-%-Quantil). Seit 1.6.5 ein Fehler bei weniger Perioden als
  Koeffizienten + 1 und eine Warnung, wenn im Rand erwartet weniger als 5 Beobachtungen liegen (Perioden mal
  min(q, 1 - q) < 5; eigene Schwelle).
- `frequency`: Renditefrequenz: `"week"` (Standard, ISO-Woche), `"day"` oder `"month"`.

# Rückgabe
Objekt der Klasse `SimLevCoVaR` mit

- summary: Tabelle (RFrame) je Anlage: `asset`, `beta` (Steigung der Systemrendite auf die Anlagerendite im
  q-Quantil, ohne Einheit), `var`, `covar`, `delta_covar` (Mittel über die Zeit) und `delta_covar_min`
  (kleinster Wert), alle außer `beta` in Prozent je Periode (Renditen mit Vorzeichen, Verluste negativ).
- series: Tabelle (RFrame) mit `date`, `asset`, `var`, `covar`, `delta_covar` je Periode und Anlage (Prozent
  je Periode).

sowie `system`, `state`, `q`, `frequency` und `n` (Anzahl Perioden). Methoden `print` und `plot`.

# Literatur
Adrian, T. & Brunnermeier, M. K. (2016), American Economic Review 106(7), 1705-1741.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1095
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
e = randn(rng, n)
d["aktien"] = 100 .* cumprod(1 .+ 0.01 .* e)
d["anleihen"] = 100 .* cumprod(1 .+ 0.004 .* (0.3 .* e .+ randn(rng, n)))
d["portfolio"] = 0.6 .* d["aktien"] .+ 0.4 .* d["anleihen"]
println(tail_covar(d, "portfolio", ["aktien", "anleihen"]; q = 0.05))
```
"""
function tail_covar(data, system, assets; state = nothing, q = 0.05, frequency = ("week", "day", "month"))
    frequency = _match_arg(frequency, ("week", "day", "month"))
    fn = "tail_covar"                                          # seit 1.6.4 vor der Rechnung (K42 E4)
    system = String(chk_name1(system, fn, "system"))
    system == "date" && chk_stop("e4.date", fn, "system")
    assets = _e4_names(assets, fn, "assets")
    state = _e4_names(state, fn, "state"; null_ok = true)
    _e4_disjoint(vcat([system], assets), state, fn, "system/assets", "state")   # B-013
    _e4_data(data, unique(vcat([system], assets, state === nothing ? String[] : state)), fn)
    data = SimLev.as_rframe(data)
    q = chk_num1(q, fn, "q"; lo = 0, hi = 1, lo_open = true, hi_open = true)
    cols = unique(vcat([system], assets))
    rd = _dep_returns(data, cols, state, frequency)
    ok = _complete_rows((rd[c] for c in names(rd))...)
    rd = SimLev.rows(rd, findall(ok))
    nr = SimLev.nrow(rd)
    M = state === nothing || isempty(state) ? nothing : reduce(hcat, [_fvec_r(rd[c]) for c in state])
    MN = M === nothing ? nothing : NamedMat(M; colnames = state)
    ys = 100 .* _fvec_r(rd[system])
    # seit 1.6.5 (CR2-R-5): zu wenige Perioden Fehler, wenige Randbeobachtungen Warnung (R tail_covar)
    kc = 2 + (M === nothing ? 0 : size(M, 2))
    0 < nr < kc + 1 && chk_stop("c.covar_perioden", fn, nr, kc, kc + 1)
    nr > 0 && nr * min(q, 1 - q) < 5 && @warn SimLev.chk_msg("c.covar_rand", fn, nr, SimLev.chk_fmt(q))
    summ = RFrame[]; series = RFrame[]
    for a in assets
        xi = 100 .* _fvec_r(rd[a])
        bq = _fvec_r(quantile_regression(xi, MN, q)); bm = _fvec_r(quantile_regression(xi, MN, 0.5))
        Mi = M === nothing ? ones(nr, 1) : hcat(ones(nr), M)
        var_q = _matvec(Mi, bq); var_m = _matvec(Mi, bm)
        Xs = M === nothing ? NamedMat(reshape(xi, :, 1); colnames = ["xi"]) : NamedMat(hcat(xi, M); colnames = vcat(["xi"], state))
        bs = _fvec_r(quantile_regression(ys, Xs, q))
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
    y = RFrame("Anlage" => collect(s["asset"]), "beta" => _sprintf_vec("%.3f", _fvec_r(s["beta"])),
               "VaR Anlage" => _sprintf_vec("%.2f", _fvec_r(s["var"])), "CoVaR" => _sprintf_vec("%.2f", _fvec_r(s["covar"])),
               "Delta-CoVaR" => _sprintf_vec("%.2f", _fvec_r(s["delta_covar"])),
               "Delta-CoVaR min" => _sprintf_vec("%.2f", _fvec_r(s["delta_covar_min"])))
    _ln(io, _print_df(y))
    nothing
end

# ═════════════════════════════════════════════════════════════════════════════
# Bootstrap-Validierung und Stress-Regime
# ═════════════════════════════════════════════════════════════════════════════

"`rowsum(L[1:(k*agg), ], rep(1:k, each = agg))` (double-Akkumulation)."
function _rowsum_blocks(L, agg::Int, k::Int)
    L = _fmat_r(L)
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
    pth isa RFrame && return reduce(hcat, [_fvec_r(pth[a]) for a in idx_names])
    if pth isa NamedMat && pth.colnames !== nothing
        return reduce(hcat, [_fvec_r(pth[:, a]) for a in idx_names])
    end
    _fmat(pth)
end

"""
    dependence_validate(boot, data; agg = 5, q = 0.10, max_paths = 200)

Abhängigkeitsstruktur von Bootstrap-Pfaden prüfen.

Vergleicht Kendalls Tau, Pearson-Korrelation, empirische Tail-Abhängigkeit und die untere
Exceedance-Korrelation der Indizes in der Historie mit ihrer Verteilung über die Bootstrap-Pfade. Liegt der
historische Wert am Rand der Pfadverteilung, gibt das Verfahren die Abhängigkeit nicht wieder (z. B.
Tail-Abhängigkeit beim IID-Bootstrap zwar erhalten, Volatilitäts-Clustering aber nicht).

# Argumente
- `boot`: Objekt der Klasse `bootstrap_result` aus `bootstrap()` mit mindestens zwei Indizes in der
  Konfiguration.
- `data`: Historische Daten wie für `bootstrap()` (Tabelle (RFrame) oder Matrix mit den Spalten der
  Konfiguration).
- `agg`: Zeilen je Periode für die Aggregation (ganze Zahl, Standard 5; z. B. 5 Handelstage oder 7
  Kalendertage ergibt Wochen; 1 = keine Aggregation).
  Seit 1.6.4 eine ganze Zahl ≥ 1, höchstens 10^8.
- `q`: Tail-Wahrscheinlichkeit als Anteil für die Tail-Kennzahlen (Standard 0.10, siehe `tail_dependence()`).
- `max_paths`: Höchstens so viele Pfade auswerten (die ersten `max_paths` Pfade; Standard 200).
  Seit 1.6.4 eine ganze Zahl ≥ 1 oder Inf (alle Pfade).

# Rückgabe
Tabelle (RFrame) mit einer Zeile je Indexpaar und Kennzahl: `pair`, `metric` (`"kendall"`, `"pearson"`,
`"lambda_lower"`, `"lambda_upper"`, `"exceed_lower"`), `historical` (Wert der Historie), `median`, `p05`,
`p95` (Median und 5-/95-%-Quantil über die Pfade) und `percentile` (Anteil der Pfade mit Wert <= Historie, 0
bis 1; Werte nahe 0 oder 1 zeigen, dass die Pfade die Kennzahl nicht wiedergeben).

# Details
Alle Kennzahlen werden auf Log-Renditen berechnet, die über nicht überlappende Blöcke von `agg` Zeilen
summiert werden (ein unvollständiger Rest am Ende entfällt; mindestens 20 Blöcke nötig). Historie: Renditen
der Indizes aus `data` gemäß `boot["config"]` (Brutto-Renditen bzw. Kurse bei `input = "prices"`); Pfade:
Log-Differenzen der Indexspalten der Pfade. Hebelprodukte und Zusatzreihen gehen nicht ein.

# Beispiel
```julia
using SimLev, Random
rng = MersenneTwister(2)
us = 1 .+ 3e-4 .+ 0.01 .* randn(rng, 1500)
d = RFrame("us" => us, "eu" => us .* (1 .+ 0.004 .* randn(rng, 1500)))
b = bootstrap(d, bootstrap_config((us = "us", eu = "eu")); method = "stationary", n = 20, params = (L = 20,),
              seed = 1, progress = false)
println(dependence_validate(b, d; agg = 5, q = 0.10))
```
"""
function dependence_validate(boot, data; agg = 5, q = 0.10, max_paths = 200)
    data = SimLev.as_rframe(data)
    SimLev.inherits(boot, "bootstrap_result") || chk_stop("c.m_dependence_validate")
    fn = "dependence_validate"                                 # seit 1.6.4 (B-033, B-053)
    agg = _e4_count(agg, fn, "agg")
    q = chk_num1(q, fn, "q"; lo = 0, hi = 1, lo_open = true, hi_open = true)
    max_paths = chk_scalar(max_paths)
    (_e4_numscalar(max_paths) && (Float64(max_paths) == Inf || (isfinite(Float64(max_paths)) &&
        Float64(max_paths) == trunc(Float64(max_paths)) && Float64(max_paths) >= 1))) || chk_stop("e1.ganz_inf", fn, "max_paths", chk_fmt(1))
    cfg = boot["config"]
    idx_names = _as_names(_el(cfg, "index_names"))
    length(idx_names) < 2 && error("dependence_validate: mindestens zwei Indizes in der Konfiguration.")
    SimLev.Bootstrap._boot_numcols(data, cfg, fn)              # seit 1.6.5 (CR2-X6-1) wie bootstrap()
    ret = _fmat_r(_el(SimLev.Bootstrap._extract_returns(data, cfg, fn), "ret"))
    hist = SimLev.RLibm.log.(ret)
    agg = Int(agg)
    function aggr(L)
        k = div(size(L, 1), agg)
        k < 20 && chk_stop("c.m_aggr")
        _rowsum_blocks(L, agg, k)
    end
    td_fun = _tail_dep_fun(q)                                   # seit 1.6.4 ohne RFrame je Paar (B-064)
    function stats_of(L)
        A = aggr(L)
        out = Float64[]
        for (i, j) in _combn2(size(A, 2))
            x = A[:, i]; y = A[:, j]
            td = td_fun(x, y)
            append!(out, [_kendall(x, y), _cor1(x, y), td[1], td[2], td[3]])
        end
        out
    end
    h = stats_of(hist)
    paths = collect(boot["paths"])
    Float64(max_paths) == Inf || (paths = paths[1:min(length(paths), Int(max_paths))])   # Inf = alle Pfade
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
Variablen aus `env` (bei einem Modul seit 1.6.4 nur dessen eigene Namen, `SimLev._UserEnv`). Eine Julia-Funktion
`f` wird als `f(data)` aufgerufen.
"""
function _eval_condition(expr, data; env = Main)
    expr isa Function && return expr(data)
    # seit 1.6.4 (Entscheidung 72, T3-R2) nur die eigenen Namen von env wie tactical_rules (bis 1.6.3 auch Base und
    # Paketfunktionen, z. B. minimum, first, nrow)
    SimLev.RExpr.eval_r(String(expr), _as_frame(data); env = env isa Module ? SimLev._UserEnv(env) : env)
end

"""
    regime_subset(data, condition; min_run = 1, env = Main)

Zeilen eines Regimes für Stress-Bootstraps.

Wählt die Zeilen aus, in denen `condition` gilt (z. B. hohe Inflation), und verwirft zu kurze Episoden. Mit
Rendite-Eingabe (`bootstrap_config(input = "returns")`) lässt sich das Ergebnis direkt an `bootstrap()` oder
`bootstrap_study()` übergeben: Die Pfade bestehen dann nur aus Blöcken dieses Regimes (inklusive der
mitgezogenen Zusatzreihen wie Zinsen). Die Episoden werden ohne Trennung aneinandergehängt; Bootstrap-Blöcke
können daher über Episodengrenzen hinwegreichen.

# Argumente
- `data`: Tabelle (RFrame), eine Zeile je Beobachtung (für `bootstrap()` typischerweise Tage mit
  Brutto-Renditen wie 1.002 und Zusatzreihen). Eine Spalte `date` ist optional.
- `condition`: Logischer Vektor der Länge `nrow(data)` (NA = false) oder Ausdruck als Zeichenkette, der in
  `data` ausgewertet wird, z. B. `"inflation >= 4"`.
  Seit 1.6.4 in allen Sprachen wie R as.logical gelesen (NA = FALSE); nicht lesbarer Text, Faktor, Datum, Liste oder Matrix sind ein Fehler; auch das Ergebnis des Ausdrucks.
  Seit 1.6.4 gelten Texte in R, Python und Julia gleich im gemeinsamen Umfang der Regeltexte von
  `tactical_rules()` (in Julia nur die eigenen Namen von `env`, bis 1.6.3 auch `Base` und Paketfunktionen);
  `condition` kann auch eine Funktion von `data` sein (Ergebnis wie oben).
- `min_run`: Mindestlänge einer Episode in Zeilen (ganze Zahl, Standard 1); kürzere zusammenhängende
  Abschnitte werden verworfen.
- `env`: Modul, in dem freie Variablen und Funktionen der Bedingungen gesucht werden (Standard `Main`).

# Rückgabe
Teilmenge von `data` (Zeilen der behaltenen Episoden in ursprünglicher Reihenfolge) mit Attribut `episodes`:
Tabelle (RFrame) mit `start`, `end` (Zeilennummern in `data`), `length` (Zeilen) und, falls `data` eine Spalte
`date` hat, `start_date`, `end_date`. Fehler, wenn keine Episode die Bedingung erfüllt.

# Beispiel
```julia
using SimLev, Random
d = RFrame("r" => 1 .+ 0.01 .* randn(MersenneTwister(1), 100), "infl" => [fill(1.0, 40); fill(5.0, 30); fill(1.0, 30)])
s = regime_subset(d, "infl >= 4"; min_run = 10)
println(SimLev.attrs(s)["episodes"])
```
"""
function regime_subset(data, condition; min_run = 1, env = Main)
    fn = "regime_subset"                                       # seit 1.6.4 (K42 E4, B-008, B-036)
    chk_df(data, fn, "data")
    data = SimLev.as_rframe(data)
    data = _as_frame(data)
    # seit 1.6.5 (CR2-P-4): Textvektor auch mit fehlenden Werten (alle übrigen Elemente Text) wie in R
    if condition isa Union{AbstractVector,Tuple} && any(v -> v isa AbstractString, condition) &&
       all(v -> v isa AbstractString || v === missing || v === nothing, condition)
        length(condition) == 1 || chk_stop("e4.bedingung", fn)
        condition = String(first(condition))
    end
    min_run = _e4_count(min_run, fn, "min_run")
    condition isa AbstractString && isempty(strip(condition)) && chk_stop("e4.bedingung", fn)   # leer: in R NULL
    cond = condition isa AbstractString ? _eval_condition(condition, data; env = env) :
           condition isa Function ? _eval_condition(condition, data; env = env) : condition
    c = _e4_cond(cond, fn)
    length(c) != SimLev.nrow(data) && chk_stop("c.m_regime_subset")
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
    any(keep) || chk_stop("c.m_regime_subset_2")
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
                          width = 900, height = 650)
    type = _match_arg(type, ("overview", "rolling", "tail", "conditional", "scatter"))
    pn = collect(x["pairs"]["pair"])
    pair = _e4_pick(pair, pn, "plot.SimLevDependence", "pair")   # seit 1.6.4 (B-007)
    (x["conditional"] === nothing || length(x["conditional"]) == 0) ||
        (condition = _e4_pick(condition, collect(keys(x["conditional"])), "plot.SimLevDependence", "condition"))
    i = pair isa AbstractString ? findfirst(==(pair), pn) : Int(pair)
    # seit 1.6.5 (CR2-L-2): Anlagen aus der Paarliste, nicht aus dem Text
    ab = [x["assets"][k] for k in _combn2(length(x["assets"]))[i]]
    X = x["returns"]
    data = SimLev.RList()
    function p_roll(c, box)
        if x["rolling"] === nothing
            data["rolling"] = SimLev.RFrame("date" => Date[], "rolling" => Float64[])
            return
        end
        rl = x["rolling"]
        series = [(_days(rl["date"]), _fvec(rl[pn[i]]), "#2C6E9B", "rollierend")]
        d = SimLev.RFrame("date" => collect(Date, rl["date"]), "rolling" => copy(_fvec_r(rl[pn[i]])))
        if x["dcc"] !== nothing
            C = x["dcc"]["correlation"]
            push!(series, (_days(X["date"]), _fvec(C[:, pn[i]]), "#B5562B", "DCC"))
            d["dcc"] = copy(_fvec_r(C[:, pn[i]]))
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
        data["tail"] = SimLev.RFrame("q" => copy(qg), "lower" => copy(_fvec_r(td["lower"])), "upper" => copy(_fvec_r(td["upper"])),
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
        lo = haskey(ct, "pearson_lo") ? _fvec_r(ct["pearson_lo"])[sel] : nothing
        hi = haskey(ct, "pearson_hi") ? _fvec_r(ct["pearson_hi"])[sel] : nothing
        _grid_bars!(c, box, collect(ct["regime"])[sel], _fvec_r(ct["pearson"])[sel]; lo = lo, hi = hi,
                    pts = _fvec_r(ct["lambda_lower"])[sel], ylim = (-1.0, 1.0), title = "$(pn[i]) nach '$cn'", ylabel = "Korrelation")
        d = SimLev.RFrame("regime" => String[string(v) for v in collect(ct["regime"])[sel]], "pearson" => _fvec_r(ct["pearson"])[sel])
        lo === nothing || (d["pearson_lo"] = lo)
        hi === nothing || (d["pearson_hi"] = hi)
        d["lambda_lower"] = _fvec_r(ct["lambda_lower"])[sel]
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
    svg = _grid_svg(ks, k -> ((c, box) -> fns[k](c, box)); width = width, height = height)
    return (svg, data)
end

"""
`plot.SimLevTailRegression` (SVG). Liefert `(svg, data)`; `data` je Treiber (Schlüssel = Name des
Treibers): `quantile`, `estimate`, `lower`, `upper`.
"""
function _plot_tail_regression(x; width = 900, height = 400)
    drv = x["drivers"]
    data = SimLev.RList()
    svg = _grid_svg(collect(drv), dv -> function (c, box)
        cf = x["coefficients"]
        sel = findall(==(dv), cf["term"])
        qv = _fvec_r(cf["quantile"])[sel]; est = _fvec_r(cf["estimate"])[sel]
        lo = _fvec_r(cf["lower"])[sel]; hi = _fvec_r(cf["upper"])[sel]
        _grid_lines!(c, box, [(qv, est, "#2C6E9B", "Quantilsregression")]; band = all(isnan, lo) ? nothing : (qv, lo, hi),
                     hline = [(x["ols"][dv], "#B5562B"), (0.0, "grey")], points = true, xlabel = "Quantil",
                     ylabel = "Koeffizient", title = "$(x["asset"]): Effekt von $dv")
        data[String(dv)] = SimLev.RFrame("quantile" => qv, "estimate" => est, "lower" => lo, "upper" => hi)
    end; ncol = length(drv), width = width, height = height)
    return (svg, data)
end

"""
`plot.SimLevCoVaR` (SVG). Liefert `(svg, data)`; `data`: `delta_covar` (`asset`, `date`,
`delta_covar` in % je Periode wie in `series`; Zeilen je Anlage in Zeichenreihenfolge).
"""
function _plot_covar(x; width = 800, height = 450)
    s = x["series"]
    cols = ["#2C6E9B", "#B5562B", "#3E8E5A", "#8A5BA8", "#C49A2C"]
    a = unique(s["asset"])
    series = [(_days(s["date"][s["asset"] .== aj]), _fvec_r(s["delta_covar"])[s["asset"] .== aj], cols[(j-1)%5+1], aj)
              for (j, aj) in enumerate(a)]
    svg = _grid_svg(["x"], _ -> ((c, box) -> _grid_lines!(c, box, series; dates = true, ylabel = "Delta-CoVaR (%)",
                                                          title = _sprintf("Delta-CoVaR für '%s' (q = %g)", x["system"], x["q"])));
                    width = width, height = height)
    sa = String[string(v) for v in s["asset"]]
    data = SimLev.RList("delta_covar" => SimLev.RFrame(
        "asset" => vcat([sa[sa .== aj] for aj in a]...),
        "date" => vcat([collect(Date, s["date"])[sa .== aj] for aj in a]...),
        "delta_covar" => vcat([_fvec_r(s["delta_covar"])[sa .== aj] for aj in a]...)))
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
