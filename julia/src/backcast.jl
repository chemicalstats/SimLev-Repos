# Backcast – Gegenstück zu r/R/backcast.R und python/simlev/backcast.py
#
# Verlängert die Historie eines ETF/ETP (auch gehebelt oder invers) über
# dessen Auflegung hinaus:
#   1. backcast_fit()  passt die Modellparameter auf dem Überlappungszeitraum
#                      von Produkt und Basisindex an,
#   2. backcast()      rechnet das Produkt zurück und verkettet mit der echten
#                      Kursreihe.
#
# Strukturmodell:
#   r_t = beta * L * x_t + (1 - L) * rate_t * T_t / rate_basis - TER_t * T_t / ter_basis
#       - spread * m(L) * T_t / rate_basis - drag * T_t / 365
# PROZENT-KONVENTION: ter, rate, spread und drag in Prozent p. a.
module Backcast

import ..SimLev
using ..SimLev: _bc_doc, _bc_panel
using ..SimLev: RList, RFrame, RVector, nrow, ncol, attrs, NA, rows,
                register_print!, register_summary!, register_plot!, inherits
using Dates

export backcast_fit, backcast

const DP = SimLev.DataPrep

_libm() = SimLev.RLibm
_stats() = SimLev.RStats

# ═══════════════════════════════════════════════════════════════════════════
# Interne Helfer
# ═══════════════════════════════════════════════════════════════════════════

_isnumval(x) = (x isa Real && !(x isa Bool)) ||
               (x isa AbstractVector && !isempty(x) && DP._is_numeric_col(x))

# --- Eingabeprüfung Backcast (seit 1.6.4, K42 E4, B-017, B-087; Hilfen in pruefen.jl und dependence.jl) ----------

_E() = SimLev.Dependence

"""Angabe einer Reihe (ter, rate, fx) vor `_resolve_series` (R `.bc_check_series`): Zahl(en) endlich, Spaltenname
einer Zahlenspalte mit endlichen Werten oder NA, Tabelle (date, Wert) mit endlichen Zahlen; Faktor, Wahrheitswerte,
Listen aus Text und Matrizen sind ein Fehler."""
function _bc_check_series(@nospecialize(x), data, fn, arg)
    E = _E()
    x === nothing && return x
    x isa SimLev.RFmt.RFactor && SimLev.chk_stop("faktor", fn, arg)
    if x isa RFrame
        if ncol(x) >= 2
            nm = names(x)
            dcol = "date" in nm ? "date" : nm[1]
            vcol = [k for k in nm if k != dcol][1]
            x[dcol] isa SimLev.RFmt.RFactor && SimLev.chk_stop("spalte_faktor", fn, dcol)
            E._e4_numcol(x, vcol, fn)
            all(isfinite, DP._as_numeric(x[vcol])) || SimLev.chk_stop("e3.werte", fn, arg)
        end
        return x
    end
    xs = x isa RVector ? x.values : x
    (xs isa AbstractVector && length(xs) == 1 && xs[1] isa AbstractString) && (xs = String(xs[1]))
    if xs isa AbstractString
        isempty(xs) && SimLev.chk_stop("e4.reihe", fn, arg)
        if String(xs) in names(data)
            E._e4_numcol(data, String(xs), fn)
            any(isinf, DP._as_numeric(data[String(xs)])) && SimLev.chk_stop("e1.spalte_endlich", fn, String(xs))
        end
        return x
    end
    vals = xs isa NamedTuple ? collect(Any, values(xs)) : xs isa AbstractDict ? collect(Any, values(xs)) :
           (xs isa AbstractVector && !isempty(xs) && all(p -> p isa Pair, xs)) ? Any[p.second for p in xs] :
           xs isa AbstractMatrix ? nothing : xs isa Union{AbstractVector,Tuple} ? collect(Any, xs) : Any[xs]
    (vals === nothing || isempty(vals) || !all(v -> E._e4_numscalar(v) || E._e4_isna(v), vals)) && SimLev.chk_stop("e4.reihe", fn, arg)
    all(v -> E._e4_numscalar(v) && isfinite(Float64(v)), vals) || SimLev.chk_stop("e3.werte", fn, arg)
    return x
end

"Gemeinsame Modellangaben von `backcast_fit()` und `backcast()` ohne Fit (R `.bc_check_args`)."
function _bc_check_args(fn, data, product, index, ter, leverage, rate, fx, rate_lag, ter_basis, rate_basis)
    E = _E()
    SimLev.chk_df(data, fn, "data")                            # Entscheidung 6, B-057
    SimLev.chk_name1(product, fn, "product"); SimLev.chk_name1(index, fn, "index")
    "date" in names(data) && SimLev.chk_col_nofactor(data, "date", fn)   # Entscheidung 15
    for col in (product, index)
        String(col) in names(data) && E._e4_numcol(data, String(col), fn)
    end
    lv = leverage isa RVector ? leverage.values : leverage
    (!(lv isa SimLev.RFmt.RFactor) && _isnumval(lv) && length(lv) == 1 && isfinite(Float64(first(lv))) && Float64(first(lv)) != 0) ||
        error("'leverage' muss eine Zahl ungleich 0 sein.")    # seit 1.6.4 auch NA und Inf
    _bc_check_series(ter, data, fn, "ter"); _bc_check_series(rate, data, fn, "rate"); _bc_check_series(fx, data, fn, "fx")
    SimLev.chk_int1(rate_lag, fn, "rate_lag"; lo = 0, hi = max(0, nrow(data) - 1))
    SimLev.chk_num1(ter_basis, fn, "ter_basis"; lo = 0, lo_open = true)
    SimLev.chk_num1(rate_basis, fn, "rate_basis"; lo = 0, lo_open = true)
    return true
end

"lag: \"auto\" oder ganze Zahl mit |lag| < nrow(data) (R `.bc_check_lag`)."
function _bc_check_lag(@nospecialize(lag), data, fn; auto_ok::Bool = true)
    key = auto_ok ? "e4.lag" : "e4.lag_ohne_fit"
    lag = SimLev.chk_scalar(lag)
    auto_ok && lag isa AbstractString && lag == "auto" && return lag
    (_E()._e4_numscalar(lag) && isfinite(Float64(lag)) && Float64(lag) == trunc(Float64(lag)) && abs(Float64(lag)) < nrow(data)) ||
        SimLev.chk_stop(key, fn)
    return lag
end

"drag, spread, beta als benannte Liste einzelner endlicher Zahlen (fixed, params; R `.bc_check_par`)."
function _bc_check_par(@nospecialize(p), fn, arg; null_ok::Bool = false)
    p === nothing && null_ok && return p
    pr = p isa RList ? [k => p[k] for k in keys(p)] : p isa NamedTuple ? [String(k) => v for (k, v) in pairs(p)] :
         p isa AbstractDict ? [string(k) => v for (k, v) in p] :
         (p isa AbstractVector && all(q -> q isa Pair, p)) ? [string(q.first) => q.second for q in p] : nothing
    ok = pr !== nothing && all(q -> q.first in ("drag", "spread", "beta"), pr) && length(unique(first.(pr))) == length(pr)
    ok && for q in pr
        v = SimLev.chk_scalar(q.second)
        (_E()._e4_numscalar(v) && isfinite(Float64(v))) || (ok = false)
    end
    ok || SimLev.chk_stop("e4.parameter", fn, arg)
    return p
end

"""
    _resolve_series(x, data, what; default = 0)

Zeitreihe aus flexibler Nutzerangabe auflösen (R: `.resolve_series`):
`nothing` (→ `default`), Skalar, Vektor der Länge `nrow(data)`, Spaltenname
in `data`, `RFrame(date, value)` als Stufenfunktion oder benannter Vektor mit
Datumsnamen (Wert gilt ab diesem Datum). Liefert einen Float64-Vektor der
Länge `nrow(data)`.
"""
function _resolve_series(x, data, what; default = 0)
    data = SimLev.as_rframe(data)
    n = DP._nrow(data)
    x === nothing && return fill(Float64(default), n)
    xf = DP._as_frame(x)
    if xf isa RFrame
        ncol(xf) < 2 && error("$(what): data.frame braucht die Spalten date und Wert.")
        nm = names(xf)
        dcol = "date" in nm ? "date" : nm[1]
        vcol = [k for k in nm if k != dcol][1]
        fd = DP._to_date(xf[dcol], "$(what): Datum")
        # seit 1.6.4 abgelehnt wie in R und Python (Entscheidung 147, T3-N5; bis 1.6.3 wurde die Zeile still übergangen)
        i0 = findfirst(isnan, DP._days(fd))
        i0 === nothing || SimLev.chk_stop("ut3.datum_fehlt", what, i0)
        return _step_series(fd, DP._as_numeric(xf[vcol]), DP._to_date(DP._col(data, "date"), what))
    end
    xs = x isa RVector ? x.values : x
    if xs isa AbstractString || (xs isa AbstractVector && length(xs) == 1 && xs[1] isa AbstractString)
        c = xs isa AbstractString ? String(xs) : String(xs[1])
        c in DP._names(data) || error("$(what): Spalte '$(c)' fehlt im Datensatz.")
        v = DP._as_numeric(DP._col(data, c))
        any(isnan, v) && (v = _fill_na(v, "locf"))
        return v
    end
    if DP._is_named_numeric(x)
        nms, vals = DP._named_parts(x)
        nd = DP._names_as_dates_optional(nms)
        if length(vals) >= 1 && !any(isnan, nd)
            return _step_series(nd, vals, DP._to_date(DP._col(data, "date"), what))
        end
        xs = vals
    end
    if _isnumval(xs)
        a = xs isa AbstractVector ? DP._as_numeric(xs) : [Float64(xs)]
        length(a) == 1 && return fill(a[1], n)
        length(a) == n && return a
    end
    error("$(what): nicht interpretierbare Angabe (Skalar, Vektor der Länge $(n), Spaltenname, data.frame(date, Wert) oder benannter Vektor mit Datumsnamen).")
end

"""
    _step_series(from, value, dates)

Stufenfunktion: Wert gilt ab Datum (vor dem ersten Datum: erster Wert).
`from` und `dates` als Datumsvektor oder Float64-Tage.
"""
function _step_series(from, value, dates)
    f = DP._days(from)
    v = DP._as_numeric(value)
    o = DP._stable_order(f)
    f = f[o]; v = v[o]
    d = DP._days(dates)
    out = Vector{Float64}(undef, length(d))
    for i in eachindex(d)
        if isnan(d[i])
            out[i] = NA
        else
            k = searchsortedlast(f, d[i])
            k == 0 && (k = 1)
            out[i] = k <= length(v) ? v[k] : NA
        end
    end
    return out
end

using ..SimLev: _getel   # util.jl (seit 1.6.4 eine Fassung)

"""
    _fill_na(v, method = "locf"; keep_leading = false)

Fehlende Werte füllen (R: `.fill_na`): `"locf"`, `"linear"`,
`"stine"` (Stineman-Interpolation der inneren Lücken mit der C-Bibliothek slc,
`SLib.stineman`, seit 1.0.0; Stützstellen sind die Positionen der
vorhandenen Werte) oder `"none"`. Mit `keep_leading = true` bleiben führende NA erhalten, sonst wird
rückwärts gefüllt. Liefert eine Float64-Kopie.
"""
function _fill_na(v, method = ("locf", "linear", "stine", "none"); keep_leading::Bool = false)
    method = DP._match_arg(method, ("locf", "linear", "stine", "none"))
    return _fill_na_m(DP._as_numeric(v), method, keep_leading)
end
# Funktionsgrenze (seit 1.6.1): der Rumpf wird für den Typ von `v` übersetzt, das Ergebnis ist ableitbar
function _fill_na_m(v, method::String, keep_leading::Bool)
    ok = findall(!isnan, v)
    (method == "none" || isempty(ok) || length(ok) == length(v)) && return v
    first_, last_ = ok[1], ok[end]
    if method == "locf"
        idx = zeros(Int, length(v))
        idx[ok] .= ok
        for i in 2:length(idx)
            idx[i] < idx[i-1] && (idx[i] = idx[i-1])
        end
        idx[idx .== 0] .= first_
        out = v[idx]
    elseif method == "linear"
        out = copy(v)
        inner = first_:last_
        r = _stats().approx(Float64.(ok), v[ok]; xout = Float64.(collect(inner)))
        out[inner] .= _getel(r, "y")
        last_ < length(v) && (out[last_+1:end] .= v[last_])
        first_ > 1 && (out[1:first_-1] .= v[first_])
    else
        out = copy(v)
        gap = setdiff(first_:last_, ok)                       # innere Lücken; Stützstellen = Positionen der Werte
        out[gap] .= SimLev.SLib.stineman(Float64.(ok), v[ok], Float64.(gap))   # Stineman (slc)
        last_ < length(v) && (out[last_+1:end] .= v[last_])
        first_ > 1 && (out[1:first_-1] .= v[first_])
    end
    keep_leading && first_ > 1 && (out[1:first_-1] .= NA)
    return out
end

"Vektor um `k` Zeilen verschieben (k > 0: Verzögerung). R: `.shift`."
function _shift(v, k)
    v = Float64.(v)
    n = length(v)
    k = Int(k)
    k == 0 && return copy(v)
    k > 0 && return vcat(fill(NA, k), v[1:max(n - k, 0)])
    return vcat(v[1-k:n], fill(NA, -k))
end

_sq(e) = [x * x for x in e]

"Verlustfunktionen für den Fit (R: `.bc_loss`)."
function _bc_loss(e, loss)
    e = [x for x in e if isfinite(x)]
    isempty(e) && return Inf
    loss == "rmse" && return sqrt(SimLev.r_mean(_sq(e)))
    loss == "mse" && return SimLev.r_mean(_sq(e))
    loss == "mae" && return SimLev.r_mean(abs.(e))
    loss == "median" && return _stats().median(abs.(e))
    loss == "max" && return maximum(abs.(e))
    error("Unbekannte loss-Funktion '$(loss)'.")
end

"Grid-Search-Metriken (R: `.bc_metric_table`): bestes Gitterelement je Metrik."
function _bc_metric_table(err_mat::AbstractMatrix, grid)
    # seit 1.6.4 (B-071) je Spalte einmal NA-Filter und abs (bis 1.6.3 je Metrik eine eigene Kopie); gleiche Werte
    # (v * v = |v| * |v|, dieselben Summen)
    nms = ["median_absolute_error", "mean_absolute_error", "mean_squared_error", "root_mean_squared_error",
           "max_absolute_error", "final_absolute_error"]
    G = size(err_mat, 2)
    M = Matrix{Float64}(undef, 6, G)
    for j in 1:G
        x = err_mat[:, j]
        a = abs.(Float64[v for v in x if !isnan(v)])
        mq = SimLev.r_mean(a .* a)
        M[1, j] = _stats().median(a)
        M[2, j] = SimLev.r_mean(a)
        M[3, j] = mq
        M[4, j] = sqrt(mq)
        M[5, j] = isempty(a) ? -Inf : maximum(a)
        M[6, j] = abs(x[findlast(isfinite, x)])
    end
    vals = Float64[Float64(grid[something(SimLev._which_min(M[k, :]), 0)]) for k in 1:6]
    return RVector(vals; names = nms)
end

struct _Prep
    data::RFrame
    n::Int
    dates::Vector{Float64}
    idx::Vector{Float64}
    prod::Vector{Float64}
    x::Vector{Float64}
    dd::Vector{Float64}
    leverage::Float64
    ter::Vector{Float64}
    rate::Vector{Float64}
    ter_cost::Vector{Float64}
    fin::Vector{Float64}
    sp_unit::Vector{Float64}
    dr_unit::Vector{Float64}
end

"Überlappung, Komponenten und Hilfsgrößen vorbereiten (R: `.bc_prepare`)."
function _bc_prepare(data, product, index, ter, leverage, rate, fx, rate_lag,
                     ter_basis, rate_basis, accrual, index_fill, lag)
    data = DP._as_frame(data)
    data isa RFrame || error("'data' muss ein data.frame sein.")
    "date" in names(data) || error("'data' braucht eine Spalte 'date'.")
    data = copy(data)
    dts = DP._to_date(data["date"], "'data\$date'")
    data["date"] = dts
    dd0 = DP._days(dts)
    any(isnan, dd0) && error("'data\$date' enthält fehlende Daten.")
    any(i -> dd0[i+1] <= dd0[i], 1:length(dd0)-1) &&
        error("'data\$date' muss streng aufsteigend und ohne Duplikate sein.")
    for col in (product, index)
        String(col) in names(data) || error("Spalte '$(col)' fehlt im Datensatz.")
    end
    lv = leverage isa RVector ? leverage.values : leverage
    (_isnumval(lv) && length(lv) == 1 && Float64(first(lv)) != 0) || error("'leverage' muss eine Zahl ungleich 0 sein.")
    L = Float64(first(lv))
    idx = DP._as_numeric(data[String(index)])
    fx !== nothing && (idx = idx .* _resolve_series(fx, data, "fx"))
    any(isnan, idx) && (idx = _fill_na(idx, index_fill; keep_leading = true))
    any(v -> !isnan(v) && v <= 0, idx) && error("Indexwerte müssen positiv sein.")
    prod = DP._as_numeric(data[String(product)])
    for i in eachindex(prod)
        (!isnan(prod[i]) && prod[i] <= 0) && (prod[i] = NA)
    end
    n = nrow(data)
    dd = vcat(1.0, Float64[dd0[i+1] - dd0[i] for i in 1:n-1])
    x = vcat(NA, Float64[idx[i] / idx[i-1] - 1 for i in 2:n])
    lag != 0 && (x = _shift(x, lag))
    ter_v = _resolve_series(ter, data, "ter")
    rate_v = _resolve_series(rate, data, "rate")
    rate_lag != 0 && (rate_v = _fill_na(_shift(rate_v, rate_lag), "locf"))
    ter_cost = if accrual == "geometric"
        Float64[SimLev._pow1m(ter_v[i] / 100, dd[i] / ter_basis) for i in 1:n]   # seit 1.6.2 (P1)
    else
        Float64[ter_v[i] / 100 * dd[i] / ter_basis for i in 1:n]
    end
    fin = Float64[(1 - L) * rate_v[i] / 100 * dd[i] / rate_basis for i in 1:n]
    m_lev = max(L - 1, 0.0) + max(-L, 0.0)
    return _Prep(data, n, dd0, idx, prod, x, dd, L, ter_v, rate_v, ter_cost, fin,
                 Float64[m_lev / 100 * d / rate_basis for d in dd], Float64[d / 100 / 365 for d in dd])
end

_par(p, k) = Float64(p[k])

"Modellrenditen für einen Parametersatz (R: `.bc_model_returns`)."
function _bc_model_returns(prep::_Prep, par, model, reg = nothing)
    # seit 1.5.1 typstabil: Parameter als Float64 in eigene Schleifen (_bc_mr_*); bis 1.5.0 Komprehensionen über
    # Werte aus der RList (dynamische Aufrufe je Tag, 5,6-mal langsamer als R). Rechenfolge unverändert.
    sp = _par(par, "spread"); dr = _par(par, "drag")
    model == "structural" && return _bc_mr_structural(prep, _par(par, "beta"), sp, dr)
    return _bc_mr_spread(prep, _bc_base(prep, par, model, reg), sp, dr)
end

# Basis der Modellrenditen ohne spread und drag (R: `.bc_base`), Vector{Float64} der Länge n
function _bc_base(prep::_Prep, par, model, reg)
    model == "structural" && return _bc_base_structural(prep, _par(par, "beta"))
    if model == "linear"
        # seit 1.6.4 die Koeffizienten als Float64 an eine typisierte Schleife (B-067; bis 1.6.3 Komprehension mit
        # Werten aus der RList, dynamischer Aufruf je Tag); gleiche Ausdrücke a + b x[i]
        cf = _coef(reg)
        return _bc_base_linear(prep.x, Float64(cf[1]), Float64(cf[2]))
    end
    out = fill(NA, prep.n)
    ok = findall(isfinite, prep.x)
    out[ok] .= SimLev.SLib.smspline_predict(reg["fit"], prep.x[ok])   # außerhalb linear fortgesetzt
    return out
end

function _bc_base_linear(x::Vector{Float64}, a::Float64, b::Float64)
    out = Vector{Float64}(undef, length(x))
    @inbounds for i in eachindex(x)
        out[i] = a + b * x[i]
    end
    out
end

function _bc_base_structural(prep::_Prep, b::Float64)
    x = prep.x; fin = prep.fin; tc = prep.ter_cost; L = prep.leverage
    out = Vector{Float64}(undef, prep.n)
    @inbounds for i in 1:prep.n
        out[i] = b * L * x[i] + fin[i] - tc[i]
    end
    out
end

function _bc_mr_structural(prep::_Prep, b::Float64, sp::Float64, dr::Float64)
    x = prep.x; fin = prep.fin; tc = prep.ter_cost; su = prep.sp_unit; du = prep.dr_unit; L = prep.leverage
    out = Vector{Float64}(undef, prep.n)
    @inbounds for i in 1:prep.n
        base = b * L * x[i] + fin[i] - tc[i]
        out[i] = base - sp * su[i] - dr * du[i]
    end
    out
end

function _bc_mr_spread(prep::_Prep, base::Vector{Float64}, sp::Float64, dr::Float64)
    su = prep.sp_unit; du = prep.dr_unit
    out = Vector{Float64}(undef, prep.n)
    @inbounds for i in 1:prep.n
        out[i] = base[i] - sp * su[i] - dr * du[i]
    end
    out
end

# Fenster rws eines Fits (seit 1.6.4, B-068, B-106): Einheiten und Basis auf rws; ohne Basis (Strukturmodell mit
# gesuchtem beta) je Auswertung b L x + fin - ter_cost. Typisierte Felder (Funktionsgrenze für die Schleifen).
struct _BcRows
    x::Vector{Float64}
    fin::Vector{Float64}
    tc::Vector{Float64}
    su::Vector{Float64}
    du::Vector{Float64}
    base::Vector{Float64}
    hasbase::Bool
    L::Float64
end
_bc_rows(prep::_Prep, base::Union{Nothing,Vector{Float64}}, rws) =
    _BcRows(prep.x[rws], prep.fin[rws], prep.ter_cost[rws], prep.sp_unit[rws], prep.dr_unit[rws],
            base === nothing ? Float64[] : base, base !== nothing, prep.leverage)
# Modellrenditen auf rws, elementweise wie _bc_model_returns(prep, p, model, reg)[rws]
function _bc_returns_on(w::_BcRows, b::Float64, sp::Float64, dr::Float64)
    m = length(w.su)
    out = Vector{Float64}(undef, m)
    if w.hasbase
        bs = w.base
        @inbounds for i in 1:m
            out[i] = bs[i] - sp * w.su[i] - dr * w.du[i]
        end
    else
        L = w.L
        @inbounds for i in 1:m
            out[i] = (b * L * w.x[i] + w.fin[i] - w.tc[i]) - sp * w.su[i] - dr * w.du[i]
        end
    end
    out
end

_coef(reg) = (c = reg["coef"]; c isa RVector ? c.values : collect(Float64, c))

_cumlog(rr) = SimLev.r_cumsum(Float64[_libm().log1p(max(v, -0.999999)) for v in rr])

"Abweichungsvektor(en) im Fit-Fenster (R: `.bc_errors`)."
function _bc_errors(r, win, obs, objective, horizon)
    rr = Float64[r[i] for i in win]                         # seit 1.6.4 eine Kopie (B-107)
    rr[1] = 0.0
    for i in eachindex(rr)
        isfinite(rr[i]) || (rr[i] = 0.0)
    end
    ls = _cumlog(rr)
    so = ls[obs.pos]; po = obs.logp
    e_lvl = (so .- so[1]) .- (po .- po[1])
    objective == "level" && return e_lvl
    m = length(so)
    h = max(1, Int(trunc(horizon)))
    e_ret = m > h ? Float64[(so[i+h] - so[i]) - (po[i+h] - po[i]) for i in 1:m-h] : Float64[]
    objective == "return" && return e_ret
    return (level = e_lvl, ret = e_ret)
end

"Daten der Zielfunktion für die C-Bibliothek (R: `.bc_cprob`)."
function _bc_cprob(prep, model, reg, rws, obs, objective, loss, horizon, hybrid_weight)
    if model == "structural"
        x = Float64.(prep.x[rws]); c1 = Float64.(prep.fin[rws]); c2 = Float64.(prep.ter_cost[rws])
    else
        x = nothing; c2 = nothing
        c1 = Float64.(_bc_model_returns(prep, RList("drag" => 0.0, "spread" => 0.0, "beta" => 1.0), model, reg)[rws])
    end
    return (x, c1, c2, Float64(prep.leverage), Float64.(prep.sp_unit[rws]), Float64.(prep.dr_unit[rws]), collect(obs.pos),
            Float64.(obs.logp), (findfirst(==(objective), ("level", "return", "hybrid")),
                                 findfirst(==(loss), ("rmse", "mse", "mae", "median", "max")), max(1, Int(trunc(horizon)))),
            Float64(hybrid_weight))
end

"Zielfunktion (R: `.bc_objective`)."
function _bc_objective(r, win, obs, objective, horizon, loss, hybrid_weight)
    e = _bc_errors(r, win, obs, objective, horizon)
    objective != "hybrid" && return _bc_loss(e, loss)
    return sqrt(hybrid_weight * SimLev.r_mean(_sq(e.ret)) + (1 - hybrid_weight) * SimLev.r_mean(_sq(e.level)))
end

"Kennzahlen Simulation vs. Produkt (R: `.bc_diagnostics`)."
function _bc_diagnostics(r, win, obs, dates)
    E = _libm()
    rr = Float64[r[i] for i in win]                         # seit 1.6.4 eine Kopie (B-107)
    rr[1] = 0.0
    for i in eachindex(rr)
        isfinite(rr[i]) || (rr[i] = 0.0)
    end
    ls = _cumlog(rr)
    pos = obs.pos
    so = ls[pos] .- ls[pos[1]]
    po = obs.logp .- obs.logp[1]
    m = length(so)
    d_obs = Float64.(dates[win])[pos]
    yrs = (d_obs[m] - d_obs[1]) / 365.25
    ret_s = Float64[E.expm1(so[i+1] - so[i]) for i in 1:m-1]     # seit 1.6.2 expm1 (P1)
    ret_p = Float64[E.expm1(po[i+1] - po[i]) for i in 1:m-1]
    diffs = ret_s .- ret_p
    per_year = yrs > 0 ? (m - 1) / yrs : 252.0
    rel = Float64[0 - E.expm1(so[i] - po[i]) for i in 1:m]    # 1 - sim/real (seit 1.6.2 genauer; 0 - : +0)
    c = length(diffs) > 2 ? Float64(_stats().cor(ret_s, ret_p)) : NA
    out = RList()
    out["n_obs"] = m
    out["years"] = yrs
    out["start"] = DP._date_of(d_obs[1])
    out["end"] = DP._date_of(d_obs[m])
    out["tracking_error"] = SimLev.r_sd(diffs) * sqrt(per_year) * 100
    out["tracking_difference"] = yrs > 0 ? (E.expm1(so[m] / yrs) - E.expm1(po[m] / yrs)) * 100 : NA
    out["cagr_sim"] = yrs > 0 ? E.expm1(so[m] / yrs) * 100 : NA
    out["cagr_product"] = yrs > 0 ? E.expm1(po[m] / yrs) * 100 : NA
    out["final_deviation"] = E.expm1(so[m] - po[m]) * 100
    out["max_abs_deviation"] = maximum(abs.(rel)) * 100
    out["rmse_level"] = sqrt(SimLev.r_mean(_sq(so .- po))) * 100
    out["correlation"] = c
    out["r_squared"] = length(diffs) > 2 ? c * c : NA
    out["deviation"] = RFrame("date" => DP._as_dates(d_obs), "deviation" => rel)
    return out
end

# ── Listen wie R (modifyList, benannte Listen) ─────────────────────────────

function _as_rlist(x)
    x === nothing && return RList()
    x isa RList && return copy(x)
    out = RList()
    if x isa Union{NamedTuple,AbstractDict}
        for (k, v) in pairs(x)
            out[String(string(k))] = v
        end
    elseif x isa AbstractVector{<:Pair} || x isa Tuple
        for p in x
            out[String(string(p.first))] = p.second
        end
    elseif x isa Pair
        out[String(string(x.first))] = x.second
    elseif x isa RVector && x.names !== nothing
        for (k, v) in zip(x.names, x.values)
            out[k] = v
        end
    else
        return nothing
    end
    return out
end

"`utils::modifyList` für flache Listen (`nothing` entfernt Einträge)."
function _modify_list(base, val)
    out = copy(base)
    for (k, v) in _as_rlist(val)
        v === nothing ? delete!(out, k) : (out[k] = v)
    end
    return out
end

# ═══════════════════════════════════════════════════════════════════════════
# Öffentliche Funktionen
# ═══════════════════════════════════════════════════════════════════════════

_default_grid() = (n = Int(floor((3 - (-3)) / 0.005 + 1e-10)); Float64[min(-3 + i * 0.005, 3.0) for i in 0:n])
_bounds0() = RList("drag" => [-10.0, 10.0], "spread" => [-5.0, 10.0], "beta" => [0.5, 1.5])

_as_chr_vec(x) = x === nothing ? String[] : x isa AbstractString ? [String(x)] : String[string(v) for v in x]

"""
    backcast_fit(data, product, index; ter = 0, leverage = 1, rate = nothing, fx = nothing,
                 model = "structural", fit = "drag", fixed = RList(), objective = "level",
                 loss = "rmse", horizon = 1, hybrid_weight = 0.5, lag = 0, rate_lag = 0,
                 start = nothing, end_ = nothing, method = "optimize", grid = nothing,
                 bounds = nothing, ter_basis = 365, rate_basis = 360, accrual = "linear",
                 index_fill = "locf", validate = true)

Backcast-Modell an ein Produkt anpassen.

Passt das Rückrechnungsmodell eines ETF/ETP (auch gehebelt oder invers) auf dem Zeitraum an, in dem sowohl das
Produkt als auch sein Basisindex vorliegen. Die freien Parameter werden so gewählt, dass die Abweichung
zwischen simuliertem und echtem Produkt minimal wird (täglich, kumuliert oder beides). Eingabe ist ein Tabelle
(RFrame) mit Datum, Produktkursen (vor der Auflegung `NA`) und Indexniveaus; das Ergebnis wird mit
`backcast()` in eine verlängerte Kursreihe umgerechnet.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Date oder umwandelbar, streng aufsteigend, ohne Duplikate) sowie
  den Spalten für Produkt und Basisindex. Typisch ein Kalendertagsraster (wie in den Projekt-Skripten) oder
  Handelstage; Lücken im Produkt (Feiertage, Börsenschluss) sind erlaubt.
- `product`: Spaltenname der Produkt-Kursreihe (NAV oder Börsenkurs; Niveaus, `NA` vor der Auflegung; Werte <=
  0 gelten als fehlend).
- `index`: Spaltenname der Basisindex-Reihe (Niveau > 0, nicht Rendite; Lücken werden nach `index_fill`
  gefüllt).
- `ter`: Laufende Kosten in Prozent p. a. (0.5 = 0,5 Prozent; Standard 0): Skalar, Vektor der Länge
  `nrow(data)`, Spaltenname, Tabelle (RFrame)(date, ter) (Stufenfunktion, gültig ab Datum) oder benannter
  Vektor mit Datumsnamen, z. B. `["2010-02-24" = 0.35, "2023-10-10" = 0.50]`.
- `leverage`: Hebel L des Produkts relativ zum Index als Zahl ungleich 0 (Standard 1; z. B. 2, -1, -2). Ist
  der Index bereits ein Hebelindex (z. B. MSCI USA Leveraged 2x Daily), ist `leverage = 1` zu setzen.
- `rate`: Finanzierungszins in Prozent p. a. (Tagesgeld, z. B. ESTR, EONIA, SOFR, EFFR) in denselben Formen
  wie `ter`; `nothing` (Standard) = 0. Wirkt nur für `leverage != 1` (Faktor 1 - L).
- `fx`: Optional (Standard `nothing` = keine Umrechnung): Umrechnungsfaktor Indexwährung -> Produktwährung in
  denselben Formen wie `ter` (z. B. Spaltenname). Der Index wird mit `fx` multipliziert.
- `model`: `"structural"` (Standard, Hebel-/Kostenmodell oben), `"linear"` (Regression Produktrendite ~
  Indexrendite, Stambaugh- Backfill) oder `"spline"` (kubischer Glättungsspline nach Reinsch mit Knoten an
  allen Stützstellen und GCV-Wahl der Glättung, Ersatz für das GAM aus '01 Base Indices'; die Kurve weicht
  leicht von `smooth.spline()` ab, das bei vielen Punkten Knoten auswählt). Die Regressionsmodelle werden auf
  Renditen direkt aufeinanderfolgender Produktbeobachtungen geschätzt und eignen sich für Proxy-Rückrechnungen
  (z. B. MSCI USA aus S&P 500).
- `fit`: Zeichenvektor der zu schätzenden Parameter (Standard `"drag"`): Teilmenge von `"drag"`
  (Restabweichung in Prozent p. a.), `"spread"` (Spread auf den finanzierten Anteil in Prozent p. a., nur für
  L != 1, sonst mit Warnung ignoriert) und `"beta"` (effektiver Hebel-Multiplikator, Faktor; nur
  Strukturmodell). `character(0)` schätzt nichts (reine Kostenrechnung).
- `fixed`: Benannte Liste fester Parameterwerte, z. B. `(spread = 0.4,)`; nicht genannte Parameter: drag = 0,
  spread = 0 (Prozent p. a.), beta = 1. Die Werte dienen auch als Startwerte der Optimierung.
- `objective`: `"level"` (Standard; kumulierte Pfadabweichung der Log-Niveaus, wie im Skript '02 Funds Data';
  bestimmt die Tracking Difference), `"return"` (Log-Renditeabweichungen über `horizon` Beobachtungen;
  Tracking Error) oder `"hybrid"` (gewichtete Kombination beider RMS-Fehler).
- `loss`: Fehlermaß für "level" und "return": "rmse" (Standard), "mse", "mae", "median" (Median der Beträge)
  oder "max". Bei "hybrid" ohne Wirkung (immer RMS).
- `horizon`: Renditehorizont in Produktbeobachtungen für "return"/"hybrid" (ganze Zahl >= 1, Standard 1).
  Werte > 1 (z. B. 5) dämpfen asynchrone Schlusskurse (Xetra vs. US-Index).
  Seit 1.6.4 kleiner als die Zahl der Produktbeobachtungen im Fit-Fenster.
- `hybrid_weight`: Gewicht des Renditeterms bei "hybrid" als Anteil (0..1, Standard 0.5); der Niveauterm
  erhält 1 - `hybrid_weight`.
- `lag`: Verzögerung des Index gegenüber dem Produkt in Zeilen (ganzzahlig, Standard 0; bei k > 0 wird die
  Produktrendite in Zeile t mit der Indexrendite aus Zeile t - k modelliert) oder `"auto"` (Lag aus -2..2 mit
  der höchsten Korrelation, bei negativem Hebel der niedrigsten).
  Seit 1.6.4 mit Betrag kleiner als die Zeilenzahl von data.
  Ist bei "auto" keine der fünf Korrelationen bestimmbar (jede braucht mindestens 30 gemeinsame Renditen, keine konstante Reihe), meldet die Funktion das seit 1.6.4 (lag dann angeben).
- `rate_lag`: Verzögerung des Zinssatzes in Zeilen (Standard 0 = Satz des Tages t; k > 0 = Satz aus Zeile t -
  k).
- `start`, `end_`: Optionales Fit-Fenster, Beginn und Ende (in R `start`, `end`; Datum oder Zeichenkette
  "JJJJ-MM-TT", keine Zahl); `nothing` (Standard) = gesamte Überlappung. Mindestens 20 gemeinsame Beobachtungen.
- `method`: `"optimize"` (Standard; ein Parameter mit `stats::optimize()` (Brent), mehrere mit projiziertem
  BFGS (C-Bibliothek von SimLev) innerhalb von `bounds`) oder `"grid"` (Gittersuche für genau einen Parameter,
  wie im Skript).
- `grid`: Gitterwerte für `method = "grid"` in der Einheit des Parameters (drag, spread: Prozent p. a.; beta:
  Faktor); Standard `seq(-3, 3, by = 0.005)`.
- `bounds`: Benannte Liste von Suchintervallen `[unten, oben]` je Parameter für `method = "optimize"`, in der
  Einheit des Parameters; Standard `list(drag = [-10, 10], spread = [-5, 10], beta = [0.5, 1.5]`. Eine eigene
  Liste ergänzt die Standardliste: Nicht genannte Parameter behalten ihr Standardintervall (je Eintrag
  `[unten, oben]` mit unten < oben).
- `ter_basis`, `rate_basis`: Tagesbasis für TER (Standard 365) und für Zins und Spread (Standard 360,
  Act/360).
  Seit 1.6.4 Zahlen > 0.
- `accrual`: Abgrenzung der TER: `"linear"` (Standard, TER * T / 365, Fondsbuchhaltung) oder `"geometric"` ((1
  + TER)^(T/365) - 1, wie in den Skripten).
- `index_fill`: Füllmethode für Indexlücken: "locf" (Standard), "linear" oder "stine" (Stineman-Interpolation
  nach Stineman 1980, skaliert wie stinepack; eigene Umsetzung in der C-Bibliothek von SimLev). Führende
  Lücken bleiben `NA`.
- `validate`: Logisch (Standard `true`): Out-of-Sample-Prüfung (Fit auf der jüngeren Hälfte der
  Produktbeobachtungen, Test auf der älteren, also in Backcast-Richtung); erst ab 80 Beobachtungen.

# Rückgabe
Objekt der Klasse `SimLevBackcastFit`, eine Liste mit u. a.

- params: Liste `drag`, `spread` (Prozent p. a.) und `beta` (Faktor).
- fitted, model, objective, loss, loss_value, method, horizon, lag: Fit-Einstellungen, Wert der Zielfunktion
  und verwendeter Lag (Zeilen).
- diagnostics, diagnostics_unfitted: Kennzahlen Simulation vs. Produkt mit bzw. ohne gefittete Parameter:
  `n_obs`, `years`, `start`, `end`, `tracking_error` (Prozent p. a.), `tracking_difference` (Prozentpunkte p.
  a.), `cagr_sim`, `cagr_product`, `final_deviation`, `max_abs_deviation` (jeweils Prozent), `rmse_level`
  (RMSE der Log-Niveaus x 100), `correlation`, `r_squared` und `deviation` (Tabelle (RFrame) date, deviation =
  1 - Sim/Produkt als Anteil).
- grid, grid_metrics: Bei `method = "grid"`: Tabelle (RFrame) (value, loss) und bestes Gitterelement je
  Fehlermetrik, sonst `nothing`.
- validation: Out-of-Sample-Ergebnis (Zeiträume `train`, `test`, Parameter `par`, Testkennzahlen in Prozent)
  oder `nothing`.
- regression: Regressionsfit (nur "linear"/"spline"): `coef` (Achsenabschnitt, Steigung) bzw. `fit`
  (Splineobjekt der C-Bibliothek mit `x`, `y`, `gam`, `lambda`, `df`, `gcv`; kein `smooth.spline`-Objekt).
- inception, window: Erstes Produktdatum und Fit-Fenster.
- drag_per_day: Drag in Prozent je Kalendertag.
- call_args: Daten und Modellangaben für `backcast()`.

# Details
Strukturmodell (`model = "structural"`) je Zeile t mit Kalendertagen T_t seit der Vorzeile und Indexrendite
x_t: r_t = β L x_t + (1 - L) i_t T_t / B_r - TER_t T_t / B_T
- s m(L) T_t / B_r - drag T_t / 365 mit m(L) = max(L-1, 0) + max(-L, 0), B_r = `rate_basis`, B_T =
  `ter_basis`; i, TER, s und drag gehen als Prozent p. a. / 100 ein. Bei den Regressionsmodellen ersetzt die
  geschätzte Regression die ersten drei Terme (`ter` und `rate` gehen dann nicht ein); `spread` und `drag`
  werden zusätzlich abgezogen.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 3000
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
d["idx"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
r = [0; diff(d["idx"]) ./ d["idx"][1:end-1]]
etf = 50 .* cumprod(1 .+ 2 .* r .- 2 / 100 / 360 .- 0.6 / 100 / 365)
etf[1:1500] .= NaN                              # Produkt erst ab Tag 1501
d["etf"] = etf; d["rate"] = fill(2.0, n)
fit = backcast_fit(d, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate")
println(fit["params"]["drag"])                  # etwa 0.1 Prozent p. a.
```
"""
function backcast_fit(data, product, index; ter = 0, leverage = 1, rate = nothing, fx = nothing,
                      model = ("structural", "linear", "spline"), fit = "drag", fixed = RList(),
                      objective = ("level", "return", "hybrid"), loss = ("rmse", "mse", "mae", "median", "max"),
                      horizon = 1, hybrid_weight = 0.5, lag = 0, rate_lag = 0, start = nothing, end_ = nothing,
                      method = ("optimize", "grid"), grid = nothing, bounds = nothing, ter_basis = 365,
                      rate_basis = 360, accrual = ("linear", "geometric"), index_fill = ("locf", "linear", "stine"),
                      validate = true)
    model = DP._match_arg(model, ("structural", "linear", "spline"))
    objective = DP._match_arg(objective, ("level", "return", "hybrid"))
    loss = DP._match_arg(loss, ("rmse", "mse", "mae", "median", "max"))
    method = DP._match_arg(method, ("optimize", "grid"))
    accrual = DP._match_arg(accrual, ("linear", "geometric"))
    index_fill = DP._match_arg(index_fill, ("locf", "linear", "stine"))
    fn = "backcast_fit"                                        # seit 1.6.4 vor der Rechnung (K42 E4, B-017)
    _bc_check_args(fn, data, product, index, ter, leverage, rate, fx, rate_lag, ter_basis, rate_basis)
    data = SimLev.as_rframe(data)
    leverage = SimLev.chk_scalar(leverage isa RVector ? leverage.values : leverage)
    ter_basis = SimLev.chk_scalar(ter_basis); rate_basis = SimLev.chk_scalar(rate_basis); rate_lag = SimLev.chk_scalar(rate_lag)
    fit isa SimLev.RFmt.RFactor && SimLev.chk_stop("faktor", fn, "fit")
    _bc_check_par(fixed, fn, "fixed")                          # B-087
    horizon = _E()._e4_count(horizon, fn, "horizon")           # B-011, B-017
    hybrid_weight = SimLev.chk_prob(hybrid_weight, fn, "hybrid_weight")
    lag = _bc_check_lag(lag, data, fn)
    start === nothing || (start = SimLev.chk_date1(start, fn, "start"))   # B-011 (Entscheidung 7: keine Zahl)
    end_ === nothing || (end_ = SimLev.chk_date1(end_, fn, "end"))
    if grid !== nothing
        gv = grid isa Tuple ? collect(Any, grid) : grid
        (!(gv isa SimLev.RFmt.RFactor) && (_E()._e4_numscalar(gv) || (gv isa AbstractVector && !(gv isa AbstractMatrix) &&
            !isempty(gv) && all(_E()._e4_numscalar, gv))) && all(v -> isfinite(Float64(v)), gv isa AbstractVector ? gv : [gv])) ||
            SimLev.chk_stop("e2.zahlen_endlich", fn, "grid")   # B-017
    end
    validate = SimLev.chk_bool1(validate, fn, "validate")::Bool   # B-051
    grid = grid === nothing ? _default_grid() : Float64.(grid isa AbstractVector ? grid : grid isa Tuple ? collect(grid) : [grid])
    fit = unique(_as_chr_vec(fit))
    (!isempty(fit) && !all(f -> f in ("drag", "spread", "beta"), fit)) &&
        error("'fit' darf nur 'drag', 'spread' und 'beta' enthalten.")
    bl = bounds === nothing ? RList() : _as_rlist(bounds)
    (bl === nothing || (length(bl) > 0 && !all(k -> k in ("drag", "spread", "beta"), keys(bl)))) &&
        error("'bounds' muss eine benannte Liste mit Einträgen drag, spread und/oder beta sein, z. B. list(drag = c(-5, 5)).")
    bounds = _modify_list(_bounds0(), bl)
    for (k, b) in bounds
        ok = _isnumval(b) && length(b) == 2 && !(b isa SimLev.RFmt.RFactor)
        bb = ok ? DP._as_numeric(b) : Float64[]
        ok = ok && all(isfinite, bb) && bb[1] < bb[2] && isfinite(bb[2] - bb[1])   # Breite endlich (B-005)
        ok || error("bounds\$$(k) muss c(unten, oben) mit unten < oben sein.")   # seit 1.6.4 ohne Wert, endlich
        bounds[k] = bb
    end
    if model != "structural" && "beta" in fit
        @warn "'beta' wird bei Regressionsmodellen über die Regression geschätzt und hier ignoriert."
        fit = [f for f in fit if f != "beta"]
    end
    if leverage == 1 && "spread" in fit
        @warn "'spread' ist bei leverage = 1 nicht identifizierbar und wird ignoriert."
        fit = [f for f in fit if f != "spread"]
    end

    lag_auto = lag isa AbstractString && lag == "auto"
    rl = Int(trunc(rate_lag))
    prep = _bc_prepare(data, product, index, ter, leverage, rate, fx, rl, ter_basis, rate_basis,
                       accrual, index_fill, lag_auto ? 0 : Int(trunc(lag)))
    if lag_auto
        pr = vcat(NA, Float64[prep.prod[i] / prep.prod[i-1] - 1 for i in 2:prep.n])
        cand = -2:2
        cors = Float64[]
        for k in cand
            xs = _shift(prep.x, k)
            ok = [isfinite(xs[i]) && isfinite(pr[i]) for i in eachindex(xs)]
            push!(cors, count(ok) < 30 ? NA : Float64(_stats().cor(xs[ok], pr[ok])))
        end
        sg = prep.leverage > 0 ? 1.0 : -1.0
        jm = SimLev._which_max(sg .* cors)
        # keine Korrelation bestimmbar: seit 1.6.4 Meldung wie R und Python (Entscheidung 145; bis 1.6.3 BoundsError)
        jm === nothing && SimLev.chk_stop("ut3.lag_auto", "backcast_fit")
        lag = cand[jm]
        prep = _bc_prepare(data, product, index, ter, leverage, rate, fx, rl, ter_basis, rate_basis,
                           accrual, index_fill, Int(lag))
    end

    has = [!isnan(prep.prod[i]) && !isnan(prep.idx[i]) for i in 1:prep.n]
    if start !== nothing
        s0 = DP._as_date_any(start)[1]
        has = has .& (prep.dates .>= s0)
    end
    if end_ !== nothing
        e0 = DP._as_date_any(end_)[1]
        has = has .& (prep.dates .<= e0)
    end
    count(has) < 20 && error("Zu wenige gemeinsame Beobachtungen von Produkt und Index (mindestens 20).")
    hw = findall(has)
    w0, w1 = hw[1], hw[end]
    win = collect(w0:w1)
    inception = DP._date_of(prep.dates[findfirst(!isnan, prep.prod)])

    make_obs(rws) = (pos = findall(has[rws]); (pos = pos, logp = Float64[_libm().log(v) for v in prep.prod[rws][pos]]))
    obs = make_obs(win)
    # seit 1.6.4: ohne Renditepaare wäre die Zielfunktion leer (B-017; bis 1.6.3 Ergebnis an der Suchgrenze)
    objective != "level" && horizon >= length(obs.pos) && SimLev.chk_stop("e4.horizont", fn, length(obs.pos))

    function fit_reg(rws)
        model == "structural" && return nothing
        o = findall(has[rws]) .+ (rws[1] - 1)
        o = o[o .> 1]
        y = Float64[prep.prod[i] / prep.prod[i-1] - 1 for i in o]
        xx = prep.x[o]
        ok = [isfinite(y[j]) && isfinite(xx[j]) && !isnan(prep.prod[o[j]-1]) for j in eachindex(o)]
        count(ok) < 20 && error("Zu wenige aufeinanderfolgende Beobachtungen für das Regressionsmodell.")
        if model == "linear"
            X = hcat(ones(count(ok)), xx[ok])
            f = SimLev.SLib.lsfit(X, y[ok])                         # kleinste Quadrate
            return RList("coef" => SimLev.RVector(f["coefficients"]; names = ["x1", "x2"]))
        end
        fs = SimLev.SLib.smspline_fit(xx[ok], y[ok])               # Glättungsspline (Reinsch 1967, GCV)
        return RList("fit" => RList("x" => fs["x"], "y" => fs["y"], "gam" => fs["gam"], "lambda" => fs["lambda"],
                                    "df" => fs["df"], "gcv" => fs["gcv"]))
    end
    reg = fit_reg(win)
    fixed1 = _as_rlist(fixed)                                  # seit 1.6.4: Länge 1 wie Einzelwert (Entscheidung 4)
    for k in collect(keys(fixed1))
        fixed1[k] = SimLev.chk_scalar(fixed1[k])
    end
    par0 = _modify_list(RList("drag" => 0.0, "spread" => 0.0, "beta" => 1.0), fixed1)

    # Fenster rws (seit 1.6.4, B-068, B-106; R `make_obj`): Einheiten und Basis einmal je Fit auf rws (elementweise
    # wie _bc_model_returns(prep, p, model, rg)[rws]); hängt die Basis vom gesuchten beta ab (Strukturmodell), je
    # Auswertung nur auf rws
    rows_of(rws, rg) = _bc_rows(prep, (model == "structural" && "beta" in fit) ? nothing : _bc_base(prep, par0, model, rg)[rws], rws)
    returns_on(w, p) = _bc_returns_on(w, _par(p, "beta"), _par(p, "spread"), _par(p, "drag"))
    function make_obj(rws, ob, rg)
        w = rows_of(rws, rg)
        ix = 1:length(rws)
        function (theta)
            p = copy(par0)
            th = theta isa AbstractVector ? theta : [theta]
            for (k, t) in zip(fit, th)
                p[k] = Float64(t)
            end
            return _bc_objective(returns_on(w, p), ix, ob, objective, horizon, loss, hybrid_weight)
        end
    end

    # metrics = false (Validierung, seit 1.6.4, B-070): im Gitter nur die Zielwerte, ohne Fehlermatrix, Metrik- und
    # Gittertabelle (genutzt wird dort nur par)
    function run_fit(rws, ob, rg; metrics::Bool = true)
        isempty(fit) && return (par = copy(par0), value = make_obj(rws, ob, rg)(Float64[]), grid = nothing, metrics = nothing)
        if method == "grid"
            length(fit) != 1 && error("method = 'grid' unterstützt genau einen Parameter in 'fit'.")
            # seit 1.6.3 je Gitterpunkt einmal gerechnet (bis 1.6.2 für Zielwert und Fehlermatrix getrennt; gleiche
            # Parameter, reine Funktionen ohne Meldungen); seit 1.6.4 nur auf rws mit der Basis vorab (B-068) und je
            # Punkt ein _bc_errors (B-069: "level" bei objective = "level", horizon bleibt dort unausgewertet, sonst
            # "hybrid"; Zielwert wie _bc_objective)
            w = rows_of(rws, rg)
            ix = 1:length(rws)
            eo = objective == "level" ? "level" : "hybrid"
            vals = Vector{Float64}(undef, length(grid))
            err_mat = metrics ? Matrix{Float64}(undef, length(ob.pos), length(grid)) : Matrix{Float64}(undef, 0, 0)
            for (j, g) in enumerate(grid)
                p = copy(par0); p[fit[1]] = Float64(g)
                e = _bc_errors(returns_on(w, p), ix, ob, eo, horizon)
                el = if objective == "level"
                    vals[j] = _bc_loss(e, loss); e
                elseif objective == "return"
                    vals[j] = _bc_loss(e.ret, loss); e.level
                else
                    vals[j] = sqrt(hybrid_weight * SimLev.r_mean(_sq(e.ret)) + (1 - hybrid_weight) * SimLev.r_mean(_sq(e.level)))
                    e.level
                end
                metrics && (err_mat[:, j] .= [0 - _libm().expm1(v) for v in el])
            end
            best = grid[something(SimLev._which_min(vals), 0)]
            p = copy(par0); p[fit[1]] = best
            metrics || return (par = p, value = minimum(vals), grid = nothing, metrics = nothing)
            return (par = p, value = minimum(vals), grid = RFrame("value" => copy(grid), "loss" => vals),
                    metrics = _bc_metric_table(err_mat, grid))
        end
        obj = make_obj(rws, ob, rg)
        if length(fit) == 1
            b = bounds[fit[1]]
            o = _stats().optimize(t -> obj(t); lower = b[1], upper = b[2], tol = 1e-8)
            p = copy(par0); p[fit[1]] = Float64(_getel(o, "minimum"))
            return (par = p, value = Float64(_getel(o, "objective")), grid = nothing, metrics = nothing)
        end
        lo = Float64[bounds[k][1] for k in fit]; hi = Float64[bounds[k][2] for k in fit]
        # glatte Zielfunktion (rmse, mse, hybrid) mit analytischem Gradienten ganz in C (wie .sl_backcast_fit
        # in R); mae, median, max wie bis 1.1.0 über .sl_optim mit numerischem Gradienten
        o = if objective == "hybrid" || loss in ("rmse", "mse")
            SimLev.SLib.backcast_fit(_bc_cprob(prep, model, rg, rws, ob, objective, loss, horizon, hybrid_weight),
                                     Float64[_par(par0, "drag"), _par(par0, "spread"), _par(par0, "beta")],
                                     Int[findfirst(==(k), ("drag", "spread", "beta")) for k in fit], lo, hi)
        else
            SimLev.SLib.optim(Float64[_par(par0, k) for k in fit], t -> obj(t); method = "L-BFGS-B", lower = lo, upper = hi)
        end
        p = copy(par0)
        for (k, t) in zip(fit, _getel(o, "par"))
            p[k] = Float64(t)
        end
        return (par = p, value = Float64(_getel(o, "value")), grid = nothing, metrics = nothing)
    end

    res = run_fit(win, obs, reg)
    r_all = _bc_model_returns(prep, res.par, model, reg)
    diag = _bc_diagnostics(r_all[win], 1:length(win), obs, prep.dates[win])
    diag_naive = _bc_diagnostics(_bc_model_returns(prep, par0, model, reg)[win], 1:length(win), obs, prep.dates[win])

    oos = nothing
    if validate && length(obs.pos) >= 80
        cut_row = win[obs.pos[div(length(obs.pos), 2)]]
        tr_rows = collect(cut_row:w1); te_rows = collect(w0:cut_row)
        ob_tr = make_obs(tr_rows); ob_te = make_obs(te_rows)
        rg_tr = try
            fit_reg(tr_rows)
        catch e
            e isa ErrorException || rethrow()
            nothing
        end
        if model == "structural" || rg_tr !== nothing
            res_tr = run_fit(tr_rows, ob_tr, rg_tr; metrics = false)   # nur par (B-070)
            d_te = _bc_diagnostics(_bc_model_returns(prep, res_tr.par, model, rg_tr)[te_rows],
                                   1:length(te_rows), ob_te, prep.dates[te_rows])
            d_te0 = _bc_diagnostics(_bc_model_returns(prep, par0, model, rg_tr)[te_rows],
                                    1:length(te_rows), ob_te, prep.dates[te_rows])
            oos = RList("train" => DP._as_dates([prep.dates[tr_rows[1]], prep.dates[w1]]),
                        "test" => DP._as_dates([prep.dates[w0], prep.dates[cut_row]]),
                        "par" => res_tr.par,
                        "test_rmse_level" => d_te["rmse_level"], "test_tracking_difference" => d_te["tracking_difference"],
                        "test_tracking_error" => d_te["tracking_error"],
                        "naive_rmse_level" => d_te0["rmse_level"],
                        "naive_tracking_difference" => d_te0["tracking_difference"])
        end
    end

    out = RList(; class = ["SimLevBackcastFit"])
    out["params"] = res.par
    out["fitted"] = fit
    out["model"] = model
    out["objective"] = objective
    out["loss"] = loss
    out["loss_value"] = res.value
    out["method"] = method
    out["horizon"] = horizon
    out["lag"] = Int(lag)
    out["diagnostics"] = diag
    out["diagnostics_unfitted"] = diag_naive
    out["grid"] = res.grid
    out["grid_metrics"] = res.metrics
    out["validation"] = oos
    out["regression"] = reg
    out["inception"] = inception
    out["window"] = DP._as_dates([prep.dates[w0], prep.dates[w1]])
    out["drag_per_day"] = _par(res.par, "drag") / 100 / 365 * 100
    out["call_args"] = RList("data" => data, "product" => product, "index" => index, "ter" => ter,
                             "leverage" => leverage, "rate" => rate, "fx" => fx, "rate_lag" => rl,
                             "ter_basis" => ter_basis, "rate_basis" => rate_basis, "accrual" => accrual,
                             "index_fill" => index_fill)
    return out
end

"""
    backcast(fit = nothing; data = nothing, params = nothing, splice = "inception",
             fill = "locf", rebase = nothing, kwargs...)

Produkt-Kursreihe zurückrechnen und verketten.

Rechnet ein Produkt mit den Parametern aus `backcast_fit()` (oder fest vorgegebenen Parametern) über die
gesamte Indexhistorie und verkettet die Simulation renditebasiert (Chain-Linking) mit der echten Produktreihe
ab Auflegung. Es entsteht kein Sprung am Verkettungstag; ab dem Verkettungstag stimmt `value` (ohne `rebase`)
an allen Beobachtungstagen mit den echten Kursen überein. Das Ergebnis kann z. B. nach Umbenennen von `value`
als Kursspalte für `simulation()` dienen.

# Argumente
- `fit`: Ein `SimLevBackcastFit`-Objekt aus `backcast_fit()`. Alternativ `nothing` (Standard), dann werden
  `data`, `product`, `index` und die Modellangaben über `...` übergeben und `params` direkt verwendet (nur
  Strukturmodell).
- `data`: Bei `fit`: optional anderer Datensatz (z. B. längere Indexhistorie) mit denselben Spaltennamen;
  `nothing` (Standard) = Datensatz des Fits. Bei `fit = nothing` Pflicht (Format wie in `backcast_fit()`).
- `params`: Optional Liste mit `drag`, `spread` (Prozent p. a.) und/oder `beta` (Faktor). Überschreibt
  einzelne Parameter des Fits; ohne Fit gelten für fehlende Einträge drag = 0, spread = 0, beta = 1.
- `splice`: `"inception"` (Standard: echte Renditen ab dem ersten Produktkurs), `"none"` (reine Modellreihe)
  oder ein Datum: echte Renditen ab dem ersten Produktkurs an oder nach diesem Datum (Fehler, wenn danach kein
  Produktkurs vorliegt).
- `fill`: Füllmethode für Produktlücken nach der Verkettung: "locf" (Standard, wie die Engine), "linear",
  "stine" (Stineman, wie bei `index_fill`) oder "model" (Lückentage mit Modellrenditen, Endpunkte aus echten
  Kursen; erhält die echten Kurse an allen Beobachtungstagen).
- `rebase`: `nothing` (Standard; Produkteinheiten, echte Kurse bleiben erhalten) oder Startwert der Reihe am
  ersten Indextag, z. B. 100 (`value` und `model` werden skaliert, `product` nicht).
  Seit 1.6.4 eine Zahl > 0.
- `kwargs...`: Bei `fit = nothing`: Argumente wie in `backcast_fit()` (`product`, `index` als Pflicht; `ter`
  (Standard 0), `leverage` (1), `rate` (`nothing` = 0), `fx`, `rate_lag`, `ter_basis`, `rate_basis`,
  `accrual`, `index_fill`, `lag`; `model` nur "structural").
  Seit 1.6.4 mit `fit` nicht erlaubt (die Angaben stammen aus dem Fit).

# Rückgabe
Tabelle (RFrame) der Klasse `["SimLevBackcast", "data.frame"]` mit einer Zeile je Zeile von `data`: `date`,
`value` (verkettete Reihe; `NA` vor dem ersten Indexwert), `return` (einfache Rendite von `value` als Anteil),
`model` (reine Modellreihe auf gleichem Niveau), `product` (Rohdaten) und `source` ("backcast", "product" oder
"filled"). Attribute `"fit"` (Fit-Objekt oder `nothing`), `"params"` (verwendete Parameter) und
`"splice_date"` (Verkettungsdatum oder `NA`).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1000
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["idx"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
etf = series_leverage(d, "idx"; leverage = 2, rate = 2, expense = 0.6)
etf[1:600] .= NaN                               # Produkt erst ab Tag 601
d["etf"] = etf
bc = backcast(; data = d, product = "etf", index = "idx", leverage = 2, rate = 2, ter = 0.6, rebase = 100)
println(count(==("product"), bc["source"]))
```
"""
function backcast(fit_pos = nothing; fit = fit_pos, data = nothing, params = nothing, splice = "inception",
                  fill = ("locf", "linear", "stine", "model"), rebase = nothing, kwargs...)
    fill = DP._match_arg(fill, ("locf", "linear", "stine", "model"))
    fn = "backcast"                                            # seit 1.6.4 vor der Rechnung (K42 E4)
    SimLev.chk_dots([String(k) for (k, _) in kwargs], ["product", "index", "ter", "leverage", "rate", "fx", "rate_lag",
                    "ter_basis", "rate_basis", "accrual", "index_fill", "lag", "model"], fn)   # Entscheidung 21
    fit === nothing || (fit isa RList && inherits(fit, "SimLevBackcastFit")) || error("'fit' muss ein SimLevBackcastFit-Objekt sein.")
    SimLev.chk_df(data, fn, "data"; null_ok = true)             # Entscheidung 6
    _bc_check_par(params, fn, "params"; null_ok = true)
    splice = SimLev.chk_scalar(splice)
    splice isa Union{AbstractString,Date,DateTime} || SimLev.chk_stop("e4.splice", fn)   # Entscheidung 7 und 15
    rebase = SimLev.chk_num1(rebase, fn, "rebase"; lo = 0, lo_open = true, null_ok = true)   # B-017
    data = SimLev.as_rframe(data)
    E = _libm()
    if fit === nothing
        dots = RList((String(k) => v for (k, v) in kwargs)...)
        data === nothing && error("Ohne 'fit' muss 'data' angegeben werden.")
        a = _modify_list(RList("ter" => 0, "leverage" => 1, "rate" => nothing, "fx" => nothing, "rate_lag" => 0,
                               "ter_basis" => 365, "rate_basis" => 360, "accrual" => "linear",
                               "index_fill" => "locf"), dots)
        (get(a, "product", nothing) === nothing || get(a, "index", nothing) === nothing) &&
            error("'product' und 'index' müssen angegeben werden.")
        a["data"] = data
        model = something(get(dots, "model", nothing), "structural")
        (model isa AbstractString && model == "structural") || error("Ohne Fit ist nur model = 'structural' möglich.")
        _bc_check_args(fn, data, a["product"], a["index"], get(a, "ter", nothing), get(a, "leverage", nothing),
                       get(a, "rate", nothing), get(a, "fx", nothing), get(a, "rate_lag", nothing), get(a, "ter_basis", nothing),
                       get(a, "rate_basis", nothing))
        for k in ("leverage", "rate_lag", "ter_basis", "rate_basis", "accrual", "index_fill")
            a[k] = SimLev.chk_scalar(a[k])
        end
        SimLev.chk_choice(a["accrual"], fn, "accrual", ["linear", "geometric"])   # bis 1.6.3 unbekannte Werte still "linear"
        SimLev.chk_choice(a["index_fill"], fn, "index_fill", ["locf", "linear", "stine"])
        _bc_check_lag(something(get(dots, "lag", nothing), 0), data, fn; auto_ok = false)   # ohne Fit kein 'auto'
        reg = nothing
        par = _modify_list(RList("drag" => 0.0, "spread" => 0.0, "beta" => 1.0), params)
        lag = Int(trunc(something(get(dots, "lag", nothing), 0)))
    else
        (fit isa RList && inherits(fit, "SimLevBackcastFit")) || error("'fit' muss ein SimLevBackcastFit-Objekt sein.")
        isempty(kwargs) || SimLev.chk_stop("e4.fit_angabe", fn, String(first(keys(kwargs))))   # Entscheidung 71
        a = copy(fit["call_args"])
        if data !== nothing
            a["data"] = data                                   # seit 1.6.4 wie im Fit geprüft
            _bc_check_args(fn, data, a["product"], a["index"], get(a, "ter", nothing), get(a, "leverage", nothing),
                           get(a, "rate", nothing), get(a, "fx", nothing), get(a, "rate_lag", nothing),
                           get(a, "ter_basis", nothing), get(a, "rate_basis", nothing))
        end
        model, reg, lag = fit["model"], fit["regression"], fit["lag"]
        par = _modify_list(fit["params"], params)
    end
    ga(k) = get(a, k, nothing)
    prep = _bc_prepare(a["data"], a["product"], a["index"], ga("ter"), ga("leverage"), ga("rate"), ga("fx"),
                       Int(trunc(something(ga("rate_lag"), 0))), ga("ter_basis"), ga("rate_basis"), ga("accrual"),
                       ga("index_fill"), lag)
    r_mod = _bc_model_returns(prep, par, model, reg)
    n = prep.n
    prod = prep.prod
    first_idx = findfirst(!isnan, prep.idx)
    obs = findall(!isnan, prod)
    k0 = if (splice isa AbstractString && splice == "none") || isempty(obs)
        0
    elseif splice isa AbstractString && splice == "inception"
        obs[1]
    else
        sd0 = DP._days(DP._to_date(splice, "splice"))
        (length(sd0) != 1 || isnan(sd0[1])) && error("splice: \"inception\", \"none\" oder ein Datum ('JJJJ-MM-TT').")
        cand = [i for i in obs if prep.dates[i] >= sd0[1]]
        isempty(cand) && error("Kein Produktkurs ab dem Verkettungsdatum vorhanden (letzter Produktkurs am $(DP._date_str(prep.dates[maximum(obs)]))).")   # seit 1.6.4 ohne Eingabewert
        cand[1]
    end
    lr1(v) = E.log1p(max(isfinite(v) ? v : 0.0, -0.999999))
    r_out = copy(r_mod)
    source = Base.fill("backcast", n)
    if k0 > 0
        seg = k0:n
        last_obs = maximum(obs)
        pv = prod[seg]
        pf = if fill == "model"
            po = findall(!isnan, pv)
            lv = Base.fill(NA, length(seg))
            lv[po] .= [E.log(v) for v in pv[po]]
            lr = Float64[lr1(v) for v in r_mod[seg]]
            for j in 1:length(po)-1
                a0, a1 = po[j], po[j+1]
                if a1 - a0 > 1
                    step = lr[a0+1:a1]
                    adj = ((lv[a1] - lv[a0]) - SimLev.r_sum(step)) / length(step)
                    lv[a0+1:a1-1] .= lv[a0] .+ SimLev.r_cumsum(step .+ adj)[1:a1-a0-1]
                end
            end
            maximum(po) < length(seg) && (lv[maximum(po)+1:end] .= lv[maximum(po)])
            Float64[E.exp(v) for v in lv]
        else
            _fill_na(pv, fill)
        end
        source[seg] .= [isnan(v) ? "filled" : "product" for v in pv]
        last_obs < n && (source[last_obs+1:n] .= "filled")
        r_seg = vcat(NA, Float64[pf[i] / pf[i-1] - 1 for i in 2:length(pf)])
        r_out[seg[2:end]] .= r_seg[2:end]
        r_out[k0] = r_mod[k0]
    end
    lr_all = Float64[lr1(v) for v in r_out]
    lr_mod = Float64[lr1(v) for v in r_mod]
    lr_all[1:first_idx] .= 0.0; lr_mod[1:first_idx] .= 0.0
    cl = SimLev.r_cumsum(lr_all); cm = SimLev.r_cumsum(lr_mod)
    if k0 > 0
        value = Float64[prod[k0] * E.exp(c - cl[k0]) for c in cl]
        model_v = Float64[prod[k0] * E.exp(c - cm[k0]) for c in cm]
    else
        value = Float64[100 * E.exp(c) for c in cl]
        model_v = Float64[100 * E.exp(c) for c in cm]
    end
    if first_idx > 1
        value[1:first_idx-1] .= NA; model_v[1:first_idx-1] .= NA
    end
    if rebase !== nothing
        s = rebase / value[first_idx]
        value = value .* s; model_v = model_v .* s
    end
    ret = vcat(NA, Float64[value[i] / value[i-1] - 1 for i in 2:n])
    out = RFrame("date" => DP._as_dates(prep.dates), "value" => value, "return" => ret, "model" => model_v,
                 "product" => prod, "source" => source; class = ["SimLevBackcast", "data.frame"])
    attrs(out)["fit"] = fit
    attrs(out)["params"] = par
    attrs(out)["splice_date"] = k0 > 0 ? DP._date_of(prep.dates[k0]) : missing
    return out
end

# ═══════════════════════════════════════════════════════════════════════════
# Methoden
# ═══════════════════════════════════════════════════════════════════════════

const _DLINE = "═"^62
const _SLINE = "─"^21

"Druckausgabe von `SimLevBackcastFit` (Text wie `print.SimLevBackcastFit`)."
function format_SimLevBackcastFit(x)
    sp = DP._sprintf
    d = x["diagnostics"]; d0 = x["diagnostics_unfitted"]
    io = IOBuffer()
    print(io, "\n", _DLINE, "\n", "                    SimLev Backcast-Fit                        \n", _DLINE, "\n\n")
    print(io, sp("  Modell:           %s (Ziel: %s, Verlust: %s, Methode: %s)\n", x["model"], x["objective"], x["loss"], x["method"]))
    print(io, sp("  Fit-Fenster:      %s bis %s (%d Beobachtungen, %.1f Jahre)\n",
                 DP._date_str(d["start"]), DP._date_str(d["end"]), d["n_obs"], d["years"]))
    lev = x["call_args"]["leverage"]
    print(io, sp("  Hebel / Lag:      %s / %d Zeilen\n", DP._fmt_num(lev isa AbstractVector ? first(lev) : lev), x["lag"]))
    print(io, "\n  Parameter\n  ", _SLINE, "\n")
    p = x["params"]
    mark(k) = k in x["fitted"] ? "(gefittet)" : "(fest)"
    x["model"] == "structural" && print(io, sp("  Beta:             %.5f %s\n", _par(p, "beta"), mark("beta")))
    Float64(first(lev)) != 1 && print(io, sp("  Spread:           %+.4f %% p. a. %s\n", _par(p, "spread"), mark("spread")))
    print(io, sp("  Drag:             %+.4f %% p. a. %s  (= %+.6f %% je Tag)\n", _par(p, "drag"), mark("drag"), x["drag_per_day"]))
    reg = get(x, "regression", nothing)
    if reg !== nothing && haskey(reg, "coef") && reg["coef"] !== nothing
        cf = _coef(reg)
        print(io, sp("  Regression:       a = %.3e, b = %.5f\n", cf[1], cf[2]))
    end
    print(io, "\n  Abweichung Simulation vs. Produkt     ohne Fit     mit Fit\n  ", _SLINE, "\n")
    row(lbl, a, b, unit = "%") = print(io, sp("  %-34s %9.4f%s %9.4f%s\n", lbl, a, unit, b, unit))
    row("Tracking Error p. a.", d0["tracking_error"], d["tracking_error"])
    row("Tracking Difference p. a.", d0["tracking_difference"], d["tracking_difference"])
    row("Endabweichung kumuliert", d0["final_deviation"], d["final_deviation"])
    row("Max. Pfadabweichung", d0["max_abs_deviation"], d["max_abs_deviation"])
    row("RMSE Log-Niveau", d0["rmse_level"], d["rmse_level"])
    print(io, sp("  %-34s %10.4f  %10.4f\n", "Korrelation Tagesrenditen", d0["correlation"], d["correlation"]))
    v = x["validation"]
    if v !== nothing
        print(io, "\n  Out-of-Sample (Fit jüngere, Test ältere Hälfte)\n  ", _SLINE, "\n")
        te = DP._days(v["test"])
        print(io, sp("  Test-Zeitraum:    %s bis %s\n", DP._date_str(te[1]), DP._date_str(te[2])))
        print(io, sp("  RMSE Log-Niveau:  %.4f %% (ohne Fit: %.4f %%)\n", v["test_rmse_level"], v["naive_rmse_level"]))
        print(io, sp("  Tracking Diff.:   %+.4f %% p. a. (ohne Fit: %+.4f %%)\n",
                     v["test_tracking_difference"], v["naive_tracking_difference"]))
    end
    gm = x["grid_metrics"]
    if gm !== nothing
        print(io, "\n  Gittersuche: bestes Gitterelement je Metrik\n  ", _SLINE, "\n")
        for (k, val) in zip(gm.names, gm.values)
            print(io, sp("  %-26s %+.4f\n", k, val))
        end
    end
    print(io, "\n", _DLINE, "\n")
    return String(take!(io))
end

"`summary.SimLevBackcastFit`: druckt den Fit, liefert Parameter, Kennzahlen (ohne Pfad) und Validierung."
function summary_SimLevBackcastFit(object; io::IO = stdout)
    print(io, format_SimLevBackcastFit(object))
    diag = RList()
    for (k, v) in object["diagnostics"]
        k == "deviation" || (diag[k] = v)
    end
    return RList("params" => object["params"], "diagnostics" => diag, "validation" => object["validation"])
end

"Druckausgabe von `SimLevBackcast` (Kopfzeile und die ersten 6 Zeilen)."
function format_SimLevBackcast(x; kw...)
    val = x["value"]
    n_bc = count(i -> x["source"][i] == "backcast" && isfinite(val[i]), 1:nrow(x))
    dd = DP._days(x["date"])
    sd0 = get(attrs(x), "splice_date", missing)
    head = DP._sprintf("SimLev Backcast: %d Zeilen, %s bis %s; %d Backcast-Tage, Verkettung am %s\n",
                       nrow(x), DP._date_str(minimum(dd)), DP._date_str(maximum(dd)), n_bc,
                       sd0 === missing || sd0 === nothing ? "NA" : DP._date_str(sd0))
    h = rows(x, 1:min(6, nrow(x)))
    h.class = String[]
    h.attrs = Dict{String,Any}()
    return head * DP._chomp(SimLev.RFmt.print_data_frame(h; kw...))
end

"Registrierte Druckmethode (R `print.SimLevBackcast(x, ...)`)."
function _print_backcast(io::IO, x; kw...)
    print(io, format_SimLevBackcast(x; kw...))
    return nothing
end

# ── Grafiken (SVG ohne externe Pakete; Bausteine `_bc_*` in svg.jl) ───────────

"""
    plot_SimLevBackcastFit(x; file = nothing, width = 720, height = 360)

Pfadabweichung im Fit-Fenster (und Verlustkurve der Gittersuche) als SVG.
Liefert `(svg, data)`; `data`: `deviation` (`date`, `deviation` als Anteil,
gezeichnet in %) und mit Gittersuche `grid` (`value`, `loss`).
"""
function plot_SimLevBackcastFit(x; file = nothing, width = 720, height = 360)
    dev = x["diagnostics"]["deviation"]
    ng = x["grid"] === nothing ? 1 : 2
    data = SimLev.RList("deviation" => RFrame("date" => collect(dev["date"]), "deviation" => collect(Float64, dev["deviation"])))
    ng == 2 && (data["grid"] = RFrame("value" => Float64.(x["grid"]["value"]), "loss" => Float64.(x["grid"]["loss"])))
    svg = _bc_doc(width, height * ng) do io
        _bc_panel(io, [(DP._days(dev["date"]), dev["deviation"] .* 100, "#2C6E9B", 1)];
                  w = width, h = height, title = "Pfadabweichung im Fit-Fenster", xlab = "Datum",
                  ylab = "1 - Sim/Produkt (%)", hlines = [0.0], xdate = true)
        if ng == 2
            g = x["grid"]
            _bc_panel(io, [(Float64.(g["value"]), Float64.(g["loss"]), "#B5562B", 1)]; y0 = height, w = width, h = height,
                      title = "Gittersuche", xlab = DP._sprintf("%s (%% p. a.)", x["fitted"][1]), ylab = x["loss"],
                      vlines = [_par(x["params"], x["fitted"][1])])
        end
    end
    return (svg, data)
end

"""
    plot_SimLevBackcast(x; log = true, file = nothing, width = 720, height = 450)

Verkettete Reihe (Backcast/Produkt), Modellreihe und Verkettungsdatum als SVG.
Liefert `(svg, data)`; `data`: `backcast` (`date`, `value`, `model`, `source`
der gezeichneten Zeilen, d. h. mit endlichem `value`).
"""
function plot_SimLevBackcast(x; log = true, file = nothing, width = 720, height = 450)
    log = SimLev.chk_bool1(log, "plot.SimLevBackcast", "log")::Bool   # seit 1.6.4 (B-051)
    val = x["value"]; mdl = x["model"]
    d = DP._days(x["date"])
    ok = isfinite.(val)
    bc = [x["source"][i] == "backcast" && ok[i] for i in eachindex(val)]
    nb = [!bc[i] && ok[i] for i in eachindex(val)]
    sd0 = get(attrs(x), "splice_date", missing)
    vl = sd0 === missing || sd0 === nothing ? Float64[] : DP._days(sd0)
    data = SimLev.RList("backcast" => RFrame("date" => collect(x["date"])[ok], "value" => val[ok], "model" => mdl[ok],
                                            "source" => String[string(v) for v in x["source"][ok]]))
    svg = _bc_doc(width, height) do io
        _bc_panel(io, [(d[ok], mdl[ok], "#A6A6A6", 1), (d[bc], val[bc], "#B5562B", 1.2), (d[nb], val[nb], "#2C6E9B", 1.2)];
                  w = width, h = height, title = "Backcast und Produkt", xlab = "Datum",
                  ylab = log ? "Wert (log. Skala)" : "Wert", logy = log, vlines = vl, xdate = true,
                  legend = [("Backcast", "#B5562B"), ("Produkt", "#2C6E9B"), ("Modell durchgehend", "#A6A6A6")])
    end
    return (svg, data)
end

function __init__()
    register_print!("SimLevBackcastFit", (io, x) -> print(io, format_SimLevBackcastFit(x)))
    register_summary!("SimLevBackcastFit", (x, args...; kw...) -> summary_SimLevBackcastFit(x))
    register_plot!("SimLevBackcastFit", SimLev._plot_method(plot_SimLevBackcastFit, "SimLevBackcastFit"))
    register_print!("SimLevBackcast", _print_backcast)
    register_plot!("SimLevBackcast", SimLev._plot_method(plot_SimLevBackcast, "SimLevBackcast"))
end

end # module
