# ─────────────────────────────────────────────────────────────────────────────
# F80: exakte Software-Nachbildung (F80Soft) von x87-`long double` (80 Bit Extended)
#
# R akkumuliert sum(), mean(), var(), cumsum(), prod() und rowSums() intern mit
# `long double`; auf x86-64 ist das das x87-Format mit 64-Bit-Mantisse. Julia
# kennt diesen Typ nicht. F80Soft bildet Addition, Subtraktion, Multiplikation,
# Division und die Rundung nach Float64 bitgenau nach (Round-to-Nearest-Even
# auf 64 Mantissenbits, danach eine zweite Rundung auf 53 Bits beim Zurück-
# wandeln – genau wie die Hardware).
#
# Darstellung endlicher Werte: Wert = m * 2^(e - 63), m mit gesetztem Bit 63.
# Der Exponentenbereich ist unbeschränkt (Int32); Unterlauf im Extended-Format
# (< 2^-16382) kommt in der Praxis nicht vor.
# ─────────────────────────────────────────────────────────────────────────────

const _ZERO = 0x00
const _FIN = 0x01
const _INF = 0x02
const _NAN = 0x03

struct F80Soft
    m::UInt64     # Mantisse (bei NaN: die Float64-Bits, gequietet)
    e::Int32      # Exponent
    neg::Bool
    cls::UInt8
end

const _QUIET = 0x0008000000000000
const _FRAC = 0x000FFFFFFFFFFFFF
# x87 "real indefinite" (Ergebnis ungültiger Operationen), als Float64 gesehen
const _INDEF_SOFT = F80Soft(0xFFF8000000000000, Int32(0), true, _NAN)

F80Soft(x::F80Soft) = x

function F80Soft(x::Float64)
    b = reinterpret(UInt64, x)
    neg = (b >> 63) == 1
    ex = Int((b >> 52) & 0x7ff)
    fr = b & _FRAC
    if ex == 0x7ff
        # NaN: Bits unverändert (ein signalisierendes NaN wie R's NA bleibt signalisierend)
        return fr == 0 ? F80Soft(UInt64(0), Int32(0), neg, _INF) : F80Soft(b, Int32(0), neg, _NAN)
    elseif ex == 0
        fr == 0 && return F80Soft(UInt64(0), Int32(0), neg, _ZERO)
        s = leading_zeros(fr)
        return F80Soft(fr << s, Int32(-1011 - s), neg, _FIN)
    else
        return F80Soft((fr | 0x0010000000000000) << 11, Int32(ex - 1023), neg, _FIN)
    end
end

function F80Soft(i::Integer)
    i == 0 && return F80Soft(UInt64(0), Int32(0), false, _ZERO)
    neg = i < 0
    u = neg ? UInt64(-(Int128(i))) : UInt64(i)
    s = leading_zeros(u)
    return F80Soft(u << s, Int32(63 - s), neg, _FIN)
end

const _EMAX = 16383     # größter Exponent im Extended-Format
const _EMIN = -16382    # kleinster normaler Exponent

# Rundung im Bereich der Extended-Denormals (Wert < 2^-16382).
function _round_denormal(neg::Bool, e::Int, S::UInt128)
    sh = 63 + (_EMIN - e)
    sh >= 128 && return F80Soft(UInt64(0), Int32(0), neg, _ZERO)
    mant = S >> sh
    rem = S & ((UInt128(1) << sh) - 1)
    half = UInt128(1) << (sh - 1)
    if rem > half || (rem == half && isodd(mant))
        mant += 1
    end
    mant == 0 && return F80Soft(UInt64(0), Int32(0), neg, _ZERO)
    mu = mant % UInt64
    s = leading_zeros(mu)
    return F80Soft(mu << s, Int32(_EMIN - s), neg, _FIN)
end

# Rundet S (führendes Bit an Position 126, Wert = S * 2^(e-126)) auf 64 Bits.
@inline function _round64(neg::Bool, e::Int, S::UInt128)
    e < _EMIN && return _round_denormal(neg, e, S)
    m = (S >> 63) % UInt64
    rem = S & ((UInt128(1) << 63) - 1)
    half = UInt128(1) << 62
    if rem > half || (rem == half && isodd(m))
        m += one(UInt64)
        if m == 0
            m = 0x8000000000000000
            e += 1
        end
    end
    e > _EMAX && return F80Soft(UInt64(0), Int32(0), neg, _INF)
    return F80Soft(m, Int32(e), neg, _FIN)
end

@inline _quiet(a::F80Soft) = F80Soft(a.m | _QUIET, a.e, a.neg, a.cls)

# NaN-Auswahl wie die x87-FPU: Ein ruhiges NaN schlägt ein signalisierendes
# (R's NA liegt im Speicher signalisierend vor); bei zwei gleichartigen NaNs
# gewinnt die größere Mantisse, bei Gleichstand die positive.
@inline function _nanprop(a::F80Soft, b::F80Soft)
    if a.cls == _NAN && b.cls == _NAN
        qa = (a.m & _QUIET) != 0
        qb = (b.m & _QUIET) != 0
        qa && !qb && return _quiet(a)
        qb && !qa && return _quiet(b)
        fa, fb = (a.m | _QUIET) & _FRAC, (b.m | _QUIET) & _FRAC
        fa == fb && return _quiet((a.m >> 63) == 0 ? a : b)
        return _quiet(fb > fa ? b : a)
    end
    return _quiet(a.cls == _NAN ? a : b)
end

@inline _negate(a::F80Soft) = a.cls == _NAN ? a : F80Soft(a.m, a.e, !a.neg, a.cls)

function Base.:+(a::F80Soft, b::F80Soft)
    if a.cls == _NAN || b.cls == _NAN
        return _nanprop(a, b)
    end
    if a.cls == _INF
        return (b.cls == _INF && a.neg != b.neg) ? _INDEF_SOFT : a
    end
    b.cls == _INF && return b
    if a.cls == _ZERO
        return b.cls == _ZERO ? F80Soft(UInt64(0), Int32(0), a.neg & b.neg, _ZERO) : b
    end
    b.cls == _ZERO && return a
    # |a| >= |b| herstellen
    if a.e < b.e || (a.e == b.e && a.m < b.m)
        a, b = b, a
    end
    d = Int(a.e) - Int(b.e)
    A = UInt128(a.m) << 63
    B = UInt128(b.m) << 63
    if d > 0
        if d >= 127
            B = UInt128(1)
        else
            lost = (B & ((UInt128(1) << d) - 1)) != 0
            B = (B >> d) | UInt128(lost)
        end
    end
    e = Int(a.e)
    if a.neg == b.neg
        S = A + B
        if (S >> 127) != 0
            S = (S >> 1) | (S & 1)
            e += 1
        end
    else
        S = A - B
        S == 0 && return F80Soft(UInt64(0), Int32(0), false, _ZERO)
        sh = leading_zeros(S) - 1
        if sh > 0
            S <<= sh
            e -= sh
        end
    end
    return _round64(a.neg, e, S)
end

Base.:-(a::F80Soft, b::F80Soft) = a + _negate(b)
Base.:-(a::F80Soft) = _negate(a)

function Base.:*(a::F80Soft, b::F80Soft)
    if a.cls == _NAN || b.cls == _NAN
        return _nanprop(a, b)
    end
    neg = a.neg != b.neg
    if a.cls == _INF || b.cls == _INF
        (a.cls == _ZERO || b.cls == _ZERO) && return _INDEF_SOFT
        return F80Soft(UInt64(0), Int32(0), neg, _INF)
    end
    (a.cls == _ZERO || b.cls == _ZERO) && return F80Soft(UInt64(0), Int32(0), neg, _ZERO)
    P = UInt128(a.m) * UInt128(b.m)
    e = Int(a.e) + Int(b.e)
    if (P >> 127) != 0
        P = (P >> 1) | (P & 1)
        e += 1
    end
    return _round64(neg, e, P)
end

function Base.:/(a::F80Soft, b::F80Soft)
    if a.cls == _NAN || b.cls == _NAN
        return _nanprop(a, b)
    end
    neg = a.neg != b.neg
    if a.cls == _INF
        return b.cls == _INF ? _INDEF_SOFT : F80Soft(UInt64(0), Int32(0), neg, _INF)
    end
    b.cls == _INF && return F80Soft(UInt64(0), Int32(0), neg, _ZERO)
    if b.cls == _ZERO
        return a.cls == _ZERO ? _INDEF_SOFT : F80Soft(UInt64(0), Int32(0), neg, _INF)
    end
    a.cls == _ZERO && return F80Soft(UInt64(0), Int32(0), neg, _ZERO)
    mb = UInt128(b.m)
    N = UInt128(a.m) << 64
    q = N ÷ mb
    r = N - q * mb
    r62 = r << 62
    q2 = r62 ÷ mb
    r2 = r62 - q2 * mb
    S = (q << 62) | q2
    e = Int(a.e) - Int(b.e)
    if (S >> 126) == 0
        S <<= 1
        e -= 1
    end
    S |= UInt128(r2 != 0)
    return _round64(neg, e, S)
end

function Base.Float64(a::F80Soft)
    a.cls == _ZERO && return a.neg ? -0.0 : 0.0
    a.cls == _INF && return a.neg ? -Inf : Inf
    a.cls == _NAN && return reinterpret(Float64, a.m | _QUIET)
    sgn = a.neg ? 0x8000000000000000 : 0x0000000000000000
    e = Int(a.e)
    m = a.m
    e > 1023 && return a.neg ? -Inf : Inf
    if e >= -1022
        mant = m >> 11
        rem = m & 0x7ff
        if rem > 0x400 || (rem == 0x400 && isodd(mant))
            mant += 1
            if mant == (UInt64(1) << 53)
                mant = UInt64(1) << 52
                e += 1
                e > 1023 && return a.neg ? -Inf : Inf
            end
        end
        return reinterpret(Float64, sgn | (UInt64(e + 1023) << 52) | (mant & _FRAC))
    end
    sh = 11 + (-1022 - e)
    sh >= 128 && return a.neg ? -0.0 : 0.0
    M = UInt128(m)
    mant = M >> sh
    rem = M & ((UInt128(1) << sh) - 1)
    half = UInt128(1) << (sh - 1)
    if rem > half || (rem == half && isodd(mant))
        mant += 1
    end
    return reinterpret(Float64, sgn | (mant % UInt64))
end

Base.convert(::Type{Float64}, a::F80Soft) = Float64(a)

const _DBL_MAX_M = 0xFFFFFFFFFFFFF800   # DBL_MAX als F80Soft-Mantisse (e = 1023)

"`x > DBL_MAX` in long double (für R's sum()/prod())."
function _gt_dblmax(a::F80Soft)
    a.neg && return false
    a.cls == _INF && return true
    a.cls != _FIN && return false
    return a.e > 1023 || (a.e == 1023 && a.m > _DBL_MAX_M)
end

"`x < -DBL_MAX` in long double."
_lt_negdblmax(a::F80Soft) = a.neg && _gt_dblmax(F80Soft(a.m, a.e, false, a.cls))

"`floorl()` für F80Soft (exakt)."
function Base.floor(a::F80Soft)
    a.cls != _FIN && return a
    e = Int(a.e)
    e >= 63 && return a
    if e < 0
        return a.neg ? F80Soft(-1) : F80Soft(UInt64(0), Int32(0), false, _ZERO)
    end
    fb = 63 - e
    ip = (a.m >> fb) << fb
    frac = a.m != ip
    if !a.neg || !frac
        return ip == 0 ? F80Soft(UInt64(0), Int32(0), a.neg, _ZERO) : F80Soft(ip, a.e, a.neg, _FIN)
    end
    # negativ mit Nachkommaanteil: Betrag aufrunden
    U = UInt128(ip) + (UInt128(1) << fb)
    if (U >> 64) != 0
        return F80Soft(0x8000000000000000, Int32(e + 1), true, _FIN)
    end
    return F80Soft(U % UInt64, a.e, true, _FIN)
end

"Quietet ein NaN (wie ein `fld` aus dem Speicher)."
_ldq_soft(x::Float64) = isnan(x) ? F80Soft(reinterpret(Float64, reinterpret(UInt64, x) | _QUIET)) : F80Soft(x)

"`a < b` in long double."
function _lt80(a::F80Soft, b::F80Soft)
    d = a - b
    return d.cls == _INF ? d.neg : (d.cls == _FIN && d.neg)
end
_iszero80(a::F80Soft) = a.cls == _ZERO
"`sqrtl()` (korrekt gerundet auf 64 Mantissenbits)."
function Base.sqrt(a::F80Soft)
    x = Float64(a)
    (a.cls == _NAN || a.cls == _ZERO) && return a
    a.neg && return F80Soft(NaN)
    a.cls == _INF && return a
    r = setprecision(BigFloat, 64) do
        sqrt(BigFloat(a.m) * BigFloat(2)^(Int(a.e) - 63))
    end
    m, e = frexp(r)                       # r = m * 2^e, 0.5 <= m < 1
    mant = UInt64(BigInt(ldexp(m, 64)))
    return F80Soft(mant, Int32(e - 1), false, _FIN)
end

# ─────────────────────────────────────────────────────────────────────────────
# Auf x86-64 rechnet F80 direkt mit dem x87-Format der Hardware (LLVM-Typ
# x86_fp80 über llvmcall): bitgleich zur Software-Fassung, aber ~50× schneller.
# Andere Plattformen nutzen die Software-Nachbildung F80Soft.
# ─────────────────────────────────────────────────────────────────────────────
if Sys.ARCH === :x86_64
    @doc "80-Bit `long double` (x87, Hardware über LLVM x86_fp80)."
    primitive type F80 80 end
    @inline F80(x::Float64) = Base.llvmcall("""%b = fpext double %0 to x86_fp80
    %r = bitcast x86_fp80 %b to i80
    ret i80 %r""", F80, Tuple{Float64}, x)
    @inline F80(x::Int64) = Base.llvmcall("""%b = sitofp i64 %0 to x86_fp80
    %r = bitcast x86_fp80 %b to i80
    ret i80 %r""", F80, Tuple{Int64}, x)
    F80(x::Integer) = F80(Int64(x))
    F80(x::F80) = x
    F80(x::Real) = F80(Float64(x))
    @inline Base.Float64(x::F80) = Base.llvmcall("""%a = bitcast i80 %0 to x86_fp80
    %r = fptrunc x86_fp80 %a to double
    ret double %r""", Float64, Tuple{F80}, x)
    for (op, ins) in ((:+, "fadd"), (:-, "fsub"), (:*, "fmul"), (:/, "fdiv"))
        @eval @inline Base.$op(x::F80, y::F80) = Base.llvmcall($("""%a = bitcast i80 %0 to x86_fp80
        %b = bitcast i80 %1 to x86_fp80
        %c = $ins x86_fp80 %a, %b
        %r = bitcast x86_fp80 %c to i80
        ret i80 %r"""), F80, Tuple{F80,F80}, x, y)
    end
    @inline Base.:-(x::F80) = Base.llvmcall("""%a = bitcast i80 %0 to x86_fp80
    %c = fneg x86_fp80 %a
    %r = bitcast x86_fp80 %c to i80
    ret i80 %r""", F80, Tuple{F80}, x)
    for (fn, intr) in ((:floor, "floor"), (:sqrt, "sqrt"))
        @eval Base.$fn(x::F80) = Base.llvmcall(($("""declare x86_fp80 @llvm.$intr.f80(x86_fp80)
        define i80 @entry(i80 %0) #0 {
        %a = bitcast i80 %0 to x86_fp80
        %c = call x86_fp80 @llvm.$intr.f80(x86_fp80 %a)
        %r = bitcast x86_fp80 %c to i80
        ret i80 %r
        }
        attributes #0 = { alwaysinline }"""), "entry"), F80, Tuple{F80}, x)
    end
    for (fn, pred) in ((:_lt80, "olt"), (:_eq80, "oeq"))
        @eval @inline $fn(x::F80, y::F80) = Base.llvmcall($("""%a = bitcast i80 %0 to x86_fp80
        %b = bitcast i80 %1 to x86_fp80
        %c = fcmp $pred x86_fp80 %a, %b
        %r = zext i1 %c to i8
        ret i8 %r"""), Bool, Tuple{F80,F80}, x, y)
    end
    _iszero80(a::F80) = _eq80(a, F80(0.0))
    Base.convert(::Type{Float64}, a::F80) = Float64(a)
    Base.show(io::IO, a::F80) = print(io, "F80(", Float64(a), ")")
    const _DBL_MAX80 = F80(floatmax(Float64))
    "`x > DBL_MAX` in long double (für R's sum()/prod())."
    _gt_dblmax(a::F80) = _lt80(_DBL_MAX80, a)
    "`x < -DBL_MAX` in long double."
    _lt_negdblmax(a::F80) = _lt80(a, -_DBL_MAX80)
    "Lädt einen Double nach long double (die Hardware quietet NaN wie `fld`)."
    _ldq(x::Float64) = F80(x)

    # ── Kompatibilitätsschicht: Felder m, e, neg, cls wie die Software-Struktur ──
    @inline _bits80(x::F80) = Base.llvmcall("""%r = zext i80 %0 to i128
    ret i128 %r""", UInt128, Tuple{F80}, x)
    @inline _from_bits80(b::UInt128) = Base.llvmcall("""%r = trunc i128 %0 to i80
    ret i80 %r""", F80, Tuple{UInt128}, b)
    "Hardware-F80 → Software-Darstellung (Felder m, e, neg, cls)."
    function _soft(a::F80)
        b = _bits80(a)
        mant = b % UInt64
        ex = Int((b >> 64) & 0x7fff)
        neg = ((b >> 79) & 1) == 1
        if ex == 0x7fff
            (mant << 1) == 0 && return F80Soft(UInt64(0), Int32(0), neg, _INF)
            return F80Soft(reinterpret(UInt64, Float64(a)), Int32(0), neg, _NAN)
        elseif ex == 0
            mant == 0 && return F80Soft(UInt64(0), Int32(0), neg, _ZERO)
            sh = leading_zeros(mant)
            return F80Soft(mant << sh, Int32(-16382 - sh), neg, _FIN)
        end
        return F80Soft(mant, Int32(ex - 16383), neg, _FIN)
    end
    "Software-Darstellung → Hardware-F80."
    function _hard(s::F80Soft)
        s.cls == _ZERO && return F80(s.neg ? -0.0 : 0.0)
        s.cls == _INF && return F80(s.neg ? -Inf : Inf)
        s.cls == _NAN && return F80(reinterpret(Float64, s.m))
        sg = s.neg ? (UInt128(1) << 79) : UInt128(0)
        E = Int(s.e) + 16383
        E > 0x7ffe && return F80(s.neg ? -Inf : Inf)
        if E >= 1
            return _from_bits80(sg | (UInt128(E) << 64) | UInt128(s.m))
        end
        sh = 1 - E
        sh >= 64 && return F80(s.neg ? -0.0 : 0.0)
        return _from_bits80(sg | UInt128(s.m >> sh))
    end
    F80(m::UInt64, e::Int32, neg::Bool, cls::UInt8) = _hard(F80Soft(m, e, neg, cls))
    F80(s::F80Soft) = _hard(s)
    function Base.getproperty(a::F80, f::Symbol)
        f in (:m, :e, :neg, :cls) || error("type F80 has no field $f")
        return getfield(_soft(a), f)
    end
    Base.propertynames(::F80, private::Bool = false) = (:m, :e, :neg, :cls)
    const _INDEF = _hard(_INDEF_SOFT)
else
    const F80 = F80Soft
    _ldq(x::Float64) = _ldq_soft(x)
    const _INDEF = _INDEF_SOFT
    _soft(a::F80Soft) = a
    _hard(a::F80Soft) = a
end
