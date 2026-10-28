# DeepAnalysis – r/R/deep_analysis.R (Vorlage python/simlev/deep_analysis.py)
#
# deep_analysis() analysiert ein oder mehrere Ergebnisse von simulation()
# (oder beliebige Kursreihen) nachträglich: Benchmark-Kennzahlen (Alpha, Beta,
# Capture, Tracking Error, Information Ratio, M²), VaR/CVaR, Rendite- und
# Monatstabellen, Saisonalität, Drawdown-Tabelle, rollierende Kennzahlen und
# geldgewichtete Rendite (MWRR).
#
# Die Hilfen im ersten Abschnitt (Datum, Schlüssel, Statistik-/Formatierungs-
# aufrufe, SVG) nutzen auch Planning und AnalysisTests.
module DeepAnalysis

import ..SimLev
using ..SimLev: _AnaSvg, _MONATE_KURZ, _ana_hline, _ana_legend, _ana_lines, _ana_panel, _ana_ramp, _ana_rect,
                _ana_svg_done, _ana_text, _ana_year_ticks
using Dates

export deep_analysis

const _NA = SimLev.NA
const _MONTH_ABB = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const _EPOCH = Date(1970, 1, 1)

# ═══════════════════════════════════════════════════════════════════════════
# Gemeinsame Hilfen (auch für Planning und AnalysisTests)
# ═══════════════════════════════════════════════════════════════════════════

"`message()`: Hinweis auf stderr."
_message(text::AbstractString) = (println(stderr, text); nothing)

"R-Fehler (`stop(text)`)."
_stop(text::AbstractString) = error(text)

# ── Vektoren ────────────────────────────────────────────────────────────────

_isnum_el(x) = x isa Real && !(x isa Bool)
"Werte eines Vektors/Skalars als `Vector{Float64}` (missing/nothing → NA)."
_f64(x::Real) = [Float64(x)]
_f64(::Missing) = [_NA]
_f64(x::AbstractVector) = Float64[_f64el(e) for e in x]
_f64(x::Tuple) = Float64[_f64el(e) for e in x]
_f64el(e) = e === missing || e === nothing ? _NA : e isa Bool ? Float64(e) : Float64(e)
"Erstes Element (Skalar bleibt Skalar)."
_first(x) = x isa AbstractVector || x isa Tuple ? first(x) : x
"Zeichenketten eines (Vektor-)Ergebnisses."
_strs(x) = x isa AbstractString ? [String(x)] : String[String(e) for e in x]
_str1(x) = x isa AbstractString ? String(x) : String(first(x))

"`which(c(key[-1] != key[-length(key)], TRUE))` (1-basiert)."
function _last_of_key(key::AbstractVector)
    n = length(key)
    [i for i in 1:n if i == n || key[i+1] != key[i]]
end

"`match(a, b)` (1-basiert, 0 = kein Treffer)."
function _match(a, b)
    pos = Dict{eltype(b),Int}()
    for (i, v) in enumerate(b)
        haskey(pos, v) || (pos[v] = i)
    end
    Int[get(pos, v, 0) for v in a]
end

"`duplicated(x, fromLast = TRUE)`."
function _duplicated_last(x)
    seen = Set{Any}()
    out = falses(length(x))
    for i in length(x):-1:1
        k = x[i] isa Float64 && isnan(x[i]) ? :NA : x[i]
        if k in seen
            out[i] = true
        else
            push!(seen, k)
        end
    end
    collect(out)
end

"R's `max()` für Doubles (NA vor NaN, erstes Maximum bei Gleichstand)."
function _rmax(x)
    s = -Inf; upd = false
    for v in x
        v = Float64(v)
        if isnan(v)
            (!upd || !SimLev.isna_strict(s)) && (s = v)
            upd = true
        elseif !upd || v > s
            s = v; upd = true
        end
    end
    upd || @warn "no non-missing arguments to max; returning -Inf"
    s
end
"R's `min()` für Doubles."
function _rmin(x)
    s = Inf; upd = false
    for v in x
        v = Float64(v)
        if isnan(v)
            (!upd || !SimLev.isna_strict(s)) && (s = v)
            upd = true
        elseif !upd || v < s
            s = v; upd = true
        end
    end
    upd || @warn "no non-missing arguments to min; returning Inf"
    s
end
"`which.min(x)` (erstes Minimum, NaN ignoriert; 0 = keines)."
function _which_min(x)
    k = 0; m = Inf
    for (i, v) in enumerate(x)
        isnan(v) && continue
        if k == 0 || v < m
            k = i; m = v
        end
    end
    k
end
function _which_max(x)
    k = 0; m = -Inf
    for (i, v) in enumerate(x)
        isnan(v) && continue
        if k == 0 || v > m
            k = i; m = v
        end
    end
    k
end

"R's `cummax()` (NA/NaN pflanzen sich fort)."
function _cummax(x::AbstractVector)
    out = Vector{Float64}(undef, length(x))
    m = -Inf
    nanv = 0.0; isn = false
    for i in eachindex(x)
        v = Float64(x[i])
        if isn
            out[i] = nanv; continue
        end
        if isnan(v)
            isn = true; nanv = v; out[i] = v; continue
        end
        m = v > m ? v : m
        out[i] = m
    end
    out
end

"`mean(<logical>)` (Ganzzahlsumme / n in long double)."
_mean_lgl(b) = isempty(b) ? NaN : SimLev.r_mean_int(Int[x ? 1 : 0 for x in b])

"`colMeans(M, na.rm)`: long-double-Summe je Spalte / Anzahl."
function _col_means(M::AbstractMatrix; na_rm::Bool = false)
    out = Vector{Float64}(undef, size(M, 2))
    for j in 1:size(M, 2)
        s = SimLev.F80(0.0); c = 0
        for i in 1:size(M, 1)
            v = Float64(M[i, j])
            if na_rm && isnan(v)
                continue
            end
            s = s + SimLev.F80(v); c += 1
        end
        out[j] = c == 0 ? NaN : Float64(s / SimLev.F80(c))
    end
    out
end

"`rowMeans(M)`: long-double-Summe über Spalten / p."
function _row_means(M::AbstractMatrix)
    n, p = size(M)
    out = Vector{Float64}(undef, n)
    for i in 1:n
        s = SimLev.F80(0.0)
        for j in 1:p
            s = s + SimLev.F80(Float64(M[i, j]))
        end
        out[i] = Float64(s / SimLev.F80(p))
    end
    out
end

# ── Datum ───────────────────────────────────────────────────────────────────

"Tage seit 1970 (Float64; missing/NA → NaN) aus Date, Zahl oder Vektor davon."
_day1(x::Date) = Float64(Dates.value(x - _EPOCH))
_day1(x::DateTime) = _day1(Date(x))
_day1(x::Real) = Float64(x)
_day1(::Missing) = NaN
_day1(::Nothing) = NaN
_days(x::AbstractVector) = Float64[_day1(e) for e in x]
_days(x) = [_day1(x)]
"Tage → Date-Vektor (NaN → missing)."
function _dates(d::AbstractVector)
    any(isnan, d) && return Union{Missing,Date}[isnan(v) ? missing : _EPOCH + Day(Int(v)) for v in d]
    Date[_EPOCH + Day(Int(v)) for v in d]
end
_date1(v::Real) = _EPOCH + Day(Int(v))

"`.to_date(x, what)` (Teil A) → Tage als Float64."
_to_date_days(x, what) = _days(SimLev.DataPrep._to_date(x, what))

"`format(<Date>)` eines Tages (NaN → \"NA\")."
_fmt_date1(day::Real) = isnan(day) ? "NA" : _fmt_ymd(_date1(day))
function _fmt_ymd(d::Date)
    y, m, dd = Dates.yearmonthday(d)
    string(y < 0 ? "-" * lpad(-y, 4, '0') : lpad(y, 4, '0'), "-", lpad(m, 2, '0'), "-", lpad(dd, 2, '0'))
end

"Schlüssel `format(date, \"%Y-%m\")` als Zahl Jahr*100+Monat."
_key_month(days) = Int[(d = _date1(v); Dates.year(d) * 100 + Dates.month(d)) for v in days]
"Schlüssel `format(date, \"%Y\")`."
_key_year(days) = Int[Dates.year(_date1(v)) for v in days]
"Schlüssel `format(date, \"%G-%V\")` (ISO-Jahr*100 + ISO-Woche)."
function _key_isoweek(days)
    out = Vector{Int}(undef, length(days))
    for (i, v) in enumerate(days)
        d = _date1(v)
        th = d + Day(4 - Dates.dayofweek(d))      # Donnerstag derselben ISO-Woche
        out[i] = Dates.year(th) * 100 + Dates.week(d)
    end
    out
end

# ── Argumente ───────────────────────────────────────────────────────────────

"Nachbildung von R's `match.arg(arg)` mit R's Meldungen."
function _match_arg(value, choices)
    choices = String[String(c) for c in choices]
    value === nothing && return choices[1]
    if value isa Union{AbstractVector,Tuple}
        all(v -> v isa AbstractString, value) || error("'arg' must be NULL or a character vector")
        String[String(v) for v in value] == choices && return choices[1]
        length(value) > 1 && error("'arg' must be of length 1")
        value = isempty(value) ? "" : first(value)
    end
    value isa Union{AbstractString,Symbol} || error("'arg' must be NULL or a character vector")
    v = String(string(value))
    i = findfirst(==(v), choices)
    if i === nothing && !isempty(v)
        hits = findall(c -> startswith(c, v), choices)
        length(hits) == 1 && (i = hits[1])
    end
    if i === nothing
        chs = unique(filter(!isempty, choices))
        error((length(chs) == 1 ? "'arg' should be " : "'arg' should be one of ") * join(("“$(c)”" for c in chs), ", "))
    end
    choices[i]
end

"Element eines Ergebnisobjekts (Feld oder Schlüssel; fehlt → nothing)."
function _rget(x, name::AbstractString, default = nothing)
    x === nothing && return default
    if x isa AbstractDict
        return haskey(x, name) ? x[name] : default
    elseif x isa NamedTuple
        return haskey(x, Symbol(name)) ? getfield(x, Symbol(name)) : default
    end
    s = Symbol(name)
    hasproperty(x, s) || return default
    v = try
        getproperty(x, s)
    catch
        return default
    end
    v
end

"""
Ergebnis ohne Element `filled` (wie `x\$filled <- NULL` in R, ältere Ergebnisse):
bei einer Liste wird das Element entfernt, bei einem Strukturtyp leer gesetzt.
"""
function _without_filled(x)
    if x isa SimLev.SimLevResult
        d = copy(getfield(x, :data)); delete!(d, "filled")
        return SimLev.SimLevResult(d, getfield(x, :trades))
    elseif x isa AbstractDict
        y = copy(x); delete!(y, "filled"); return y
    end
    T = typeof(x)
    vals = Any[f == :filled ? similar(getfield(x, f), 0) : getfield(x, f) for f in fieldnames(T)]
    T(vals...)
end

_is_result(x) = x isa SimLev.SimLevResult || (x isa SimLev.RList && "SimLevResult" in SimLev.r_class(x))
_is_frame(x) = x isa SimLev.RFrame || x isa NamedTuple ||
               ((x isa AbstractVector{<:Pair} || (x isa AbstractDict && !(x isa SimLev.RList))) && SimLev.as_rframe(x) isa SimLev.RFrame)
"data.frame aus natürlichen Julia-Formen (NamedTuple, Dict, Pair-Vektor; siehe `SimLev.as_rframe`)."
_as_frame(x::SimLev.RFrame) = x
_as_frame(x::NamedTuple) = SimLev.RFrame((String(k) => v for (k, v) in pairs(x))...)
_as_frame(x::Union{AbstractVector{<:Pair},AbstractDict}) = SimLev.as_rframe(x)

"`is.numeric()` einer data.frame-Spalte."
function _col_is_numeric(v)
    v isa AbstractVector || return _isnum_el(v)
    T = nonmissingtype(eltype(v))
    T <: Bool && return false
    T <: Real && return true
    T === Any || return false
    vals = [e for e in v if e !== missing && e !== nothing]
    !isempty(vals) && all(_isnum_el, vals)
end
"`class(v)[1]` einer Spalte (für Meldungen)."
function _r_class(v)
    T = nonmissingtype(eltype(v))
    T <: Bool && return "logical"
    T <: Integer && return "integer"
    T <: AbstractFloat && return "numeric"
    T <: Date && return "Date"
    T <: AbstractString && return "character"
    vals = [e for e in v if e !== missing && e !== nothing]
    !isempty(vals) && all(e -> e isa Bool, vals) && return "logical"
    "character"
end
"`as.numeric()` einer Spalte."
_as_numeric_col(v) = Float64[e === missing || e === nothing ? _NA : Float64(e) for e in v]

# ── Statistik / Formatierung (Infrastruktur) ────────────────────────────────

_vecf(x) = x isa AbstractArray ? Float64[Float64(e) for e in vec(collect(x isa SimLev.RVector ? x.values : x))] :
           x isa Real ? [Float64(x)] : _f64(collect(x))

"`stats::quantile(x, probs, names = FALSE)` (Typ 7)."
_quantile(x, probs) = _vecf(SimLev.RStats.quantile(collect(Float64, x), collect(Float64, probs); names = false))
_q1(x, p) = _quantile(x, [Float64(p)])[1]
"`stats::cor(x, y)` (Pearson) zweier Vektoren."
_cor(x, y) = _vecf(SimLev.RStats.cor(collect(Float64, x), collect(Float64, y)))[1]
"`stats::cor(M)` einer Matrix → Matrix."
_cor_mat(M::AbstractMatrix) = (r = SimLev.RStats.cor(Matrix{Float64}(M)); Matrix{Float64}(r isa SimLev.NamedMat ? r.data : r))
"`stats::cov(x, y)`."
_cov(x, y) = _vecf(SimLev.RStats.cov(collect(Float64, x), collect(Float64, y)))[1]

"`sprintf(fmt, ...)` mit skalaren Argumenten (R-Regeln)."
_sp(fmt::AbstractString, args...) = _str1(SimLev.RFmt.r_sprintf(fmt, args...))
"`formatC(strs, width = w)` → zusammengefügt (gemeinsame Breite wie R)."
_fmtc_w(strs, w) = isempty(strs) ? "" : join(_strs(SimLev.RFmt.formatC(String[String(s) for s in strs]; width = w)))
"`format(x)` (R's Standardformat) als Zeichenketten."
_format(x) = _strs(SimLev.RFmt.r_format(x))
"`nchar(s)`."
_nchar(s::AbstractString) = length(s)
"Druckausgabe (Text von `print()`, RFmt.print_*) mit abschließendem Zeilenumbruch."
_print_txt(f::Function, args...; kw...) = String(f(args...; kw...)) * "\n"
"`print(<matrix>)`."
_print_matrix(io::IO, M) = print(io, _print_txt(SimLev.RFmt.print_matrix, M))
"`print(<data.frame>, row.names = FALSE)`."
_print_df(io::IO, df; row_names::Bool = true) = print(io, _print_txt(SimLev.RFmt.print_data_frame, df; row_names = row_names))
"`print(<named vector>)`."
_print_vector(io::IO, v) = print(io, _print_txt(SimLev.RFmt.print_vector, v))
"`round(x, digits)` elementweise (Matrix/Vektor/NamedMat)."
_rround(x::Real, d = 0) = Float64(SimLev.RFmt.r_round(Float64(x), d))
function _rround(M::SimLev.NamedMat, d = 0)
    SimLev.NamedMat(map(v -> _rround(v, d), M.data); rownames = M.rownames, colnames = M.colnames)
end
_rround(M::AbstractArray, d = 0) = map(v -> _rround(v, d), M)

# ═══════════════════════════════════════════════════════════════════════════
# Reihen aufbereiten
# ═══════════════════════════════════════════════════════════════════════════

"Aufbereitete Reihe (`.da_series`): Datum als Tage seit 1970."
mutable struct DASeries
    name::String
    date::Vector{Float64}
    value::Vector{Float64}
    filled::Vector{Bool}
    worth::Union{Nothing,Vector{Float64}}
    flows::Union{Nothing,Vector{Float64}}
    result::Any
    start_gross::Union{Nothing,Float64}
    defl::Union{Nothing,Vector{Float64}}
end

function _logical_or_false(e)
    (e === missing || e === nothing) && return false
    e isa Bool && return e
    e isa Real && return !isnan(Float64(e)) && e != 0
    false
end

"Eine Reihe für die Analyse aufbereiten (`.da_series`)."
function _da_series(x, name::AbstractString)
    name = String(name)
    if _is_result(x)
        ix = SimLev.Withdrawal.result_index(x)
        value = _f64(ix["value"]); n = length(value)
        fl0 = _rget(x, "filled")
        fl = if fl0 === nothing || !(fl0 isa AbstractVector) || length(fl0) != n
            fill(false, n)
        else
            Bool[_logical_or_false(e) for e in fl0]
        end
        inv = _rget(x, "invested")
        sg = inv === nothing ? nothing : (v = _f64(inv); isempty(v) ? nothing : v[1])
        return DASeries(name, _to_date_days(ix["date"], "'$name'"), value, fl, _f64(ix["worth"]), _f64(ix["flows"]),
                        x, sg, nothing)
    end
    if _is_frame(x)
        x = _as_frame(x)
        nms = names(x)
        if !("date" in nms)
            _stop(_sp("'%s': data.frame braucht eine Spalte 'date' (vorhanden: %s)%s.", name, join(nms, ", "),
                      length(nms) == 1 ? "; nur eine Spalte: Trennzeichen prüfen, Semikolon-Dateien mit read.csv2() einlesen" : ""))
        end
        vc = if "value" in nms
            "value"
        else
            txt = _strs(SimLev.DataPrep._num_text_cols(x, "date"))
            isempty(txt) || SimLev.DataPrep._num_text_stop(x, txt, name)
            num = [k for k in nms if _col_is_numeric(x[k]) && k != "date"]
            isempty(num) && _stop(_sp("'%s': keine numerische Wertspalte gefunden.", name))
            length(num) > 1 && _message(_sp("Hinweis: '%s': Wertspalte '%s' verwendet (weitere numerische Spalten: %s).",
                                            name, num[1], join(num[2:end], ", ")))
            num[1]
        end
        col = x[vc]
        if !_col_is_numeric(col)
            sub = SimLev.RFrame(vc => col)
            isempty(_strs(SimLev.DataPrep._num_text_cols(sub))) || SimLev.DataPrep._num_text_stop(x, [vc], name)
            _stop(_sp("'%s': Wertspalte '%s' ist nicht numerisch (Klasse %s).", name, vc, _r_class(col)))
        end
        v = _as_numeric_col(col)
        d = _to_date_days(x["date"], "'$name': Spalte 'date'")
        fm = get(SimLev.attrs(x), "filled", nothing)
        fl = fill(false, length(v))
        if fm isa SimLev.RFrame && SimLev.nrow(fm) == length(v)        # align_series(): Bool-Spalten als RFrame
            fn = names(fm)
            j = vc in fn ? vc : length(fn) == 1 ? fn[1] : nothing
            j === nothing || (fl = Bool[e === true for e in fm[j]])
        elseif fm isa AbstractMatrix && size(fm, 1) == length(v)
            cn = fm isa SimLev.NamedMat ? fm.colnames : nothing
            j = cn !== nothing && vc in cn ? findfirst(==(vc), cn) : size(fm, 2) == 1 ? 1 : nothing
            j === nothing || (fl = Bool[fm[i, j] === true for i in 1:size(fm, 1)])
        end
        idx = findall(!isnan, d)
        idx = idx[sortperm(d[idx]; alg = MergeSort)]
        d = d[idx]; v = v[idx]; fl = fl[idx]
        dup = _duplicated_last(d)
        if any(dup)
            _message(_sp("Hinweis: '%s' hat %d doppelte Daten; der letzte Wert je Datum wird verwendet.", name, count(dup)))
            d = d[.!dup]; v = v[.!dup]; fl = fl[.!dup]
        end
        has = findall(!isnan, v)
        isempty(has) && _stop(_sp("'%s': Wertspalte '%s' hat keine Werte.", name, vc))
        r = has[1]:has[end]
        d = d[r]; v = v[r]; fl = fl[r]
        if any(isnan, v)
            fl = fl .| isnan.(v)
            v = _f64(SimLev.Backcast._fill_na(v, "locf"))
        end
        bad = findall(e -> !isfinite(e) || e <= 0, v)
        if !isempty(bad)
            _stop(_sp("'%s': Wertspalte '%s' muss positive Niveaus enthalten (Kurse oder Indexstände, keine Renditen); %d Werte <= 0, z. B. %s am %s.",
                      name, vc, length(bad), _format(v[bad[1]])[1], _fmt_date1(d[bad[1]])))
        end
        length(v) < 2 && _stop(_sp("'%s': mindestens zwei Daten mit Wert nötig.", name))
        return DASeries(name, d, v, collect(Bool, fl), nothing, nothing, nothing, nothing, nothing)
    end
    _stop(_sp("'%s' muss ein SimLevResult oder ein data.frame(date, value) sein.", name))
end

"""
Risikoloser Zins je ausgewerteter Rendite (`.da_rf`); `kk` 1-basiert.
Liefert `RList(r, ann, cum)`.
"""
function _da_rf(date, rate, kk, defl = nothing)
    date = date isa AbstractVector{Float64} ? date : _days(date)
    rate = _f64(rate); kk = Int[Int(k) for k in (kk isa AbstractVector ? kk : [kk])]
    n = length(date)
    g = zeros(n)
    for i in 2:n
        g[i] = SimLev.RLibm.log1p(rate[i] / 100) * (date[i] - date[i-1]) / 365.25
    end
    if defl !== nothing
        df = _f64(defl)
        for i in 2:n
            g[i] = g[i] - (SimLev.RLibm.log(df[i]) - SimLev.RLibm.log(df[i-1]))
        end
    end
    L = SimLev.r_cumsum(g)
    Lk = L[kk]
    r = Float64[SimLev.RLibm.expm1(Lk[i+1] - Lk[i]) for i in 1:length(Lk)-1]
    span = (date[end] - date[1]) / 365.25
    ann = SimLev.RLibm.expm1((L[end] - L[1]) / SimLev.r_max2(span, 1e-9))
    SimLev.RList("r" => r, "ann" => ann, "cum" => L)
end

"Reihe deflationieren (Kaufkraft des Startdatums), `.da_deflate`."
function _da_deflate(s::DASeries, inflation)
    d = s.date
    infl1 = inflation isa Real && !(inflation isa Bool) ? Float64(inflation) :
            (inflation isa AbstractVector && !(inflation isa SimLev.RVector && inflation.names !== nothing) &&
             length(inflation) == 1 && _isnum_el(inflation[1])) ? Float64(inflation[1]) : nothing
    cpi = if infl1 !== nothing
        b = 1 + infl1 / 100
        Float64[SimLev.r_pow(b, (v - d[1]) / 365.25) for v in d]
    else
        dd = _dates(d)
        _f64(SimLev.DataPrep._cpi_level(inflation, SimLev.RFrame("date" => dd), dd, "inflation"))
    end
    if any(isnan, cpi)
        ok = findall(!isnan, cpi)
        _stop(_sp("inflation: Preisindex erst ab %s bekannt, die Reihe '%s' beginnt am %s.",
                  isempty(ok) ? "NA" : _fmt_date1(d[ok[1]]), s.name, _fmt_date1(d[1])))
    end
    f = cpi ./ cpi[1]
    t = DASeries(s.name, s.date, s.value ./ f, s.filled, s.worth === nothing ? nothing : s.worth ./ f,
                 s.flows === nothing ? nothing : s.flows ./ f, s.result, s.start_gross, f)
    t
end

"Wertreihe auf Perioden-Endwerte reduzieren (letzter verfügbarer Tag)."
function _da_period_values(date::AbstractVector{Float64}, value::AbstractVector, unit::AbstractString)
    key = unit == "month" ? _key_month(date) : _key_year(date)
    last = _last_of_key(key)
    (key = key[last], date = date[last], value = Float64.(value[last]), start_value = Float64(value[1]),
     start_date = date[1])
end
"Periodenrenditen `c(v[1] / start, v[-1] / v[-n]) - 1`."
function _period_returns(m)
    v = m.value
    out = Vector{Float64}(undef, length(v))
    isempty(v) && return out
    out[1] = v[1] / m.start_value - 1
    for i in 2:length(v)
        out[i] = v[i] / v[i-1] - 1
    end
    out
end
_ratio_m1(v) = Float64[v[i] / v[i-1] - 1 for i in 2:length(v)]

"Interne-Zinsfuß-Rendite (MWRR, p. a.) eines Ergebnisses (`.da_mwrr`)."
function _da_mwrr(s::DASeries)
    s.worth === nothing && return _NA
    w = s.worth; n = length(w)
    n < 2 && return _NA
    t = (s.date .- s.date[1]) ./ 365.25; horizon = t[n]
    fl = s.flows === nothing ? zeros(n) : copy(s.flows)
    length(fl) != n && (fl = zeros(n))
    fl[isnan.(fl)] .= 0.0
    fi = [i for i in 2:n if fl[i] != 0]
    if isempty(fi)
        return (w[1] > 0 && horizon > 0 && w[n] >= 0) ? SimLev.r_pow(w[n] / w[1], 1 / horizon) - 1 : _NA
    end
    start = s.start_gross !== nothing ? s.start_gross : w[1]
    Float64(_xirr_rate(vcat(0.0, t[fi]), vcat(start, fl[fi]), w[n], horizon))
end
"`.xirr_rate()` der Engine (J-ENG: `SimLev.xirr_rate`, früher `_xirr_rate`)."
_xirr_rate(t, amount, end_value, horizon) =
    (isdefined(SimLev, :xirr_rate) ? SimLev.xirr_rate : getfield(SimLev, :_xirr_rate))(t, amount, end_value, horizon)

const _DD_COLS = ["start", "trough", "end", "depth", "days_to_trough", "days_to_recover", "days_total"]

"Drawdown-Episoden (`.da_drawdowns`), nach Tiefe sortiert."
function _da_drawdowns(date, value, top = 10)
    date = date isa AbstractVector{Float64} ? date : _days(date)
    value = _f64(value)
    peak = _cummax(value)
    dd = value ./ peak .- 1
    n = length(value)
    neg = dd .< 0
    prev = vcat(false, neg[1:end-1]); nxt = vcat(neg[2:end], false)
    st = findall(neg .& .!prev)
    if isempty(st)
        return SimLev.RFrame("start" => Date[], "trough" => Date[], "end" => Date[], "depth" => Float64[],
                             "days_to_trough" => Float64[], "days_to_recover" => Float64[], "days_total" => Float64[])
    end
    en = findall(neg .& .!nxt)
    seg = cumsum(neg .& .!prev)[neg]
    rws = findall(neg)
    tr = Int[]
    for k in 1:maximum(seg)
        r = rws[seg .== k]
        push!(tr, r[_which_min(dd[r])])
    end
    s0 = max.(1, st .- 1); rec = en .+ 1; opn = rec .> n
    recc = min.(rec, n)
    endv = date[recc]; endv[opn] .= NaN
    depth = dd[tr]
    dtt = date[tr] .- date[s0]
    dtr = Float64[opn[i] ? _NA : date[recc[i]] - date[tr[i]] for i in eachindex(tr)]
    dtot = Float64[opn[i] ? date[n] - date[s0[i]] : date[recc[i]] - date[s0[i]] for i in eachindex(tr)]
    o = sortperm(depth; alg = MergeSort)
    m = Int(min(top, length(o)))
    o = o[1:max(0, m)]
    SimLev.RFrame("start" => _dates(date[s0][o]), "trough" => _dates(date[tr][o]), "end" => _dates(endv[o]),
                  "depth" => depth[o], "days_to_trough" => dtt[o], "days_to_recover" => dtr[o], "days_total" => dtot[o])
end

_calc_skew(r) = (v = SimLev.calculate_skewness(r); v === nothing || v === missing ? _NA : Float64(v))
_calc_kurt(r) = (v = SimLev.calculate_kurtosis(r); v === nothing || v === missing ? _NA : Float64(v))

"`sum()` eines Werts aus dem Ergebnis (Vektor, benannte Liste, Skalar)."
function _sum_any(v)
    v === nothing && return 0.0
    v isa Real && return Float64(v)
    v isa AbstractDict && return SimLev.r_sum(Float64[_sum_any(e) for e in values(v)])
    SimLev.r_sum(_f64(collect(v)))
end

"Kennzahlen einer Reihe (`.da_metrics`): (Namen, Werte)."
function _da_metrics(s::DASeries, rate, ppy, var_levels)
    val = s.value; fl = s.filled
    kk = vcat(1, findall(.!fl[2:end]) .+ 1)
    vk = val[kk]
    r = Float64[vk[i] / vk[i-1] - 1 for i in 2:length(vk)]
    rfl = _da_rf(s.date, rate, kk, s.defl); rf = rfl["r"]
    yrs = (s.date[end] - s.date[1]) / 365.25
    cagr = SimLev.r_pow(val[end] / val[1], 1 / yrs) - 1
    vol = SimLev.r_sd(r) * sqrt(ppy)
    ex = r .- rf
    down = ex[ex .< 0]
    peak = _cummax(val); dd = 1 .- val ./ peak
    mdd = _rmax(dd)
    ulcer = sqrt(SimLev.r_mean(dd .* dd))
    mr = _period_returns(_da_period_values(s.date, val, "month"))
    yr = _period_returns(_da_period_values(s.date, val, "year"))
    var_d = Float64[-_q1(r, a) for a in var_levels]
    cvar_d = Float64[(q = _q1(r, a); -SimLev.r_mean(r[r .<= q])) for a in var_levels]
    var_m = Float64[-_q1(mr, a) for a in var_levels]
    cvar_m = Float64[(q = _q1(mr, a); -SimLev.r_mean(mr[mr .<= q])) for a in var_levels]
    ddt = _da_drawdowns(s.date, val, 1e6)
    rf_ann = rfl["ann"]
    sdex = SimLev.r_sd(ex)
    mex = SimLev.r_mean(ex)
    nd = SimLev.nrow(ddt)
    neg = r[r .< 0]; pos = r[r .> 0]
    nm = String["start_value", "end_value", "years", "total_return", "cagr", "mwrr", "volatility", "sharpe", "sortino",
                "calmar", "max_drawdown", "avg_drawdown", "ulcer_index", "upi", "longest_drawdown_days", "recovery_factor",
                "required_to_recover", "skewness", "excess_kurtosis", "best_day", "worst_day", "best_month", "worst_month",
                "best_year", "worst_year", "positive_months", "avg_gain", "avg_loss", "gain_loss_ratio"]
    vals = Float64[
        val[1], val[end], yrs, val[end] / val[1] - 1, cagr, _da_mwrr(s), vol,
        (sdex > 0) ? mex * ppy / (sdex * sqrt(ppy)) : _NA,
        !isempty(down) ? mex * ppy / (sqrt(SimLev.r_mean([(e = min(v, 0.0); e * e) for v in ex])) * sqrt(ppy)) : _NA,
        mdd > 0 ? cagr / mdd : _NA,
        mdd, nd > 0 ? SimLev.r_mean(-ddt["depth"]) : 0.0,
        ulcer, ulcer > 0 ? (cagr - rf_ann) / ulcer : _NA,
        nd > 0 ? _rmax(ddt["days_total"]) : 0.0,
        mdd > 0 ? (val[end] / val[1] - 1) / mdd : _NA,
        dd[end] > 0 ? 1 / (1 - dd[end]) - 1 : 0.0,
        _calc_skew(r), _calc_kurt(r),
        _rmax(r), _rmin(r), _rmax(mr), _rmin(mr), _rmax(yr), _rmin(yr), _mean_lgl(mr .> 0),
        SimLev.r_mean(pos), SimLev.r_mean(neg),
        !isempty(neg) ? SimLev.r_mean(pos) / abs(SimLev.r_mean(neg)) : _NA]
    lab = String[_sp("%g", 100 * a) for a in var_levels]
    for (pre, vv) in (("var_daily_", var_d), ("cvar_daily_", cvar_d), ("var_monthly_", var_m), ("cvar_monthly_", cvar_m))
        for (lb, v) in zip(lab, vv)
            push!(nm, pre * lb); push!(vals, v)
        end
    end
    res = s.result
    push!(nm, "taxes", "trades_per_year")
    if res !== nothing
        tr = _rget(res, "tax_report")
        tx = tr === nothing ? nothing : _rget(tr, "total_taxes_paid")
        push!(vals, tx === nothing ? 0.0 : Float64(_first(tx)))
        push!(vals, _sum_any(_rget(res, "buys")) + _sum_any(_rget(res, "sells")))
    else
        push!(vals, _NA, _NA)
    end
    nm, vals
end

const _BM_ROWS = ["alpha", "beta", "correlation", "r_squared", "correlation_up", "correlation_down",
                  "up_capture", "down_capture", "capture_spread", "active_return", "tracking_error",
                  "information_ratio", "m2", "treynor"]

"Benchmark-Kennzahlen auf gemeinsamen Tagen (`.da_benchmark`)."
function _da_benchmark(s::DASeries, b::DASeries, rate, ppy, cagr_s, cagr_b)
    common = sort(collect(intersect(Set(s.date), Set(b.date))))
    is = _match(common, s.date); ib = _match(common, b.date)
    vs = s.value[is]; vb = b.value[ib]
    keep = .!(s.filled[is][2:end] .| b.filled[ib][2:end])
    if count(keep) < 3
        _stop(_sp("Benchmark '%s' und Reihe '%s' haben zu wenige gemeinsame Daten (%d gemeinsame Renditen, mindestens 3).",
                  b.name, s.name, count(keep)))
    end
    kk = vcat(1, findall(keep) .+ 1)
    vsk = vs[kk]; vbk = vb[kk]
    rs = _ratio_m1(vsk); rb = _ratio_m1(vbk)
    rfl = _da_rf(common, _f64(rate)[is], kk, s.defl !== nothing ? s.defl[is] : nothing); rf = rfl["r"]
    es = rs .- rf; eb = rb .- rf
    beta = _cov(es, eb) / SimLev.r_var(eb)
    alpha = (SimLev.r_mean(es) - beta * SimLev.r_mean(eb)) * ppy
    te = SimLev.r_sd(rs .- rb) * sqrt(ppy)
    mrs = _period_returns(_da_period_values(common, vs, "month"))
    mrb = _period_returns(_da_period_values(common, vb, "month"))
    gm(x) = SimLev.r_pow(SimLev.r_prod(1 .+ x), 1 / length(x)) - 1
    up = mrb .> 0; dn = mrb .< 0
    upc = any(up) ? gm(mrs[up]) / gm(mrb[up]) : _NA
    dnc = any(dn) ? gm(mrs[dn]) / gm(mrb[dn]) : _NA
    sharpe_s = SimLev.r_mean(es) * ppy / (SimLev.r_sd(es) * sqrt(ppy))
    rf_ann = rfl["ann"]
    c = _cor(rs, rb)
    Float64[alpha, beta, c, c * c,
            count(rb .> 0) > 2 ? _cor(rs[rb .> 0], rb[rb .> 0]) : _NA,
            count(rb .< 0) > 2 ? _cor(rs[rb .< 0], rb[rb .< 0]) : _NA,
            upc, dnc, upc - dnc, cagr_s - cagr_b, te,
            te > 0 ? SimLev.r_mean(rs .- rb) * ppy / te : _NA,
            sharpe_s * SimLev.r_sd(rb) * sqrt(ppy) + rf_ann,
            beta != 0 ? (SimLev.r_mean(es) * ppy) / beta : _NA]
end

"Monatsrenditen-Tabelle (Jahr x Monat, plus Jahr) als NamedMat."
function _da_monthly_table(s::DASeries)
    m = _da_period_values(s.date, s.value, "month")
    mr = _period_returns(m)
    yy = [k ÷ 100 for k in m.key]; mm = [k % 100 for k in m.key]
    years = sort(unique(yy))
    pos = Dict(y => i for (i, y) in enumerate(years))
    M = fill(_NA, length(years), 13)
    for (y, mo, v) in zip(yy, mm, mr)
        M[pos[y], mo] = v
    end
    yv = _da_period_values(s.date, s.value, "year")
    yr = _period_returns(yv)
    yi = _match(years, yv.key)
    for (i, j) in enumerate(yi)
        M[i, 13] = j == 0 ? _NA : yr[j]
    end
    SimLev.NamedMat(M; rownames = string.(years), colnames = vcat(_MONTH_ABB, "Year"))
end

const _ROLL_COLS = ["cagr", "volatility", "sharpe", "max_drawdown", "beta", "excess_cagr"]

"Rollierende Kennzahlen auf Monatsbasis (`.da_rolling`); `nothing` bei zu kurzer Reihe."
function _da_rolling(s::DASeries, b, window_m, rf_cum)
    m = _da_period_values(s.date, s.value, "month")
    v = vcat(m.start_value, m.value); d = vcat(m.start_date, m.date)
    Lk = rf_cum[_match(d, s.date)]
    n = length(v); w = Int(window_m)
    n <= w && return nothing
    vb = nothing
    if b !== nothing
        vb = Vector{Float64}(undef, n)
        for i in 1:n
            kb = searchsortedlast(b.date, d[i])
            x = kb > 0 ? b.value[kb] : _NA
            vb[i] = (!isfinite(x) || x <= 0) ? _NA : x
        end
    end
    out = zeros(n - w, 6)
    for (row, k) in enumerate(w+1:n)
        seg = v[k-w:k]
        r = _ratio_m1(seg)
        yrs = (d[k] - d[k-w]) / 365.25
        cg = SimLev.r_pow(seg[end] / seg[1], 1 / yrs) - 1
        vo = SimLev.r_sd(r) * sqrt(12)
        mdd = _rmax(1 .- seg ./ _cummax(seg))
        bt = _NA; exr = _NA
        if vb !== nothing && !any(isnan, vb[k-w:k])
            sb = vb[k-w:k]; rb = _ratio_m1(sb)
            bt = _cov(r, rb) / SimLev.r_var(rb)
            exr = cg - (SimLev.r_pow(sb[end] / sb[1], 1 / yrs) - 1)
        end
        rf_w = SimLev.RLibm.expm1((Lk[k] - Lk[k-w]) / yrs)
        out[row, :] = [cg, vo, vo > 0 ? (cg - rf_w) / vo : _NA, mdd, bt, exr]
    end
    SimLev.RFrame("date" => _dates(d[w+1:n]), (c => out[:, j] for (j, c) in enumerate(_ROLL_COLS))...)
end

# ═══════════════════════════════════════════════════════════════════════════
# deep_analysis
# ═══════════════════════════════════════════════════════════════════════════

_is_listlike(x) = (x isa AbstractDict && !_is_result(x)) || x isa AbstractVector{<:Pair} ||
                  (x isa AbstractVector && !(x isa SimLev.RVector) &&
                   !(eltype(x) <: Union{Real,Missing,AbstractString,Date}))

"Namen und Elemente einer R-Liste (`names(x)` → nothing, wenn unbenannt)."
function _list_items(x)
    if x isa AbstractDict
        return String[String(string(k)) for k in keys(x)], Any[v for v in values(x)]
    elseif x isa AbstractVector{<:Pair}
        return String[String(string(p.first)) for p in x], Any[p.second for p in x]
    end
    nothing, Any[v for v in x]
end

"""
    deep_analysis(x; benchmark = nothing, risk_free = 0, rolling_years = 3,
                  var_levels = [0.01, 0.05, 0.10], top_drawdowns = 10, inflation = nothing)

Vertiefte Analyse von Simulationsergebnissen (R: `deep_analysis()`).
`x`: `SimLevResult`, data.frame (`RFrame` mit `date` und Wertspalte) oder eine
Liste davon (`RList`/`Dict`/`Vector`; unbenannt: Reihen `S1`, `S2`, …).
Ergebnis: `RList` der Klasse `SimLevAnalysis` (`metrics`, `benchmark_metrics`,
`benchmark`, `annual`, `monthly`, `seasonality`, `drawdowns`, `rolling`,
`rolling_years`, `correlation`, `series`, `risk_free`, `var_levels`, `real`);
Ausgabe mit `show`, `r_summary` und `r_plot`.
"""
function deep_analysis(x; benchmark = nothing, risk_free = 0, rolling_years = 3,
                       var_levels = [0.01, 0.05, 0.10], top_drawdowns = 10, inflation = nothing)
    x = SimLev.as_rframe(x)
    benchmark = SimLev.as_rframe(benchmark)
    risk_free = SimLev.as_rframe(risk_free)
    inflation = SimLev.as_rframe(inflation)
    if _is_result(x) || _is_frame(x)
        x = SimLev.RList("Strategie" => x)
    end
    (_is_listlike(x) && length(x) > 0) || _stop("x muss ein SimLevResult, ein data.frame oder eine Liste davon sein.")
    keys_, vals = _list_items(x)
    if keys_ === nothing || any(==(""), keys_)
        keys_ = ["S$i" for i in eachindex(vals)]
    end
    ry = rolling_years
    ryv = ry isa AbstractVector ? collect(ry) : Any[ry]
    rynum = all(_isnum_el, ryv)
    if !rynum || length(ryv) != 1 || isnan(Float64(ryv[1])) || _rround(12 * Float64(ryv[1])) < 2
        txt = rynum && !isempty(ryv) ? _format(_f64(ryv)) : _format(ryv)
        _stop(join(_sp("rolling_years muss mindestens 2/12 (zwei Monate) betragen (ist: %s).", t) for t in txt))
    end
    vl = var_levels isa AbstractVector ? collect(var_levels) : Any[var_levels]
    if isempty(vl) || !all(_isnum_el, vl) || any(e -> isnan(Float64(e)), vl) || any(e -> e <= 0 || e >= 1, vl)
        _stop("var_levels: Wahrscheinlichkeiten als Anteile zwischen 0 und 1, z. B. c(0.01, 0.05).")
    end
    vlf = Float64[Float64(e) for e in vl]
    order = String[]; ser = Dict{String,DASeries}()
    for (k, v) in zip(keys_, vals)
        s = _da_series(v, k)
        haskey(ser, k) || push!(order, k)
        ser[k] = s
    end
    bname = nothing; bser = nothing
    if benchmark !== nothing
        if benchmark isa AbstractString || (benchmark isa AbstractVector && !isempty(benchmark) && all(e -> e isa AbstractString, benchmark))
            bl = benchmark isa AbstractString ? [String(benchmark)] : String.(benchmark)
            (length(bl) != 1 || !haskey(ser, bl[1])) && _stop(_sp("benchmark muss ein Name aus x sein (%s).", join(order, ", ")))
            bname = bl[1]; bser = ser[bname]
        else
            bname = "Benchmark"
            haskey(ser, bname) && _stop("x enthält bereits eine Reihe 'Benchmark'; benchmark = \"Benchmark\" wählen oder die Reihe in x umbenennen.")
            bser = _da_series(benchmark, bname)
            ser[bname] = bser; push!(order, bname)
        end
    end
    for k in order
        s = ser[k]; nn = count(.!s.filled[2:end])
        nn < 2 && _stop(_sp("'%s': zu kurz (%d Renditen ohne gefüllte Tage, mindestens 2).", s.name, nn))
    end
    if inflation !== nothing
        for k in order
            ser[k] = _da_deflate(ser[k], inflation)
        end
        bname === nothing || (bser = ser[bname])
    end
    rf_of(s) = _f64(SimLev.Backcast._resolve_series(risk_free, SimLev.RFrame("date" => _dates(s.date)), "risk_free"))
    ppy_of(s) = count(.!s.filled[2:end]) / ((s.date[end] - s.date[1]) / 365.25)
    rfs = Dict(k => rf_of(ser[k]) for k in order)
    mets = [_da_metrics(ser[k], rfs[k], ppy_of(ser[k]), vlf) for k in order]
    mnames = mets[1][1]
    met = SimLev.NamedMat(reduce(hcat, [m[2] for m in mets]); rownames = mnames, colnames = order)
    bm = nothing
    if bser !== nothing
        others = [k for k in order if k != bname]
        ic = findfirst(==("cagr"), mnames)
        cb = met.data[ic, findfirst(==(bname), order)]
        cols = [_da_benchmark(ser[nm], bser, rfs[nm], ppy_of(ser[nm]), met.data[ic, findfirst(==(nm), order)], cb) for nm in others]
        B = isempty(cols) ? zeros(14, 0) : reduce(hcat, cols)
        bm = SimLev.NamedMat(B; rownames = _BM_ROWS, colnames = isempty(others) ? nothing : others)
    end
    monthly = SimLev.RList()
    for k in order
        monthly[k] = _da_monthly_table(ser[k])
    end
    yrs_all = sort(unique(vcat([monthly[k].rownames for k in order]...)))
    A = fill(_NA, length(yrs_all), length(order))
    for (j, k) in enumerate(order)
        M = monthly[k]; ii = _match(yrs_all, M.rownames)
        for (i, r) in enumerate(ii)
            r > 0 && (A[i, j] = M.data[r, 13])
        end
    end
    annual = SimLev.NamedMat(A; rownames = yrs_all, colnames = order)
    seas = reduce(hcat, [_col_means(monthly[k].data[:, 1:12]; na_rm = true) for k in order])
    seasonality = SimLev.NamedMat(seas; rownames = _MONTH_ABB, colnames = order)
    dds = SimLev.RList()
    for k in order
        dds[k] = _da_drawdowns(ser[k].date, ser[k].value, top_drawdowns)
    end
    w = Int(_rround(12 * Float64(ryv[1])))
    rolling = SimLev.RList()
    for k in order
        s = ser[k]
        rolling[k] = _da_rolling(s, (bser !== nothing && s !== bser) ? bser : nothing, w,
                                 _da_rf(s.date, rfs[k], 1, s.defl)["cum"])
    end
    common = copy(ser[order[1]].date)
    for k in order[2:end]
        st = Set(ser[k].date)
        common = [c for c in common if c in st]
    end
    common = unique(common)
    cor_d = nothing; cor_m = nothing
    if length(order) > 1 && length(common) > 30
        Rd = reduce(hcat, [_ratio_m1(ser[k].value[_match(common, ser[k].date)]) for k in order])
        cor_d = SimLev.NamedMat(_cor_mat(Rd); rownames = order, colnames = order)
        Rm = reduce(hcat, [_ratio_m1(_da_period_values(common, ser[k].value[_match(common, ser[k].date)], "month").value) for k in order])
        cor_m = SimLev.NamedMat(_cor_mat(Rm); rownames = order, colnames = order)
    end
    series = SimLev.RList()
    for k in order
        series[k] = SimLev.RFrame("date" => _dates(ser[k].date), "value" => copy(ser[k].value))
    end
    SimLev.RList("metrics" => met, "benchmark_metrics" => bm, "benchmark" => bname, "annual" => annual,
                 "monthly" => monthly, "seasonality" => seasonality, "drawdowns" => dds, "rolling" => rolling,
                 "rolling_years" => rolling_years,
                 "correlation" => SimLev.RList("daily" => cor_d, "monthly" => cor_m),
                 "series" => series, "risk_free" => risk_free, "var_levels" => var_levels,
                 "real" => inflation !== nothing; class = ["SimLevAnalysis"])
end

# ═══════════════════════════════════════════════════════════════════════════
# Ausgabe
# ═══════════════════════════════════════════════════════════════════════════

const _PCT = Set(["total_return", "cagr", "mwrr", "volatility", "max_drawdown", "avg_drawdown", "ulcer_index",
                  "required_to_recover", "best_day", "worst_day", "best_month", "worst_month", "best_year", "worst_year",
                  "positive_months", "avg_gain", "avg_loss", "alpha", "active_return", "tracking_error", "m2", "treynor"])

const _LABELS = Dict(
    "total_return" => "Gesamtrendite", "cagr" => "CAGR (TWR)", "mwrr" => "MWRR (geldgewichtet)",
    "volatility" => "Volatilität p. a.", "sharpe" => "Sharpe", "sortino" => "Sortino", "calmar" => "Calmar",
    "max_drawdown" => "Max. Drawdown", "avg_drawdown" => "Mittlerer Drawdown", "ulcer_index" => "Ulcer Index",
    "upi" => "Ulcer Performance Index", "longest_drawdown_days" => "Längster Drawdown",
    "recovery_factor" => "Recovery Factor", "best_year" => "Bestes Jahr", "worst_year" => "Schlechtestes Jahr",
    "worst_month" => "Schlechtester Monat", "positive_months" => "Positive Monate", "var_daily_5" => "VaR 5 % (Tag)",
    "cvar_daily_5" => "CVaR 5 % (Tag)", "var_monthly_5" => "VaR 5 % (Monat)", "cvar_monthly_5" => "CVaR 5 % (Monat)",
    "taxes" => "Steuern", "alpha" => "Alpha p. a.", "beta" => "Beta", "correlation" => "Korrelation",
    "r_squared" => "R²", "up_capture" => "Up-Capture", "down_capture" => "Down-Capture",
    "capture_spread" => "Capture Spread", "active_return" => "Aktive Rendite p. a.",
    "tracking_error" => "Tracking Error", "information_ratio" => "Information Ratio",
    "m2" => "M² (Modigliani)", "treynor" => "Treynor")

const _SHOW = ["total_return", "cagr", "mwrr", "volatility", "sharpe", "sortino", "calmar", "max_drawdown",
               "avg_drawdown", "ulcer_index", "upi", "longest_drawdown_days", "best_year", "worst_year",
               "worst_month", "positive_months", "var_daily_5", "cvar_daily_5", "var_monthly_5",
               "cvar_monthly_5", "taxes"]

const _BAR = "═"^62

function _da_fmt(k::AbstractString, v::Float64)
    isnan(v) && return "–"
    (k in _PCT || startswith(k, "var_") || startswith(k, "cvar_")) && return _sp("%.2f %%", 100 * v)
    k in ("start_value", "end_value", "taxes") && return _str1(SimLev.RFmt.formatC(v; format = "f", digits = 0, big_mark = " "))
    k == "longest_drawdown_days" && return _sp("%.0f T.", v)
    _sp("%.3f", v)
end

"`format(s, width = w)` für Zeichenketten (Auffüllen nach Zeichen)."
_fmt_width(s::AbstractString, w::Int) = _str1(SimLev.RFmt.r_format(String(s); width = w))

function _rows_text(io::IO, M::SimLev.NamedMat, keys, w)
    for k in keys
        i = findfirst(==(k), M.rownames)
        cells = [_da_fmt(k, Float64(v)) for v in M.data[i, :]]
        print(io, "  ", _fmt_width(_LABELS[k], 26), _fmtc_w(cells, w), "\n")
    end
end

"`print.SimLevAnalysis`."
function _print_analysis(io::IO, x)
    M = x["metrics"]
    show_ = [k for k in _SHOW if k in M.rownames]
    cn = M.colnames
    w = max(12, maximum(_nchar.(cn)) + 1)
    print(io, "\n", _BAR, "\n")
    print(io, "                    SimLev Detailanalyse                       \n")
    print(io, _BAR, "\n")
    s1 = first(values(x["series"]))
    dd = _days(s1["date"])
    print(io, _sp("  Zeitraum: %s bis %s (%.1f Jahre)%s\n\n", _fmt_date1(_rmin(dd)), _fmt_date1(_rmax(dd)),
                  M.data[findfirst(==("years"), M.rownames), 1],
                  get(x, "real", false) === true ? ", real (Kaufkraft zu Beginn)" : ""))
    print(io, _sp("  %-26s%s\n", "", _fmtc_w(cn, w)))
    _rows_text(io, M, show_, w)
    B = get(x, "benchmark_metrics", nothing)
    if B !== nothing
        print(io, "\n  Gegen Benchmark '", x["benchmark"], "'\n")
        print(io, _sp("  %-26s%s\n", "", _fmtc_w(B.colnames === nothing ? String[] : B.colnames, w)))
        _rows_text(io, B, ["alpha", "beta", "correlation", "r_squared", "up_capture", "down_capture",
                           "capture_spread", "active_return", "tracking_error", "information_ratio", "m2"], w)
    end
    print(io, _BAR, "\n")
    nothing
end

"`summary.SimLevAnalysis`: druckt Kennzahlen, Jahresrenditen (%) und je Reihe die fünf größten Drawdowns."
function _summary_analysis(object; io::IO = stdout)
    _print_analysis(io, object)
    print(io, "\n  Jahresrenditen (%)\n")
    A = object["annual"]
    _print_matrix(io, SimLev.NamedMat(map(v -> _rround(100 * v, 2), A.data); rownames = A.rownames, colnames = A.colnames))
    for (nm, d) in object["drawdowns"]
        print(io, _sp("\n  Größte Drawdowns: %s\n", nm))
        d2 = SimLev.rows(d, 1:min(5, SimLev.nrow(d)))
        d2["depth"] = String[_sp("%.2f %%", 100 * v) for v in d2["depth"]]
        _print_df(io, d2; row_names = false)
    end
    SimLev.RList("metrics" => object["metrics"], "benchmark" => get(object, "benchmark_metrics", nothing),
                 "annual" => object["annual"], "drawdowns" => object["drawdowns"])
end

# ── Grafik (SVG ohne externe Pakete; Bausteine `_ana_*` in svg.jl) ─────────────

const _COLS = ["#2C6E9B", "#B5562B", "#3E8E5A", "#8A5BA8", "#C49A2C", "#4A4A4A"]

"""
`plot.SimLevAnalysis` (SVG): Wertentwicklung, Drawdowns, rollierend, Jahresrenditen oder Monats-Heatmap.

Liefert `(svg, data)`; `data` je gezeichnetem Panel: `growth` (`series`, `date`, `growth` = Wert /
Startwert), `drawdown` (`series`, `date`, `drawdown` als Anteil), `rolling` (`series`, `date`,
`<metric>`), `annual` (`year` und je Reihe eine Spalte, Anteile) bzw. `monthly` (`year`, `month`,
`return`; gezeichnete Zellen).
"""
function _plot_analysis(x; type = ["overview", "growth", "drawdown", "rolling", "annual", "monthly"], series = 1,
                        metric = "cagr", file = nothing)
    type = _match_arg(type, ["overview", "growth", "drawdown", "rolling", "annual", "monthly"])
    nms = collect(keys(x["monthly"]))
    if type == "monthly"
        bad = (series isa AbstractVector && length(series) != 1) ||
              (series isa AbstractString && !(series in nms)) ||
              (_isnum_el(series) && !(series >= 1 && series <= length(nms)))
        bad && _stop(_sp("series: Name oder Nummer einer Reihe (%s).", join(nms, ", ")))
    end
    if type in ("overview", "rolling") && !(metric in _ROLL_COLS)
        _stop("metric: 'cagr', 'volatility', 'sharpe', 'max_drawdown', 'beta' oder 'excess_cagr'.")
    end
    snames = collect(keys(x["series"]))
    cols = [_COLS[mod1(i, 6)] for i in eachindex(snames)]
    pct = !(metric in ("beta", "sharpe"))
    data = SimLev.RList()
    _rep(ks, vs) = String[k for (k, v) in zip(ks, vs) for _ in eachindex(v)]
    _cdates(fr) = vcat([collect(Date, f["date"]) for f in fr]...)
    function p_growth(s, x0, y0, w, h)
        ys = [x["series"][k]["value"] ./ x["series"][k]["value"][1] for k in snames]
        ds = [_days(x["series"][k]["date"]) for k in snames]
        allv = filter(isfinite, vcat(ys...)); alld = vcat(ds...)
        p = _ana_panel(s, x0, y0, w, h, (minimum(alld), maximum(alld)), (minimum(allv), maximum(allv)); logy = true,
                       title = "Wertentwicklung (TWR, Start = 1)", ylab = "Wachstum (log)", xticks = _ana_year_ticks(alld)[1],
                       xlabels = _ana_year_ticks(alld)[2])
        for i in eachindex(snames)
            _ana_lines(s, p, ds[i], ys[i]; col = cols[i], lwd = 1.3)
        end
        _ana_legend(s, p, snames, cols)
        data["growth"] = SimLev.RFrame("series" => _rep(snames, ys), "date" => _cdates([x["series"][k] for k in snames]),
                                       "growth" => vcat(ys...))
    end
    function p_dd(s, x0, y0, w, h)
        dd = [(v = x["series"][k]["value"]; v ./ _cummax(v) .- 1) for k in snames]
        ys = [100 .* d for d in dd]
        ds = [_days(x["series"][k]["date"]) for k in snames]
        alld = vcat(ds...)
        p = _ana_panel(s, x0, y0, w, h, (minimum(alld), maximum(alld)), (minimum(vcat(ys...)), 0.0);
                       title = "Drawdowns", ylab = "Drawdown (%)", xticks = _ana_year_ticks(alld)[1], xlabels = _ana_year_ticks(alld)[2])
        for i in eachindex(snames)
            _ana_lines(s, p, ds[i], ys[i]; col = cols[i], lwd = 1)
        end
        data["drawdown"] = SimLev.RFrame("series" => _rep(snames, dd), "date" => _cdates([x["series"][k] for k in snames]),
                                         "drawdown" => vcat(dd...))
    end
    function p_roll(s, x0, y0, w, h)
        rl = [(k, r) for (k, r) in x["rolling"] if r !== nothing]
        if isempty(rl)
            _ana_panel(s, x0, y0, w, h, (0, 1), (0, 1); title = "Rollierend: Zeitraum zu kurz", box = false, xticks = [], yticks = [])
            data["rolling"] = SimLev.RFrame("series" => String[], "date" => Date[], metric => Float64[])
            return
        end
        f = pct ? 100 : 1
        raw = [collect(Float64, r[metric]) for (_, r) in rl]
        ys = [f .* v for v in raw]; ds = [_days(r["date"]) for (_, r) in rl]
        allv = filter(isfinite, vcat(ys...)); alld = vcat(ds...)
        p = _ana_panel(s, x0, y0, w, h, (minimum(alld), maximum(alld)), isempty(allv) ? (0.0, 1.0) : (minimum(allv), maximum(allv));
                       title = _sp("Rollierend %g J.: %s", Float64(_first(x["rolling_years"])), metric),
                       ylab = pct ? metric * " (%)" : metric, xticks = _ana_year_ticks(alld)[1], xlabels = _ana_year_ticks(alld)[2])
        for (i, (k, _)) in enumerate(rl)
            _ana_lines(s, p, ds[i], ys[i]; col = cols[findfirst(==(k), snames)], lwd = 1.2)
        end
        _ana_hline(s, p, 0.0)
        data["rolling"] = SimLev.RFrame("series" => _rep([k for (k, _) in rl], raw), "date" => _cdates([r for (_, r) in rl]),
                                        metric => vcat(raw...))
    end
    function p_annual(s, x0, y0, w, h)
        A = 100 .* x["annual"].data; A[isnan.(A)] .= 0
        ny, k = size(A)
        p = _ana_panel(s, x0, y0, w, h, (0.5, ny + 0.5), (min(0.0, minimum(A)), max(0.0, maximum(A)));
                       title = "Jahresrenditen", ylab = "Rendite (%)", xticks = collect(1:ny), xlabels = x["annual"].rownames)
        bw = 0.8 / k
        for i in 1:ny, j in 1:k
            xl = i - 0.4 + (j - 1) * bw
            _ana_rect(s, p, xl, 0.0, xl + bw, A[i, j]; fill = cols[j])
        end
        _ana_hline(s, p, 0.0; col = "grey", dash = "")
        An = x["annual"]
        data["annual"] = SimLev.RFrame("year" => Int[parse(Int, r) for r in An.rownames],
                                       (String(c) => An.data[:, j] for (j, c) in enumerate(An.colnames))...)
    end
    function p_monthly(s, x0, y0, w, h)
        nm = series isa AbstractString ? series : nms[Int(series)]
        M = 100 .* x["monthly"][nm].data[:, 1:12]
        fin = filter(isfinite, M); lim = isempty(fin) ? 1.0 : maximum(abs.(fin))
        pal = _ana_ramp(["#B5562B", "#F7F3EE", "#2C6E9B"], 41)
        ny = size(M, 1)
        raw = x["monthly"][nm].data[:, 1:12]; rn = x["monthly"][nm].rownames
        yy = Int[]; mm = Int[]; vv = Float64[]
        p = _ana_panel(s, x0, y0, w, h, (0.5, 12.5), (0.5, ny + 0.5); title = "Monatsrenditen: $nm",
                       xticks = collect(1:12), xlabels = _MONATE_KURZ, yticks = collect(1:ny), ylabels = x["monthly"][nm].rownames)
        for i in 1:ny, j in 1:12
            v = M[i, j]; isfinite(v) || continue
            c = pal[clamp(round(Int, (v + lim) / (2 * lim) * 40) + 1, 1, 41)]
            _ana_rect(s, p, j - 0.5, i - 0.5, j + 0.5, i + 0.5; fill = c)
            ny <= 30 && _ana_text(s, p, j, i, _sp("%.1f", v); size = 7)
            push!(yy, parse(Int, rn[i])); push!(mm, j); push!(vv, raw[i, j])
        end
        data["monthly"] = SimLev.RFrame("year" => yy, "month" => mm, "return" => vv)
    end
    s = _AnaSvg(type == "overview" ? 1100 : 900, type == "overview" ? 760 : 520)
    if type == "overview"
        p_growth(s, 0, 0, 550, 380); p_dd(s, 550, 0, 550, 380)
        p_roll(s, 0, 380, 550, 380); p_annual(s, 550, 380, 550, 380)
    else
        Dict("growth" => p_growth, "drawdown" => p_dd, "rolling" => p_roll, "annual" => p_annual,
             "monthly" => p_monthly)[type](s, 0, 0, 900, 520)
    end
    return (_ana_svg_done(s, nothing), data)
end

function __init__()
    SimLev.register_print!("SimLevAnalysis", _print_analysis)
    SimLev.register_summary!("SimLevAnalysis", (x, args...; kw...) -> _summary_analysis(x; kw...))
    SimLev.register_plot!("SimLevAnalysis", SimLev._plot_method(_plot_analysis, "SimLevAnalysis"))
end

end # module
