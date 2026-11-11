# Herkunft:           übersetzt aus R 4.3.3, src/main/summary.c, cum.c, array.c, arithmetic.c
#                     (R_zeroin2/uniroot aus zeroin.c bzw. nlm.R entfallen, XIRR im Kern)
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Summen und Kumulationen rechnen die C-Kerne
#                     core/slc_rbase*.
# ─────────────────────────────────────────────────────────────────────────────
# R-kompatible Numerik
#
# Summen, Mittel, Varianz, Kumulationen und Potenz rechnen die C-Kerne
# core/slc_rbase*.cpp (r/rbase_c.jl), auch %% und R_strtod (slc_rbase_num.cpp). NA wird wie in R als NaN mit der
# Nutzlast 1954 dargestellt, sodass NA und NaN unterscheidbar bleiben.
# ─────────────────────────────────────────────────────────────────────────────

"R's `NA_real_`: NaN mit Nutzlast 1954 (signalisierend gespeichert, wie in R)."
const NA = reinterpret(Float64, 0x7FF00000000007A2)

"TRUE nur für R's NA (nicht für NaN) – entspricht `R_IsNA`."
isna_strict(x::Float64) = isnan(x) && (reinterpret(UInt64, x) & 0x00000000FFFFFFFF) == 0x00000000000007A2
# seit 1.6.4 (K42 E5) wie Python: andere Zahlen sind nie NA, Felder elementweise, sonst Meldung statt MethodError
isna_strict(x::Real) = false
isna_strict(x::AbstractArray{<:Real}) = Bool[isna_strict(Float64(v)) for v in x]
isna_strict(x) = chk_stop("zahlen", "isna_strict", "x")

"R's `is.na()` für einen Eintrag (`missing`, `nothing`, NA und NaN); seit 1.6.3 eine Fassung für data, data_prep,
dependence, optimize, overfitting, tactical, RFmt und RStats (bis 1.6.2 acht gleiche Kopien; RExpr bleibt eigen)."
_isna(v) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))
"Eintrag als Float64 (`missing`/`nothing` → NA); seit 1.6.4 eine Fassung für trigger, Overfitting und RLinalg."
_f64(v) = v === missing || v === nothing ? NA : Float64(v)

# ── Summen, Mittel, Varianz, Kumulationen (C-Kerne core/slc_rbase.cpp) ─────
# R akkumuliert in long double; die C-Kerne tun dasselbe (x87 auf x86-64, gegen R bitgleich geprüft)
# und sind dieselbe Implementierung wie in Python. Die frühere Nachbildung über F80/F80Soft mit der
# x87-Regel für zwei NaN-Operanden entfällt hier.

"""Text wie R (seit 1.6.4, C-060; bis 1.6.3 rechnete `collect(Float64, x)` mit Zeichencodes): `kind` :sum Fehler (sum,
prod), :mean `nothing` (NA mit Warnung), :num Umwandlung wie as.numeric (NA mit Warnung bei Nicht-Zahlen)."""
function _rtext(x, kind::Symbol)
    istext = x isa AbstractString || x isa AbstractChar ||
             ((x isa AbstractArray || x isa Tuple) && any(t -> t isa AbstractString || t isa AbstractChar, x))
    istext || return x
    kind === :sum && error("invalid 'type' (character) of argument")
    kind === :mean && (@warn "argument is not numeric or logical: returning NA"; return nothing)
    xs = x isa Union{AbstractString,AbstractChar} ? [x] : collect(x)
    out = Float64[]; bad = false
    for t in xs
        if t isa Union{AbstractString,AbstractChar}
            v, b = RExpr._str2num(String(string(t)))
            push!(out, v); bad |= b
        else
            push!(out, t === missing ? NA : Float64(t))
        end
    end
    bad && @warn "NAs introduced by coercion"
    return out
end

"`sum(x)` / `sum(x, na.rm = TRUE)` wie in R."
r_sum(x; na_rm::Bool = false) = _rb_sum(_rbv(_rtext(x, :sum)), na_rm)

"`cumsum(x)` wie in R (long double; NA/NaN über `handleNaN`)."
r_cumsum(x) = _rb_cumsum(_rbv(_rtext(x, :num)))

"`prod(x)` wie in R."
r_prod(x; na_rm::Bool = false) = _rb_prod(_rbv(_rtext(x, :sum)), na_rm)

_dropnan(x) = Float64[v for v in x if !isnan(Float64(v))]

"`mean(x)` für Doubles wie R's `real_mean` (Summe/n plus Korrekturdurchlauf)."
r_mean(x; na_rm::Bool = false) = (x = _rtext(x, :mean); x === nothing ? NA : _rb_mean(na_rm ? _dropnan(x) : _rbv(x)))

"`mean(x)` für Integer-Vektoren wie in R."
r_mean_int(x) = _rb_mean_int(Int64[Int64(v) for v in x])

"`var(x)` wie R (long double, Mittelwert als double gespeichert)."
function r_var(x; na_rm::Bool = false)
    a = _rbv(_rtext(x, :num))
    if na_rm
        a = _dropnan(a)
    elseif any(isnan, a)
        return NA
    end
    return _rb_var(a)
end

"`sd(x)` wie in R: `sqrt(var(x))`."
r_sd(x; na_rm::Bool = false) = r_sqrt(r_var(x; na_rm = na_rm))

"`sqrt` mit R-Semantik (negativ → NaN statt Fehler)."
r_sqrt(x::Float64) = x < 0 ? NaN : sqrt(x)

"`rowSums(m, na.rm)` für eine Liste gleich langer Spalten (long double je Zeile)."
function r_rowsums(cols::AbstractVector; na_rm::Bool = false)
    nr = isempty(cols) ? 0 : length(cols[1])
    x = Vector{Float64}(undef, nr * length(cols))
    for (j, c) in enumerate(cols)
        length(c) == nr || error("interner Fehler: Spalten ungleich lang")
        @inbounds for i in 1:nr
            x[(j - 1) * nr + i] = Float64(c[i])
        end
    end
    return _rb_margsums(x, nr, length(cols), na_rm, false, true)
end

# ── C-Bibliotheken je Betriebssystem (einzige Stelle; RLibm, RFmt nutzen sie) ─
# libm: Linux glibc `libm.so.6` (bitgleich zu R nur hier zugesagt), macOS
# libSystem, Windows die UCRT (`ucrtbase`, hat die C99-Funktionen log1p, expm1,
# lgamma, …; Rückfall `msvcrt`), sonst `libm`. snprintf ruft seit 1.6.0 der C-Kern
# (core/slc_rbase_fmt.cpp). Fehlt ein Symbol, scheitert erst der Aufruf, nie das Laden.
function _pick_lib(cands...)
    for c in cands
        h = Base.Libc.Libdl.dlopen(c, Base.Libc.Libdl.RTLD_LAZY; throw_error = false)
        h === nothing || (Base.Libc.Libdl.dlclose(h); return c)
    end
    return first(cands)
end
const _LIBM = Sys.islinux() ? "libm.so.6" :
              Sys.isapple() ? "/usr/lib/libSystem.B.dylib" :
              Sys.iswindows() ? _pick_lib("ucrtbase", "msvcrt") : _pick_lib("libm.so", "libm")
# C-snprintf (bis 1.5.2 _c_sprintf hier): seit 1.6.0 im C-Kern core/slc_rbase_fmt.cpp

# ── Potenz wie R (R_POW / R_pow) ────────────────────────────────────────────

@inline _libm_pow(x::Float64, y::Float64) = ccall((:pow, _LIBM), Float64, (Float64, Float64), x, y)

"Skalares `x ^ y` wie in R (`x^2` als `x*x`, sonst `pow()` der C-Bibliothek; C-Kern `sl_r_pow1`)."
r_pow(x::Real, y::Real) = _rb_pow1(Float64(x), Float64(y))


@inline function _r_nan2(a::Float64, b::Float64)
    isnan(a) && isna_strict(a) && return a      # NA schlägt NaN
    isnan(b) && return b
    return a
end
"R's `min(a, b)` für zwei Skalare (NA/NaN-Regeln wie R's `rmin`)."
@inline r_min2(a::Float64, b::Float64) = (isnan(a) || isnan(b)) ? _r_nan2(a, b) : (b < a ? b : a)
"R's `max(a, b)` für zwei Skalare."
@inline r_max2(a::Float64, b::Float64) = (isnan(a) || isnan(b)) ? _r_nan2(a, b) : (b > a ? b : a)

# (cpp_min/cpp_max und die NaN-genauen Einzeloperationen nan_add, nan_mul … (0.10.0) sind mit
# den Julia-Ports der geteilten Kerne entfallen; diese rechnen jetzt die C++-Kerne selbst.)

"`cumprod(x)` wie in R (long double; NA/NaN über `handleNaN`; C-Kern)."
r_cumprod(x) = _rb_cumprod(_rbv(_rtext(x, :num)))

"`cummax(x)` wie in R (ab dem ersten NA/NaN über `handleNaN`; C-Kern)."
r_cummax(x) = _rb_cummax(_rbv(_rtext(x, :num)))

"`stats::median(x)` für Zahlen (über `RStats.median`: R's Teilsortierung, Mittel in long double)."
r_median(x; na_rm::Bool = false) = Float64(RStats.median(collect(Float64, x); na_rm = na_rm))

const _DBL_EPS = 2.220446049250313e-16

"`as.numeric(<Zeichenkette>)` wie R (R_strtod mit long double; ungültig → NA)."
function r_as_numeric(s::AbstractString)
    str = String(s)
    # seit 1.6.4 nur ASCII (Entscheidung 27, Befund C-022: Unicode-Leerraum ergab je Sprache etwas anderes, ungültiges
    # UTF-8 bzw. Mehrbytezeichen am Anfang StringIndexError/InvalidCharError); sonst NA wie in Python
    isascii(str) || return NA
    p = 1
    n = ncodeunits(str)
    while p <= n && isspace(str[p]); p += 1; end
    rest(q) = all(isspace, SubString(str, q))
    sign = 1.0
    if p <= n && str[p] in ('-', '+')
        str[p] == '-' && (sign = -1.0)
        p += 1
    end
    tail = SubString(str, p)
    lt = lowercase(tail)
    for (pre, v) in (("nan", NaN), ("infinity", Inf), ("inf", Inf))
        if startswith(lt, pre)
            return rest(p + length(pre)) ? sign * v : NA
        end
    end
    if startswith(strip(String(SubString(str, 1))), "NA") && strip(str) == "NA"
        return NA
    end
    # Zahlteil (dezimal, hexadezimal) in long double über den C-Kern (core/slc_rbase_num.cpp)
    v, used, gt = _rb_strtod_num(str, p)
    (used < 0 || !rest(p + used)) && return NA
    gt && return sign * Inf
    return sign * v
end
