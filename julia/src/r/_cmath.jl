# C-Semantik für die nmath-Portierung (in `RNmath` eingebunden).
#
# libm-Aufrufe über glibc (`SimLev.RLibm.c_*`) mit C-Randwerten, Konstanten
# aus Rmath.h/float.h und R's fmax2, fmin2, fsign, imax2, imin2,
# R_forceint, R_pow, R_pow_di, logspace_add, R_Log1_Exp.
# Vorlage: python/simlev/_r/_cmath.py.

const INF = Inf
const NINF = -Inf
# float.h
const DBL_EPSILON = 2.220446049250313e-16
const DBL_MIN = 2.2250738585072014e-308
const DBL_MAX = 1.7976931348623157e308
const DBL_MANT_DIG = 53
const DBL_MIN_EXP = -1021
const DBL_MAX_EXP = 1024
const INT_MAX = 2147483647
# Rmath.h
const M_E = 2.718281828459045235360287471353
const M_LN2 = 0.693147180559945309417232121458
const M_LN10 = 2.302585092994045684017991454684
const M_PI = 3.141592653589793238462643383280
const M_2PI = 6.283185307179586476925286766559
const M_PI_2 = 1.570796326794896619231321691640
const M_1_PI = 0.318309886183790671537767526745
const M_SQRT2 = 1.414213562373095048801688724210
const M_SQRT_32 = 5.656854249492380195206754896838
const M_SQRT_PI = 1.772453850905516027298167483341
const M_1_SQRT_2PI = 0.398942280401432677939946059934
const M_LN_2PI = 1.837877066409345483560659472811
const M_LN_SQRT_PI = 0.572364942924700087071713675677
const M_LN_SQRT_2PI = 0.918938533204672741780329736406
const M_LN_SQRT_PId2 = 0.225791352644727432363097614947

"R-Warnung aus C-Code (`MATHLIB_WARNING`)."
ml_warning(msg::AbstractString) = (@warn msg; nothing)

const _LM = SimLev.RLibm

# ── libm mit C-Semantik ────────────────────────────────────────────────────
@inline clog(x::Float64) = x > 0 ? _LM.c_log(x) : x == 0 ? NINF : isnan(x) ? x : NaN
@inline clog1p(x::Float64) = x > -1 ? _LM.c_log1p(x) : x == -1 ? NINF : isnan(x) ? x : NaN
@inline cexp(x::Float64) = _LM.c_exp(x)
@inline cexpm1(x::Float64) = _LM.c_expm1(x)
"C `pow(x, y)` (glibc, ohne R's Sonderbehandlung)."
@inline cpow(x::Float64, y::Float64) = _LM.c_pow(x, y)
@inline csqrt(x::Float64) = x >= 0.0 ? Base.sqrt(x) : isnan(x) ? x : NaN
@inline cldexp(x::Float64, e::Integer) = _LM.c_ldexp(x, e)
@inline cfmod(x::Float64, y::Float64) = _LM.c_fmod(x, y)
@inline csin(x::Float64) = isfinite(x) ? _LM.c_sin(x) : (isnan(x) ? x : NaN)
@inline ccos(x::Float64) = isfinite(x) ? _LM.c_cos(x) : (isnan(x) ? x : NaN)
@inline ctan(x::Float64) = isfinite(x) ? _LM.c_tan(x) : (isnan(x) ? x : NaN)
"C-`lgamma` (libm), nicht R's `lgammafn`."
@inline clgamma(x::Float64) = _LM.c_lgamma(x)
"C `nearbyint` = `R_forceint` (Rundung zur nächsten geraden Zahl)."
@inline R_forceint(x::Float64) = Base.round(x)
@inline ctrunc(x::Float64) = Base.trunc(x)
@inline cfloor(x::Float64) = Base.floor(x)

"C-Cast `(int) x` (Abschneiden; außerhalb des Bereichs wie x86: INT_MIN)."
@inline function c_int(x::Float64)
    (isnan(x) || x >= 2147483648.0 || x <= -2147483649.0) && return Int(typemin(Int32))
    return Int(unsafe_trunc(Int64, x))
end

@inline R_nonint(x::Float64) = abs(x - R_forceint(x)) > 1e-7 * fmax2(1.0, abs(x))

# ── R-Hilfen ──────────────────────────────────────────────────────────────
@inline fmax2(x::Float64, y::Float64) = (isnan(x) || isnan(y)) ? x + y : (x < y ? y : x)
@inline fmin2(x::Float64, y::Float64) = (isnan(x) || isnan(y)) ? x + y : (x < y ? x : y)
@inline imax2(x::Integer, y::Integer) = x < y ? y : x
@inline imin2(x::Integer, y::Integer) = x < y ? x : y
@inline fsign(x::Float64, y::Float64) = (isnan(x) || isnan(y)) ? x + y : (y >= 0 ? abs(x) : -abs(x))

"R's `R_pow` (arithmetic.c)."
R_pow(x::Float64, y::Float64) = SimLev.r_pow(x, y)

"R's `R_pow_di(x, n)` (ganzzahliger Exponent)."
function R_pow_di(x::Float64, n::Integer)
    xn = 1.0
    isnan(x) && return x
    n = Int(n)
    if n != 0
        isfinite(x) || return R_pow(x, Float64(n))
        is_neg = n < 0
        is_neg && (n = -n)
        while true
            (n & 1) != 0 && (xn *= x)
            n >>= 1
            if n != 0
                x *= x
            else
                break
            end
        end
        is_neg && (xn = 1.0 / xn)
    end
    return xn
end

"`log(1 - exp(x))` (dpq.h)."
@inline R_Log1_Exp(x::Float64) = x > -M_LN2 ? clog(-cexpm1(x)) : clog1p(-cexp(x))

"`log(exp(logx) + exp(logy))` wie R's `logspace_add`."
@inline _logspace_add(logx::Float64, logy::Float64) = fmax2(logx, logy) + clog1p(cexp(-abs(logx - logy)))
"`log(exp(logx) - exp(logy))` wie R's `logspace_sub`."
@inline _logspace_sub(logx::Float64, logy::Float64) = logx + R_Log1_Exp(logy - logx)

# R_D__0 usw. als Funktionen der Flags
@inline _D0(log_p::Bool) = log_p ? NINF : 0.0
@inline _D1(log_p::Bool) = log_p ? 0.0 : 1.0
@inline _DT0(lower::Bool, log_p::Bool) = lower ? _D0(log_p) : _D1(log_p)
@inline _DT1(lower::Bool, log_p::Bool) = lower ? _D1(log_p) : _D0(log_p)

# printf-artiges %g / %f für Warnungstexte
_g(x::Real) = Printf.@sprintf("%g", Float64(x))
_f(x::Real) = Printf.@sprintf("%f", Float64(x))
