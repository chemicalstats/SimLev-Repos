# DataPrep – Gegenstück zu r/R/data_prep.R und python/simlev/data_prep.py
#
#   series_align        Quellen nach Datum zusammenführen, Kalender, Füllung
#   series_check        Prüfbericht (Lücken, Ausreißer, Spikes, Splits, stehende Kurse)
#   series_align_macro         Makroreihen mit Veröffentlichungsverzug auf den Tageskalender
#   series_convert_currency    Währungsumrechnung
#   index_total_return  Kurs- zu Total-Return-Index
#   series_deflate             reale Werte über einen Preisindex
#   series_splice       Ketten aus mehreren Reihen
#   strategy_from_weights, portfolio_template
#
# Datumswerte: R-`Date`-Vektoren entsprechen `Vector{Date}` (mit NA:
# `Vector{Union{Missing,Date}}`). Intern wird mit Tagen seit 1970-01-01 als
# Float64 gerechnet (`_days`, NA = `SimLev.NA`); `_as_dates` wandelt zurück.
module DataPrep

import ..SimLev
using ..SimLev: RList, RFrame, RVector, NamedMat, nrow, ncol, attrs, NA, isna_strict, rows,
                register_print!, register_summary!, r_class, inherits
using Dates

export series_align, series_check, series_align_macro, series_convert_currency, index_total_return, series_deflate,
       series_splice, strategy_from_weights, portfolio_template

# ═══════════════════════════════════════════════════════════════════════════
# Allgemeine Hilfen (R-Semantik)
# ═══════════════════════════════════════════════════════════════════════════

"R-`message()`: Text mit Zeilenumbruch auf `stderr`."
message(text) = (io = SimLev.RParallel.r_stderr(); println(io, text); flush(io); nothing)

"""
    _match_arg(arg, choices)

R-`match.arg(arg)` mit den Voreinstellungen `choices`: `nothing` oder der
vollständige Auswahlvektor ergeben die erste Wahl; eindeutige Präfixe werden
ergänzt. Fehlermeldungen wortgleich zu R.
"""
function _match_arg(arg, choices)
    ch = String[String(c) for c in choices]
    arg === nothing && return ch[1]
    if arg isa Union{AbstractVector,Tuple}
        a = collect(arg)
        (length(a) == length(ch) && all(i -> a[i] isa AbstractString && a[i] == ch[i], eachindex(a))) && return ch[1]
        length(a) == 1 || error("'arg' must be of length 1")
        arg = a[1]
    end
    arg isa Symbol && (arg = String(arg))
    arg isa AbstractString || error("'arg' must be NULL or a character vector")
    arg in ch && return String(arg)
    hits = isempty(arg) ? String[] : [c for c in ch if startswith(c, arg)]
    length(hits) == 1 && return hits[1]
    error("'arg' should be one of " * join(("\u201c$(c)\u201d" for c in ch), ", "))
end

_isna(x) = x === missing || x === nothing || (x isa AbstractFloat && isnan(x))
_isna(x::Date) = false
_isnum(x) = x isa Real && !(x isa Bool)

"R-`format(x)` für eine einzelne Zahl."
function _fmt_num(x)
    x === missing && return "NA"
    R = SimLev.RFmt
    if isdefined(R, :format)
        s = R.format(x)
        return s isa AbstractString ? String(s) : String(first(s))
    end
    x isa Integer && return string(x)
    return SimLev.r_format_digits(Float64(x), 7)
end

"R-`sprintf()` für skalare Argumente."
function _sprintf(fmt::AbstractString, args...)
    R = SimLev.RFmt
    if isdefined(R, :sprintf)
        s = R.sprintf(fmt, args...)
        return s isa AbstractString ? String(s) : String(first(s))
    end
    return SimLev.rsprintf(fmt, args...)
end

"C-`%g` wie R-`sprintf(\"%g\", x)`."
_sprintf_g(x) = _sprintf("%g", Float64(x))

# ── Kalender (proleptisch gregorianisch, beliebige Jahre) ───────────────────

const _UTD0 = 719163   # Dates.value(Date(1970, 1, 1))

# Teil:               _civil_to_days, _days_to_civil
# Herkunft:           übersetzt aus H. Hinnant, chrono-Compatible Low-Level Date Algorithms,
#                     https://howardhinnant.github.io/date_algorithms.html
# Rechte:             gemeinfrei ("Consider these donated to the public domain.")
# Lizenz der Vorlage: keine (gemeinfrei)
# Änderungen:         Int64 mit fld/div/mod; Monatsverschiebung als mod(m + 9, 12).
"(Jahr, Monat, Tag) → Tage seit 1970-01-01."
function _civil_to_days(y::Integer, m::Integer, d::Integer)
    y = Int64(y) - (m <= 2)
    era = fld(y, 400)
    yoe = y - era * 400
    mp = mod(m + 9, 12)
    doy = div(153 * mp + 2, 5) + d - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    return era * 146097 + doe - 719468
end

"Tage seit 1970-01-01 → (Jahr, Monat, Tag)."
function _days_to_civil(z::Integer)
    z = Int64(z) + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = mp < 10 ? mp + 3 : mp - 9
    return (y + (m <= 2), m, d)
end

_date_of(z::Real) = Date(Dates.UTD(_UTD0 + Int64(floor(z))))
_day_of(d::Date) = Float64(Dates.value(d) - _UTD0)
_day_of(d::DateTime) = _day_of(Date(d))

"Datumswerte → Float64-Tage seit 1970-01-01 (NA = `SimLev.NA`)."
_days(x::Nothing) = Float64[]
_days(x::Date) = [_day_of(x)]
_days(x::DateTime) = [_day_of(x)]
_days(x::Missing) = [NA]
_days(x::Real) = [Float64(x)]
_days(x::RVector) = _days(x.values)
function _days(x::AbstractVector)
    all(v -> v === missing || v === nothing || v isa Union{Date,DateTime,Real}, x) || return _days(_to_date(x))
    out = Vector{Float64}(undef, length(x))
    for (i, v) in enumerate(x)
        out[i] = v === missing || v === nothing ? NA : v isa Union{Date,DateTime} ? _day_of(v) :
                 Float64(v)
    end
    out
end
_days(x) = _days(_to_date(x))

"Float64-Tage → Datumsvektor (NA/NaN → `missing`; Bruchteile abgerundet)."
function _as_dates(d)
    dv = d isa AbstractVector ? d : [d]
    if any(v -> v === missing || (v isa AbstractFloat && isnan(v)), dv)
        return Union{Missing,Date}[v === missing || isnan(v) ? missing : _date_of(v) for v in dv]
    end
    return Date[_date_of(v) for v in dv]
end

"`format(<Date>)` für einen Tag (NA → \"NA\")."
function _date_str(day)
    day === missing && return "NA"
    day isa Date && (day = _day_of(day))
    (day === nothing || isnan(day)) && return "NA"
    y, m, d = _days_to_civil(Int64(floor(day)))
    y < 0 && return string("-", lpad(-y, 4, '0'), "-", lpad(m, 2, '0'), "-", lpad(d, 2, '0'))
    y < 1000 && return string(y, "-", lpad(m, 2, '0'), "-", lpad(d, 2, '0'))
    return string(lpad(y, 4, '0'), "-", lpad(m, 2, '0'), "-", lpad(d, 2, '0'))
end

"`as.Date(s, format = \"%Y-%m-%d\")` (bzw. `/`) für einen Text; NA = `SimLev.NA` (core/slc_rbase_date.c)."
function _strptime_ymd(s, sep::Char = '-')
    (s === nothing || s === missing) && return NA
    z = SimLev._rb_strptime_ymd(s, sep)
    return z === nothing ? NA : Float64(z)
end

"`as.Date(<character>)` mit `tryFormats` (Format nach dem ersten Wert); `nothing`, wenn keines passt."
function _as_date_chr(strs)
    s = [v === missing || v === nothing ? nothing : String(v) for v in strs]
    i1 = findfirst(!isnothing, s)
    i1 === nothing && return fill(NA, length(s))
    for sep in ('-', '/')
        if !isnan(_strptime_ymd(s[i1], sep))
            return Float64[_strptime_ymd(v, sep) for v in s]
        end
    end
    return nothing
end

"`as.Date(names(x), optional = TRUE)` → Float64-Tage (NA bei Fehlschlag)."
function _names_as_dates_optional(nms)
    r = _as_date_chr(nms)
    r === nothing ? fill(NA, length(nms)) : r
end

const _RX4 = r"^[0-9]{4}[-/]"
_trimws(s) = s === nothing ? nothing : String(strip(s, [' ', '\t', '\r', '\n']))

function _todate_numeric_error(what, x1)
    error(_sprintf("%s: Datum ist numerisch (z. B. %s); erwartet Date, POSIXct oder Text 'JJJJ-MM-TT'.",
                   what, _fmt_num(x1)))
end

"""
    _to_date(x, what = "date"; strict = true)

Datumsangaben in Date umwandeln (R: `.to_date`): `Date`/`DateTime`
(Kalendertag), Text nur "JJJJ-MM-TT" und "JJJJ/MM/TT" mit vierstelliger
Jahreszahl; numerische Werte werden abgelehnt. Mit `strict = true` Fehler für
nicht lesbare Werte, sonst NA. Liefert immer einen Vektor (`Vector{Date}`,
mit NA `Vector{Union{Missing,Date}}`).
"""
function _to_date(x, what = "date"; strict::Bool = true)
    x === nothing && return Date[]
    x isa RVector && (x = x.values)
    x isa Union{Date,DateTime,AbstractString,Real,Missing} && (x = [x])
    x isa Tuple && (x = collect(x))
    x isa AbstractVector || error("$what: nicht lesbares Datum ($(typeof(x)))")
    T = nonmissingtype(eltype(x))
    if T <: Date
        return any(ismissing, x) ? Union{Missing,Date}[v for v in x] : Date[v for v in x]
    elseif T <: DateTime || T <: Union{Date,DateTime}
        return any(ismissing, x) ? Union{Missing,Date}[v === missing ? missing : Date(v) for v in x] :
               Date[Date(v) for v in x]
    end
    vals = [v for v in x if !_isna(v)]
    if !isempty(vals) && all(v -> v isa Union{Date,DateTime}, vals)
        return _as_dates([v === missing || v === nothing ? NA : _day_of(v) for v in x])
    end
    if (T <: Real && !(T <: Bool) && T !== Union{}) || (!isempty(vals) && all(_isnum, vals))
        _todate_numeric_error(what, isempty(x) ? missing : (x[1] === nothing ? missing : x[1]))
    end
    s = Union{Nothing,String}[_isna(v) || v isa Bool ? (v isa Bool ? (v ? "TRUE" : "FALSE") : nothing) : string(v) for v in x]
    s = [v === nothing ? nothing : _trimws(v) for v in s]
    s = [v !== nothing && v == "" ? nothing : v for v in s]
    d = Float64[_strptime_ymd(v, '-') for v in s]
    for i in eachindex(s)
        if s[i] !== nothing && isnan(d[i])
            d[i] = _strptime_ymd(s[i], '/')
        end
    end
    bad = [i for i in eachindex(s) if s[i] !== nothing && (isnan(d[i]) || !occursin(_RX4, s[i]))]
    if !isempty(bad) && strict
        error(_sprintf("%s: %d Datumswerte nicht als 'JJJJ-MM-TT' lesbar (z. B. '%s'). Andere Formate vorher umwandeln, z. B. as.Date(x, format = \"%%d.%%m.%%Y\") für '31.12.2024' oder format = \"%%d-%%m-%%Y\".",
                       what, length(bad), s[bad[1]]))
    end
    d[bad] .= NA
    return _as_dates(d)
end

"`as.Date(x)` (Date, Zeitstempel oder Text mit `tryFormats`) → Float64-Tage."
function _as_date_any(x)
    xv = x isa RVector ? x.values : x
    if xv isa AbstractString || (xv isa AbstractVector && !isempty(xv) &&
                                 all(v -> v isa AbstractString || _isna(v), xv) && any(v -> v isa AbstractString, xv))
        arr = xv isa AbstractString ? [xv] : [_isna(v) ? nothing : v for v in xv]
        r = _as_date_chr(arr)
        r === nothing && error("character string is not in a standard unambiguous format")
        return r
    end
    return _days(_to_date(x; strict = false))
end

"""
    _add_months(x, k)

Datum plus `k` Kalendermonate, auf das Monatsende begrenzt (R:
`.add_months`); 31.01. + 1 Monat = 28.02. bzw. 29.02. Vektorisiert über `x`
und `k` (Recycling wie R). Liefert einen Datumsvektor.
"""
function _add_months(x, k)
    dx = _as_date_any(x)
    kk = Float64[Float64(v) for v in (k isa AbstractVector ? k : [k])]
    n = (isempty(dx) || isempty(kk)) ? 0 : max(length(dx), length(kk))
    n == 0 && return Date[]
    out = Vector{Float64}(undef, n)
    for i in 1:n
        a = dx[mod1(i, length(dx))]; b = kk[mod1(i, length(kk))]
        if isnan(a) || isnan(b)
            out[i] = NA; continue
        end
        y, mo, md = _days_to_civil(Int64(floor(a)))
        m = (mo - 1) + Int64(trunc(b))
        y2 = y + fld(m, 12); mo2 = mod(m, 12)
        first = _civil_to_days(y2, mo2 + 1, 1)
        nxt = _civil_to_days(y2 + div(mo2 + 1, 12), mod(mo2 + 1, 12) + 1, 1)
        out[i] = Float64(first + min(md, nxt - first) - 1)
    end
    return _as_dates(out)
end

# ── Spaltentypen (R-Semantik) ───────────────────────────────────────────────

_colvec(v::RVector) = v.values
_colvec(v::AbstractVector) = v
_colvec(v) = [v]

"`is.numeric()` für eine Spalte (ganze/reelle Zahlen, nicht logisch/Datum/Text)."
function _is_numeric_col(v)
    v = _colvec(v)
    T = nonmissingtype(eltype(v))
    T === Union{} && return false
    T <: Bool && return false
    T <: Real && return true
    T <: Union{AbstractString,Date,DateTime} && return false
    vals = [e for e in v if !_isna(e)]
    return !isempty(vals) && all(_isnum, vals)
end

"`is.character(v) || is.factor(v)`."
function _is_chr_col(v)
    v = _colvec(v)
    T = nonmissingtype(eltype(v))
    T === Union{} && return false
    T <: AbstractString && return true
    T <: Union{Real,Date,DateTime} && return false
    vals = [e for e in v if !_isna(e)]
    return !isempty(vals) && all(e -> e isa AbstractString, vals)
end

"`inherits(v, c(\"Date\", \"POSIXt\"))`."
function _is_date_col(v)
    v = _colvec(v)
    T = nonmissingtype(eltype(v))
    T === Union{} && return false
    T <: Union{Date,DateTime} && return true
    vals = [e for e in v if !_isna(e)]
    return !isempty(vals) && all(e -> e isa Union{Date,DateTime}, vals)
end

function _parse_num(s::AbstractString)
    t = _trimws(String(s))
    (t == "" || t == "NA") && return (NA, false)
    r = tryparse(Float64, t)
    r === nothing && return (NA, true)
    return (r, false)
end

"`as.numeric(v)` (Text → Zahl mit Warnung bei NA durch Umwandlung)."
function _as_numeric(v)
    v = _colvec(v)
    eltype(v) === Float64 && return copy(v)
    out = Vector{Float64}(undef, length(v))
    coerced = false
    for (i, e) in enumerate(v)
        if e === missing || e === nothing
            out[i] = NA
        elseif e isa Real
            out[i] = Float64(e)
        elseif e isa Union{Date,DateTime}
            out[i] = _day_of(e)
        elseif e isa AbstractString
            r, c = _parse_num(e)
            out[i] = r; coerced |= c
        else
            out[i] = NA; coerced = true
        end
    end
    coerced && @warn "NAs introduced by coercion"
    return out
end

"Spalten-Paare einer Tabelle (RFrame, NamedTuple, Dict) oder `nothing`."
function _as_frame(x)
    x isa RFrame && return x
    x isa AbstractVector{<:Pair} && return SimLev.as_rframe(x)
    if x isa NamedTuple
        isempty(x) && return RFrame()
        all(v -> v isa AbstractVector, values(x)) || return x
        return RFrame((String(k) => v for (k, v) in pairs(x))...)
    end
    if x isa AbstractDict && !(x isa RList) && !isempty(x) && all(v -> v isa AbstractVector, values(x))
        return RFrame((String(string(k)) => v for (k, v) in x)...)
    end
    return x
end

_names(x::RFrame) = names(x)
_names(x::NamedTuple) = String[String(k) for k in keys(x)]
_names(x::AbstractDict) = String[String(string(k)) for k in keys(x)]
_names(x) = String[]

_nrow(x::RFrame) = nrow(x)
_nrow(x) = (f = _as_frame(x); f isa RFrame ? nrow(f) : length(x))

_col(x::RFrame, k) = x[String(k)]
_col(x, k) = _as_frame(x)[String(k)]

const _RX_NUMTXT = r"^[-+]?[0-9][0-9.,' ]*([eE][-+]?[0-9]+)?$"
const _RX_DOTDATE = r"^[0-9]{1,2}[.][0-9]{1,2}[.][0-9]{2,4}$"

_chr_vals(v) = [e === missing || e === nothing ? nothing : _trimws(string(e)) for e in _colvec(v)]

"""
    _num_text_cols(x, exclude = String[])

Text- oder Faktorspalten, die wie Zahlen aussehen (z. B. Kurse mit
Dezimalkomma). R: `.num_text_cols`; liefert die Spaltennamen.
"""
function _num_text_cols(x, exclude = String[])
    exclude isa AbstractString && (exclude = [exclude])
    x = _as_frame(x)
    cand = [k for k in _names(x) if _is_chr_col(_col(x, k)) && !(k in exclude)]
    out = String[]
    for k in cand
        s = [e for e in _chr_vals(_col(x, k)) if e !== nothing && e != ""]
        isempty(s) && continue
        hit = Float64[(occursin(_RX_NUMTXT, e) && !occursin(_RX_DOTDATE, e)) ? 1.0 : 0.0 for e in s]
        SimLev.r_mean(hit) >= 0.9 && push!(out, k)
    end
    return out
end

"Fehlermeldung für Zahlen als Text (R: `.num_text_stop`)."
function _num_text_stop(x, cols, name)
    cols isa AbstractString && (cols = [cols])
    x = _as_frame(x)
    ex = [e for e in _chr_vals(_col(x, cols[1])) if e !== nothing && e != ""]
    ex = vcat([e for e in ex if occursin(',', e)], ex)
    ex0 = isempty(ex) ? "NA" : ex[1]
    error(_sprintf("'%s': Spalte %s enthält Zahlen als Text bzw. Faktor (z. B. '%s'), vermutlich mit Dezimalkomma. Vorher umwandeln, z. B. mit read.csv2() oder as.numeric(sub(\",\", \".\", x, fixed = TRUE)).",
                   name, join(("'" * c * "'" for c in cols), ", "), ex0))
end

"Benannter numerischer Vektor (`RVector` mit Namen, Paare oder Dict aus Zahlen)?"
_is_named_numeric(x) = false
_is_named_numeric(x::RVector) = x.names !== nothing && _is_numeric_col(x.values)
_is_named_numeric(x::AbstractVector{<:Pair}) = !isempty(x) && all(p -> _isnum(p.second) || p.second === missing, x)
_is_named_numeric(x::AbstractDict) = !(x isa RList) && !isempty(x) && all(v -> _isnum(v) || v === missing, values(x))
_is_named_numeric(x::Pair) = _isnum(x.second)

"(Namen, Werte) eines benannten numerischen Vektors."
_named_parts(x::RVector) = (copy(x.names), _as_numeric(x.values))
_named_parts(x::AbstractVector{<:Pair}) = (String[string(p.first) for p in x], _as_numeric([p.second for p in x]))
_named_parts(x::AbstractDict) = (String[string(k) for k in keys(x)], _as_numeric(collect(values(x))))
_named_parts(x::Pair) = ([string(x.first)], _as_numeric([x.second]))

function _duplicated(v; from_last::Bool = false)
    out = falses(length(v))
    seen = Set{Any}()
    idx = from_last ? (length(v):-1:1) : (1:length(v))
    for i in idx
        key = v[i] isa AbstractFloat && isnan(v[i]) ? :NA : v[i]
        if key in seen
            out[i] = true
        else
            push!(seen, key)
        end
    end
    out
end

_stable_order(x) = sortperm(x; alg = Base.Sort.DEFAULT_STABLE)

"""
    _dp_frame(x, name)

Eine Quelle in `RFrame(date, ...)` mit numerischen Spalten wandeln (R:
`.dp_frame`): Datumsspalte suchen, Zeilen ohne Datum entfernen, nach Datum
sortieren, bei doppeltem Datum den letzten Wert behalten. Bei genau einer
numerischen Spalte heißt sie `name`.
"""
function _dp_frame(x, name)
    if _is_named_numeric(x)
        nm, vals = _named_parts(x)
        x = RFrame("date" => _to_date(nm, "'$(name)' (Namen)"), "value" => vals)
    end
    x = _as_frame(x)
    x isa RFrame || error("'$(name)' muss ein data.frame mit Spalte 'date' sein.")
    nms = _names(x)
    dcol = if "date" in nms
        "date"
    else
        dc = [k for k in nms if _is_date_col(_col(x, k))]
        isempty(dc) ? (isempty(nms) ? nothing : nms[1]) : dc[1]
    end
    dcol === nothing && error("'$(name)': keine numerische Spalte.")
    _is_numeric_col(_col(x, dcol)) &&
        error("'$(name)': keine Datumsspalte; Spalte '$(dcol)' ist numerisch (z. B. Zeilennummern aus write.csv). Spalte 'date' (Date oder 'JJJJ-MM-TT') angeben.")
    num = [k for k in nms if _is_numeric_col(_col(x, k)) && k != dcol]
    nr = nrow(x)
    rn = [k for k in num if k == "X" && nr > 0 && (v = _as_numeric(_col(x, k)); all(i -> v[i] == i, 1:nr))]
    if !isempty(rn) && length(num) > 1
        message("Hinweis: '$(name)': Spalte 'X' (Zeilennummern, z. B. aus write.csv) wird ignoriert.")
        num = [k for k in num if !(k in rn)]
    end
    txt = _num_text_cols(x, [dcol])
    isempty(txt) || _num_text_stop(x, txt, name)
    isempty(num) && error("'$(name)': keine numerische Spalte.")
    days = _days(_to_date(_col(x, dcol), "'$(name)': Spalte '$(dcol)'"))
    cols = [_as_numeric(_col(x, k)) for k in num]
    cn = length(num) == 1 ? [String(name)] : num
    keep = findall(!isnan, days)
    days = days[keep]; cols = [c[keep] for c in cols]
    o = _stable_order(days)
    days = days[o]; cols = [c[o] for c in cols]
    dup = _duplicated(days; from_last = true)
    if any(dup)
        message("Hinweis: '$(name)' hat $(count(dup)) doppelte Daten; der letzte Wert je Datum wird verwendet.")
        days = days[.!dup]; cols = [c[.!dup] for c in cols]
    end
    return RFrame(vcat(["date"], cn), AbstractVector[_as_dates(days), cols...]; nrow = length(days))
end

# ═══════════════════════════════════════════════════════════════════════════
# series_align
# ═══════════════════════════════════════════════════════════════════════════

# Benannte Quellen: Schlüsselwörter oder Paare "Name" => Quelle (für Namen,
# die keine Julia-Bezeichner sind); `nothing`, wenn eine Quelle unbenannt ist.
function _named_sources(args, kw)
    out = Tuple{String,Any}[]
    for a in args
        a isa Pair || return nothing
        push!(out, (String(string(a.first)), a.second))
    end
    for (k, v) in kw
        push!(out, (String(k), v))
    end
    return out
end

function _match_days(a, b)
    pos = Dict{Float64,Int}()
    for (i, v) in enumerate(b)
        haskey(pos, v) || (pos[v] = i)
    end
    return [get(pos, v, 0) for v in a]
end

"""
    series_align(; calendar = "day", range = "common", fill = "locf",
                 max_gap = Inf, start = nothing, end_ = nothing, sources...)
    series_align("name" => quelle, ...; kwargs...)

Datenquellen nach Datum zusammenführen.

Einstieg für eigene Daten: Führt Kursreihen aus verschiedenen Quellen (z. B. mit `utils::read.csv()`
eingelesene Dateien) auf einen gemeinsamen Kalender zusammen und liefert einen Tabelle (RFrame) mit Spalte
`date` (Klasse Date) und je einer numerischen Spalte pro Reihe. Erwartet werden Niveaus (Kurse, Indexstände),
keine Renditen: Lücken werden mit dem letzten Kurs (LOCF) oder linear gefüllt, was nur für Niveaus sinnvoll
ist. Renditereihen vorher in einen Index umrechnen, z. B. `100 * cumprod(1 + r)`.

# Argumente
- `calendar`: Zeilen des Ergebnisses: `"day"` (Standard; alle Kalendertage), `"union"` (alle Daten, an denen
  mindestens eine Quelle notiert) oder `"intersect"` (nur Daten, an denen alle Quellen notieren).
- `range`: Zeitraum: `"common"` (Standard; vom spätesten Start bis zum frühesten Ende aller Quellen) oder
  `"all"` (gesamter Zeitraum; außerhalb der Laufzeit einer Reihe NA).
- `fill`: Füllung fehlender Werte: `"locf"` (Standard; letzter Wert), `"linear"` (lineare Interpolation) oder
  `"none"`. Gefüllt wird nur innerhalb der Laufzeit einer Reihe (erstes bis letztes vorhandenes Datum).
- `max_gap`: Höchste Lücke in Kalendertagen zwischen zwei vorhandenen Werten, die noch gefüllt wird; längere
  Lücken bleiben NA (mit Hinweis). Standard `Inf` = alle Lücken füllen.
- `start`: Optional Beginn und Ende des Zeitraums (Date oder `"JJJJ-MM-TT"`); `nothing` = durch `range`
  bestimmt.
- `start`: Optional Beginn und Ende des Zeitraums (Date oder `"JJJJ-MM-TT"`); `nothing` = durch `range`
  bestimmt.
- `sources`: Benannte Quellen als Schlüsselwörter oder Paare `"name" => quelle`.
- `kwargs...`: Benannte Quellen (Name = Spaltenname im Ergebnis): `data.frame(date, value)` mit genau einer
  numerischen Spalte (sie wird nach dem Argument benannt), `data.frame(date, A, B, ...)` mit mehreren
  numerischen Spalten (Spaltennamen bleiben erhalten und müssen über alle Quellen eindeutig sein) oder
  benannte numerische Vektoren mit Datumsnamen (`["2024-01-02" = 100, ...]`).

# Rückgabe
Tabelle (RFrame) mit Spalte `date` (Klasse Date) und je einer numerischen Spalte pro Reihe, mit Attribut
`filled` (logische Matrix Zeilen x Reihen, true = gefüllter Wert).

# Details
Mit `calendar = "day"` (Standard) entsteht ein lückenloser Kalendertags-Kalender: Wochenenden und Feiertage
werden gefüllt, und unterschiedliche Börsenkalender (z. B. US- und EU-Feiertage) werden ohne Zeilenverlust
vereinheitlicht. Das Ergebnis passt direkt in `simulation()`, `series_check()`, `result_analysis()` (je Reihe
als `data.frame(date, value)`) und die Gewichts-Erzeuger wie `tactical_rules()`. `simulation()`,
`tactical_simulation()` und `result_analysis()` werten das Attribut `filled` aus: Ein Tag, an dem keine Anlage
der Strategie einen echten Kurs hat, gilt als aufgefüllt (kein Handel, nicht in den Risikokennzahlen) - genau
wie Kalendertage, die `simulation()` bei Handelstagsdaten selbst per LOCF auffüllt.

Je Quelle gilt: Fehlt eine Spalte `date`, wird die erste Spalte der Klasse Date bzw. POSIXct als Datum
verwendet, sonst die erste Spalte (eine numerische erste Spalte, etwa Zeilennummern `X` aus
`utils::write.csv()`, wird als Datum abgelehnt; eine Spalte `X` mit den Zeilennummern 1, 2, ... wird neben
weiteren Wertspalten mit Hinweis ignoriert). Zeichenketten müssen das Format `"JJJJ-MM-TT"` haben; andere
Formate wie `"31.12.2024"` vorher mit dem Argument `format` von `as.Date()` umwandeln, siehe Beispiel (nicht
lesbare Daten und Texte ohne vierstellige Jahreszahl am Anfang sind ein Fehler). POSIXct-Zeitstempel zählen
mit dem Kalendertag in ihrer eigenen Zeitzone. Übernommen werden nur numerische Spalten; andere Text-Spalten
fallen weg, Text- oder Faktorspalten, die wie Zahlen aussehen (etwa Kurse mit Dezimalkomma, als Text
eingelesen), sind ein Fehler. Zeilen ohne Datum werden entfernt, die Zeilen nach Datum sortiert, bei doppeltem
Datum gilt der letzte Wert (mit Hinweis).

# Beispiel
```julia
using SimLev, Dates
a = RFrame("date" => Date(2024, 1, 1) .+ Day.([0, 1, 2, 5]), "value" => [100.0, 101, 102, 103])
b = RFrame("date" => Date(2024, 1, 2) .+ Day.(0:5), "value" => 50.0 .+ (0:5))
println(series_align(us = a, eu = b))
```
"""
function series_align(args...; calendar = ("day", "union", "intersect"), range = ("common", "all"),
                      fill = ("locf", "linear", "none"), max_gap = Inf, start = nothing, end_ = nothing,
                      sources...)
    calendar = _match_arg(calendar, ("day", "union", "intersect"))
    rng = _match_arg(range, ("common", "all"))
    fill = _match_arg(fill, ("locf", "linear", "none"))
    src = _named_sources(args, sources)
    (src === nothing || isempty(src) || any(p -> p[1] == "", src)) &&
        error("series_align: Quellen benennen, z. B. series_align(us = df1, eu = df2).")
    fr = [(k, _dp_frame(v, k)) for (k, v) in src]
    fdays = [_days(f["date"]) for (_, f) in fr]
    first_ = [isempty(d) ? NA : d[1] for d in fdays]
    last_ = [isempty(d) ? NA : d[end] for d in fdays]
    any(isnan, first_) && error("missing value where TRUE/FALSE needed")
    lo = rng == "common" ? maximum(first_) : minimum(first_)
    hi = rng == "common" ? minimum(last_) : maximum(last_)
    if start !== nothing
        s0 = _days(_to_date(start, "series_align: start"))
        lo = any(isnan, s0) ? NA : maximum(vcat([lo], s0))
    end
    if end_ !== nothing
        e0 = _days(_to_date(end_, "series_align: end"))
        hi = any(isnan, e0) ? NA : minimum(vcat([hi], e0))
    end
    (isnan(lo) || isnan(hi)) && error("missing value where TRUE/FALSE needed")
    lo > hi && error("series_align: Die Quellen überlappen sich nicht.")
    dates = if calendar == "day"
        [lo + i for i in 0:Int(floor(hi - lo))]
    elseif calendar == "union"
        sort(unique(vcat(fdays...)))
    else
        dd = copy(fdays[1])
        for b in fdays[2:end]
            bs = Set(b)
            dd = [v for v in dd if v in bs]
        end
        dd
    end
    dates = [v for v in dates if v >= lo && v <= hi]
    onames = String["date"]
    ocols = AbstractVector[_as_dates(dates)]
    fnames = String[]
    fcols = AbstractVector[]
    for (j, (nm, f)) in enumerate(fr)
        fd = fdays[j]
        for k in names(f)
            k == "date" && continue
            k in onames && error("series_align: Spaltenname '$(k)' kommt mehrfach vor.")
            vals = f[k]
            mi = _match_days(dates, fd)
            v = Float64[m > 0 ? vals[m] : NA for m in mi]
            obs = .!isnan.(v)
            in_life = [d >= fd[1] && d <= fd[end] for d in dates]
            if fill != "none" && any(obs)
                w = SimLev.Backcast._fill_na(v, fill; keep_leading = true)
                w[.!in_life] .= NA
                if isfinite(max_gap)
                    oi = findall(obs)
                    long = [i for i in 1:length(oi)-1 if dates[oi[i+1]] - dates[oi[i]] > max_gap && oi[i+1] - oi[i] > 1]
                    for i in long
                        w[oi[i]+1:oi[i+1]-1] .= NA
                    end
                    isempty(long) || message("Hinweis: '$(k)': $(length(long)) Lücken > $(_sprintf_g(max_gap)) Tage bleiben NA.")
                end
                v = w
            end
            push!(onames, k); push!(ocols, v)
            push!(fnames, k); push!(fcols, Bool[!obs[i] && !isnan(v[i]) for i in eachindex(v)])
        end
    end
    df = RFrame(onames, ocols; nrow = length(dates))
    attrs(df)["filled"] = RFrame(fnames, fcols; nrow = length(dates))
    return df
end

# ═══════════════════════════════════════════════════════════════════════════
# series_check
# ═══════════════════════════════════════════════════════════════════════════

function _which_min(a)
    best = 0; bv = Inf
    for (i, v) in enumerate(a)
        if !isnan(v) && (best == 0 || v < bv)
            best, bv = i, v
        end
    end
    return best
end
function _which_max(a)
    best = 0; bv = -Inf
    for (i, v) in enumerate(a)
        if !isnan(v) && (best == 0 || v > bv)
            best, bv = i, v
        end
    end
    return best
end

_rsign(x) = isnan(x) ? x : (x > 0 ? 1.0 : x < 0 ? -1.0 : 0.0)

function _rle(b::AbstractVector{Bool})
    lengths = Int[]; values = Bool[]
    for v in b
        if !isempty(values) && values[end] == v
            lengths[end] += 1
        else
            push!(values, v); push!(lengths, 1)
        end
    end
    return lengths, values
end

"""
    series_check(data; columns = nothing, jump = 20, stale = 10, revert = 0.8)

Kursreihen prüfen.

Erstellt einen Prüfbericht für eigene Kursreihen, bevor sie in `simulation()` oder die Analysefunktionen
gehen. Erwartet wird ein Tabelle (RFrame) mit Spalte `date` und Kursspalten (Niveaus, keine Renditen), z. B.
aus `series_align()`. Gemeldet werden: fehlende oder nicht lesbare Daten (z. B. Leerzeile am Dateiende),
doppelte oder unsortierte Daten, Kalenderlücken über 5 Tage, fehlende Werte innerhalb der Laufzeit, Sprünge,
wahrscheinliche Splits (Sprung nahe einem ganzzahligen Verhältnis 2:1 bis 10:1 bzw. 1:2 bis 1:10, ohne
Rücklauf), Spikes (Sprung mit sofortigem Rücklauf, typischer Datenfehler), Werte <= 0 und stehende Kurse. Die
Funktion ändert die Daten nicht.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Date oder `"JJJJ-MM-TT"`) und Kursspalten.
- `columns`: Zeichenvektor der zu prüfenden Spalten (Standard `nothing` = alle numerischen Spalten außer
  `date`).
- `jump`: Sprungschwelle in Prozent (20 = 20 %): Veränderung zum vorigen vorhandenen Wert, ab der ein Sprung
  gemeldet wird.
- `stale`: Mindestlänge in Zeilen einer Folge unveränderter Werte, die als stehender Kurs gemeldet wird (bei
  Kalendertagsdaten sind 2-4 Zeilen über Wochenenden und Feiertage normal).
- `revert`: Rücklauf am Folgetag als Anteil des Sprungs (0.8 = 80 %, gemessen in Log-Renditen), ab dem ein
  Sprung als Spike gilt.

# Rückgabe
Objekt der Klasse `SimLevDataCheck`, eine Liste mit

- summary: Tabelle (RFrame) je Spalte: `column`, `start`, `end` (erstes/letztes Datum mit Wert), `n` (Werte),
  `missing` (NA innerhalb der Laufzeit), `jumps` (alle Sprünge über `jump`, einschließlich Spikes und Splits),
  `spikes`, `splits`, `stale_max` (längste Folge gleicher Werte in Zeilen), `nonpositive` (Anzahl Werte <= 0).
- issues: Tabelle (RFrame) je Fund: `column`, `date`, `type` (Art des Funds), `value` (Kurs) und `info` (bei
  Sprüngen die Veränderung in Prozent, bei Kalenderlücken die Tage, bei stehenden Kursen die Zeilen).
- settings: benannter Vektor `jump`, `stale`, `revert`.

`print()` zeigt die Zusammenfassung und die ersten `max_issues` (Standard 25) Funde.

# Details
Sprünge werden zwischen aufeinanderfolgenden vorhandenen Werten (NA übersprungen) gemessen, also je Zeile,
nicht je Kalendertag, und nur zwischen zwei positiven Werten; Werte <= 0 (z. B. eine Zinsreihe mit negativen
Sätzen) erscheinen nur als "Wert <= 0".

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 400
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["A"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["A"][300:end] ./= 2               # Split 2:1
println(series_check(d)["summary"])
```
"""
function series_check(data; columns = nothing, jump = 20, stale = 10, revert = 0.8)
    data = SimLev.as_rframe(data)
    data = _as_frame(data)
    (data isa RFrame && "date" in _names(data)) || error("series_check: data.frame mit Spalte 'date' erwartet.")
    d = _days(_to_date(_col(data, "date"), "series_check: date"; strict = false))
    if columns === nothing
        columns = [k for k in _names(data) if _is_numeric_col(_col(data, k)) && k != "date"]
    elseif columns isa AbstractString
        columns = [columns]
    end
    iss_col = String[]; iss_date = Float64[]; iss_type = String[]; iss_val = Float64[]; iss_info = Float64[]
    add(col, i, type_, value, info = NA) = (push!(iss_col, col); push!(iss_date, d[i]); push!(iss_type, type_);
                                           push!(iss_val, value); push!(iss_info, info))
    for i in first(findall(isnan, d), 20)
        add("date", i, "Datum fehlt oder nicht lesbar (Zeile $(i))", NA)
    end
    okd = findall(!isnan, d)
    dd = d[okd]
    dupl = _duplicated(dd)
    if any(dupl)
        for i in okd[dupl]
            add("date", i, "doppeltes Datum", NA)
        end
    end
    dg = [dd[i+1] - dd[i] for i in 1:length(dd)-1]
    if any(<(0), dg)
        add("date", okd[findfirst(<(0), dg) + 1], "Datum nicht sortiert", NA)
    end
    for i in findall(>(5), dg)
        add("date", okd[i+1], "Kalenderlücke (Tage)", dg[i])
    end
    cand = vcat(Float64[2, 3, 4, 5, 6, 7, 8, 9, 10], [1 / k for k in 2:10])
    srows = NamedTuple[]
    for k in columns
        v = _as_numeric(_col(data, k))
        ok = findall(!isnan, v)
        if isempty(ok)
            push!(srows, (column = k, start = NA, end_ = NA, n = 0, miss = length(v), jumps = 0, spikes = 0,
                          splits = 0, stale_max = 0, nonpositive = 0))
            continue
        end
        miss = count(isnan, v[ok[1]:ok[end]])
        npos = findall(e -> e <= 0, v)
        for i in first(npos, 20)
            add(k, i, "Wert <= 0", v[i])
        end
        x = v[ok]
        m = length(x)
        r = Float64[x[j+1] / x[j] - 1 for j in 1:m-1]
        for j in 1:m-1
            (x[j+1] > 0 && x[j] > 0) || (r[j] = NA)
        end
        ri = ok[2:end]
        J = [j for j in eachindex(r) if isfinite(r[j]) && abs(r[j]) > jump / 100]
        n_spike = 0; n_split = 0; skip = Int[]
        for j in J
            j in skip && continue
            nxt = j < length(r) ? r[j+1] : NA
            ratio = x[j] / x[j+1]
            near = cand[_which_min([abs(SimLev.RLibm.log(ratio / c)) for c in cand])]
            rj = r[j]
            if !isnan(nxt) && _rsign(nxt) != _rsign(rj) &&
               abs(SimLev.RLibm.log1p(nxt)) >= revert * abs(SimLev.RLibm.log1p(rj))
                n_spike += 1; push!(skip, j + 1)
                add(k, ri[j], "Spike (Rücklauf am Folgetag)", v[ri[j]], 100 * rj)
            elseif abs(SimLev.RLibm.log(ratio / near)) < 0.02
                n_split += 1
                lab = near >= 1 ? _sprintf("%g:1", near) : _sprintf("1:%g", 1 / near)
                add(k, ri[j], "möglicher Split (Verhältnis $(lab))", v[ri[j]], 100 * rj)
            else
                add(k, ri[j], "Sprung", v[ri[j]], 100 * rj)
            end
        end
        lengths, values = _rle(Bool[x[j+1] - x[j] == 0 for j in 1:m-1])
        runs = [L for (L, b) in zip(lengths, values) if b]
        smax = isempty(runs) ? 1 : maximum(runs) + 1
        if !isempty(runs)
            cs = cumsum(lengths)
            ends = [cs[i] for i in eachindex(values) if values[i]]
            long = [q for q in eachindex(runs) if runs[q] + 1 >= stale]
            for q in first(long, 20)
                add(k, ok[ends[q] - runs[q] + 1], "stehender Kurs (Zeilen)", x[ends[q]], Float64(runs[q] + 1))
            end
        end
        jumps = count(j -> !(j in skip), J)
        push!(srows, (column = k, start = d[ok[1]], end_ = d[ok[end]], n = length(ok), miss = miss, jumps = jumps,
                      spikes = n_spike, splits = n_split, stale_max = smax, nonpositive = length(npos)))
    end
    S = if isempty(srows)
        nothing
    else
        st = Float64[r.start for r in srows]; en = Float64[r.end_ for r in srows]
        stc, enc = if srows[1].n == 0
            all(isnan, st) ? (fill(missing, length(st)), fill(missing, length(en))) : (st, en)
        else
            (_as_dates(st), _as_dates(en))
        end
        RFrame("column" => String[r.column for r in srows], "start" => stc, "end" => enc,
               (c => Int[getfield(r, f) for r in srows] for (c, f) in (("n", :n), ("missing", :miss), ("jumps", :jumps), ("spikes", :spikes),
                                                                  ("splits", :splits), ("stale_max", :stale_max), ("nonpositive", :nonpositive)))...)
    end
    I = RFrame("column" => iss_col, "date" => _as_dates(iss_date), "type" => iss_type, "value" => iss_val,
               "info" => iss_info; nrow = length(iss_col))
    res = RList(; class = ["SimLevDataCheck"])
    res["summary"] = S
    res["issues"] = I
    res["settings"] = RVector(Float64[jump, stale, revert]; names = ["jump", "stale", "revert"])
    return res
end

"Druckausgabe von `SimLevDataCheck` (wie `print.SimLevDataCheck(x, max_issues = 25)`)."
function format_SimLevDataCheck(x; max_issues = 25)
    F = SimLev.RFmt
    io = IOBuffer()
    print(io, "SimLev-Datenprüfung\n\n")
    S = x["summary"]
    if S === nothing
        print(io, "NULL\n")
    else
        print(io, _chomp(F.print_data_frame(S; row_names = false)), "\n")
    end
    I = x["issues"]
    n = nrow(I)
    if n == 0
        print(io, "\nKeine Auffälligkeiten.\n")
    else
        print(io, "\n$(n) Auffälligkeiten", n > max_issues ? " (erste $(max_issues))" : "", ":\n")
        y = rows(I, 1:min(n, max_issues))
        info = y["info"]
        fi = F.formatC(info; digits = 2, format = "f")
        fi isa AbstractString && (fi = [fi])
        y["info"] = String[isnan(info[i]) ? "" : String(fi[i]) for i in eachindex(info)]
        print(io, _chomp(F.print_data_frame(y; row_names = false)), "\n")
    end
    return _chomp(String(take!(io)))
end
_chomp(s) = (s = String(s); endswith(s, "\n") ? s[1:prevind(s, end)] : s)

"Registrierte Druckmethode (R `print.SimLevDataCheck(x, max_issues = 25L, ...)`; weitere Schlüsselwörter ignoriert wie R)."
function _print_datacheck(io::IO, x; max_issues = 25, kw...)
    print(io, format_SimLevDataCheck(x; max_issues = max_issues))
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# series_align_macro
# ═══════════════════════════════════════════════════════════════════════════

"""
    series_align_macro(data, macro_; name = "macro", lag = 0, lag_unit = "day",
                transform = "level", periods = nothing)

Makroreihen mit Veröffentlichungsverzug auf den Tageskalender legen.

Ordnet niederfrequente Reihen (Inflation, Leitzins, Zinsstruktur, Arbeitslosigkeit, ...) einem Tageskalender
zu, und zwar so, wie sie zum jeweiligen Tag bekannt waren: Ein Wert für den Referenzmonat Januar, der Mitte
Februar veröffentlicht wird, gilt erst ab Mitte Februar. Ohne diesen Verzug enthalten bedingte Analysen und
Signale Informationen aus der Zukunft.

# Argumente
- `data`: Datumsvektor oder Tabelle (RFrame) mit Spalte `date` (z. B. aus `series_align()`).
- `macro_`: `data.frame(date, value)` (es zählt die erste numerische Spalte; fehlt `date`, gilt die erste
  Spalte als Datum) oder benannter numerischer Vektor mit Datumsnamen. `date` ist der Referenzzeitpunkt (z. B.
  Monatsanfang des Referenzmonats).
- `name`: Name der neuen Spalte, wenn `data` ein Tabelle (RFrame) ist (Standard `"macro"`).
- `lag`: Veröffentlichungsverzug als Zahl in Einheiten von `lag_unit` (Standard 0 = ab dem Referenzdatum
  bekannt).
- `lag_unit`: Einheit von `lag`: `"day"` (Standard; Kalendertage) oder `"month"` (Kalendermonate; der Tag wird
  auf das Monatsende begrenzt, z. B. 31.01. + 1 Monat = 29.02. bzw. 28.02.).
- `transform`: `"level"` (Standard; Wert unverändert), `"yoy"` (Veränderung gegen Vorjahr in Prozent, 2 = 2
  %), `"mom"` (gegen Vorperiode in Prozent), `"diff"` (absolute Differenz zur Vorperiode, z. B. Zinsänderung
  in Prozentpunkten) oder `"yoy_diff"` (absolute Differenz zum Vorjahr).
- `periods`: Perioden je Jahr der Makroreihe, bestimmt den Abstand für `"yoy"` und `"yoy_diff"`. Standard
  `nothing` = aus dem mittleren Datumsabstand geschätzt (1, 4, 12, 52 oder 252, z. B. 12 für Monatsdaten). Bei
  1, 4 und 12 wird der Bezugswert per Datum gesucht (Vorjahr bzw. Vormonat/-quartal desselben Kalenders; fehlt
  er, etwa bei einem fehlenden Monat, ist das Ergebnis NA), sonst per Zeile (`periods` bzw. eine Zeile
  zurück).

# Rückgabe
Bei Datumsvektor ein numerischer Vektor gleicher Länge, sonst `data` mit neuer Spalte `name` (NA vor dem
ersten bekannten Wert).

# Details
Ein Wert gilt ab `Referenzdatum + lag` bis zum nächsten verfügbaren Wert (Stufenfunktion); davor ist das
Ergebnis NA. Die Umrechnung (`transform`) erfolgt auf der Makroreihe selbst, vor der Zuordnung. Das Ergebnis
eignet sich z. B. für Bedingungen in `tactical_rules()` (`"inflation > 3"`) oder als Preisindex für
`series_deflate()`.

# Beispiel
```julia
using SimLev, Dates
cpi = RFrame("date" => [Date(2020, 1, 1) + Month(k) for k in 0:35], "value" => 100 .* 1.002 .^ (0:35))
d = RFrame("date" => Date(2021, 1, 1) .+ Day.(0:399))
d = series_align_macro(d, cpi; name = "inflation", lag = 45, transform = "yoy")
println(d["inflation"][end])
```
"""
function series_align_macro(data, macro_; name = "macro", lag = 0, lag_unit = ("day", "month"),
                     transform = ("level", "yoy", "mom", "diff", "yoy_diff"), periods = nothing)
    data = SimLev.as_rframe(data)
    macro_ = SimLev.as_rframe(macro_)
    lag_unit = _match_arg(lag_unit, ("day", "month"))
    transform = _match_arg(transform, ("level", "yoy", "mom", "diff", "yoy_diff"))
    m = _dp_frame(macro_, "macro")
    v = m[names(m)[2]]
    md = _days(m["date"])
    if periods === nothing
        sp = SimLev.RStats.median(Float64[md[i+1] - md[i] for i in 1:length(md)-1])
        periods = sp >= 300 ? 1 : sp >= 80 ? 4 : sp >= 25 ? 12 : sp >= 6 ? 52 : 252
    end
    p = Int(trunc(Float64(periods)))
    k = length(v)
    ym = [_days_to_civil(Int64(z)) for z in md]
    yy = [t[1] for t in ym]; mon = [t[2] - 1 for t in ym]
    key = p == 1 ? yy : p == 4 ? [4 * yy[i] + div(mon[i], 3) for i in 1:k] :
          p == 12 ? [12 * yy[i] + mon[i] for i in 1:k] : nothing
    if key !== nothing
        pos = Dict{Int,Int}()
        for (i, e) in enumerate(key)
            haskey(pos, e) || (pos[e] = i)
        end
        prev = [get(pos, e - 1, 0) for e in key]
        prev_y = [get(pos, e - p, 0) for e in key]
    else
        prev = [i - 1 for i in 1:k]
        prev_y = [i > p ? i - p : 0 for i in 1:k]
    end
    shift(ix) = Float64[i > 0 ? v[i] : NA for i in ix]
    vv = transform == "level" ? copy(v) :
         transform == "yoy" ? 100 .* (v ./ shift(prev_y) .- 1) :
         transform == "mom" ? 100 .* (v ./ shift(prev) .- 1) :
         transform == "diff" ? v .- shift(prev) : v .- shift(prev_y)
    lagf = Float64(lag isa AbstractVector ? lag[1] : lag)
    avail = if lag_unit == "day" || lagf == 0
        md .+ (lag_unit == "day" ? lagf : 0.0)
    else
        _days(_add_months(_as_dates(md), lag))
    end
    df = _as_frame(data)
    is_df = df isa RFrame
    dates = _days(_to_date(is_df ? _col(df, "date") : data, "series_align_macro: data"))
    o = _stable_order(avail)
    avail = avail[o]; vv = vv[o]
    out = Vector{Float64}(undef, length(dates))
    for (i, x) in enumerate(dates)
        if isnan(x)
            out[i] = NA
        else
            j = searchsortedlast(avail, x)
            out[i] = j > 0 ? vv[j] : NA
        end
    end
    if is_df
        df = copy(df)
        df[String(name)] = out
        return df
    end
    return out
end

# ═══════════════════════════════════════════════════════════════════════════
# series_convert_currency, index_total_return, series_deflate
# ═══════════════════════════════════════════════════════════════════════════

"""
    series_convert_currency(data, columns, fx; method = "divide", suffix = nothing)

Währung umrechnen.

Rechnet Kursspalten eines Tabelle (RFrame) tageweise mit einem Wechselkurs in eine andere Währung um, z. B.
einen US-Index in USD nach EUR, bevor er in `simulation()` geht. Erwartet wird ein Tabelle (RFrame) mit Spalte
`date` und Kursniveaus (z. B. aus `series_align()`). Je Zeile wird der Kurs durch den Wechselkurs geteilt
(`"divide"`) oder mit ihm multipliziert (`"multiply"`); eine Kurssicherung wird nicht abgebildet.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` und den Kursspalten.
- `columns`: Zeichenvektor der umzurechnenden Spalten.
- `fx`: Wechselkurs als Niveau: Spaltenname in `data` (NA per LOCF gefüllt), `data.frame(date, value)`
  (Stufenfunktion: Wert gilt ab seinem Datum bis zum nächsten; vor dem ersten Datum gilt der erste Wert),
  benannter Vektor mit Datumsnamen, Vektor der Länge `nrow(data)` oder Skalar (fester Kurs). Alle Werte müssen
  positiv sein.
- `method`: `"divide"` (Standard; Wechselkurs als Fremdwährung je Zielwährung, z. B. USD-Index mit EURUSD =
  USD je EUR in EUR umrechnen) oder `"multiply"` (Wechselkurs als Zielwährung je Fremdwährung).
- `suffix`: Endung für neue Spalten (z. B. `"_eur"`); Standard `nothing` = die Spalten in `columns` werden
  überschrieben.

# Rückgabe
`data` mit umgerechneten (bzw. zusätzlichen) Spalten.

# Beispiel
```julia
using SimLev, Dates
d = RFrame("date" => Date(2024, 1, 1) .+ Day.(0:4), "sp500_usd" => [4700.0, 4710, 4690, 4720, 4730],
           "eurusd" => [1.10, 1.11, 1.10, 1.09, 1.10])
println(series_convert_currency(d, "sp500_usd", "eurusd"; suffix = "_eur"))
```
"""
function series_convert_currency(data, columns, fx; method = ("divide", "multiply"), suffix = nothing)
    data = SimLev.as_rframe(data)
    fx = SimLev.as_rframe(fx)
    method = _match_arg(method, ("divide", "multiply"))
    columns isa AbstractString && (columns = [columns])
    data = _as_frame(data)
    nms = _names(data)
    miss = unique([c for c in columns if !(c in nms)])
    isempty(miss) || error("series_convert_currency: Spalte(n) $(join(("'" * m * "'" for m in miss), ", ")) fehlen in data (vorhanden: $(join(nms, ", "))).")
    f = SimLev.Backcast._resolve_series(fx, data, "fx")
    bad = [i for i in eachindex(f) if !isfinite(f[i]) || f[i] <= 0]
    isempty(bad) || error("series_convert_currency: Wechselkurs fx muss positiv sein; $(length(bad)) Zeilen ungültig (z. B. Zeile $(bad[1]): $(_fmt_num(f[bad[1]]))).")
    data = copy(data)
    for k in columns
        nm = suffix === nothing ? k : k * suffix
        x = _as_numeric(_col(data, k))
        data[nm] = method == "divide" ? x ./ f : x .* f
    end
    return data
end

_rep_len(x, n) = (v = x isa AbstractVector ? x : [x]; n == 0 ? Float64[] : Float64[v[mod1(i, length(v))] for i in 1:n])

"""
    index_total_return(price; dividends = nothing, yield = nothing, withholding = 0,
                       dates = nothing, start = nothing)

Total-Return-Index aus Kursindex und Ausschüttungen.

r_t = fracP_t + D_t (1 - w)P_t-1 - 1 + (y_t)/(100)(1-w)(Δ t)/(365.25) mit Ausschüttung je Anteil D_t am
Ex-Tag, Quellensteuer w und alternativ laufend aufgezinster Dividendenrendite y_t (Prozent p. a.). Δ t ist der
Abstand zur Vorzeile in Kalendertagen.

# Argumente
- `price`: Kursreihe als numerischer Vektor (Niveaus); NA werden per LOCF gefüllt.
- `dividends`: Ausschüttung je Anteil in Währungseinheiten am Ex-Tag (numerischer Vektor gleicher Länge, 0
  oder NA an Tagen ohne Ausschüttung). Standard `nothing` = keine.
- `yield`: Dividendenrendite in Prozent p. a. (2 = 2 %; Skalar oder Vektor gleicher Länge), anteilig je Zeile
  aufgezinst. Standard `nothing` = keine.
- `withholding`: Quellensteuer in Prozent (15 = 15 %), mindert `dividends` und `yield`. Standard 0.
- `dates`: Datumsvektor gleicher Länge für Δ t, aufsteigend sortiert wie `price` (sonst Fehler); Standard
  `nothing` = 1 Tag je Zeile (nur für `yield` von Bedeutung).
- `start`: Startwert des Index (Standard `nothing` = erster Kurs).

# Rückgabe
Numerischer Indexvektor gleicher Länge wie `price`.

# Details
Wandelt einen Kursindex (Preisindex ohne Ausschüttungen) in einen Total-Return-Index um (Ausschüttungen nach
Quellensteuer reinvestiert). Arbeitet auf Vektoren; das Ergebnis kann direkt als neue Kursspalte in den
Tabelle (RFrame) für `simulation()` geschrieben werden. Werden `dividends` und `yield` zugleich angegeben,
wirken beide.

# Total-Return-Index aus Kursindex und Ausschüttungen
`r_t = (P_t + D_t (1 - w)) / P_{t-1} - 1 + y_t/100 (1-w) Δt/365.25`.

# Beispiel
```julia
using SimLev
p = [100, 101, 99, 100, 102, 103]
div = [0, 0, 0, 2, 0, 0]             # 2 je Anteil am Ex-Tag (Zeile 4)
println(index_total_return(p; dividends = div, withholding = 15))
```
"""
function index_total_return(price; dividends = nothing, yield = nothing, yield_ = nothing, withholding = 0,
                            dates = nothing, start = nothing)
    yv = yield === nothing ? yield_ : yield
    p = _as_numeric(price)
    n = length(p)
    w = withholding / 100
    any(isnan, p) && (p = SimLev.Backcast._fill_na(p, "locf"))
    D = dividends === nothing ? zeros(n) : (x = _as_numeric(dividends); x[isnan.(x)] .= 0; x)
    y = yv === nothing ? zeros(n) : _rep_len(_as_numeric(yv), n)
    if dates !== nothing
        dd = _days(_to_date(dates, "index_total_return: dates"))
        length(dd) != n && error("index_total_return: dates hat Länge $(length(dd)), price $(n).")
        (any(isnan, dd) || any(i -> dd[i+1] < dd[i], 1:length(dd)-1)) &&
            error("index_total_return: dates müssen vollständig und aufsteigend sortiert sein (wie price).")
        dt = vcat(0.0, [dd[i+1] - dd[i] for i in 1:n-1])
    else
        dt = ones(n)
    end
    r = vcat(0.0, Float64[(p[t] + D[t] * (1 - w)) / p[t-1] - 1 + y[t] / 100 * (1 - w) * dt[t] / 365.25 for t in 2:n])
    s = start === nothing ? p[1] : Float64(start)
    return s .* SimLev.RBase.r_cumprod(1 .+ r)
end

"""
    _cpi_level(cpi, data, dts, what)

Preisindex-Niveau je Zeile; vor dem ersten bekannten Wert NA (R:
`.cpi_level`). `dts`: Datumswerte der Zeilen (Date-Vektor oder Float64-Tage).
"""
function _cpi_level(cpi, data, dts, what)
    dd = _days(dts)
    if cpi isa AbstractString || (cpi isa AbstractVector{<:AbstractString} && length(cpi) == 1)
        c = cpi isa AbstractString ? String(cpi) : String(cpi[1])
        c in _names(data) || error("$(what): Spalte '$(c)' fehlt im Datensatz.")
        return SimLev.Backcast._fill_na(_as_numeric(_col(data, c)), "locf"; keep_leading = true)
    end
    cf = _as_frame(cpi)
    first_ = nothing
    if cf isa RFrame
        nm = _names(cf)
        dcol = "date" in nm ? "date" : nm[1]
        fd = filter(!isnan, _days(_to_date(_col(cf, dcol), "$(what): Datum")))
        first_ = isempty(fd) ? Inf : minimum(fd)
    elseif _is_named_numeric(cpi)
        nms, _ = _named_parts(cpi)
        nd = _names_as_dates_optional(nms)
        any(isnan, nd) || (first_ = minimum(nd))
    end
    v = SimLev.Backcast._resolve_series(cpi, RFrame("date" => _as_dates(dd)), what)
    if first_ !== nothing
        v = copy(v)
        for i in eachindex(dd)
            dd[i] < first_ && (v[i] = NA)
        end
    end
    return v
end

"""
    series_deflate(data, columns, cpi; base_date = nothing, suffix = "_real")

Reale Werte über einen Preisindex: real_t = nominal_t * cpi_b / cpi_t.

Rechnet nominale Kurs- oder Wertspalten in reale Werte (Kaufkraft des Bezugsdatums) um: real_t = nominal_t ·
cpi_b / cpi_t mit der Bezugszeile b. Erwartet wird ein Tabelle (RFrame) mit Spalte `date` und einem Preisindex
als Niveau (z. B. Verbraucherpreisindex), keine Inflationsrate. Die realen Spalten kommen als neue Spalten
hinzu und können wie Kursspalten in `simulation()` oder `result_analysis()` verwendet werden; für die reale
Auswertung fertiger Ergebnisse hat `result_analysis()` ein eigenes Argument `inflation`.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` und den Spalten aus `columns`.
- `columns`: Zeichenvektor der Spalten, die deflationiert werden.
- `cpi`: Preisindex-Niveau: Spaltenname in `data` (NA per LOCF gefüllt; z. B. mit `series_align_macro()` und
  Veröffentlichungsverzug vorbereitet), `data.frame(date, value)` (Stufenfunktion: Wert gilt ab seinem Datum),
  benannter Vektor mit Datumsnamen oder Vektor der Länge `nrow(data)`. Vor dem ersten bekannten Wert wird
  nicht zurückgefüllt: Die realen Werte dieser Zeilen sind NA (mit Hinweis).
- `base_date`: Bezugsdatum, an dem real = nominal (Date oder `"JJJJ-MM-TT"`; verwendet wird die Zeile mit dem
  nächstgelegenen Datum; dort muss der Preisindex bekannt sein). Standard `nothing` = erste Zeile mit
  bekanntem Preisindex.
- `suffix`: Endung für die neuen Spalten (Standard `"_real"`).

# Rückgabe
`data` mit zusätzlichen realen Spalten `paste0(columns, suffix)`.

# Beispiel
```julia
using SimLev, Dates
cpi = RFrame("date" => [Date(2020, 1, 1) + Month(k) for k in 0:35], "value" => 100 .* 1.003 .^ (0:35))
d = RFrame("date" => Date(2021, 1, 1) .+ Day.(0:399), "depot" => 10000 .* 1.0002 .^ (0:399))
d = series_align_macro(d, cpi; name = "cpi", lag = 1, lag_unit = "month")
println(series_deflate(d, "depot", "cpi")["depot_real"][end])
```
"""
function series_deflate(data, columns, cpi; base_date = nothing, suffix = "_real")
    data = SimLev.as_rframe(data)
    cpi = SimLev.as_rframe(cpi)
    columns isa AbstractString && (columns = [columns])
    data = _as_frame(data)
    dts = _days(_to_date(_col(data, "date"), "series_deflate: data\$date"))
    c0 = _cpi_level(cpi, data, dts, "cpi")
    known = findall(!isnan, c0)
    isempty(known) && error("series_deflate: Preisindex cpi hat keinen Wert im Zeitraum von data.")
    known[1] > 1 && message("Hinweis: series_deflate: Preisindex erst ab $(_date_str(dts[known[1]])) bekannt; $(known[1] - 1) Zeilen davor bleiben NA.")
    b = if base_date === nothing
        known[1]
    else
        bd = _days(_to_date(base_date, "base_date"))
        _which_min([abs(t - bd[1]) for t in dts])
    end
    isnan(c0[b]) && error("series_deflate: am Bezugsdatum $(_date_str(dts[b])) ist kein Preisindex bekannt (erster Wert am $(_date_str(dts[known[1]]))); base_date später wählen.")
    data = copy(data)
    for k in columns
        data[k * suffix] = _as_numeric(_col(data, k)) ./ c0 .* c0[b]
    end
    return data
end

# ═══════════════════════════════════════════════════════════════════════════
# series_splice
# ═══════════════════════════════════════════════════════════════════════════

"""
    series_splice(; dates = nothing, series...)
    series_splice("name" => reihe, ...; dates = nothing)

Reihen verketten (Proxy -> Index -> Fonds).

Verbindet mehrere Reihen renditebasiert zu einer langen Historie. Die erste Reihe hat Vorrang: Wo sie
vorliegt, wird sie unverändert übernommen. Davor (und in ihren Lücken) werden die Tagesrenditen der nächsten
verfügbaren Reihe verkettet, usw. Typisch: Fonds, dann zurückgerechneter Fonds aus `backcast()`, dann ein
Proxy-Index.

# Argumente
- `dates`: Datumsvektor, wenn Vektoren übergeben werden (sonst ignoriert).
- `series`: Benannte Reihen als Schlüsselwörter oder Paare `"name" => reihe`.

# Rückgabe
Tabelle (RFrame) mit `date`, `value` (verkettete Reihe) und `source`: Name der Reihe, deren Wert (erste Reihe)
bzw. Rendite vom Vortag auf diesen Tag verwendet wurde (NA, wo keine Rendite vorliegt, z. B. in der ersten
Zeile).

# Details
Alle Reihen müssen Niveaus (Kurse, Indexstände) sein, keine Renditen; das Niveau der Kette richtet sich nach
der ersten Reihe. Vor dem Start der ersten Reihe wird rückwärts verkettet, solange Renditen vorliegen. Das
Ergebnis lässt sich als Kursspalte in `simulation()` oder als `data.frame(date, value)` in `result_analysis()`
verwenden.

# Beispiel
```julia
using SimLev, Dates, Random
dts = Date(2010, 1, 1) .+ Day.(0:1499)
v = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(MersenneTwister(1), 1500))
k = dts .>= Date(2012, 1, 1)
lang = series_splice(fonds = RFrame("date" => dts[k], "value" => 0.5 .* v[k]), proxy = RFrame("date" => dts, "value" => v))
println(count(isequal("proxy"), lang["source"]))
```
"""
function series_splice(args...; dates = nothing, series...)
    src = _named_sources(args, series)
    (src === nothing || length(src) < 2 || any(p -> p[1] == "", src)) && error("series_splice: mindestens zwei benannte Reihen.")
    nms = [s[1] for s in src]
    Fl = nothing
    if all(s -> _as_frame(s[2]) isa RFrame, src)
        al = series_align((k => _as_frame(v) for (k, v) in src)...; range = "all")
        dates = al["date"]
        V = [Float64.(al[k]) for k in nms]
        F = attrs(al)["filled"]
        Fl = [Bool.(F[k]) for k in nms]
    else
        dates === nothing && error("series_splice: 'dates' angeben, wenn Vektoren übergeben werden.")
        V = [_as_numeric(v) for (_, v) in src]
    end
    n = length(V[1])
    nc = length(V)
    Rm = [vcat(NA, Float64[c[t] / c[t-1] - 1 for t in 2:n]) for c in V]
    p = copy(V[1])
    if Fl !== nothing
        other = [any(j -> !isnan(V[j][i]) && !Fl[j][i], 2:nc) for i in 1:n]
        run = cumsum(.!Fl[1])
        gmax = Dict{Int,Float64}(); gsum = Dict{Int,Float64}()
        for i in 1:n
            g = run[i]
            a1 = Float64(other[i] && Fl[1][i]); a2 = Float64(Fl[1][i])
            gmax[g] = max(get(gmax, g, -Inf), a1)
            gsum[g] = get(gsum, g, 0.0) + a2
        end
        for i in 1:n
            if Fl[1][i] && gmax[run[i]] > 0 && gsum[run[i]] > 4
                p[i] = NA; Rm[1][i] = NA
            end
        end
    end
    pick = [something(findfirst(j -> isfinite(Rm[j][i]), 1:nc), 0) for i in 1:n]
    r = Float64[pick[i] > 0 ? Rm[pick[i]][i] : NA for i in 1:n]
    a = findfirst(!isnan, p)
    a === nothing && error("series_splice: Die erste Reihe hat keine Werte.")
    lv = fill(NA, n)
    lv[a] = p[a]
    for t in a+1:n
        lv[t] = !isnan(p[t]) ? p[t] : !isnan(r[t]) ? lv[t-1] * (1 + r[t]) : lv[t-1]
    end
    if a > 1
        for t in a:-1:2
            isnan(r[t]) && break
            lv[t-1] = lv[t] / (1 + r[t])
        end
    end
    srcname = Union{Missing,String}[!isnan(p[i]) ? nms[1] : pick[i] == 0 ? missing : nms[pick[i]] for i in 1:n]
    for i in 1:n
        isnan(lv[i]) && (srcname[i] = missing)
    end
    any(ismissing, srcname) || (srcname = String[s for s in srcname])
    return RFrame("date" => _to_date(dates, "series_splice: dates"), "value" => lv, "source" => srcname)
end

# ═══════════════════════════════════════════════════════════════════════════
# Portfolios
# ═══════════════════════════════════════════════════════════════════════════

"Benannter Vektor → (Namen oder `nothing`, Werte)."
_named(x::RVector) = (x.names === nothing ? nothing : copy(x.names), collect(Any, x.values))
_named(x::AbstractVector{<:Pair}) = (String[string(p.first) for p in x], Any[p.second for p in x])
_named(x::Pair) = ([string(x.first)], Any[x.second])
_named(x::NamedTuple) = (String[string(k) for k in keys(x)], collect(Any, values(x)))
_named(x::AbstractDict) = (String[string(k) for k in keys(x)], collect(Any, values(x)))
_named(x::AbstractVector) = (nothing, collect(Any, x))
_named(x) = (nothing, Any[x])

_rlen(v) = v === nothing ? 0 : v isa Union{AbstractVector,NamedTuple,AbstractDict,Tuple} ? length(v) : 1

"""
    strategy_from_weights(weights; kwargs...)

Strategie aus Gewichten.

Baut aus einem benannten Gewichtsvektor eine statische Strategie für `simulation()`, ohne jedes Asset einzeln
mit `asset_config()` anlegen zu müssen. Die Namen müssen den Kursspalten des Datensatzes entsprechen (z. B.
aus `series_align()`). Jedes Asset erhält `share = Gewicht`; alle weiteren Einstellungen kommen aus `...` oder
den Standardwerten von `asset_config()` (ETF, Buy and Hold, ohne Spread).

# Argumente
- `weights`: Benannter numerischer Vektor Spaltenname -> Gewicht als Anteil (0.6 = 60 %), z. B. `(world = 0.6,
  bonds = 0.4)`. Alle Gewichte müssen positiv sein (Assets mit Gewicht 0 weglassen), die Namen eindeutig, und
  die Summe muss 1 sein (wie in `simulation()`; sonst Fehler schon hier).
- `kwargs...`: Weitere Argumente für `asset_config()` (z. B. `asset_class`, `spread` in Prozent,
  `partial_exemption` in Prozent). Ein unbenannter einzelner Wert gilt für alle Assets; benannte Vektoren
  werden je Asset zugeordnet, auch mit einem einzigen Element wie `partial_exemption = (aktien = 30,)`
  (fehlende Assets behalten den Standardwert, Namen ohne passendes Asset werden ignoriert). Nur ein einzelner
  benannter Wert, dessen Name kein Asset ist, gilt für alle Assets.

  `wrapper` (Fonds-Wrapper, `wrapper_config`) ist eine Ausnahme, weil ein `SimLevWrapperConfig` selbst eine
  benannte Liste ist: Ein einzelnes `SimLevWrapperConfig` gilt für alle Assets; eine benannte Liste solcher
  Objekte (Name = Asset, z. B. `wrapper = (world = w,)`) gilt je Asset, Assets ohne Eintrag bleiben ohne
  Wrapper. Fehler: Namen, die kein Asset sind, Elemente, die kein `SimLevWrapperConfig` sind, eine Liste ohne
  Namen, und `wrapper` zusammen mit `trading = "signal"` für dasselbe Asset (die Meldung nennt das Asset).

# Rückgabe
Objekt der Klasse `strategy` (wie `create_strategy()`).

# Beispiel
```julia
using SimLev
st = strategy_from_weights((aktien = 0.7, gold = 0.3); asset_class = (aktien = "etf", gold = "etc"),
                           partial_exemption = (aktien = 30, gold = 0))
println(st)
```
"""
function strategy_from_weights(weights; kwargs...)
    nms, vals = _named(weights)
    (nms === nothing || any(k -> k === missing || k == "", nms)) && error("weights muss benannt sein.")
    dup = _duplicated(nms)
    if any(dup)
        u = unique(nms[dup])
        error("weights: doppelte Namen $(join(("'" * k * "'" for k in u), ", ")); jedes Asset nur einmal angeben.")
    end
    w = Float64[_isna(v) ? NA : Float64(v) for v in vals]
    (any(isnan, w) || any(<=(0), w)) && error("Gewichte müssen positiv sein (Assets mit Gewicht 0 weglassen).")
    s = SimLev.r_sum(w)
    abs(s - 1) > 1e-6 && error(_sprintf("Gewichte summieren sich zu %.4f; simulation() verlangt die Summe 1 (Anteile, 0.6 = 60 %%).", s))
    # Fonds-Wrapper: ein SimLevWrapperConfig gilt für alle Assets, eine benannte Liste je Asset
    wmap = Dict{String,Any}()
    if haskey(kwargs, :wrapper)
        wmap = _sfw_wrappers(kwargs[:wrapper], nms)
        kwargs = pairs((; (k => v for (k, v) in kwargs if k !== :wrapper)...))
    end
    per_asset(v) = (vn = _named(v)[1]; vn !== nothing && (_rlen(v) > 1 || (_rlen(v) == 1 && vn[1] in nms)))
    scalar(v) = v isa Union{AbstractVector,Tuple} && length(v) == 1 ? first(v) :
                v isa Union{NamedTuple,AbstractDict} && length(v) == 1 ? first(values(v)) :
                v isa Pair ? v.second : v
    assets = Pair{String,Any}[]
    for (i, nm) in enumerate(nms)
        a = Pair{Symbol,Any}[]
        for (key, v) in kwargs
            if per_asset(v)
                vn, vv = _named(v)
                j = findfirst(==(nm), vn)
                val = j === nothing ? missing : vv[j]
            else
                val = scalar(v)
            end
            (_rlen(val) == 1 && _isna(val)) && continue
            push!(a, key => val)
        end
        wr = get(wmap, nm, nothing)
        if wr === nothing
            push!(assets, nm => SimLev.asset_config(; share = w[i], a...))
            continue
        end
        ac = try
            SimLev.asset_config(; share = w[i], a..., wrapper = wr)
        catch e
            (e isa ErrorException && e.msg == SimLev._AC_MSG_WRAPPER_SIGNAL) || rethrow()
            error("wrapper: Asset '$nm' hat trading = \"signal\"; mit wrapper ist nur trading = \"bnh\" möglich (keine Signale auf den Anteilswert; Signale gehen in der inneren Strategie).")
        end
        push!(assets, nm => ac)
    end
    return SimLev.create_strategy(; assets = assets)
end

"""
    _sfw_wrappers(wv, assets)

Argument `wrapper` von `strategy_from_weights` je Asset (R: `.sfw_wrappers`): `nothing` oder leer →
ohne Wrapper; ein `SimLevWrapperConfig` → für alle Assets; eine benannte Liste (NamedTuple, `Dict`, `RList`,
Paare) Asset → `SimLevWrapperConfig` → je Asset, Assets ohne Eintrag ohne Wrapper. Sonst Fehler (Reihenfolge:
Art, Namen vorhanden, doppelte Namen, unbekannte Namen, Elemente). Ergebnis: `Dict` Asset → Wrapper.
"""
function _sfw_wrappers(wv, assets::Vector{String})
    @nospecialize
    wv === nothing && return Dict{String,Any}()
    inherits(wv, "SimLevWrapperConfig") && return Dict{String,Any}(nm => wv for nm in assets)
    if wv isa RFrame || !(wv isa Union{AbstractDict,NamedTuple,AbstractVector,Tuple,Pair})
        error("wrapper muss ein Objekt aus wrapper_config() (gilt für alle Assets) oder eine benannte Liste solcher Objekte sein (Name = Asset), nicht $(SimLev._cls_all(wv)).")
    end
    _rlen(wv) == 0 && return Dict{String,Any}()
    nm, vals = wv isa Tuple ? (nothing, collect(Any, wv)) : _named(wv)
    (nm === nothing || any(k -> k == "", nm)) &&
        error("wrapper: als Liste braucht jedes Element einen Namen (Name = Asset, z. B. list($(assets[1]) = wrapper_config(...))).")
    dup = _duplicated(nm)
    if any(dup)
        u = unique(nm[dup])
        error("wrapper: doppelte Namen $(join(("'" * k * "'" for k in u), ", ")); jedes Asset nur einmal angeben.")
    end
    unk = [k for k in nm if !(k in assets)]
    isempty(unk) || error("wrapper: $(join(("'" * k * "'" for k in unk), ", ")) $(length(unk) == 1 ? "ist kein Asset der Strategie" : "sind keine Assets der Strategie") (Assets: $(join(assets, ", "))).")
    for (k, v) in zip(nm, vals)
        inherits(v, "SimLevWrapperConfig") ||
            error("wrapper: Eintrag '$k' muss ein Objekt aus wrapper_config() sein, nicht $(SimLev._cls_all(v)).")
    end
    return Dict{String,Any}(zip(nm, vals))
end

const _PORTFOLIO_TEMPLATES = [
    "60_40" => ["stocks" => 0.60, "bonds" => 0.40],
    "permanent" => ["stocks" => 0.25, "long_bonds" => 0.25, "cash" => 0.25, "gold" => 0.25],
    "all_weather" => ["stocks" => 0.30, "long_bonds" => 0.40, "inter_bonds" => 0.15, "gold" => 0.075, "commodities" => 0.075],
    "golden_butterfly" => ["stocks" => 0.20, "small_value" => 0.20, "long_bonds" => 0.20, "short_bonds" => 0.20, "gold" => 0.20],
    "three_fund" => ["stocks" => 0.48, "intl_stocks" => 0.32, "bonds" => 0.20],
    "hfea" => ["stocks_3x" => 0.55, "long_bonds_3x" => 0.45],
    "stocks_gold" => ["stocks" => 0.80, "gold" => 0.20],
]

"""
    portfolio_template(name = nothing; map = nothing, kwargs...)

Portfolio-Vorlagen.

Bekannte statische Allokationen mit Rollen-Namen (z. B. `stocks`, `long_bonds`, `gold`). Über `map` werden die
Rollen den Spalten des Datensatzes zugeordnet. Die Vorlagen sind Ausgangspunkte zum Vergleich, keine
Empfehlungen.

# Argumente
- `name`: Name der Vorlage als Zeichenkette (siehe Tabelle). Ohne `name` (Standard `nothing`) liefert
  `portfolio_template()` die Liste aller Vorlagen; `map` und `...` sind dann nicht erlaubt.
- `map`: Benannter Zeichenvektor Rolle -> Spaltenname im Datensatz, z. B. `(stocks = "msci_world",)`. Standard
  `nothing`; Rollen ohne Eintrag behalten ihren Namen und müssen dann als Spalte vorliegen. Unbekannte Rollen
  und mehrere Rollen auf derselben Spalte sind ein Fehler.
- `kwargs...`: Weitere Argumente für `strategy_from_weights()` bzw. `asset_config()` (z. B. `spread`,
  `partial_exemption`, `wrapper`). Benannte Werte je Asset, auch die Namen einer `wrapper`-Liste, beziehen
  sich auf die Namen nach `map` (Spaltennamen); Rollen ohne `map`-Eintrag behalten ihren Namen.

# Rückgabe
Mit `name`: Objekt der Klasse `strategy` für `simulation()`; ohne `name`: Tabelle (RFrame) aller Vorlagen mit
`template`, `role` und `weight` (Anteil, 0.6 = 60 %).

# Details
- `60_40` | Aktien 60, Anleihen 40
- `permanent` | Permanent Portfolio (H. Browne): je 25 Aktien, lange Anleihen, Geldmarkt, Gold
- `all_weather` | vereinfachtes All Weather: 30/40/15/7.5/7.5
- `golden_butterfly` | je 20 Aktien, Small Value, lange und kurze Anleihen, Gold
- `three_fund` | Aktien Heimat 48, international 32, Anleihen 20
- `hfea` | 55 3x-Aktien, 45 3x-lange Anleihen
- `stocks_gold` | Aktien 80, Gold 20

Gewichte in der Tabelle in Prozent; in der Strategie als Anteile.

# Beispiel
```julia
using SimLev
st = portfolio_template("permanent"; map = (stocks = "msci_world", long_bonds = "bund_10y", cash = "geldmarkt",
                                           gold = "gold_eur"))
println(st)
```
"""
function portfolio_template(name_pos = nothing; name = name_pos, map = nothing, kwargs...)
    if name === nothing
        (map !== nothing || !isempty(kwargs)) &&
            error("portfolio_template: map und weitere Argumente nur zusammen mit name; ohne name liefert portfolio_template() die Liste der Vorlagen.")
        return _template_list()
    end
    i = findfirst(p -> p.first == name, _PORTFOLIO_TEMPLATES)
    i === nothing && error("Unbekannte Vorlage '$(name)'. Verfügbar: $(join(first.(_PORTFOLIO_TEMPLATES), ", "))")
    w = _PORTFOLIO_TEMPLATES[i].second
    roles = String[p.first for p in w]
    vals = Float64[p.second for p in w]
    if map !== nothing
        mn, mv = _named(map)
        (mn === nothing || any(k -> k == "", mn)) &&
            error("map muss benannt sein: Rolle -> Spaltenname, z. B. c(stocks = \"msci_world\").")
        unk = unique([k for k in mn if !(k in roles)])
        isempty(unk) || error("map: unbekannte Rolle(n) $(join(("'" * k * "'" for k in unk), ", ")) für Vorlage '$(name)'; Rollen: $(join(roles, ", ")).")
        roles = [(j = findfirst(==(r), mn); j === nothing ? r : string(mv[j])) for r in roles]
        dup = _duplicated(roles)
        if any(dup)
            u = unique(roles[dup])
            error("map: mehrere Rollen zeigen auf dieselbe Spalte $(join(("'" * k * "'" for k in u), ", ")); je Spalte nur eine Rolle (Gewichte sonst selbst zusammenfassen und strategy_from_weights() verwenden).")
        end
    end
    return strategy_from_weights(RVector(vals; names = roles); kwargs...)
end

"Alle Portfolio-Vorlagen als `RFrame(template, role, weight)`."
function _template_list()
    t = String[]; r = String[]; w = Float64[]
    for (n, d) in _PORTFOLIO_TEMPLATES, (k, v) in d
        push!(t, n); push!(r, k); push!(w, v)
    end
    return RFrame("template" => t, "role" => r, "weight" => w)
end

function __init__()
    register_print!("SimLevDataCheck", _print_datacheck)
end

end # module
