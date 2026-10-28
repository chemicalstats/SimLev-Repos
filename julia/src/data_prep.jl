# DataPrep – r/R/data_prep.R (Vorlage python/simlev/data_prep.py)
#
#   align_series        Quellen nach Datum zusammenführen, Kalender, Füllung
#   check_series        Prüfbericht (Lücken, Ausreißer, Spikes, Splits, stehende Kurse)
#   align_macro         Makroreihen mit Veröffentlichungsverzug auf den Tageskalender
#   convert_currency    Währungsumrechnung
#   total_return_index  Kurs- zu Total-Return-Index
#   deflate             reale Werte über einen Preisindex
#   splice_series       Ketten aus mehreren Reihen
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

export align_series, check_series, align_macro, convert_currency, total_return_index, deflate,
       splice_series, strategy_from_weights, portfolio_template

# ═══════════════════════════════════════════════════════════════════════════
# Allgemeine Hilfen (R-Semantik)
# ═══════════════════════════════════════════════════════════════════════════

"R-`message()`: Text mit Zeilenumbruch auf `stderr`."
message(text) = (println(stderr, text); flush(stderr); nothing)

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

_days_in_month(y, m) = _civil_to_days(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 1) - _civil_to_days(y, m, 1)

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

# R's strptime: get_number(from, to, n) – überspringt Leerzeichen, liest
# höchstens n Ziffern, solange val * 10 <= to.
function _get_number(s::Vector{UInt8}, p::Int, from::Int, to::Int, n::Int)
    while p <= length(s) && s[p] == UInt8(' ')
        p += 1
    end
    (p > length(s) || !(UInt8('0') <= s[p] <= UInt8('9'))) && return (nothing, p)
    val = 0
    k = n
    while true
        val = val * 10 + Int(s[p] - UInt8('0'))
        p += 1
        k -= 1
        (k > 0 && val * 10 <= to && p <= length(s) && UInt8('0') <= s[p] <= UInt8('9')) || break
    end
    (val < from || val > to) && return (nothing, p)
    return (val, p)
end

"`as.Date(s, format = \"%Y-%m-%d\")` (bzw. `/`) für einen Text; NA = `SimLev.NA`."
function _strptime_ymd(s, sep::Char = '-')
    (s === nothing || s === missing) && return NA
    b = Vector{UInt8}(codeunits(String(s)))
    y, p = _get_number(b, 1, 0, 9999, 4)
    y === nothing && return NA
    (p <= length(b) && b[p] == UInt8(sep)) || return NA
    m, p = _get_number(b, p + 1, 1, 12, 2)
    m === nothing && return NA
    (p <= length(b) && b[p] == UInt8(sep)) || return NA
    d, p = _get_number(b, p + 1, 1, 31, 2)
    d === nothing && return NA
    d > _days_in_month(y, m) && return NA
    return Float64(_civil_to_days(y, m, d))
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

Datumsangaben in Date umwandeln (Port von `.to_date`): `Date`/`DateTime`
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

Datum plus `k` Kalendermonate, auf das Monatsende begrenzt (Port von
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
Dezimalkomma). Port von `.num_text_cols`; liefert die Spaltennamen.
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

"Fehlermeldung für Zahlen als Text (Port von `.num_text_stop`)."
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

Eine Quelle in `RFrame(date, ...)` mit numerischen Spalten wandeln (Port von
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
# align_series
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
    align_series(; calendar = "day", range = "common", fill = "locf",
                 max_gap = Inf, start = nothing, end_ = nothing, sources...)
    align_series("name" => quelle, ...; kwargs...)

Datenquellen nach Datum zusammenführen. Benannte Quellen (Name =
Spaltenname im Ergebnis) als `RFrame(date, value)` (eine numerische Spalte),
`RFrame(date, A, B, ...)` oder benannter numerischer Vektor mit
Datumsnamen. Liefert ein `RFrame` mit Spalte `date` und je einer Spalte pro
Reihe; `attrs(df)["filled"]` ist ein `RFrame` aus Bool-Spalten (TRUE =
gefüllter Wert).
"""
function align_series(args...; calendar = ("day", "union", "intersect"), range = ("common", "all"),
                      fill = ("locf", "linear", "none"), max_gap = Inf, start = nothing, end_ = nothing,
                      sources...)
    calendar = _match_arg(calendar, ("day", "union", "intersect"))
    rng = _match_arg(range, ("common", "all"))
    fill = _match_arg(fill, ("locf", "linear", "none"))
    src = _named_sources(args, sources)
    (src === nothing || isempty(src) || any(p -> p[1] == "", src)) &&
        error("align_series: Quellen benennen, z. B. align_series(us = df1, eu = df2).")
    fr = [(k, _dp_frame(v, k)) for (k, v) in src]
    fdays = [_days(f["date"]) for (_, f) in fr]
    first_ = [isempty(d) ? NA : d[1] for d in fdays]
    last_ = [isempty(d) ? NA : d[end] for d in fdays]
    any(isnan, first_) && error("missing value where TRUE/FALSE needed")
    lo = rng == "common" ? maximum(first_) : minimum(first_)
    hi = rng == "common" ? minimum(last_) : maximum(last_)
    if start !== nothing
        s0 = _days(_to_date(start, "align_series: start"))
        lo = any(isnan, s0) ? NA : maximum(vcat([lo], s0))
    end
    if end_ !== nothing
        e0 = _days(_to_date(end_, "align_series: end"))
        hi = any(isnan, e0) ? NA : minimum(vcat([hi], e0))
    end
    (isnan(lo) || isnan(hi)) && error("missing value where TRUE/FALSE needed")
    lo > hi && error("align_series: Die Quellen überlappen sich nicht.")
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
            k in onames && error("align_series: Spaltenname '$(k)' kommt mehrfach vor.")
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
# check_series
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
    check_series(data; columns = nothing, jump = 20, stale = 10, revert = 0.8)

Kursreihen prüfen: Prüfbericht (Klasse `SimLevDataCheck`) mit `summary`,
`issues` und `settings`. Die Daten werden nicht geändert.
"""
function check_series(data; columns = nothing, jump = 20, stale = 10, revert = 0.8)
    data = SimLev.as_rframe(data)
    data = _as_frame(data)
    (data isa RFrame && "date" in _names(data)) || error("check_series: data.frame mit Spalte 'date' erwartet.")
    d = _days(_to_date(_col(data, "date"), "check_series: date"; strict = false))
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

"`print.SimLevDataCheck(x, max_issues = 25)`."
function print_SimLevDataCheck(x; max_issues = 25, io::IO = stdout)
    println(io, format_SimLevDataCheck(x; max_issues = max_issues))
    return x
end

# ═══════════════════════════════════════════════════════════════════════════
# align_macro
# ═══════════════════════════════════════════════════════════════════════════

"""
    align_macro(data, macro_; name = "macro", lag = 0, lag_unit = "day",
                transform = "level", periods = nothing)

Makroreihen mit Veröffentlichungsverzug auf den Tageskalender legen: Ein
Wert gilt ab `Referenzdatum + lag` bis zum nächsten verfügbaren Wert. Bei
einem Datumsvektor als `data` ein Float64-Vektor gleicher Länge, sonst eine
Kopie von `data` mit neuer Spalte `name`.
"""
function align_macro(data, macro_; name = "macro", lag = 0, lag_unit = ("day", "month"),
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
    dates = _days(_to_date(is_df ? _col(df, "date") : data, "align_macro: data"))
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
# convert_currency, total_return_index, deflate
# ═══════════════════════════════════════════════════════════════════════════

"""
    convert_currency(data, columns, fx; method = "divide", suffix = nothing)

Währung umrechnen: je Zeile Kurs durch den Wechselkurs teilen (`"divide"`)
oder mit ihm multiplizieren (`"multiply"`). `fx` als Spaltenname,
`RFrame(date, value)` (Stufenfunktion), benannter Vektor, Vektor der Länge
`nrow(data)` oder Skalar.
"""
function convert_currency(data, columns, fx; method = ("divide", "multiply"), suffix = nothing)
    data = SimLev.as_rframe(data)
    fx = SimLev.as_rframe(fx)
    method = _match_arg(method, ("divide", "multiply"))
    columns isa AbstractString && (columns = [columns])
    data = _as_frame(data)
    nms = _names(data)
    miss = unique([c for c in columns if !(c in nms)])
    isempty(miss) || error("convert_currency: Spalte(n) $(join(("'" * m * "'" for m in miss), ", ")) fehlen in data (vorhanden: $(join(nms, ", "))).")
    f = SimLev.Backcast._resolve_series(fx, data, "fx")
    bad = [i for i in eachindex(f) if !isfinite(f[i]) || f[i] <= 0]
    isempty(bad) || error("convert_currency: Wechselkurs fx muss positiv sein; $(length(bad)) Zeilen ungültig (z. B. Zeile $(bad[1]): $(_fmt_num(f[bad[1]]))).")
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
    total_return_index(price; dividends = nothing, yield = nothing, withholding = 0,
                       dates = nothing, start = nothing)

Total-Return-Index aus Kursindex und Ausschüttungen:
`r_t = (P_t + D_t (1 - w)) / P_{t-1} - 1 + y_t/100 (1-w) Δt/365.25`.
"""
function total_return_index(price; dividends = nothing, yield = nothing, yield_ = nothing, withholding = 0,
                            dates = nothing, start = nothing)
    yv = yield === nothing ? yield_ : yield
    p = _as_numeric(price)
    n = length(p)
    w = withholding / 100
    any(isnan, p) && (p = SimLev.Backcast._fill_na(p, "locf"))
    D = dividends === nothing ? zeros(n) : (x = _as_numeric(dividends); x[isnan.(x)] .= 0; x)
    y = yv === nothing ? zeros(n) : _rep_len(_as_numeric(yv), n)
    if dates !== nothing
        dd = _days(_to_date(dates, "total_return_index: dates"))
        length(dd) != n && error("total_return_index: dates hat Länge $(length(dd)), price $(n).")
        (any(isnan, dd) || any(i -> dd[i+1] < dd[i], 1:length(dd)-1)) &&
            error("total_return_index: dates müssen vollständig und aufsteigend sortiert sein (wie price).")
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

Preisindex-Niveau je Zeile; vor dem ersten bekannten Wert NA (Port von
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
    deflate(data, columns, cpi; base_date = nothing, suffix = "_real")

Reale Werte über einen Preisindex: `real_t = nominal_t * cpi_b / cpi_t`.
"""
function deflate(data, columns, cpi; base_date = nothing, suffix = "_real")
    data = SimLev.as_rframe(data)
    cpi = SimLev.as_rframe(cpi)
    columns isa AbstractString && (columns = [columns])
    data = _as_frame(data)
    dts = _days(_to_date(_col(data, "date"), "deflate: data\$date"))
    c0 = _cpi_level(cpi, data, dts, "cpi")
    known = findall(!isnan, c0)
    isempty(known) && error("deflate: Preisindex cpi hat keinen Wert im Zeitraum von data.")
    known[1] > 1 && message("Hinweis: deflate: Preisindex erst ab $(_date_str(dts[known[1]])) bekannt; $(known[1] - 1) Zeilen davor bleiben NA.")
    b = if base_date === nothing
        known[1]
    else
        bd = _days(_to_date(base_date, "base_date"))
        _which_min([abs(t - bd[1]) for t in dts])
    end
    isnan(c0[b]) && error("deflate: am Bezugsdatum $(_date_str(dts[b])) ist kein Preisindex bekannt (erster Wert am $(_date_str(dts[known[1]]))); base_date später wählen.")
    data = copy(data)
    for k in columns
        data[k * suffix] = _as_numeric(_col(data, k)) ./ c0 .* c0[b]
    end
    return data
end

# ═══════════════════════════════════════════════════════════════════════════
# splice_series
# ═══════════════════════════════════════════════════════════════════════════

"""
    splice_series(; dates = nothing, series...)
    splice_series("name" => reihe, ...; dates = nothing)

Reihen verketten (Proxy → Index → Fonds); die erste Reihe hat Vorrang.
Mindestens zwei benannte Reihen in Prioritätsreihenfolge, alle als
numerische Vektoren gleicher Länge (dann `dates` angeben) oder alle als
`RFrame(date, value)`. Liefert `RFrame(date, value, source)`.
"""
function splice_series(args...; dates = nothing, series...)
    src = _named_sources(args, series)
    (src === nothing || length(src) < 2 || any(p -> p[1] == "", src)) && error("splice_series: mindestens zwei benannte Reihen.")
    nms = [s[1] for s in src]
    Fl = nothing
    if all(s -> _as_frame(s[2]) isa RFrame, src)
        al = align_series((k => _as_frame(v) for (k, v) in src)...; range = "all")
        dates = al["date"]
        V = [Float64.(al[k]) for k in nms]
        F = attrs(al)["filled"]
        Fl = [Bool.(F[k]) for k in nms]
    else
        dates === nothing && error("splice_series: 'dates' angeben, wenn Vektoren übergeben werden.")
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
    a === nothing && error("splice_series: Die erste Reihe hat keine Werte.")
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
    return RFrame("date" => _to_date(dates, "splice_series: dates"), "value" => lv, "source" => srcname)
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

Strategie aus einem benannten Gewichtsvektor (`RVector`, Paare, NamedTuple
oder Dict); jedes Asset erhält `asset_share = Gewicht`. Weitere Argumente
gehen an `asset_config`: ein einzelner Wert gilt für alle Assets, benannte
Vektoren werden je Asset zugeordnet.
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
        push!(assets, nm => SimLev.asset_config(; asset_share = w[i], a...))
    end
    return SimLev.create_strategy(; assets = assets)
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

Bekannte statische Allokationen mit Rollen-Namen; `map` (benannter Vektor
Rolle → Spaltenname) ordnet die Rollen den Spalten zu. Weitere Argumente
gehen an [`strategy_from_weights`](@ref). Ohne `name` (Standard `nothing`)
liefert die Funktion alle Vorlagen als `RFrame(template, role, weight)`;
`map` und weitere Argumente sind dann nicht erlaubt.
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
    register_print!("SimLevDataCheck", (io, x) -> print(io, format_SimLevDataCheck(x)))
end

end # module
