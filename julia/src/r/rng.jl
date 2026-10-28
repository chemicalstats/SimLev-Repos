# RRng – Zufallszahlen wie R (Mersenne-Twister, L'Ecuyer-CMRG, sample.int, r*-Verteilungen)
#
# Der Zustand ist global wie `.Random.seed` in R: `set_seed` entspricht
# `set.seed()`, `get_random_seed`/`set_random_seed`/`rm_random_seed` dem
# Lesen, Zuweisen und Löschen von `.Random.seed` im globalen Environment.
# Eine Aufgabe von `RParallel.par_lapply` rechnet mit einer eigenen Kopie
# (`TaskState` im task-lokalen Speicher, `with_state`); alle Zugriffe gehen
# deshalb über `_st()`, `_rg()` und `_rp()`.
# Unterstützt: Generatoren "Mersenne-Twister" (Voreinstellung) und
# "L'Ecuyer-CMRG", Normalverteilung "Inversion", Stichprobenarten "Rejection"
# (Voreinstellung) und "Rounding"; Funktionen runif, rnorm, rexp, rgamma,
# rchisq, rt, rpois, rgeom, sample.int, parallel::nextRNGStream.
#
# Die skalaren Kerne (`unif_rand`, `norm_rand`, `exp_rand`, `rgamma1` …)
# entsprechen den gleichnamigen C-Funktionen (`R::runif` = `runif1`) und
# rufen – wie in C – kein GetRNGstate auf (dafür `_get_state()`).
# Vorlage: python/simlev/_r/rng.py; maßgeblich R 4.3.3 src/main/RNG.c,
# src/nmath/{snorm,sexp,rgamma,rpois,…}.c, src/main/random.c, stats/src/random.c.
module RRng

import ..SimLev
using ..SimLev: NA

const MERSENNE_TWISTER = 3
const LECUYER_CMRG = 7
const INVERSION = 4
const REJECTION = 1
const ROUNDING = 0

const _KIND_NAMES = ["Wichmann-Hill", "Marsaglia-Multicarry", "Super-Duper", "Mersenne-Twister",
                     "Knuth-TAOCP", "user-supplied", "Knuth-TAOCP-2002", "L'Ecuyer-CMRG"]
const _N01_NAMES = ["Buggy Kinderman-Ramage", "Ahrens-Dieter", "Box-Muller", "user-supplied",
                    "Inversion", "Kinderman-Ramage"]
const _SAMPLE_NAMES = ["Rounding", "Rejection"]

const _I2_32M1 = 2.328306437080797e-10      # 1/(2^32 - 1)
const _N = 624
const _MM = 397
const _MATRIX_A = 0x9908B0DF
const _UPPER = 0x80000000
const _LOWER = 0x7FFFFFFF
const _m1 = Int64(4294967087)
const _m2 = Int64(4294944443)
const _NORMC = 2.328306549295727688e-10
const _BIG = 134217728.0                     # 2^27

"Zustand des R-Generators (RNG_kind, N01_kind, Sample_kind, i_seed)."
mutable struct RandomState
    kind::Int
    n01::Int
    sample::Int
    exists::Bool             # existiert .Random.seed?
    mt::Vector{UInt32}
    mti::Int                 # dummy[0] (0-basiert wie in C)
    lec::Vector{Int64}       # sechs Werte (als nichtnegative 32-Bit-Zahlen)
end
RandomState() = RandomState(MERSENNE_TWISTER, INVERSION, REJECTION, false, zeros(UInt32, _N), _N + 1, zeros(Int64, 6))

const _S = RandomState()          # Zustand außerhalb von par_lapply-Aufgaben

# Zustand beim Laden zurücksetzen (wie ein frischer R-Prozess ohne
# .Random.seed), auch wenn beim Vorkompilieren Zufallszahlen gezogen wurden.
function __init__()
    _S.kind = MERSENNE_TWISTER; _S.n01 = INVERSION; _S.sample = REJECTION; _S.exists = false
    fill!(_S.mt, 0x0); _S.mti = _N + 1; fill!(_S.lec, 0)
    _RG.aa = _RG.aaa = 0.0
    _RP.muprev = _RP.muprev2 = 0.0; _RP.l = 0; _RP.m = 0; fill!(_RP.pp, 0.0)
    nothing
end

# ── Mersenne-Twister ───────────────────────────────────────────────────────

function _mt_sgenrand(seed::UInt32, _S::RandomState = _st())
    mt = _S.mt
    @inbounds for i in 1:_N
        v = seed & 0xffff0000
        seed = 0x00010dcd * seed + 0x00000001
        v |= (seed & 0xffff0000) >> 16
        seed = 0x00010dcd * seed + 0x00000001
        mt[i] = v
    end
    _S.mti = _N
end

function _mt_twist(_S::RandomState = _st())
    mt = _S.mt
    @inbounds begin
        for kk in 1:(_N-_MM)
            y = (mt[kk] & _UPPER) | (mt[kk+1] & _LOWER)
            mt[kk] = mt[kk+_MM] ⊻ (y >> 1) ⊻ ((y & 0x1) == 0 ? 0x0 : _MATRIX_A)
        end
        for kk in (_N-_MM+1):(_N-1)
            y = (mt[kk] & _UPPER) | (mt[kk+1] & _LOWER)
            mt[kk] = mt[kk+(_MM-_N)] ⊻ (y >> 1) ⊻ ((y & 0x1) == 0 ? 0x0 : _MATRIX_A)
        end
        y = (mt[_N] & _UPPER) | (mt[1] & _LOWER)
        mt[_N] = mt[_MM] ⊻ (y >> 1) ⊻ ((y & 0x1) == 0 ? 0x0 : _MATRIX_A)
    end
    _S.mti = 0
end

"`fixup(MT_genrand())`."
@inline function _mt_one(_S::RandomState = _st())
    if _S.mti >= _N
        _S.mti == _N + 1 && _mt_sgenrand(UInt32(4357), _S)
        _mt_twist(_S)
    end
    @inbounds y = _S.mt[_S.mti+1]
    _S.mti += 1
    y ⊻= (y >> 11)
    y ⊻= (y << 7) & 0x9d2c5680
    y ⊻= (y << 15) & 0xefc60000
    y ⊻= (y >> 18)
    v = Float64(y) * 2.3283064365386963e-10
    return v <= 0.0 ? 0.5 * _I2_32M1 : v
end

# ── L'Ecuyer-CMRG ──────────────────────────────────────────────────────────

@inline function _lec_one(_S::RandomState = _st())
    s = _S.lec
    @inbounds begin
        p1 = 1403580 * s[2] - 810728 * s[1]
        k = div(p1, _m1)                 # C: Abschneiden zur Null
        p1 -= k * _m1
        p1 < 0 && (p1 += _m1)
        s[1] = s[2]; s[2] = s[3]; s[3] = p1 & 0xFFFFFFFF
        p2 = 527612 * s[6] - 1370589 * s[4]
        k = div(p2, _m2)
        p2 -= k * _m2
        p2 < 0 && (p2 += _m2)
        s[4] = s[5]; s[5] = s[6]; s[6] = p2 & 0xFFFFFFFF
        return Float64((p1 > p2) ? (p1 - p2) : (p1 - p2 + _m1)) * _NORMC
    end
end

function _time_seed()
    ns = time_ns()
    t = Base.Libc.TimeVal()
    sec = UInt64(t.sec)
    nsec = UInt64(t.usec) * 1000 + (ns % 1000)
    seed = UInt32(((nsec << 16) ⊻ sec) & 0xFFFFFFFF)
    seed ⊻= UInt32((UInt64(getpid()) << 16) & 0xFFFFFFFF)
    return seed
end

# ── Initialisierung (RNG_Init, FixupSeeds, Randomize) ────────────────────

_lcg(s::UInt32) = 0x00010dcd * s + 0x00000001

function _rng_init(kind::Int, seed::UInt32)
    _S = _st()
    for _ in 1:50
        seed = _lcg(seed)
    end
    if kind == MERSENNE_TWISTER
        seed = _lcg(seed)                 # i_seed[0] = dummy[0], danach überschrieben
        for i in 1:_N
            seed = _lcg(seed)
            _S.mt[i] = seed
        end
        _S.mti = _N                       # FixupSeeds(initial = 1)
        all(==(0x0), _S.mt) && _rng_init(kind, _time_seed())
    elseif kind == LECUYER_CMRG
        for i in 1:6
            seed = _lcg(seed)
            while Int64(seed) >= _m2
                seed = _lcg(seed)
            end
            _S.lec[i] = Int64(seed)
        end
    else
        error("RNG-Art $(_KIND_NAMES[kind+1]) ist nicht portiert")
    end
end
_rng_init(kind::Integer, seed::Integer) = _rng_init(Int(kind), UInt32(seed & 0xFFFFFFFF))

_randomize(kind) = _rng_init(kind, _time_seed())

"GetRNGstate(): ohne .Random.seed zufällig initialisieren."
function _get_state()
    _S = _st()
    if !_S.exists
        _randomize(_S.kind)
        _S.exists = true
    end
    nothing
end

# ── .Random.seed ─────────────────────────────────────────────────────────

_to_int32(u::Integer) = reinterpret(Int32, UInt32(u & 0xFFFFFFFF))

"`exists(\".Random.seed\", globalenv())`."
has_random_seed() = _st().exists

"Kopie von `.Random.seed` (`Vector{Int32}`) oder `nothing`."
function get_random_seed()
    _S = _st()
    _S.exists || return nothing
    code = _S.kind + 100 * _S.n01 + 10000 * _S.sample
    if _S.kind == MERSENNE_TWISTER
        out = Vector{Int32}(undef, 2 + _N)
        out[1] = Int32(code)
        out[2] = Int32(_S.mti)
        for i in 1:_N
            out[2+i] = reinterpret(Int32, _S.mt[i])
        end
        return out
    end
    return Int32[Int32(code); [_to_int32(v) for v in _S.lec]]
end

"`assign(\".Random.seed\", seed, globalenv())`."
function set_random_seed(seed)
    s = Int64[Int64(v) for v in vec(collect(seed))]
    tmp = s[1]
    kind = Int(tmp % 100)
    n01 = Int(tmp % 10000 ÷ 100)
    smp = Int(tmp ÷ 10000)
    kind in (MERSENNE_TWISTER, LECUYER_CMRG) || error("RNG-Art $kind ist nicht portiert")
    _S = _st()
    _S.kind, _S.n01, _S.sample = kind, n01, smp
    _S.exists = true
    if length(s) == 1
        _randomize(kind)
        return nothing
    end
    if kind == MERSENNE_TWISTER
        mti = s[2]
        for i in 1:_N
            _S.mt[i] = UInt32(s[2+i] & 0xFFFFFFFF)
        end
        mti <= 0 && (mti = _N)
        _S.mti = Int(mti)
        all(==(0x0), _S.mt) && _randomize(kind)
    else
        for i in 1:6
            _S.lec[i] = s[1+i] & 0xFFFFFFFF
        end
        a = _S.lec
        (all(==(0), a[1:3]) || any(>=(_m1), a[1:3])) && _randomize(kind)
        (all(==(0), a[4:6]) || any(>=(_m2), a[4:6])) && _randomize(kind)
    end
    nothing
end

"`rm(\".Random.seed\", envir = globalenv())`."
rm_random_seed() = (_st().exists = false; nothing)

# ── set.seed / RNGkind ───────────────────────────────────────────────────

function _match(name, table, what)
    name === nothing && return nothing
    name isa Integer && return Int(name)
    name == "default" && return -1
    i = findfirst(==(name), table)
    i !== nothing && return i - 1
    hits = [i for (i, t) in enumerate(table) if startswith(t, name)]
    if length(hits) != 1
        error(what == "kind" ? "'$name' is not a valid abbreviation of an RNG" : "'$name' is not a valid choice")
    end
    return hits[1] - 1
end

function _set_kind(newkind::Int)
    newkind == -1 && (newkind = MERSENNE_TWISTER)
    _get_state()
    u = unif_rand()
    if u < 0.0 || u > 1.0
        _rng_init(newkind, _time_seed())
    else
        _rng_init(newkind, UInt32(trunc(UInt64, u * 4294967295.0) & 0xFFFFFFFF))
    end
    _st().kind = newkind
end

function _set_n01(kind::Int)
    kind == -1 && (kind = INVERSION)
    kind == INVERSION || error("Normalverteilungsart $(_N01_NAMES[kind+1]) ist nicht portiert")
    _get_state()
    _st().n01 = kind
end

function _set_sample(kind::Int)
    kind == -1 && (kind = REJECTION)
    _get_state()
    _st().sample = kind
end

function _apply_kinds(kind, normal_kind, sample_kind)
    k = _match(kind, _KIND_NAMES, "kind")
    n = _match(normal_kind, _N01_NAMES, "normal")
    s = _match(sample_kind, _SAMPLE_NAMES, "sample")
    s == ROUNDING && @warn "non-uniform 'Rounding' sampler used"
    k === nothing || _set_kind(k)
    n === nothing || _set_n01(n)
    s === nothing || _set_sample(s)
end

"`RNGkind()`: liefert die bisherigen Arten (Namen, Vektor der Länge 3) und setzt neue."
function rng_kind(kind_ = nothing, normal_kind_ = nothing, sample_kind_ = nothing;
                  kind = kind_, normal_kind = normal_kind_, sample_kind = sample_kind_)
    _get_state()
    _S = _st()
    old = [_KIND_NAMES[_S.kind+1], _N01_NAMES[_S.n01+1], _SAMPLE_NAMES[_S.sample+1]]
    _apply_kinds(kind, normal_kind, sample_kind)
    return old
end

"`set.seed(seed, kind, normal.kind, sample.kind)`."
function set_seed(seed, kind_ = nothing, normal_kind_ = nothing, sample_kind_ = nothing;
                  kind = kind_, normal_kind = normal_kind_, sample_kind = sample_kind_)
    if seed === nothing
        sd = _time_seed()
    else
        x = Float64(seed)                        # ganze Zahlen zählen als R-double
        isnan(x) && error("supplied seed is not a valid integer")
        if !(-2147483648.0 < x < 2147483648.0)
            # asInteger: außerhalb des int-Bereichs NA mit Warnung
            @warn "NAs introduced by coercion to integer range"
            error("supplied seed is not a valid integer")
        end
        si = trunc(Int64, x)
        sd = UInt32(si & 0xFFFFFFFF)
    end
    _apply_kinds(kind, normal_kind, sample_kind)
    _S = _st()
    _rng_init(_S.kind, sd)
    _S.exists = true
    nothing
end

# ── L'Ecuyer-Streams (parallel::nextRNGStream) ───────────────────────────

const _A1p127 = UInt64[2427906178 3580155704 949770784; 226153695 1230515664 3580155704; 1988835001 986791581 1230515664]
const _A2p127 = UInt64[1464411153 277697599 1610723613; 32183930 1464411153 1022607788; 2824425944 32183930 2093834863]
const _A1p76 = UInt64[82758667 1871391091 4127413238; 3672831523 69195019 1871391091; 3672091415 3528743235 69195019]
const _A2p76 = UInt64[1511326704 3759209742 1610795712; 4292754251 1511326704 3889917532; 3859662829 4292754251 3708466080]

function _advance(seed, A1, A2)
    raw = vec(collect(seed))
    s = UInt64[UInt64(Int64(v) & 0xFFFFFFFF) for v in raw]
    (length(s) != 7 || s[1] % 100 != LECUYER_CMRG) && error("invalid value of 'seed'")
    x = s[2:7]
    out = Vector{Int32}(undef, 7)
    out[1] = Int32(raw[1])
    for i in 1:3
        tmp = UInt64(0)
        for j in 1:3
            tmp += A1[i, j] * x[j]
            tmp %= UInt64(_m1)
        end
        out[1+i] = _to_int32(tmp)
    end
    for i in 1:3
        tmp = UInt64(0)
        for j in 1:3
            tmp += A2[i, j] * x[j+3]
            tmp %= UInt64(_m2)
        end
        out[4+i] = _to_int32(tmp)
    end
    return out
end

"`parallel::nextRNGStream(seed)`."
next_rng_stream(seed) = _advance(seed, _A1p127, _A2p127)
"`parallel::nextRNGSubStream(seed)`."
next_rng_substream(seed) = _advance(seed, _A1p76, _A2p76)

# ── Grundgeneratoren ─────────────────────────────────────────────────────

"`unif_rand()` (ohne GetRNGstate – Aufrufer sorgt für Zustand)."
@inline unif_rand() = (S = _st(); S.kind == MERSENNE_TWISTER ? _mt_one(S) : _lec_one(S))

"`norm_rand()` mit N01_kind = Inversion."
@inline function norm_rand()
    u1 = unif_rand()
    u1 = Float64(unsafe_trunc(Int32, _BIG * u1)) + unif_rand()
    return SimLev.RNmath.qnorm5(u1 / _BIG, 0.0, 1.0, true, false)
end

const _EXP_Q = (0.6931471805599453, 0.9333736875190459, 0.9888777961838675,
                0.9984959252914960, 0.9998292811061389, 0.9999833164100727,
                0.9999985691438767, 0.9999998906925558, 0.9999999924734159,
                0.9999999995283275, 0.9999999999728814, 0.9999999999985598,
                0.9999999999999289, 0.9999999999999968, 0.9999999999999999,
                1.0000000000000000)

"`exp_rand()` (Ahrens & Dieter 1972, R's sexp.c)."
function exp_rand()
    q = _EXP_Q
    a = 0.0
    u = unif_rand()
    while u <= 0.0 || u >= 1.0
        u = unif_rand()
    end
    while true
        u += u
        u > 1.0 && break
        a += q[1]
    end
    u -= 1.0
    u <= q[1] && return a + u
    i = 1
    ustar = unif_rand()
    umin = ustar
    while true
        ustar = unif_rand()
        umin > ustar && (umin = ustar)
        i += 1
        u > q[i] || break
    end
    return a + umin * q[1]
end

function _rbits(bits::Int)
    v = Int64(0)
    n = 0
    while n <= bits
        v1 = unsafe_trunc(Int64, floor(unif_rand() * 65536))
        v = 65536 * v + v1
        n += 16
    end
    return Float64(v & ((Int64(1) << bits) - 1))
end

"`R_unif_index(dn)`: ganze Zahl in [0, dn) (als Float64)."
function unif_index(dn::Real)
    dn = Float64(dn)
    _st().sample == ROUNDING && return floor(dn * unif_rand())
    dn <= 0 && return 0.0
    bits = unsafe_trunc(Int, ceil(SimLev.RLibm.c_log2(dn)))
    while true
        dv = _rbits(bits)
        dn <= dv || return dv
    end
end

# ── Skalare Verteilungen (nmath) ─────────────────────────────────────────

"`Rf_runif(a, b)` bzw. `R::runif`."
function runif1(a::Real = 0.0, b::Real = 1.0)
    a = Float64(a); b = Float64(b)
    (!(isfinite(a) && isfinite(b)) || b < a) && return NaN
    a == b && return a
    u = unif_rand()
    while u <= 0 || u >= 1
        u = unif_rand()
    end
    return a + (b - a) * u
end

"`Rf_rnorm(mu, sigma)` bzw. `R::rnorm`."
function rnorm1(mu::Real = 0.0, sigma::Real = 1.0)
    mu = Float64(mu); sigma = Float64(sigma)
    (isnan(mu) || !isfinite(sigma) || sigma < 0.0) && return NaN
    (sigma == 0.0 || !isfinite(mu)) && return mu
    return mu + sigma * norm_rand()
end

"`Rf_rexp(scale)`."
function rexp1(scale::Real = 1.0)
    scale = Float64(scale)
    if !isfinite(scale) || scale <= 0.0
        scale == 0.0 && return 0.0
        return NaN
    end
    return scale * exp_rand()
end

mutable struct _RGState
    aa::Float64; aaa::Float64; s::Float64; s2::Float64; d::Float64
    q0::Float64; b::Float64; si::Float64; c::Float64
end
const _RG = _RGState(0, 0, 0, 0, 0, 0, 0, 0, 0)

@inline _clog(x::Float64) = SimLev.RLibm._log(x)
@inline _cexp(x::Float64) = SimLev.RLibm.c_exp(x)

"`Rf_rgamma(a, scale)` (Ahrens & Dieter GD/GS, R's rgamma.c)."
function rgamma1(a::Real, scale::Real)
    a = Float64(a); scale = Float64(scale)
    sqrt32 = 5.656854
    exp_m1 = 0.36787944117144232159
    q1, q2, q3, q4, q5, q6, q7 = 0.04166669, 0.02083148, 0.00801191, 0.00144121, -7.388e-5, 2.4511e-4, 2.424e-4
    a1, a2, a3, a4, a5, a6, a7 = 0.3333333, -0.250003, 0.2000062, -0.1662921, 0.1423657, -0.1367177, 0.1233795
    st = _rg()
    (isnan(a) || isnan(scale)) && return NaN
    if a <= 0.0 || scale <= 0.0
        (scale == 0.0 || a == 0.0) && return 0.0
        return NaN
    end
    (!isfinite(a) || !isfinite(scale)) && return Inf
    if a < 1.0
        e = 1.0 + exp_m1 * a
        local x::Float64
        while true
            p = e * unif_rand()
            if p >= 1.0
                x = -_clog((e - p) / a)
                exp_rand() >= (1.0 - a) * _clog(x) && break
            else
                x = _cexp(_clog(p) / a)
                exp_rand() >= x && break
            end
        end
        return scale * x
    end
    if a != st.aa
        st.aa = a
        st.s2 = a - 0.5
        st.s = sqrt(st.s2)
        st.d = sqrt32 - st.s * 12.0
    end
    s, s2, d = st.s, st.s2, st.d
    t = norm_rand()
    x = s + 0.5 * t
    ret_val = x * x
    t >= 0.0 && return scale * ret_val
    u = unif_rand()
    d * u <= t * t * t && return scale * ret_val
    if a != st.aaa
        st.aaa = a
        r = 1.0 / a
        st.q0 = ((((((q7 * r + q6) * r + q5) * r + q4) * r + q3) * r + q2) * r + q1) * r
        if a <= 3.686
            st.b = 0.463 + s + 0.178 * s2
            st.si = 1.235
            st.c = 0.195 / s - 0.079 + 0.16 * s
        elseif a <= 13.022
            st.b = 1.654 + 0.0076 * s2
            st.si = 1.68 / s + 0.275
            st.c = 0.062 / s + 0.024
        else
            st.b = 1.77
            st.si = 0.75
            st.c = 0.1515 / s
        end
    end
    q0, b, si, c = st.q0, st.b, st.si, st.c
    if x > 0.0
        v = t / (s + s)
        if abs(v) <= 0.25
            q = q0 + 0.5 * t * t * ((((((a7 * v + a6) * v + a5) * v + a4) * v + a3) * v + a2) * v + a1) * v
        else
            q = q0 - s * t + 0.25 * t * t + (s2 + s2) * _clog(1.0 + v)
        end
        _clog(1.0 - u) <= q && return scale * ret_val
    end
    while true
        e = exp_rand()
        u = unif_rand()
        u = u + u - 1.0
        t = u < 0.0 ? b - si * e : b + si * e
        if t >= -0.71874483771719
            v = t / (s + s)
            if abs(v) <= 0.25
                q = q0 + 0.5 * t * t * ((((((a7 * v + a6) * v + a5) * v + a4) * v + a3) * v + a2) * v + a1) * v
            else
                q = q0 - s * t + 0.25 * t * t + (s2 + s2) * _clog(1.0 + v)
            end
            if q > 0.0
                w = SimLev.RLibm.c_expm1(q)
                c * abs(u) <= w * _cexp(e - 0.5 * t * t) && break
            end
        end
    end
    x = s + 0.5 * t
    return scale * x * x
end

"`Rf_rchisq(df)`."
function rchisq1(df::Real)
    df = Float64(df)
    (!isfinite(df) || df < 0.0) && return NaN
    return rgamma1(df / 2.0, 2.0)
end

"`Rf_rt(df)`."
function rt1(df::Real)
    df = Float64(df)
    (isnan(df) || df <= 0.0) && return NaN
    isfinite(df) || return norm_rand()
    num = norm_rand()
    return num / sqrt(rchisq1(df) / df)
end

mutable struct _RPState
    l::Int; m::Int
    b1::Float64; b2::Float64; c::Float64; c0::Float64; c1::Float64; c2::Float64; c3::Float64
    pp::Vector{Float64}
    p0::Float64; p::Float64; q::Float64; s::Float64; d::Float64; omega::Float64
    big_l::Float64; muprev::Float64; muprev2::Float64
end
const _RP = _RPState(0, 0, 0, 0, 0, 0, 0, 0, 0, zeros(36), 0, 0, 0, 0, 0, 0, 0, 0, 0)
const _FACT = (1.0, 1.0, 2.0, 6.0, 24.0, 120.0, 720.0, 5040.0, 40320.0, 362880.0)
const _M_1_SQRT_2PI = 0.398942280401432677939946059934

"`Rf_rpois(mu)` (Ahrens & Dieter 1982, R's rpois.c, mit statischem Zustand)."
function rpois1(mu::Real)
    mu = Float64(mu)
    a0, a1, a2, a3, a4, a5, a6, a7 = -0.5, 0.3333333, -0.2500068, 0.2000118, -0.1661269, 0.1421878, -0.1384794, 0.1250060
    one_7, one_12, one_24 = 0.1428571428571428571, 0.0833333333333333333, 0.0416666666666666667
    st = _rp()
    pp = st.pp                     # pp[k] in C ↔ pp[k+1] hier
    difmuk = 0.0; E = 0.0; fk = 0.0; u = 0.0; pois = -1.0
    new_big_mu = false
    (!isfinite(mu) || mu < 0) && return NaN
    mu <= 0.0 && return 0.0
    big_mu = mu >= 10.0
    if !(big_mu && mu == st.muprev)
        if big_mu
            new_big_mu = true
            st.muprev = mu
            st.s = sqrt(mu)
            st.d = 6.0 * mu * mu
            st.big_l = floor(mu - 1.1484)
        else
            if mu != st.muprev
                st.muprev = mu
                st.m = max(1, unsafe_trunc(Int32, mu))
                st.l = 0
                st.q = st.p0 = st.p = SimLev.RLibm.c_exp(-mu)
            end
            while true
                u = unif_rand()
                u <= st.p0 && return 0.0
                l = st.l
                if l != 0
                    k = u <= 0.458 ? 1 : min(l, st.m)
                    while k <= l
                        u <= pp[k+1] && return Float64(k)
                        k += 1
                    end
                    l == 35 && continue
                end
                l += 1
                st.l = l
                for k in l:35
                    st.p *= mu / k
                    st.q += st.p
                    pp[k+1] = st.q
                    if u <= st.q
                        st.l = k
                        return Float64(k)
                    end
                end
                st.l = 35
            end
        end
    end
    s, d = st.s, st.d
    g = mu + s * norm_rand()
    if g >= 0.0
        pois = floor(g)
        pois >= st.big_l && return pois
        fk = pois
        difmuk = mu - fk
        u = unif_rand()
        d * u >= difmuk * difmuk * difmuk && return pois
    end
    if new_big_mu || mu != st.muprev2
        st.muprev2 = mu
        st.omega = _M_1_SQRT_2PI / s
        b1 = one_24 / mu
        b2 = 0.3 * b1 * b1
        c3 = one_7 * b1 * b2
        st.b1, st.b2, st.c3 = b1, b2, c3
        st.c2 = b2 - 15.0 * c3
        st.c1 = b1 - 6.0 * b2 + 45.0 * c3
        st.c0 = 1.0 - b1 + 3.0 * b2 - 15.0 * c3
        st.c = 0.1069 / mu
    end
    omega, c, c0, c1, c2, c3 = st.omega, st.c, st.c0, st.c1, st.c2, st.c3
    kflag = g >= 0.0 ? 0 : -1
    while true
        if kflag != 0
            E = exp_rand()
            u = 2 * unif_rand() - 1.0
            t = 1.8 + (u >= 0 ? abs(E) : -abs(E))     # fsign(E, u)
            t > -0.6744 || continue
            pois = floor(mu + s * t)
            fk = pois
            difmuk = mu - fk
            kflag = 1
        end
        # Step F
        if pois < 10
            px = -mu
            py = SimLev.RLibm.c_pow(mu, pois) / _FACT[unsafe_trunc(Int, pois)+1]
        else
            dl = one_12 / fk
            dl = dl * (1.0 - 4.8 * dl * dl)
            v = difmuk / fk
            if abs(v) <= 0.25
                px = fk * v * v * (((((((a7 * v + a6) * v + a5) * v + a4) * v + a3) * v + a2) * v + a1) * v + a0) - dl
            else
                px = fk * _clog(1.0 + v) - difmuk - dl
            end
            py = _M_1_SQRT_2PI / sqrt(fk)
        end
        x = (0.5 - difmuk) / s
        x *= x
        fx = -0.5 * x
        fy = omega * (((c3 * x + c2) * x + c1) * x + c0)
        if kflag > 0
            c * abs(u) <= py * _cexp(px + E) - fy * _cexp(fx + E) && break
        else
            fy - u * fy <= py * _cexp(px - fx) && break
            kflag = 1        # weiter mit Step E
        end
    end
    return pois
end

"`Rf_rgeom(p)`."
function rgeom1(p::Real)
    p = Float64(p)
    (!isfinite(p) || p <= 0 || p > 1) && return NaN
    return rpois1(exp_rand() * ((1 - p) / p))
end

# ── R-Funktionen (vektorisiert, mit Recycling) ───────────────────────────

function _n_of(n)
    if n isa AbstractArray || n isa Tuple
        length(n) != 1 && return length(n)
        n = first(n)
    end
    dn = Float64(n)
    (isnan(dn) || dn < 0 || dn > 4.503599627370496e15) && error("invalid arguments")
    return trunc(Int, dn)
end

_arr(x::Real) = Float64[x]
_arr(::Nothing) = Float64[]
_arr(x) = Float64[v === missing ? NA : Float64(v) for v in vec(collect(x))]

function _fill_na(n)
    @warn "NAs produced"
    return fill(NA, n)
end

function _gen1(fn::F, n, a; int::Bool = false) where {F}
    n = _n_of(n)
    aa = _arr(a)
    n == 0 && return Float64[]
    isempty(aa) && return _fill_na(n)
    _get_state()
    na = length(aa)
    out = Vector{Float64}(undef, n)
    naflag = false
    @inbounds for i in 1:n
        y = fn(aa[(i-1)%na+1])
        if isnan(y)
            naflag = true
            int && (y = NA)            # INTSXP: NA_INTEGER
        end
        out[i] = y
    end
    naflag && @warn "NAs produced"
    return out
end

function _gen2(fn::F, n, a, b) where {F}
    n = _n_of(n)
    aa = _arr(a)
    bb = _arr(b)
    n == 0 && return Float64[]
    (isempty(aa) || isempty(bb)) && return _fill_na(n)
    _get_state()
    na, nb = length(aa), length(bb)
    out = Vector{Float64}(undef, n)
    naflag = false
    @inbounds for i in 1:n
        y = fn(aa[(i-1)%na+1], bb[(i-1)%nb+1])
        isnan(y) && (naflag = true)
        out[i] = y
    end
    naflag && @warn "NAs produced"
    return out
end

"`runif(n, min, max)`."
function runif(n, min_ = 0.0, max_ = 1.0; min = min_, max = max_)
    a = _arr(min); b = _arr(max)
    nn = _n_of(n)
    if length(a) == 1 && length(b) == 1 && nn > 0
        lo, hi = a[1], b[1]
        if isfinite(lo) && isfinite(hi) && lo < hi
            _get_state()
            out = Vector{Float64}(undef, nn)
            d = hi - lo
            S = _st()
            if S.kind == MERSENNE_TWISTER
                @inbounds for i in 1:nn
                    out[i] = lo + d * _mt_one(S)    # MT: stets 0 < u < 1
                end
            else
                @inbounds for i in 1:nn
                    out[i] = lo + d * _lec_one()
                end
            end
            return out
        end
    end
    return _gen2(runif1, n, a, b)
end

"`rnorm(n, mean, sd)`."
function rnorm(n, mean_ = 0.0, sd_ = 1.0; mean = mean_, sd = sd_)
    a = _arr(mean); b = _arr(sd)
    nn = _n_of(n)
    if length(a) == 1 && length(b) == 1 && nn > 0
        mu, sg = a[1], b[1]
        if isfinite(mu) && isfinite(sg) && sg > 0
            _get_state()
            out = Vector{Float64}(undef, nn)
            @inbounds for i in 1:nn
                out[i] = mu + sg * norm_rand()
            end
            return out
        end
    end
    return _gen2(rnorm1, n, a, b)
end

"`rexp(n, rate)` (C: `rexp(1/rate)`)."
rexp(n, rate_ = 1.0; rate = rate_) = _gen1(rexp1, n, 1.0 ./ _arr(rate))

"`rgamma(n, shape, rate = 1, scale = 1/rate)`."
function rgamma(n, shape, rate_ = 1.0, scale_ = nothing; rate = rate_, scale = scale_)
    sc = scale === nothing ? 1.0 ./ _arr(rate) : scale
    return _gen2(rgamma1, n, shape, sc)
end

"`rchisq(n, df)` (zentral)."
rchisq(n, df) = _gen1(rchisq1, n, df)
"`rt(n, df)` (zentral)."
rt(n, df) = _gen1(rt1, n, df)
"`rpois(n, lambda)` (Ergebnis Float64; NaN → NA wie R's NA_integer_)."
rpois(n, lam) = _gen1(rpois1, n, lam; int = true)
"`rgeom(n, prob)`."
rgeom(n, prob) = _gen1(rgeom1, n, prob; int = true)

# ── sample.int ───────────────────────────────────────────────────────────

"R's `revsort`: absteigend per Heapsort, `ib` parallel (sort.c)."
function _revsort!(a::Vector{Float64}, ib::Vector{Int})
    n = length(a)
    n <= 1 && return
    # 1-basiert wie im C-Code (a--, ib--) – passt direkt zu Julia
    l = (n >> 1) + 1
    ir = n
    while true
        if l > 1
            l -= 1
            ra = a[l]
            ii = ib[l]
        else
            ra = a[ir]
            ii = ib[ir]
            a[ir] = a[1]
            ib[ir] = ib[1]
            ir -= 1
            if ir == 1
                a[1] = ra
                ib[1] = ii
                return
            end
        end
        i = l
        j = l << 1
        while j <= ir
            if j < ir && a[j] > a[j+1]
                j += 1
            end
            if ra > a[j]
                a[i] = a[j]
                ib[i] = ib[j]
                i = j
                j += j
            else
                j = ir + 1
            end
        end
        a[i] = ra
        ib[i] = ii
    end
end

function _fixup_prob(p::Vector{Float64}, require_k::Int, replace::Bool)
    s = 0.0
    npos = 0
    for v in p
        isfinite(v) || error("NA in probability vector")
        v < 0.0 && error("negative probability")
        if v > 0.0
            npos += 1
            s += v
        end
    end
    (npos == 0 || (!replace && require_k > npos)) && error("too few positive probabilities")
    return Float64[v / s for v in p]
end

"""
    sample_int(n, size = n, replace = false; prob = nothing, use_hash = nothing)

`sample.int(n, size, replace, prob, useHash)`; liefert `Vector{Int}` mit
1-basierten Indizes wie R. `size`/`replace`/`prob` auch als Schlüsselwörter.
"""
function sample_int(n, size_ = nothing, replace_ = false, prob_ = nothing;
                    size = size_, replace = replace_, prob = prob_, use_hash = nothing)
    dn = Float64(n)
    size === nothing && (size = dn)
    k = trunc(Int, Float64(size))
    replace = Bool(replace)
    if use_hash === nothing
        use_hash = dn > 1e7 && !replace && prob === nothing && k <= dn / 2
    end
    if use_hash
        (!isfinite(dn) || dn < 0 || dn > 4.5e15 || (k > 0 && dn == 0)) && error("invalid first argument")
        k < 0 && error("invalid 'size' argument")
        k > dn / 2 && error("This algorithm is for size <= n/2")
        _get_state()
        out = Vector{Int}(undef, k)
        seen = Set{Int}()
        for i in 1:k
            v = 0
            for _ in 1:100
                v = Int(unif_index(dn) + 1)
                v in seen || break
            end
            push!(seen, v)
            out[i] = v
        end
        return out
    end
    if prob !== nothing
        ni = trunc(Int, dn)
        (ni < 0 || (k > 0 && ni == 0)) && error("invalid first argument")
        k < 0 && error("invalid 'size' argument")
        (!replace && k > ni) && error("cannot take a sample larger than the population when 'replace = FALSE'")
        p = _arr(prob)
        length(p) != ni && error("incorrect number of probabilities")
        _get_state()
        p = _fixup_prob(p, k, replace)
        if replace
            nc = count(v -> ni * v > 0.1, p)
            nc > 200 && return _walker(ni, p, k)
            perm = collect(1:ni)
            _revsort!(p, perm)
            for i in 2:ni
                p[i] += p[i-1]
            end
            out = Vector{Int}(undef, k)
            for i in 1:k
                rU = unif_rand()
                j = 1
                while j < ni
                    rU <= p[j] && break
                    j += 1
                end
                out[i] = perm[j]
            end
            return out
        end
        perm = collect(1:ni)
        _revsort!(p, perm)
        out = Vector{Int}(undef, k)
        totalmass = 1.0
        n1 = ni - 1                       # C: 0-basiert, letzter Index
        for i in 1:k
            rT = totalmass * unif_rand()
            mass = 0.0
            j = 0
            while j < n1
                mass += p[j+1]
                rT <= mass && break
                j += 1
            end
            out[i] = perm[j+1]
            totalmass -= p[j+1]
            for kk in j:(n1-1)
                p[kk+1] = p[kk+2]
                perm[kk+1] = perm[kk+2]
            end
            n1 -= 1
        end
        return out
    end
    (!isfinite(dn) || dn < 0 || dn > 4.5e15 || (k > 0 && dn == 0)) && error("invalid first argument")
    k < 0 && error("invalid 'size' argument")
    (!replace && k > dn) && error("cannot take a sample larger than the population when 'replace = FALSE'")
    _get_state()
    if replace || k < 2
        return Int[Int(unif_index(dn) + 1) for _ in 1:k]
    end
    ni = trunc(Int, dn)
    x = collect(0:ni-1)
    out = Vector{Int}(undef, k)
    for i in 1:k
        j = Int(unif_index(ni))
        out[i] = x[j+1] + 1
        ni -= 1
        x[j+1] = x[ni+1]
    end
    return out
end

function _walker(n::Int, p::Vector{Float64}, nans::Int)
    q = Float64[v * n for v in p]
    a = zeros(Int, n)
    HL = zeros(Int, n)
    H = -1
    L = n
    for i in 0:n-1
        if q[i+1] < 1.0
            H += 1
            HL[H+1] = i
        else
            L -= 1
            HL[L+1] = i
        end
    end
    if H >= 0 && L < n
        for k in 0:n-2
            i = HL[k+1]
            j = HL[L+1]
            a[i+1] = j
            q[j+1] += q[i+1] - 1
            q[j+1] < 1.0 && (L += 1)
            L >= n && break
        end
    end
    for i in 0:n-1
        q[i+1] += i
    end
    out = Vector{Int}(undef, nans)
    for t in 1:nans
        if _st().sample == ROUNDING
            rU = unif_rand() * n
            k = unsafe_trunc(Int, rU)
        else
            k = Int(unif_index(n))
            rU = k + unif_rand()
        end
        out[t] = rU < q[k+1] ? k + 1 : a[k+1] + 1
    end
    return out
end

"`sample(x, size, replace, prob)`."
function sample(x, size_ = nothing, replace_ = false, prob_ = nothing;
                size = size_, replace = replace_, prob = prob_)
    if x isa Real || (x isa AbstractArray && length(x) == 1)
        v = first(x)
        if v isa Real && !(v isa Bool) && isfinite(v) && v >= 1
            return sample_int(Float64(v); size = size, replace = replace, prob = prob)
        end
    end
    xa = x isa SimLev.RVector ? x.values : vec(collect(x))
    size === nothing && (size = length(xa))
    idx = sample_int(length(xa); size = size, replace = replace, prob = prob)
    return xa[idx]
end

# ── Zustand je Aufgabe (RParallel) ──────────────────────────────────────

"Zufallszustand einer Aufgabe: Generator samt den statischen Werten von rgamma und rpois."
struct TaskState
    S::RandomState
    RG::_RGState
    RP::_RPState
end

const _TLS_KEY = :SimLev_RRng_state

@inline function _task_state()
    tls = current_task().storage
    tls === nothing && return nothing
    return get(tls::IdDict{Any,Any}, _TLS_KEY, nothing)
end
"Aktueller Generatorzustand: der der Aufgabe (`with_state`), sonst der globale."
@inline _st() = (t = _task_state(); t === nothing ? _S : (t::TaskState).S)
@inline _rg() = (t = _task_state(); t === nothing ? _RG : (t::TaskState).RG)
@inline _rp() = (t = _task_state(); t === nothing ? _RP : (t::TaskState).RP)

_copy(s::RandomState) = RandomState(s.kind, s.n01, s.sample, s.exists, copy(s.mt), s.mti, copy(s.lec))
_copy(g::_RGState) = _RGState(g.aa, g.aaa, g.s, g.s2, g.d, g.q0, g.b, g.si, g.c)
_copy(r::_RPState) = _RPState(r.l, r.m, r.b1, r.b2, r.c, r.c0, r.c1, r.c2, r.c3, copy(r.pp), r.p0, r.p, r.q, r.s,
                              r.d, r.omega, r.big_l, r.muprev, r.muprev2)

"Unabhängige Kopie des aktuellen Zustands (`.Random.seed`, RNGkind, rgamma/rpois)."
copy_state() = TaskState(_copy(_st()), _copy(_rg()), _copy(_rp()))

"`f()` mit dem Zustand `st` als Zufallszustand der laufenden Aufgabe."
with_state(f, st::TaskState) = task_local_storage(f, _TLS_KEY, st)

end # module
