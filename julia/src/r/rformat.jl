# ─────────────────────────────────────────────────────────────────────────────
# Textausgabe wie R (Engine): sprintf() mit NA/NaN/Inf-Regeln, format() und
# as.character() für Zahlen (formatReal/scientific aus R's format.c, long
# double über F80), deparse() für einfache Werte, round()/signif().
# ─────────────────────────────────────────────────────────────────────────────

const _FMT_CACHE = Dict{String,Printf.Format}()
const _FMT_LOCK = ReentrantLock()
_pf(spec::String) = lock(() -> get!(() -> Printf.Format(spec), _FMT_CACHE, spec), _FMT_LOCK)
_cfmt(spec::String, x) = Printf.format(_pf(spec), x)

_as_float(x::Real) = Float64(x)
_as_float(::Missing) = NA
_as_float(::Nothing) = NA

"Wert als Text wie R's `as.character()` in `%s` (Zahlen 15 Stellen, Datum JJJJ-MM-TT)."
function _as_str(@nospecialize(v))
    v === nothing && return "NULL"
    v === missing && return "NA"
    v isa AbstractString && return String(v)
    v isa AbstractChar && return string(v)
    v isa Bool && return v ? "TRUE" : "FALSE"
    v isa Date && return Dates.format(v, dateformat"yyyy-mm-dd")
    v isa DateTime && return Dates.format(v, dateformat"yyyy-mm-dd HH:MM:SS")
    v isa Real && return r_as_character(v)
    v isa Symbol && return String(v)
    return string(v)
end

function _rspec(flags::String, width::String, prec::Union{Nothing,String}, conv::Char, @nospecialize(x))
    spec = "%" * flags * width * (prec === nothing ? "" : "." * prec)
    if conv == 's'
        return _cfmt(spec * "s", _as_str(x))
    elseif conv in ('d', 'i', 'o', 'x', 'X')
        if x isa Bool
            return _cfmt(spec * conv, Int(x))
        elseif x isa Integer
            return _cfmt(spec * conv, x)
        end
        v = _as_float(x)
        if isnan(v)
            return _cfmt("%" * replace(flags, "0" => "", "+" => "", " " => "") * width * "s", "NA")
        end
        (isfinite(v) && v == trunc(v)) ||
            error("invalid format '" * spec * conv * "'; use format %f, %e, %g or %a for numeric objects")
        return _cfmt(spec * conv, Int64(v))
    elseif conv in ('e', 'E', 'f', 'F', 'g', 'G', 'a', 'A')
        x isa AbstractString && error("invalid format '" * spec * conv * "'; use format %s for character objects")
        v = _as_float(x)
        isfinite(v) && return _cfmt(spec * conv, v)
        sp = occursin(' ', flags)
        s = isnan(v) ? (isna_strict(v) ? (sp ? " NA" : "NA") : (sp ? " NaN" : "NaN")) :
            v > 0 ? (occursin('+', flags) ? "+Inf" : (sp ? " Inf" : "Inf")) : "-Inf"
        return _cfmt("%" * replace(flags, "0" => "", "+" => "", " " => "") * width * "s", s)
    elseif conv == 'c'
        return _cfmt(spec * "c", x)
    end
    error("unrecognised format specification '" * spec * conv * "'")
end

"""
    r_sprintf(fmt, args...)

R's `sprintf()` für skalare Argumente: NA/NaN/Inf in Gleitkommaformaten als Text
(gleiche Breite), ganzzahlige Doubles in `%d`, Zahlen in `%s` über
`as.character()`, `*` für Breite/Genauigkeit.
"""
function r_sprintf(fmt::AbstractString, @nospecialize(args...))
    out = IOBuffer()
    s = String(fmt)
    i = 1
    n = ncodeunits(s)
    k = 0
    while i <= n
        c = s[i]
        if c != '%'
            write(out, c)
            i = nextind(s, i)
            continue
        end
        j = i + 1
        if j <= n && s[j] == '%'
            write(out, '%'); i = j + 1; continue
        end
        f0 = j
        while j <= n && s[j] in ('-', '+', ' ', '0', '#')
            j += 1
        end
        flags = s[f0:j-1]
        width = ""
        if j <= n && s[j] == '*'
            k += 1; width = string(Int(args[k])); j += 1
            if startswith(width, "-")
                flags *= "-"; width = width[2:end]
            end
        else
            w0 = j
            while j <= n && isdigit(s[j]); j += 1; end
            width = s[w0:j-1]
        end
        prec = nothing
        if j <= n && s[j] == '.'
            j += 1
            if j <= n && s[j] == '*'
                k += 1; prec = string(Int(args[k])); j += 1
            else
                p0 = j
                while j <= n && isdigit(s[j]); j += 1; end
                prec = s[p0:j-1]
            end
        end
        # Längenmodifikatoren ignorieren (wie R)
        while j <= n && s[j] in ('l', 'h', 'L', 'q')
            j += 1
        end
        conv = s[j]
        k += 1
        write(out, _rspec(flags, width, prec, conv, args[k]))
        i = j + 1
    end
    return String(take!(out))
end
const rsprintf = r_sprintf

# ── formatReal / scientific (R's format.c) ──────────────────────────────────

# Zehnerpotenzen 1e0 … 1e27 exakt in long double (5^k < 2^63)
const _TBL80 = [F80(Int64(5)^k) * F80(2.0^k) for k in 0:27]
const _KP_MAX = 27

@inline _f80_lt(a::F80, b::F80) = _lt80(a, b)

"`nearbyintl` (Rundung zur nächsten ganzen Zahl, bei .5 zur geraden) für F80."
function _rintl(a::F80)
    isfinite(Float64(a)) || return a
    f = floor(a)
    d = a - f
    h = F80(0.5)
    if _f80_lt(h, d)
        return f + F80(1.0)
    elseif _f80_lt(d, h)
        return f
    end
    # genau .5: gerade wählen
    ff = Float64(f)
    return iseven(Int64(ff)) || abs(ff) >= 2.0^62 ? f : f + F80(1.0)
end

_libm_log10(x::Float64) = ccall((:log10, _LIBM), Float64, (Float64,), x)

"`scientific()`: (neg, kpower, nsig, roundingwidens) für |x| mit `digits` Stellen."
function _scientific(x::Float64, digits::Int)
    x == 0.0 && return (0, 0, 1, false)
    neg, r = x < 0 ? (1, -x) : (0, x)
    if digits >= 16
        s = _cfmt("%#." * string(digits - 1) * "e", r)
        mant, ex = split(s, 'e')
        kpower = parse(Int, ex)
        digs = replace(mant, "." => "")
        i = digits
        while i >= 2 && digs[i] == '0'
            i -= 1
        end
        return (neg, kpower, i, false)
    end
    kp = Int(floor(_libm_log10(r))) - digits + 1
    r_prec = F80(r)
    if abs(kp) <= _KP_MAX
        if kp > 0
            r_prec = r_prec / _TBL80[kp+1]
        elseif kp < 0
            r_prec = r_prec * _TBL80[-kp+1]
        end
    else
        # powl(10, kp): außerhalb des Tabellenbereichs (sehr große/kleine Zahlen) über Doubles
        r_prec = kp > 0 ? r_prec / F80(exp10(Float64(kp))) : r_prec * F80(exp10(Float64(-kp)))
    end
    if _f80_lt(r_prec, _TBL80[digits])
        r_prec = r_prec * F80(10.0)
        kp -= 1
    end
    alpha = Float64(_rintl(r_prec))
    nsig = digits
    for _ in 1:digits
        alpha /= 10.0
        if alpha == floor(alpha)
            nsig -= 1
        else
            break
        end
    end
    if nsig == 0 && digits > 0
        nsig = 1
        kp += 1
    end
    kpower = kp + digits - 1
    rgt = digits - kpower
    rgt = rgt < 0 ? 0 : rgt > _KP_MAX ? _KP_MAX : rgt
    fuzz = 0.5 / Float64(_TBL80[rgt+1])
    rw = kpower > 0 && kpower <= _KP_MAX && _f80_lt(F80(r), _TBL80[kpower+1] - F80(fuzz))
    return (neg, kpower, nsig, rw)
end

"`formatReal()`: gemeinsame Breite w, Nachkommastellen d, Exponentformat e."
function _format_real(xs::AbstractVector{Float64}, digits::Int = 7, nsmall::Int = 0, scipen::Int = 0)
    naflag = nanflag = posinf = neginf = false
    neg = 0
    BIG = 10^9
    mnl = BIG
    mxl = rgt = mxsl = mxns = -BIG
    for x in xs
        if !isfinite(x)
            if isnan(x)
                isna_strict(x) ? (naflag = true) : (nanflag = true)
            elseif x > 0
                posinf = true
            else
                neginf = true
            end
            continue
        end
        neg_i, kpower, nsig, rw = _scientific(x, digits)
        left = kpower + 1
        rw && (left -= 1)
        sleft = neg_i + (left <= 0 ? 1 : left)
        right = nsig - left
        neg_i == 1 && (neg = 1)
        rgt = max(rgt, right)
        mxl = max(mxl, left)
        mnl = min(mnl, left)
        mxsl = max(mxsl, sleft)
        mxns = max(mxns, nsig)
    end
    digits == 0 && (rgt = 0)
    mxl < 0 && (mxsl = 1 + neg)
    rgt < 0 && (rgt = 0)
    wF = mxsl + rgt + (rgt != 0 ? 1 : 0)
    e = (mxl > 100 || mnl <= -99) ? 2 : 1
    if mxns != -BIG
        d = mxns - 1
        w = neg + (d > 0 ? 1 : 0) + d + 4 + e
        if wF <= w + scipen
            e = 0
            if nsmall > rgt
                rgt = nsmall
                wF = mxsl + rgt + (rgt != 0 ? 1 : 0)
            end
            d = rgt
            w = wF
        end
    else
        w = d = e = 0
    end
    naflag && w < 2 && (w = 2)
    nanflag && w < 3 && (w = 3)
    posinf && w < 3 && (w = 3)
    neginf && w < 4 && (w = 4)
    return (w, d, e)
end

function _drop0(s::String)
    m = match(r"^(.*?\.)(\d*)(.*)$", s)
    m === nothing && return s
    head, digs, tail = m.captures[1], rstrip(m.captures[2], '0'), m.captures[3]
    return (isempty(digs) ? head[1:end-1] : head * digs) * tail
end

function _encode_real(x::Float64, w::Int, d::Int, e::Int; drop0::Bool = false)
    x == 0.0 && (x = 0.0)
    if !isfinite(x)
        s = isnan(x) ? (isna_strict(x) ? "NA" : "NaN") : (x > 0 ? "Inf" : "-Inf")
        return lpad(s, w)
    end
    s = if e != 0
        d > 0 ? _cfmt("%#" * string(w) * "." * string(d) * "e", x) : _cfmt("%" * string(w) * "." * string(d) * "e", x)
    else
        _cfmt("%" * string(w) * "." * string(d) * "f", x)
    end
    drop0 && occursin('.', s) && (s = _drop0(s))
    return s
end

function _insert_big_mark(s::String, mark::String)
    m = match(r"^(\s*[-+]?)(\d+)(.*)$", s)
    (m === nothing || length(m.captures[2]) < 4) && return s
    digs = m.captures[2]
    parts = String[]
    i = length(digs)
    while i >= 1
        j = max(1, i - 2)
        pushfirst!(parts, digs[j:i])
        i = j - 1
    end
    return m.captures[1] * join(parts, mark) * m.captures[3]
end

_isnumval(v) = v isa Real && !(v isa Bool)

"""
    r_format(x; digits = 7, nsmall = 0, big_mark = "", scientific = nothing, width = nothing)

`format(x, ...)` wie R für Zahlen-, Wahrheits-, Text- und Datumsvektoren
(gemeinsame Breite). Rückgabe: Vektor der formatierten Elemente.
"""
function r_format(x; digits = nothing, nsmall::Int = 0, big_mark::AbstractString = "",
                  scientific = nothing, width = nothing)
    x === nothing && return String[]
    vals = x isa AbstractVector ? collect(Any, x) : x isa Tuple ? collect(Any, x) : Any[x]
    isempty(vals) && return String[]
    dg = digits === nothing ? 7 : Int(digits)
    scipen = scientific === nothing ? 0 : scientific isa Bool ? (scientific ? -99 : 310) : Int(scientific)
    if all(v -> _isnumval(v) || v === missing || v === nothing, vals) && any(_isnumval, vals)
        fv = Float64[_isnumval(v) ? Float64(v) : NA for v in vals]
        if all(v -> v isa Integer || v === missing || v === nothing, vals)
            out = String[v isa Integer ? string(v) : "NA" for v in vals]
            ww = maximum(length, out)
            out = [lpad(s, ww) for s in out]
        else
            w, d, e = _format_real(fv, dg, nsmall, scipen)
            out = String[_encode_real(v, w, d, e) for v in fv]
        end
        if !isempty(big_mark)
            out = [_insert_big_mark(s, String(big_mark)) for s in out]
            ww = maximum(length, out)
            out = [lpad(s, ww) for s in out]
        end
        width !== nothing && (out = [lpad(s, Int(width)) for s in out])
        return out
    end
    if all(v -> v isa Bool || v === missing || v === nothing, vals)
        out = String[v isa Bool ? (v ? "TRUE" : "FALSE") : "NA" for v in vals]
        ww = maximum(length, out)
        return [lpad(s, ww) for s in out]
    end
    out = String[v === missing || v === nothing ? "NA" : _as_str(v) for v in vals]
    ww = max(width === nothing ? 0 : Int(width), maximum(length, out))
    return [rpad(s, ww) for s in out]
end

"`format(x)` für einen einzelnen Wert."
function r_format1(x; kw...)
    r = r_format(x; kw...)
    return isempty(r) ? "character(0)" : r[1]
end

"`as.character(x)` für eine Zahl wie R (15 signifikante Stellen, ohne Endnullen)."
function r_as_character(x)
    x === missing && return "NA"
    x === nothing && return "NULL"
    x isa Bool && return x ? "TRUE" : "FALSE"
    x isa Integer && abs(x) < 2^31 && return string(x)
    xf = Float64(x)
    isnan(xf) && return isna_strict(xf) ? "NA" : "NaN"
    isinf(xf) && return xf > 0 ? "Inf" : "-Inf"
    w, d, e = _format_real([xf], 15, 0, 0)
    return _encode_real(xf, 0, d, e; drop0 = true)
end

"`paste(deparse(x), collapse = \"\")` für einfache Werte."
function r_deparse(@nospecialize(x))
    one(v) = v === nothing || v === missing ? "NA" :
             v isa AbstractString ? "\"" * replace(String(v), "\\" => "\\\\", "\"" => "\\\"") * "\"" :
             v isa Bool ? (v ? "TRUE" : "FALSE") :
             v isa Date ? "\"" * _as_str(v) * "\"" :
             v isa Integer ? string(v) :
             v isa Real ? (isnan(v) ? (isna_strict(Float64(v)) ? "NA" : "NaN") : isinf(v) ? (v > 0 ? "Inf" : "-Inf") :
                           (r = _format_real([Float64(v)], 15, 0, 0); _encode_real(Float64(v), r...))) :
             v isa Symbol ? String(v) : repr(v)
    x === nothing && return "NULL"
    if x isa AbstractDict || x isa NamedTuple || x isa AbstractVector{<:Pair}
        ps = x isa NamedTuple ? collect(pairs(x)) : collect(x)
        isempty(ps) && return "list()"
        return "list(" * join((string(k) * " = " * r_deparse(v) for (k, v) in ps), ", ") * ")"
    end
    if x isa AbstractVector || x isa Tuple
        vals = collect(Any, x)
        isempty(vals) && return x isa AbstractVector{<:Real} ? "numeric(0)" : "NULL"
        any(v -> v isa Union{AbstractVector,Tuple,AbstractDict,NamedTuple}, vals) &&
            return "list(" * join((r_deparse(v) for v in vals), ", ") * ")"
        # R (deparse.c): sind alle Elemente eines double-Vektors NA (nicht NaN), heißt jedes NA_real_
        # (bzw. NA_character_ bei Zeichenvektoren), sonst NA
        if all(v -> v isa AbstractFloat && isna_strict(Float64(v)), vals)
            length(vals) == 1 && return "NA_real_"
            return "c(" * join(fill("NA_real_", length(vals)), ", ") * ")"
        elseif x isa AbstractVector && nonmissingtype(eltype(x)) <: AbstractString && all(ismissing, vals)
            length(vals) == 1 && return "NA_character_"
            return "c(" * join(fill("NA_character_", length(vals)), ", ") * ")"
        end
        length(vals) == 1 && return one(vals[1])
        return "c(" * join((one(v) for v in vals), ", ") * ")"
    end
    x isa AbstractFloat && isna_strict(Float64(x)) && return "NA_real_"
    return one(x)
end

# ── Runden ──────────────────────────────────────────────────────────────────

"R's `R_pow_di` (wiederholtes Quadrieren wie in R's arithmetic.c)."
function _pow_di(x::Float64, n::Int)
    xn = 1.0
    isnan(x) && return x
    if n != 0
        isfinite(x) || return r_pow(x, Float64(n))
        is_neg = n < 0
        is_neg && (n = -n)
        while true
            (n & 1) != 0 && (xn *= x)
            n >>= 1
            n != 0 || break
            x *= x
        end
        is_neg && (xn = 1.0 / xn)
    end
    return xn
end

"R's `round(x, digits)` (Algorithmus seit R 4.0.0, nmath/fround.c)."
function r_round(x::Real, digits::Real = 0)
    x = Float64(x); digits = Float64(digits)
    (isnan(x) || isnan(digits)) && return x + digits
    (!isfinite(x) || digits > 323 || x == 0.0) && return x
    digits < -308 && return 0.0
    digits == 0 && return round(x, RoundNearest)
    dig = Int(floor(digits + 0.5))
    sgn = 1.0
    if x < 0.0
        sgn = -1.0; x = -x
    end
    l10x = 0.301029995663981195213738894724 * (0.5 + exponent(x))
    l10x + dig > 15 && return sgn * x
    if dig <= 308
        pow10 = _pow_di(10.0, dig)
        x10 = x * pow10
        i10 = floor(x10)
        xd = i10 / pow10
        xu = ceil(x10) / pow10
    else
        p10 = _pow_di(10.0, dig - 308)
        pow10 = _pow_di(10.0, 308)
        x10 = (x * pow10) * p10
        i10 = floor(x10)
        xd = i10 / pow10 / p10
        xu = ceil(x10) / pow10 / p10
    end
    du = xu - x
    dd = x - xd
    return sgn * ((du < dd || (du == dd && rem(i10, 2.0) == 1)) ? xu : xd)
end

"R's `signif(x, digits)` (nmath/fprec.c)."
function r_signif(x::Real, digits::Real = 6)
    x = Float64(x); digits = Float64(digits)
    max10e = 308
    (isnan(x) || isnan(digits)) && return x + digits
    isfinite(x) || return x
    if !isfinite(digits)
        digits > 0 && return x
        digits = 1.0
    end
    x == 0 && return x
    dig = Int(round(digits))
    dig > 22 && return x
    dig < 1 && (dig = 1)
    sgn = 1.0
    if x < 0.0
        sgn = -sgn; x = -x
    end
    l10 = _libm_log10(x)
    e10 = Int(dig - 1 - floor(l10))
    if abs(l10) < max10e - 2
        p10 = 1.0
        if e10 > max10e
            p10 = _pow_di(10.0, e10 - max10e)
            e10 = max10e
        end
        if e10 > 0
            pow10 = _pow_di(10.0, e10)
            return sgn * (round((x * pow10) * p10, RoundNearest) / pow10) / p10
        end
        pow10 = _pow_di(10.0, -e10)
        return sgn * (round(x / pow10, RoundNearest) * pow10)
    end
    do_round = max10e - l10 >= _pow_di(10.0, -dig)
    e2 = dig + (e10 > 0 ? 1 : -1) * 22
    p10 = _pow_di(10.0, e2)
    x *= p10
    P10 = _pow_di(10.0, e10 - e2)
    x *= P10
    do_round && (x += 0.5)
    x = floor(x) / p10
    return sgn * x / P10
end

"`format(x, digits = d)` für einen Skalar wie R's `formatReal`."
r_format_digits(x::Real, digits::Int = 7) = r_format1(Float64(x); digits = digits)
