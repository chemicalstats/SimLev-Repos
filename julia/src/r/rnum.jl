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
# core/slc_rbase*.c (r/rbase_c.jl), auch %% und R_strtod (slc_rbase_num.c). NA wird wie in R als NaN mit der
# Nutzlast 1954 dargestellt, sodass NA und NaN unterscheidbar bleiben.
# ─────────────────────────────────────────────────────────────────────────────

"R's `NA_real_`: NaN mit Nutzlast 1954 (signalisierend gespeichert, wie in R)."
const NA = reinterpret(Float64, 0x7FF00000000007A2)

"TRUE nur für R's NA (nicht für NaN) – entspricht `R_IsNA`."
isna_strict(x::Float64) = isnan(x) && (reinterpret(UInt64, x) & 0x00000000FFFFFFFF) == 0x00000000000007A2

# ── Summen, Mittel, Varianz, Kumulationen (C-Kerne core/slc_rbase.c) ─────
# R akkumuliert in long double; die C-Kerne tun dasselbe (x87 auf x86-64, gegen R bitgleich geprüft)
# und sind dieselbe Implementierung wie in Python. Die frühere Nachbildung über F80/F80Soft mit der
# x87-Regel für zwei NaN-Operanden entfällt hier.

"`sum(x)` / `sum(x, na.rm = TRUE)` wie in R."
r_sum(x; na_rm::Bool = false) = _rb_sum(_rbv(x), na_rm)

"`cumsum(x)` wie in R (long double; NA/NaN über `handleNaN`)."
r_cumsum(x) = _rb_cumsum(_rbv(x))

"`prod(x)` wie in R."
r_prod(x; na_rm::Bool = false) = _rb_prod(_rbv(x), na_rm)

_dropnan(x) = Float64[v for v in x if !isnan(Float64(v))]

"`mean(x)` für Doubles wie R's `real_mean` (Summe/n plus Korrekturdurchlauf)."
r_mean(x; na_rm::Bool = false) = _rb_mean(na_rm ? _dropnan(x) : _rbv(x))

"`mean(x)` für Integer-Vektoren wie in R."
r_mean_int(x) = _rb_mean_int(Int64[Int64(v) for v in x])

"`var(x)` wie R (long double, Mittelwert als double gespeichert)."
function r_var(x; na_rm::Bool = false)
    a = _rbv(x)
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
# lgamma, …; Rückfall `msvcrt`), sonst `libm`. snprintf: glibc `libc.so.6`,
# macOS libSystem, Windows `msvcrt` (`_snprintf`; die UCRT exportiert kein
# `snprintf`). Fehlt ein Symbol, scheitert erst der Aufruf, nie das Laden.
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
const _LIBC = Sys.islinux() ? "libc.so.6" :
              Sys.isapple() ? "/usr/lib/libSystem.B.dylib" :
              Sys.iswindows() ? "msvcrt" : _pick_lib("libc.so", "libc")
const _SNPRINTF = Sys.iswindows() ? :_snprintf : :snprintf

# C `snprintf(buf, n, fmt, args...)` für die benötigten Argumentmuster
const _CTYPE = Dict(Float64 => :Cdouble, Int32 => :Cint, String => :Cstring)
for sig in ((Float64,), (Int32,), (String,), (Int32, Int32, Float64), (Int32, Int32), (Int32, Float64))
    nm = [Symbol(:a, i) for i in eachindex(sig)]
    targs = [:($(nm[i])::$(sig[i])) for i in eachindex(sig)]
    cargs = [:($(nm[i])::$(_CTYPE[sig[i]])) for i in eachindex(sig)]
    call = Expr(:call, Expr(:., :_LIBC, QuoteNode(_SNPRINTF)), Expr(:parameters, cargs...),
                :(buf::Ptr{UInt8}), :(nb::Csize_t), :(fmt::Cstring))
    @eval _c_snprintf(buf::Vector{UInt8}, nb::Int, fmt::String, $(targs...)) =
        $(Expr(:macrocall, Symbol("@ccall"), LineNumberNode(@__LINE__, Symbol(@__FILE__)), Expr(:(::), call, :Cint)))
end

"`sprintf(fmt, args...)` über C-`snprintf` (Puffer wächst bei Bedarf; Windows: `_snprintf` liefert -1)."
function _c_sprintf(fmt::String, args...)
    nb = 128
    for a in args
        a isa String && (nb += ncodeunits(a))
    end
    while true
        buf = Vector{UInt8}(undef, nb)
        n = Int(_c_snprintf(buf, nb, fmt, args...))
        0 <= n < nb && return String(resize!(buf, n))
        nb = n >= 0 ? n + 1 : 2nb
        nb > (1 << 26) && error("snprintf: Formatierung von \"$fmt\" fehlgeschlagen")
    end
end

# ── Potenz wie R (R_POW / R_pow) ────────────────────────────────────────────

@inline _libm_pow(x::Float64, y::Float64) = ccall((:pow, _LIBM), Float64, (Float64, Float64), x, y)

"Skalares `x ^ y` wie in R (`x^2` als `x*x`, sonst `pow()` der C-Bibliothek; C-Kern `sl_r_pow1`)."
r_pow(x::Real, y::Real) = _rb_pow1(Float64(x), Float64(y))

"Elementweises `x ^ y` mit R-Semantik (C-Kern `sl_r_pow`)."
r_pow_vec(x, y::Real) = _rb_pow(_rbv(x), Float64(y))

"`x %% 1` für Doubles wie R's `myfmod(x, 1)`."
r_mod1(x::Float64) = _rb_fmod_ld(x, 1.0)   # C-Kern (core/slc_rbase_num.c)

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

# ── Ergänzungen für die Engine 0.5.0 ────────────────────────────────────────

@inline _libm_exp(x::Float64) = ccall((:exp, _LIBM), Float64, (Float64,), x)
@inline _libm_expm1(x::Float64) = ccall((:expm1, _LIBM), Float64, (Float64,), x)
@inline _libm_log(x::Float64) = ccall((:log, _LIBM), Float64, (Float64,), x)

"`cumprod(x)` wie in R (long double; NA/NaN über `handleNaN`; C-Kern)."
r_cumprod(x) = _rb_cumprod(_rbv(x))

"`cummax(x)` wie in R (ab dem ersten NA/NaN über `handleNaN`; C-Kern)."
r_cummax(x) = _rb_cummax(_rbv(x))

"`stats::median(x)` für Zahlen (über `RStats.median`: R's Teilsortierung, Mittel in long double)."
r_median(x; na_rm::Bool = false) = Float64(RStats.median(collect(Float64, x); na_rm = na_rm))

const _DBL_EPS = 2.220446049250313e-16
const _DBL_MAX = 1.7976931348623157e308

"`as.numeric(<Zeichenkette>)` wie R (R_strtod mit long double; ungültig → NA)."
function r_as_numeric(s::AbstractString)
    str = String(s)
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
    # Zahlteil (dezimal, hexadezimal) in long double über den C-Kern (core/slc_rbase_num.c)
    v, used, gt = _rb_strtod_num(str, p)
    (used < 0 || !rest(p + used)) && return NA
    gt && return sign * Inf
    return sign * v
end
