# ─────────────────────────────────────────────────────────────────────────────
# R-kompatible Numerik
#
# Die Funktionen bilden die Akkumulationsreihenfolge und -genauigkeit von R
# exakt nach (long double über F80). NA wird wie in R als NaN mit der
# Nutzlast 1954 dargestellt, sodass NA und NaN unterscheidbar bleiben.
# ─────────────────────────────────────────────────────────────────────────────

"R's `NA_real_`: NaN mit Nutzlast 1954 (signalisierend gespeichert, wie in R)."
const NA = reinterpret(Float64, 0x7FF00000000007A2)

"TRUE nur für R's NA (nicht für NaN) – entspricht `R_IsNA`."
isna_strict(x::Float64) = isnan(x) && (reinterpret(UInt64, x) & 0x00000000FFFFFFFF) == 0x00000000000007A2

const _LD0 = F80(0.0)
const _LD1 = F80(1.0)

# ── NA/NaN in long-double-Summen ───────────────────────────────────────────
# Treffen in einer x87-Operation zwei NaN aufeinander (z. B. `sum(c(NaN, NA))`),
# entscheidet die FPU: ein ruhiges NaN schlägt ein signalisierendes (R's NA
# liegt im Speicher signalisierend vor und wird bei `fadd m64` unverändert
# verglichen), bei zwei ruhigen gewinnt die größere Mantisse. Ob LLVM die
# Hardware-F80 als `fadd m64` (wie gcc in R) oder als `fld` + `faddp` (das NA
# vorher quietet) übersetzt, hängt von der Codeerzeugung ab. Deshalb rechnet
# die schnelle Hardware-Schleife nur, solange kein NaN herauskommt; ist das
# Ergebnis NaN, wird mit der Software-Nachbildung `F80Soft` wiederholt, die die
# Regel für Speicheroperanden fest nachbildet (`F80Soft(x)` lässt NA
# signalisierend, `_ldq_soft` quietet wie `fld`). Kosten: ein `isnan` je Aufruf.
const _HW80 = F80 !== F80Soft

function _r_sum(::Type{T}, x, na_rm::Bool) where {T}
    s = T(0.0)
    @inbounds for v in x
        fv = Float64(v)
        if !na_rm || !isnan(fv)
            s = s + T(fv)
        end
    end
    _gt_dblmax(s) && return Inf
    _lt_negdblmax(s) && return -Inf
    return Float64(s)
end

"`sum(x)` / `sum(x, na.rm = TRUE)` wie in R."
function r_sum(x; na_rm::Bool = false)
    r = _r_sum(F80, x, na_rm)
    (_HW80 && isnan(r)) ? _r_sum(F80Soft, x, na_rm) : r
end

"""
R's `handleNaN` (cum.c): ab dem ersten NaN/NA wird das Ergebnis neu gesetzt –
NA, sobald ein NA vorkam, sonst NaN. R ruft das nach `cumsum`/`cumprod` auf,
wenn die Summe NaN ist; so hängt die Unterscheidung NA/NaN nicht von der
x87-Regel für zwei NaN-Operanden ab (die bei `fadd m64` das ruhige NaN der
Summe gegen ein signalisierendes NA aus dem Speicher gewinnen lässt, nach
einem `fld` dagegen die größere Mantisse – je nach Codeerzeugung).
"""
function _handle_nan!(out::AbstractVector{Float64}, v::AbstractVector{Float64})
    hasNA = false
    hasNaN = false
    @inbounds for i in eachindex(v, out)
        hasNaN = hasNaN || isnan(v[i])
        hasNA = hasNA || (hasNaN && isna_strict(v[i]))
        if hasNA
            out[i] = NA
        elseif hasNaN
            out[i] = NaN
        end
    end
    return out
end

"`cumsum(x)` wie in R (long double; NA/NaN über `handleNaN`)."
function r_cumsum(x)
    out = Vector{Float64}(undef, length(x))
    s = _LD0
    @inbounds for (i, v) in enumerate(x)
        s = s + _ldq(Float64(v))
        out[i] = Float64(s)
    end
    isnan(Float64(s)) && _handle_nan!(out, Float64[Float64(v) for v in x])
    return out
end

function _r_prod(::Type{T}, x, na_rm::Bool) where {T}
    s = T(1.0)
    @inbounds for v in x
        fv = Float64(v)
        if !na_rm || !isnan(fv)
            s = s * T(fv)
        end
    end
    _gt_dblmax(s) && return Inf
    _lt_negdblmax(s) && return -Inf
    return Float64(s)
end

"`prod(x)` wie in R."
function r_prod(x; na_rm::Bool = false)
    r = _r_prod(F80, x, na_rm)
    (_HW80 && isnan(r)) ? _r_prod(F80Soft, x, na_rm) : r
end

_dropnan(x) = Float64[v for v in x if !isnan(Float64(v))]

"`mean(x)` für Doubles wie R's `real_mean` (Summe/n plus Korrekturdurchlauf)."
function r_mean(x; na_rm::Bool = false)
    a = na_rm ? _dropnan(x) : collect(Float64, x)
    r = _r_mean(F80, a)
    (_HW80 && isnan(r)) ? _r_mean(F80Soft, a) : r
end

function _r_mean(::Type{T}, a::Vector{Float64}) where {T}
    n = length(a)
    n == 0 && return NaN
    ln = T(n)
    s = T(0.0)
    @inbounds for v in a
        s = s + T(v)
    end
    finite_s = isfinite(Float64(s))
    if finite_s
        s = s / ln
    else
        s = T(0.0)
        @inbounds for v in a
            s = s + T(v / n)
        end
    end
    if finite_s && isfinite(Float64(s))
        t = T(0.0)
        @inbounds for v in a
            t = t + (T(v) - s)
        end
        s = s + t / ln
    elseif isfinite(Float64(s))
        t = T(0.0)
        @inbounds for v in a
            t = t + (T(v) - s) / ln
        end
        s = s + t
    end
    return Float64(s)
end

"`mean(x)` für Integer-Vektoren wie in R."
function r_mean_int(x)
    n = length(x)
    n == 0 && return NaN
    s = _LD0
    for v in x
        s = s + F80(Int(v))
    end
    return Float64(s / F80(n))
end

"`var(x)` wie R's `cov_complete1` (long double, Mittelwert als double gespeichert)."
function r_var(x; na_rm::Bool = false)
    a = collect(Float64, x)
    if na_rm
        a = _dropnan(a)
    elseif any(isnan, a)
        return NA
    end
    n = length(a)
    n <= 1 && return NA
    ln = F80(n)
    s = _LD0
    @inbounds for v in a
        s = s + F80(v)
    end
    tmp = s / ln
    if isfinite(Float64(tmp))
        s = _LD0
        @inbounds for v in a
            s = s + (F80(v) - tmp)
        end
        tmp = tmp + s / ln
    end
    xm = F80(Float64(tmp))
    s = _LD0
    @inbounds for v in a
        d = F80(v) - xm
        s = s + d * d
    end
    return Float64(s / F80(n - 1))
end

"`sd(x)` wie in R: `sqrt(var(x))`."
r_sd(x; na_rm::Bool = false) = r_sqrt(r_var(x; na_rm = na_rm))

"`sqrt` mit R-Semantik (negativ → NaN statt Fehler)."
r_sqrt(x::Float64) = x < 0 ? NaN : sqrt(x)

"`rowSums(m, na.rm)` für eine Liste gleich langer Spalten (long double je Zeile)."
function r_rowsums(cols::AbstractVector; na_rm::Bool = false)
    out = _r_rowsums(F80, cols, na_rm)
    if _HW80 && any(isnan, out)
        soft = _r_rowsums(F80Soft, cols, na_rm)
        @inbounds for i in eachindex(out)
            isnan(out[i]) && (out[i] = soft[i])
        end
    end
    return out
end

function _r_rowsums(::Type{T}, cols::AbstractVector, na_rm::Bool) where {T}
    n = isempty(cols) ? 0 : length(cols[1])
    acc = fill(T(0.0), n)
    for c in cols
        @inbounds for i in 1:n
            v = Float64(c[i])
            if na_rm && isnan(v)
                v = 0.0
            end
            acc[i] = acc[i] + T(v)
        end
    end
    return Float64[Float64(a) for a in acc]
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

"Skalares `x ^ y` wie in R (`x^2` als `x*x`, sonst `pow()` der C-Bibliothek)."
function r_pow(x::Real, y::Real)
    x = Float64(x); y = Float64(y)
    y == 2.0 && return x * x
    (x == 1.0 || y == 0.0) && return 1.0
    if x == 0.0
        y > 0.0 && return 0.0
        y < 0.0 && return Inf
        return y
    end
    if isfinite(x) && isfinite(y)
        return _libm_pow(x, y)
    end
    (isnan(x) || isnan(y)) && return x + y
    if !isfinite(x)
        if x > 0
            return y < 0.0 ? 0.0 : Inf
        else
            if isfinite(y) && y == floor(y)
                return y < 0.0 ? 0.0 : (_isodd_float(y) ? x : -x)
            end
        end
    end
    if !isfinite(y)
        if x >= 0
            if y > 0
                return x >= 1 ? Inf : 0.0
            else
                return x < 1 ? Inf : 0.0
            end
        end
    end
    return NaN
end

_isodd_float(y::Float64) = abs(y) < 2.0^53 && isodd(Int64(y))

"Elementweises `x ^ y` mit R-Semantik."
r_pow_vec(x, y::Real) = Float64[r_pow(v, y) for v in x]

"`x %% 1` für Doubles wie R's `myfmod(x, 1)`."
function r_mod1(x::Float64)
    q = x / 1.0
    tmp = _ldq(x) - F80(floor(q)) * _LD1
    return Float64(tmp - floor(tmp / _LD1) * _LD1)
end

@inline function _r_nan2(a::Float64, b::Float64)
    isnan(a) && isna_strict(a) && return a      # NA schlägt NaN
    isnan(b) && return b
    return a
end
"R's `min(a, b)` für zwei Skalare (NA/NaN-Regeln wie R's `rmin`)."
@inline r_min2(a::Float64, b::Float64) = (isnan(a) || isnan(b)) ? _r_nan2(a, b) : (b < a ? b : a)
"R's `max(a, b)` für zwei Skalare."
@inline r_max2(a::Float64, b::Float64) = (isnan(a) || isnan(b)) ? _r_nan2(a, b) : (b > a ? b : a)

"`std::min(a, b)` aus C++ (`b < a ? b : a`)."
@inline cpp_min(a::Float64, b::Float64) = b < a ? b : a
"`std::max(a, b)` aus C++ (`a < b ? b : a`)."
@inline cpp_max(a::Float64, b::Float64) = a < b ? b : a

# ── Ergänzungen für die Engine 0.5.0 ────────────────────────────────────────

@inline _libm_exp(x::Float64) = ccall((:exp, _LIBM), Float64, (Float64,), x)
@inline _libm_expm1(x::Float64) = ccall((:expm1, _LIBM), Float64, (Float64,), x)
@inline _libm_log(x::Float64) = ccall((:log, _LIBM), Float64, (Float64,), x)

"`cumprod(x)` wie in R (long double; NA/NaN über `handleNaN`)."
function r_cumprod(x)
    out = Vector{Float64}(undef, length(x))
    s = _LD1
    @inbounds for (i, v) in enumerate(x)
        s = s * _ldq(Float64(v))
        out[i] = Float64(s)
    end
    isnan(Float64(s)) && _handle_nan!(out, Float64[Float64(v) for v in x])
    return out
end

"`cummax(x)` wie in R (NA/NaN pflanzt sich über `max + x` fort)."
function r_cummax(x)
    out = Vector{Float64}(undef, length(x))
    m = -Inf
    @inbounds for (i, v) in enumerate(x)
        fv = Float64(v)
        if isnan(fv) || isnan(m)
            m = m + fv
        else
            m = m > fv ? m : fv
        end
        out[i] = m
    end
    return out
end

"`stats::median(x)` für Zahlen (über `RStats.median`: R's Teilsortierung, Mittel in long double)."
r_median(x; na_rm::Bool = false) = Float64(RStats.median(collect(Float64, x); na_rm = na_rm))

const _DBL_EPS = 2.220446049250313e-16
const _DBL_MAX = 1.7976931348623157e308

"Port von `R_zeroin2` (stats/src/zeroin.c); Rückgabe (Wurzel, Iterationen, Genauigkeit)."
function r_zeroin2(f, ax::Float64, bx::Float64, fa::Float64, fb::Float64, tol::Float64, maxit::Int)
    a, b = ax, bx
    c, fc = a, fa
    maxit_c = maxit + 1
    fa == 0.0 && return (a, 0, 0.0)
    fb == 0.0 && return (b, 0, 0.0)
    while maxit_c != 0
        maxit_c -= 1
        prev_step = b - a
        if abs(fc) < abs(fb)
            a = b; b = c; c = a
            fa = fb; fb = fc; fc = fa
        end
        tol_act = 2 * _DBL_EPS * abs(b) + tol / 2
        new_step = (c - b) / 2
        if abs(new_step) <= tol_act || fb == 0.0
            return (b, maxit - maxit_c, abs(c - b))
        end
        if abs(prev_step) >= tol_act && abs(fa) > abs(fb)
            cb = c - b
            if a == c
                t1 = fb / fa
                p = cb * t1
                q = 1.0 - t1
            else
                q = fa / fc
                t1 = fb / fc
                t2 = fb / fa
                p = t2 * (cb * q * (q - t1) - (b - a) * (t1 - 1.0))
                q = (q - 1.0) * (t1 - 1.0) * (t2 - 1.0)
            end
            if p > 0.0
                q = -q
            else
                p = -p
            end
            if p < (0.75 * cb * q - abs(tol_act * q) / 2) && p < abs(prev_step * q / 2)
                new_step = p / q
            end
        end
        if abs(new_step) < tol_act
            new_step = new_step > 0.0 ? tol_act : -tol_act
        end
        a = b; fa = fb
        b += new_step
        fb = f(b)
        if (fb > 0 && fc > 0) || (fb < 0 && fc < 0)
            c = a; fc = fa
        end
    end
    return (b, -1, abs(c - b))
end

"`stats::uniroot(f, interval, f.lower, f.upper, tol, maxiter)` (extendInt = \"no\")."
function r_uniroot(f, interval; f_lower = nothing, f_upper = nothing, tol::Float64 = _DBL_EPS^0.25, maxiter::Int = 1000)
    lower, upper = minimum(interval), maximum(interval)
    lower < upper || error("lower < upper  is not fulfilled")
    fl = f_lower === nothing ? f(lower) : Float64(f_lower)
    fu = f_upper === nothing ? f(upper) : Float64(f_upper)
    isnan(fl) && error("f.lower = f(lower) is NA")
    isnan(fu) && error("f.upper = f(upper) is NA")
    sign(fl) * sign(fu) <= 0 || error("f() values at end points not of opposite sign")
    function fcn2(x)
        v = Float64(f(x))
        if !isfinite(v)
            if v == -Inf
                @warn "-Inf replaced by maximally negative value"
                return -_DBL_MAX
            end
            @warn "NA/Inf replaced by maximum positive value"
            return _DBL_MAX
        end
        return v
    end
    tr(v) = max(min(v, _DBL_MAX), -_DBL_MAX)
    root, it, prec = r_zeroin2(fcn2, Float64(lower), Float64(upper), tr(fl), tr(fu), tol, maxiter)
    if it < 0
        @warn "_NOT_ converged in $maxiter iterations"
        it = maxiter
    end
    return (root = root, iter = it, estim_prec = prec)
end

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
    if length(tail) > 2 && tail[1] == '0' && tail[2] in ('x', 'X')
        q = p + 2
        ans = _LD0
        while q <= n && (isdigit(str[q]) || str[q] in 'a':'f' || str[q] in 'A':'F')
            ans = F80(16.0) * ans + F80(Float64(parse(Int, str[q]; base = 16)))
            q += 1
        end
        rest(q) || return NA
        return sign * Float64(ans)
    end
    ans = _LD0
    nd = 0
    expn = 0
    q = p
    ten = F80(10.0)
    while q <= n && isdigit(str[q])
        ans = ten * ans + F80(Float64(str[q] - '0')); q += 1; nd += 1
    end
    if q <= n && str[q] == '.'
        q += 1
        while q <= n && isdigit(str[q])
            ans = ten * ans + F80(Float64(str[q] - '0')); q += 1; nd += 1; expn -= 1
        end
    end
    nd == 0 && return NA
    if q <= n && str[q] in ('e', 'E')
        q += 1
        es = 1
        if q <= n && str[q] in ('-', '+')
            str[q] == '-' && (es = -1)
            q += 1
        end
        k = 0
        while q <= n && isdigit(str[q])
            k = k < 9999 ? 10k + (str[q] - '0') : k; q += 1
        end
        expn += es * k
    end
    rest(q) || return NA
    if expn + nd < -300
        for _ in 1:nd
            ans = ans / ten
        end
        expn += nd
    end
    p10 = ten; fac = _LD1
    if expn < -307
        k = -expn
        while k != 0
            (k & 1) != 0 && (fac = fac / p10)
            k >>= 1; p10 = p10 * p10
        end
        ans = ans * fac
    elseif expn < 0
        k = -expn
        while k != 0
            (k & 1) != 0 && (fac = fac * p10)
            k >>= 1; p10 = p10 * p10
        end
        ans = ans / fac
    elseif !_iszero80(ans)
        k = expn
        while k != 0
            (k & 1) != 0 && (fac = fac * p10)
            k >>= 1; p10 = p10 * p10
        end
        ans = ans * fac
    end
    _gt_dblmax(ans) && return sign * Inf
    return sign * Float64(ans)
end
