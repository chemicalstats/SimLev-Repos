"""Zufallszahlen wie in R (R 4.3, ``src/main/RNG.c``, ``src/nmath/r*.c``).

Der Zustand ist global wie ``.Random.seed`` in R: :func:`set_seed` entspricht
``set.seed()``, :func:`get_random_seed`/:func:`set_random_seed`/
:func:`rm_random_seed` entsprechen dem Lesen, Zuweisen und Löschen von
``.Random.seed`` im globalen Environment. Unterstützt werden die Generatoren
"Mersenne-Twister" (Voreinstellung) und "L'Ecuyer-CMRG", die Normalverteilung
"Inversion" (Voreinstellung) und die Stichprobenarten "Rejection"
(Voreinstellung) und "Rounding" – zusammen mit allen Zufallsfunktionen, die
SimLev nutzt (``runif``, ``rnorm``, ``rexp``, ``rgamma``, ``rchisq``, ``rt``,
``rpois``, ``rgeom``, ``sample.int``, ``parallel::nextRNGStream``).

Die skalaren Kerne (:func:`unif_rand`, :func:`norm_rand`, :func:`exp_rand`,
``rgamma1`` …) entsprechen den gleichnamigen C-Funktionen und werden von den
Portierungen der C++-Kerne verwendet (``R::runif`` = :func:`runif1`).
"""
from __future__ import annotations

import math
import os
import time
import warnings

import numpy as np

from .rnum import NA_REAL as _NA_REAL

__all__ = [
    "set_seed", "rng_kind", "get_random_seed", "set_random_seed", "rm_random_seed",
    "has_random_seed", "next_rng_stream", "next_rng_substream",
    "unif_rand", "norm_rand", "exp_rand", "unif_index",
    "runif1", "rnorm1", "rexp1", "rgamma1", "rchisq1", "rt1", "rpois1", "rgeom1",
    "runif", "rnorm", "rexp", "rgamma", "rchisq", "rt", "rpois", "rgeom",
    "sample_int", "sample", "RandomState",
]

# ── Konstanten ────────────────────────────────────────────────────────────
MERSENNE_TWISTER = 3
LECUYER_CMRG = 7
INVERSION = 4
REJECTION = 1
ROUNDING = 0

_KIND_NAMES = ["Wichmann-Hill", "Marsaglia-Multicarry", "Super-Duper", "Mersenne-Twister",
               "Knuth-TAOCP", "user-supplied", "Knuth-TAOCP-2002", "L'Ecuyer-CMRG"]
_N01_NAMES = ["Buggy Kinderman-Ramage", "Ahrens-Dieter", "Box-Muller", "user-supplied",
              "Inversion", "Kinderman-Ramage"]
_SAMPLE_NAMES = ["Rounding", "Rejection"]

_I2_32M1 = 2.328306437080797e-10      # 1/(2^32 - 1)
_M32 = 0xFFFFFFFF
_N = 624
_MM = 397
_MATRIX_A = 0x9908B0DF
_UPPER = 0x80000000
_LOWER = 0x7FFFFFFF
_m1 = 4294967087
_m2 = 4294944443
_NORMC = 2.328306549295727688e-10
_BIG = 134217728.0                     # 2^27


class RandomState:
    """Zustand des R-Generators (entspricht RNG_kind, N01_kind, Sample_kind
    und ``RNG_Table[kind].i_seed``)."""

    def __init__(self):
        self.kind = MERSENNE_TWISTER
        self.n01 = INVERSION
        self.sample = REJECTION
        self.exists = False            # existiert .Random.seed?
        # Mersenne-Twister
        self.mt = np.zeros(_N, dtype=np.uint32)
        self.mti = _N + 1
        self._buf = np.empty(0)        # vorberechnete Ausgaben ab Position mti
        self._buf_pos = 0
        # L'Ecuyer
        self.lec = [0, 0, 0, 0, 0, 0]

    # Mersenne-Twister ----------------------------------------------------
    def _mt_sgenrand(self, seed):
        mt = np.zeros(_N, dtype=np.uint32)
        for i in range(_N):
            v = seed & 0xFFFF0000
            seed = (69069 * seed + 1) & _M32
            v |= (seed & 0xFFFF0000) >> 16
            seed = (69069 * seed + 1) & _M32
            mt[i] = v
        self.mt = mt
        self.mti = _N

    def _mt_twist(self):
        mt = self.mt.astype(np.uint64)
        mag = np.array([0, _MATRIX_A], dtype=np.uint64)
        # kk = 0 .. N-M-1  (nutzt alte Werte mt[kk+1], mt[kk+M])
        kk = np.arange(0, _N - _MM)
        y = (mt[kk] & _UPPER) | (mt[kk + 1] & _LOWER)
        mt[kk] = mt[kk + _MM] ^ (y >> np.uint64(1)) ^ mag[(y & np.uint64(1)).astype(np.int64)]
        # kk = N-M .. N-2 in Blöcken, da mt[kk+(M-N)] bereits neu ist
        start = _N - _MM
        while start < _N - 1:
            stop = min(_N - 1, start + (_N - _MM))
            kk = np.arange(start, stop)
            y = (mt[kk] & _UPPER) | (mt[kk + 1] & _LOWER)
            mt[kk] = mt[kk + (_MM - _N)] ^ (y >> np.uint64(1)) ^ mag[(y & np.uint64(1)).astype(np.int64)]
            start = stop
        y = (mt[_N - 1] & _UPPER) | (mt[0] & _LOWER)
        mt[_N - 1] = mt[_MM - 1] ^ (y >> np.uint64(1)) ^ mag[int(y & np.uint64(1))]
        self.mt = mt.astype(np.uint32)
        self.mti = 0
        self._temper()

    def _temper(self):
        y = self.mt.astype(np.uint64)
        y ^= y >> np.uint64(11)
        y ^= (y << np.uint64(7)) & np.uint64(0x9D2C5680)
        y ^= (y << np.uint64(15)) & np.uint64(0xEFC60000)
        y ^= y >> np.uint64(18)
        y &= np.uint64(_M32)
        v = y.astype(np.float64) * 2.3283064365386963e-10
        v[v <= 0.0] = 0.5 * _I2_32M1                        # fixup()
        self._buf = v

    def mt_block(self, n):
        """``n`` Werte von ``fixup(MT_genrand())`` als Array."""
        out = np.empty(n)
        k = 0
        while k < n:
            if self.mti >= _N:
                if self.mti == _N + 1:
                    self._mt_sgenrand(4357)
                self._mt_twist()
            elif self._buf.size != _N:
                self._temper()
            take = min(n - k, _N - self.mti)
            out[k:k + take] = self._buf[self.mti:self.mti + take]
            self.mti += take
            k += take
        return out

    def mt_one(self):
        if self.mti >= _N:
            if self.mti == _N + 1:
                self._mt_sgenrand(4357)
            self._mt_twist()
        elif self._buf.size != _N:
            self._temper()
        v = self._buf[self.mti]
        self.mti += 1
        return float(v)

    # L'Ecuyer-CMRG -------------------------------------------------------
    def lec_one(self):
        s = self.lec
        p1 = 1403580 * s[1] - 810728 * s[0]
        k = _trunc_div(p1, _m1)
        p1 -= k * _m1
        if p1 < 0:
            p1 += _m1
        s[0] = s[1]
        s[1] = s[2]
        s[2] = p1 & _M32
        p2 = 527612 * s[5] - 1370589 * s[3]
        k = _trunc_div(p2, _m2)
        p2 -= k * _m2
        if p2 < 0:
            p2 += _m2
        s[3] = s[4]
        s[4] = s[5]
        s[5] = p2 & _M32
        return float((p1 - p2) if p1 > p2 else (p1 - p2 + _m1)) * _NORMC


def _trunc_div(a, b):
    """C-Ganzzahldivision (Abschneiden zur Null) für int64-Werte.

    R rechnet ``k = (int) (p1 / m1)`` mit int_least64_t-Operanden, also
    ganzzahlige Division mit Abschneiden."""
    q = abs(a) // b
    return q if a >= 0 else -q


_S = RandomState()


def _time_seed():
    ns = time.time_ns()
    sec = ns // 1_000_000_000
    nsec = ns % 1_000_000_000
    seed = ((nsec << 16) ^ sec) & _M32
    seed ^= (os.getpid() << 16) & _M32
    return seed & _M32


# ── Initialisierung (RNG_Init, FixupSeeds, Randomize) ────────────────────

def _rng_init(kind, seed):
    seed &= _M32
    for _ in range(50):
        seed = (69069 * seed + 1) & _M32
    if kind == MERSENNE_TWISTER:
        vals = []
        for _ in range(_N + 1):
            seed = (69069 * seed + 1) & _M32
            vals.append(seed)
        _S.mt = np.array(vals[1:], dtype=np.uint32)
        _S.mti = _N                    # FixupSeeds(initial = 1): dummy[0] = 624
        _S._buf = np.empty(0)
        if not _S.mt.any():
            _rng_init(kind, _time_seed())
    elif kind == LECUYER_CMRG:
        vals = []
        for _ in range(6):
            seed = (69069 * seed + 1) & _M32
            while seed >= _m2:
                seed = (69069 * seed + 1) & _M32
            vals.append(seed)
        _S.lec = vals
    else:
        raise NotImplementedError("RNG-Art %s ist nicht portiert" % _KIND_NAMES[kind])


def _randomize(kind):
    _rng_init(kind, _time_seed())


def _get_state():
    """GetRNGstate(): ohne .Random.seed zufällig initialisieren."""
    if not _S.exists:
        _randomize(_S.kind)
        _S.exists = True


# ── .Random.seed ─────────────────────────────────────────────────────────

def _to_int32(u):
    u &= _M32
    return u - (1 << 32) if u >= (1 << 31) else u


def has_random_seed() -> bool:
    """``exists(".Random.seed", globalenv())``."""
    return _S.exists


def get_random_seed():
    """Kopie von ``.Random.seed`` (``numpy.int32``-Array) oder ``None``."""
    if not _S.exists:
        return None
    code = _S.kind + 100 * _S.n01 + 10000 * _S.sample
    if _S.kind == MERSENNE_TWISTER:
        mti = _S.mti
        vals = [code, mti] + [int(v) for v in _S.mt]
    else:
        vals = [code] + list(_S.lec)
    return np.array([_to_int32(v) if i > 0 else v for i, v in enumerate(vals)], dtype=np.int32)


def set_random_seed(seed) -> None:
    """``assign(".Random.seed", seed, globalenv())``."""
    s = [int(v) for v in np.asarray(seed).ravel()]
    tmp = s[0]
    kind = tmp % 100
    n01 = tmp % 10000 // 100
    smp = tmp // 10000
    if kind not in (MERSENNE_TWISTER, LECUYER_CMRG):
        raise NotImplementedError("RNG-Art %d ist nicht portiert" % kind)
    _S.kind, _S.n01, _S.sample = kind, n01, smp
    _S.exists = True
    if kind == MERSENNE_TWISTER:
        if len(s) == 1:
            _randomize(kind)
            return
        mti = s[1]
        _S.mt = np.array([v & _M32 for v in s[2:2 + _N]], dtype=np.uint32)
        if mti <= 0:
            mti = _N
        _S.mti = mti
        _S._buf = np.empty(0)
        if not _S.mt.any():
            _randomize(kind)
    else:
        if len(s) == 1:
            _randomize(kind)
            return
        _S.lec = [v & _M32 for v in s[1:7]]
        a = _S.lec
        if not any(a[:3]) or any(v >= _m1 for v in a[:3]):
            _randomize(kind)
        if not any(a[3:]) or any(v >= _m2 for v in a[3:]):
            _randomize(kind)


def rm_random_seed() -> None:
    """``rm(".Random.seed", envir = globalenv())``."""
    _S.exists = False


# ── set.seed / RNGkind ───────────────────────────────────────────────────

def _match(name, table, what):
    if name is None:
        return None
    if isinstance(name, (int, np.integer)):
        return int(name)
    if name == "default":
        return -1
    hits = [i for i, t in enumerate(table) if t.startswith(name)]
    if len(hits) != 1:
        raise ValueError("'%s' is not a valid abbreviation of an RNG" % name if what == "kind"
                         else "'%s' is not a valid choice" % name)
    return hits[0]


def _set_kind(newkind):
    if newkind == -1:
        newkind = MERSENNE_TWISTER
    _get_state()
    u = unif_rand()
    if u < 0.0 or u > 1.0:
        _rng_init(newkind, _time_seed())
    else:
        _rng_init(newkind, int(u * 4294967295.0) & _M32)
    _S.kind = newkind


def _set_n01(kind):
    if kind == -1:
        kind = INVERSION
    if kind != INVERSION:
        raise NotImplementedError("Normalverteilungsart %s ist nicht portiert" % _N01_NAMES[kind])
    _get_state()
    _S.n01 = kind


def _set_sample(kind):
    if kind == -1:
        kind = REJECTION
    _get_state()
    _S.sample = kind


def rng_kind(kind=None, normal_kind=None, sample_kind=None):
    """``RNGkind()``: liefert die bisherigen Arten (Namen) und setzt neue."""
    _get_state()
    old = (_KIND_NAMES[_S.kind], _N01_NAMES[_S.n01], _SAMPLE_NAMES[_S.sample])
    k = _match(kind, _KIND_NAMES, "kind")
    n = _match(normal_kind, _N01_NAMES, "normal")
    s = _match(sample_kind, _SAMPLE_NAMES, "sample")
    if k is not None:
        _set_kind(k)
    if n is not None:
        _set_n01(n)
    if s is not None:
        if s == ROUNDING:
            warnings.warn("non-uniform 'Rounding' sampler used", stacklevel=2)
        _set_sample(s)
    return old


def set_seed(seed, kind=None, normal_kind=None, sample_kind=None) -> None:
    """``set.seed(seed, kind, normal.kind, sample.kind)``."""
    if seed is None:
        sd = _time_seed()
    else:
        x = float(seed)                          # Python-int zählt als R-double
        if math.isnan(x):
            raise ValueError("supplied seed is not a valid integer")
        if x >= 2147483648.0 or x <= -2147483648.0:
            # asInteger: außerhalb des int-Bereichs NA mit Warnung (R_print coercion)
            warnings.warn("NAs introduced by coercion to integer range", stacklevel=2)
            raise ValueError("supplied seed is not a valid integer")
        sd = int(x)                              # asInteger: Abschneiden
        sd &= _M32
    k = _match(kind, _KIND_NAMES, "kind")
    n = _match(normal_kind, _N01_NAMES, "normal")
    s = _match(sample_kind, _SAMPLE_NAMES, "sample")
    if k is not None:
        _set_kind(k)
    if n is not None:
        _set_n01(n)
    if s is not None:
        if s == ROUNDING:
            warnings.warn("non-uniform 'Rounding' sampler used", stacklevel=2)
        _set_sample(s)
    _rng_init(_S.kind, sd)
    _S.exists = True


# ── L'Ecuyer-Streams (parallel::nextRNGStream) ───────────────────────────

_A1p127 = ((2427906178, 3580155704, 949770784),
           (226153695, 1230515664, 3580155704),
           (1988835001, 986791581, 1230515664))
_A2p127 = ((1464411153, 277697599, 1610723613),
           (32183930, 1464411153, 1022607788),
           (2824425944, 32183930, 2093834863))
_A1p76 = ((82758667, 1871391091, 4127413238),
          (3672831523, 69195019, 1871391091),
          (3672091415, 3528743235, 69195019))
_A2p76 = ((1511326704, 3759209742, 1610795712),
          (4292754251, 1511326704, 3889917532),
          (3859662829, 4292754251, 3708466080))


def _advance(seed, A1, A2):
    s = [int(v) & _M32 for v in np.asarray(seed).ravel()]
    if len(s) != 7 or s[0] % 100 != LECUYER_CMRG:
        raise ValueError("invalid value of 'seed'")
    x = s[1:]
    out = [s[0]]
    for i in range(3):
        tmp = 0
        for j in range(3):
            tmp = (tmp + A1[i][j] * x[j]) & 0xFFFFFFFFFFFFFFFF
            tmp %= _m1
        out.append(tmp)
    for i in range(3):
        tmp = 0
        for j in range(3):
            tmp = (tmp + A2[i][j] * x[j + 3]) & 0xFFFFFFFFFFFFFFFF
            tmp %= _m2
        out.append(tmp)
    raw = np.asarray(seed).ravel()
    return np.array([int(raw[0])] + [_to_int32(v) for v in out[1:]], dtype=np.int32)


def next_rng_stream(seed):
    """``parallel::nextRNGStream(seed)``."""
    return _advance(seed, _A1p127, _A2p127)


def next_rng_substream(seed):
    """``parallel::nextRNGSubStream(seed)``."""
    return _advance(seed, _A1p76, _A2p76)


# ── Grundgeneratoren ─────────────────────────────────────────────────────

def unif_rand() -> float:
    """``unif_rand()`` (ohne GetRNGstate – Aufrufer sorgt für Zustand)."""
    if _S.kind == MERSENNE_TWISTER:
        return _S.mt_one()
    return _S.lec_one()


def _unif_block(n) -> np.ndarray:
    if _S.kind == MERSENNE_TWISTER:
        return _S.mt_block(n)
    return np.array([_S.lec_one() for _ in range(n)], dtype=np.float64)


# qnorm5(p, 0, 1, TRUE, FALSE) für 0 < p < 1 (AS 241, R's qnorm.c)
def _qnorm_std(p: float) -> float:
    q = p - 0.5
    if abs(q) <= .425:
        r = .180625 - q * q
        return q * (((((((r * 2509.0809287301226727 +
                          33430.575583588128105) * r + 67265.770927008700853) * r +
                        45921.953931549871457) * r + 13731.693765509461125) * r +
                      1971.5909503065514427) * r + 133.14166789178437745) * r +
                    3.387132872796366608) \
            / (((((((r * 5226.495278852854561 +
                     28729.085735721942674) * r + 39307.89580009271061) * r +
                   21213.794301586595867) * r + 5394.1960214247511077) * r +
                 687.1870074920579083) * r + 42.313330701600911252) * r + 1.)
    lp = math.log((0.5 - p + 0.5) if q > 0 else p)
    r = math.sqrt(-lp)
    if r <= 5.:
        r += -1.6
        val = (((((((r * 7.7454501427834140764e-4 +
                     .0227238449892691845833) * r + .24178072517745061177) *
                   r + 1.27045825245236838258) * r +
                  3.64784832476320460504) * r + 5.7694972214606914055) *
                r + 4.6303378461565452959) * r +
               1.42343711074968357734) \
            / (((((((r *
                     1.05075007164441684324e-9 + 5.475938084995344946e-4) *
                    r + .0151986665636164571966) * r +
                   .14810397642748007459) * r + .68976733498510000455) *
                 r + 1.6763848301838038494) * r +
                2.05319162663775882187) * r + 1.)
    else:
        r += -5.
        val = (((((((r * 2.01033439929228813265e-7 +
                     2.71155556874348757815e-5) * r +
                    .0012426609473880784386) * r + .026532189526576123093) *
                  r + .29656057182850489123) * r +
                 1.7848265399172913358) * r + 5.4637849111641143699) *
               r + 6.6579046435011037772) \
            / (((((((r *
                     2.04426310338993978564e-15 + 1.4215117583164458887e-7) *
                    r + 1.8463183175100546818e-5) * r +
                   7.868691311456132591e-4) * r + .0148753612908506148525)
                 * r + .13692988092273580531) * r +
                .59983220655588793769) * r + 1.)
    if q < 0.0:
        val = -val
    return val


def _qnorm_std_vec(p: np.ndarray) -> np.ndarray:
    """Vektorisierte Fassung von :func:`_qnorm_std` (gleiche Operationen)."""
    p = np.asarray(p, dtype=np.float64)
    q = p - 0.5
    out = np.empty_like(p)
    c = np.abs(q) <= .425
    if c.any():
        qq = q[c]
        r = .180625 - qq * qq
        out[c] = qq * (((((((r * 2509.0809287301226727 +
                             33430.575583588128105) * r + 67265.770927008700853) * r +
                           45921.953931549871457) * r + 13731.693765509461125) * r +
                         1971.5909503065514427) * r + 133.14166789178437745) * r +
                       3.387132872796366608) \
            / (((((((r * 5226.495278852854561 +
                     28729.085735721942674) * r + 39307.89580009271061) * r +
                   21213.794301586595867) * r + 5394.1960214247511077) * r +
                 687.1870074920579083) * r + 42.313330701600911252) * r + 1.)
    t = ~c
    if t.any():
        idx = np.flatnonzero(t)
        out[idx] = [_qnorm_std(float(v)) for v in p[idx]]
    return out


def norm_rand() -> float:
    """``norm_rand()`` mit N01_kind = Inversion."""
    u1 = unif_rand()
    u1 = float(int(_BIG * u1)) + unif_rand()
    return _qnorm_std(u1 / _BIG)


def _norm_block(n) -> np.ndarray:
    if n <= 0:
        return np.empty(0)
    u = _unif_block(2 * n).reshape(n, 2)
    u1 = np.floor(_BIG * u[:, 0]) + u[:, 1]
    return _qnorm_std_vec(u1 / _BIG)


_EXP_Q = (0.6931471805599453, 0.9333736875190459, 0.9888777961838675,
          0.9984959252914960, 0.9998292811061389, 0.9999833164100727,
          0.9999985691438767, 0.9999998906925558, 0.9999999924734159,
          0.9999999995283275, 0.9999999999728814, 0.9999999999985598,
          0.9999999999999289, 0.9999999999999968, 0.9999999999999999,
          1.0000000000000000)


def exp_rand() -> float:
    """``exp_rand()`` (Ahrens & Dieter 1972, R's sexp.c)."""
    q = _EXP_Q
    a = 0.
    u = unif_rand()
    while u <= 0. or u >= 1.:
        u = unif_rand()
    while True:
        u += u
        if u > 1.:
            break
        a += q[0]
    u -= 1.
    if u <= q[0]:
        return a + u
    i = 0
    ustar = unif_rand()
    umin = ustar
    while True:
        ustar = unif_rand()
        if umin > ustar:
            umin = ustar
        i += 1
        if not (u > q[i]):
            break
    return a + umin * q[0]


def _rbits(bits) -> float:
    v = 0
    n = 0
    while n <= bits:
        v1 = int(math.floor(unif_rand() * 65536))
        v = (65536 * v + v1) & 0xFFFFFFFFFFFFFFFF
        n += 16
    return float(v & ((1 << bits) - 1))


def unif_index(dn: float) -> float:
    """``R_unif_index(dn)``: ganze Zahl in [0, dn)."""
    if _S.sample == ROUNDING:
        return math.floor(dn * unif_rand())
    if dn <= 0:
        return 0.0
    bits = int(math.ceil(math.log2(dn)))
    while True:
        dv = _rbits(bits)
        if not (dn <= dv):
            return dv


# ── Skalare Verteilungen (nmath) ─────────────────────────────────────────

def runif1(a: float = 0.0, b: float = 1.0) -> float:
    """``Rf_runif(a, b)`` bzw. ``R::runif``."""
    if not (math.isfinite(a) and math.isfinite(b)) or b < a:
        return math.nan
    if a == b:
        return a
    u = unif_rand()
    while u <= 0 or u >= 1:
        u = unif_rand()
    return a + (b - a) * u


def rnorm1(mu: float = 0.0, sigma: float = 1.0) -> float:
    """``Rf_rnorm(mu, sigma)`` bzw. ``R::rnorm``."""
    if math.isnan(mu) or not math.isfinite(sigma) or sigma < 0.:
        return math.nan
    if sigma == 0. or not math.isfinite(mu):
        return mu
    return mu + sigma * norm_rand()


def rexp1(scale: float = 1.0) -> float:
    if not math.isfinite(scale) or scale <= 0.0:
        if scale == 0.:
            return 0.
        return math.nan
    return scale * exp_rand()


_RG = {"aa": 0., "aaa": 0., "s": 0., "s2": 0., "d": 0., "q0": 0., "b": 0., "si": 0., "c": 0.}


def rgamma1(a: float, scale: float) -> float:
    """``Rf_rgamma(a, scale)`` (Ahrens & Dieter GD/GS, R's rgamma.c)."""
    sqrt32 = 5.656854
    exp_m1 = 0.36787944117144232159
    q1, q2, q3, q4, q5, q6, q7 = 0.04166669, 0.02083148, 0.00801191, 0.00144121, -7.388e-5, 2.4511e-4, 2.424e-4
    a1, a2, a3, a4, a5, a6, a7 = 0.3333333, -0.250003, 0.2000062, -0.1662921, 0.1423657, -0.1367177, 0.1233795
    st = _RG
    if math.isnan(a) or math.isnan(scale):
        return math.nan
    if a <= 0.0 or scale <= 0.0:
        if scale == 0. or a == 0.:
            return 0.
        return math.nan
    if not math.isfinite(a) or not math.isfinite(scale):
        return math.inf
    if a < 1.:
        e = 1.0 + exp_m1 * a
        while True:
            p = e * unif_rand()
            if p >= 1.0:
                x = -math.log((e - p) / a)
                if exp_rand() >= (1.0 - a) * _clog(x):
                    break
            else:
                x = math.exp(_clog(p) / a)
                if exp_rand() >= x:
                    break
        return scale * x
    if a != st["aa"]:
        st["aa"] = a
        st["s2"] = a - 0.5
        st["s"] = math.sqrt(st["s2"])
        st["d"] = sqrt32 - st["s"] * 12.0
    s, s2, d = st["s"], st["s2"], st["d"]
    t = norm_rand()
    x = s + 0.5 * t
    ret_val = x * x
    if t >= 0.0:
        return scale * ret_val
    u = unif_rand()
    if d * u <= t * t * t:
        return scale * ret_val
    if a != st["aaa"]:
        st["aaa"] = a
        r = 1.0 / a
        st["q0"] = ((((((q7 * r + q6) * r + q5) * r + q4) * r + q3) * r + q2) * r + q1) * r
        if a <= 3.686:
            st["b"] = 0.463 + s + 0.178 * s2
            st["si"] = 1.235
            st["c"] = 0.195 / s - 0.079 + 0.16 * s
        elif a <= 13.022:
            st["b"] = 1.654 + 0.0076 * s2
            st["si"] = 1.68 / s + 0.275
            st["c"] = 0.062 / s + 0.024
        else:
            st["b"] = 1.77
            st["si"] = 0.75
            st["c"] = 0.1515 / s
    q0, b, si, c = st["q0"], st["b"], st["si"], st["c"]
    if x > 0.0:
        v = t / (s + s)
        if abs(v) <= 0.25:
            q = q0 + 0.5 * t * t * ((((((a7 * v + a6) * v + a5) * v + a4) * v + a3) * v + a2) * v + a1) * v
        else:
            q = q0 - s * t + 0.25 * t * t + (s2 + s2) * _clog(1.0 + v)
        if _clog(1.0 - u) <= q:
            return scale * ret_val
    while True:
        e = exp_rand()
        u = unif_rand()
        u = u + u - 1.0
        if u < 0.0:
            t = b - si * e
        else:
            t = b + si * e
        if t >= -0.71874483771719:
            v = t / (s + s)
            if abs(v) <= 0.25:
                q = q0 + 0.5 * t * t * ((((((a7 * v + a6) * v + a5) * v + a4) * v + a3) * v + a2) * v + a1) * v
            else:
                q = q0 - s * t + 0.25 * t * t + (s2 + s2) * _clog(1.0 + v)
            if q > 0.0:
                w = math.expm1(q) if q < 709.7 else math.inf
                if c * abs(u) <= w * _cexp(e - 0.5 * t * t):
                    break
    x = s + 0.5 * t
    return scale * x * x


def _clog(x):
    if x > 0:
        return math.log(x)
    if x == 0:
        return -math.inf
    return math.nan


def _cexp(x):
    try:
        return math.exp(x)
    except OverflowError:
        return math.inf


def rchisq1(df: float) -> float:
    if not math.isfinite(df) or df < 0.0:
        return math.nan
    return rgamma1(df / 2.0, 2.0)


def rt1(df: float) -> float:
    if math.isnan(df) or df <= 0.0:
        return math.nan
    if not math.isfinite(df):
        return norm_rand()
    num = norm_rand()
    return num / math.sqrt(rchisq1(df) / df)


_RP = {"l": 0, "m": 0, "b1": 0., "b2": 0., "c": 0., "c0": 0., "c1": 0., "c2": 0., "c3": 0.,
       "pp": [0.] * 36, "p0": 0., "p": 0., "q": 0., "s": 0., "d": 0., "omega": 0.,
       "big_l": 0., "muprev": 0., "muprev2": 0.}
_FACT = (1., 1., 2., 6., 24., 120., 720., 5040., 40320., 362880.)
_M_1_SQRT_2PI = 0.398942280401432677939946059934


def rpois1(mu: float) -> float:
    """``Rf_rpois(mu)`` (Ahrens & Dieter 1982, R's rpois.c, mit statischem Zustand)."""
    a0, a1, a2, a3, a4, a5, a6, a7 = -0.5, 0.3333333, -0.2500068, 0.2000118, -0.1661269, 0.1421878, -0.1384794, 0.1250060
    one_7, one_12, one_24 = 0.1428571428571428571, 0.0833333333333333333, 0.0416666666666666667
    st = _RP
    pp = st["pp"]
    difmuk = 0.
    E = 0.
    fk = 0.
    u = 0.
    pois = -1.
    new_big_mu = False
    if not math.isfinite(mu) or mu < 0:
        return math.nan
    if mu <= 0.:
        return 0.
    big_mu = mu >= 10.
    if big_mu:
        new_big_mu = False
    if not (big_mu and mu == st["muprev"]):
        if big_mu:
            new_big_mu = True
            st["muprev"] = mu
            st["s"] = math.sqrt(mu)
            st["d"] = 6. * mu * mu
            st["big_l"] = math.floor(mu - 1.1484)
        else:
            if mu != st["muprev"]:
                st["muprev"] = mu
                st["m"] = max(1, int(mu))
                st["l"] = 0
                st["q"] = st["p0"] = st["p"] = math.exp(-mu)
            while True:
                u = unif_rand()
                if u <= st["p0"]:
                    return 0.
                l = st["l"]
                if l != 0:
                    k = 1 if u <= 0.458 else min(l, st["m"])
                    while k <= l:
                        if u <= pp[k]:
                            return float(k)
                        k += 1
                    if l == 35:
                        continue
                st["l"] = l = l + 1
                for k in range(l, 36):
                    st["p"] *= mu / k
                    st["q"] += st["p"]
                    pp[k] = st["q"]
                    if u <= st["q"]:
                        st["l"] = k
                        return float(k)
                st["l"] = 35
    s, d = st["s"], st["d"]
    g = mu + s * norm_rand()
    if g >= 0.:
        pois = math.floor(g)
        if pois >= st["big_l"]:
            return pois
        fk = pois
        difmuk = mu - fk
        u = unif_rand()
        if d * u >= difmuk * difmuk * difmuk:
            return pois
    if new_big_mu or mu != st["muprev2"]:
        st["muprev2"] = mu
        st["omega"] = _M_1_SQRT_2PI / s
        b1 = one_24 / mu
        b2 = 0.3 * b1 * b1
        c3 = one_7 * b1 * b2
        st["b1"], st["b2"], st["c3"] = b1, b2, c3
        st["c2"] = b2 - 15. * c3
        st["c1"] = b1 - 6. * b2 + 45. * c3
        st["c0"] = 1. - b1 + 3. * b2 - 15. * c3
        st["c"] = 0.1069 / mu
    omega, c, c0, c1, c2, c3 = st["omega"], st["c"], st["c0"], st["c1"], st["c2"], st["c3"]
    kflag = -1
    if g >= 0.:
        kflag = 0
    while True:
        if kflag != 0:
            E = exp_rand()
            u = 2 * unif_rand() - 1.
            t = 1.8 + (abs(E) if u >= 0 else -abs(E))     # fsign(E, u)
            if not (t > -0.6744):
                continue
            pois = math.floor(mu + s * t)
            fk = pois
            difmuk = mu - fk
            kflag = 1
        # Step F
        if pois < 10:
            px = -mu
            py = math.pow(mu, pois) / _FACT[int(pois)]
        else:
            dl = one_12 / fk
            dl = dl * (1. - 4.8 * dl * dl)
            v = difmuk / fk
            if abs(v) <= 0.25:
                px = fk * v * v * (((((((a7 * v + a6) * v + a5) * v + a4) * v + a3) * v + a2) * v + a1) * v + a0) - dl
            else:
                px = fk * math.log(1. + v) - difmuk - dl
            py = _M_1_SQRT_2PI / math.sqrt(fk)
        x = (0.5 - difmuk) / s
        x *= x
        fx = -0.5 * x
        fy = omega * (((c3 * x + c2) * x + c1) * x + c0)
        if kflag > 0:
            if c * abs(u) <= py * _cexp(px + E) - fy * _cexp(fx + E):
                break
        else:
            if fy - u * fy <= py * _cexp(px - fx):
                break
            kflag = 1        # weiter mit Step E
    return pois


def rgeom1(p: float) -> float:
    if not math.isfinite(p) or p <= 0 or p > 1:
        return math.nan
    return rpois1(exp_rand() * ((1 - p) / p))


# ── Zustand für die C-Nachbildung (python/src/_rng_r.c, Etappe 7.3b) ─────
#
# Die gemeinsamen Kerne mit Zufallszahlen (Bootstrap, truncnorm) ziehen in der
# C-Erweiterung simlev._ext über eine C-Nachbildung von R's RNG. Sie arbeitet auf diesem
# Zustand: c_state() übergibt ihn als drei Puffer, der Kern zieht, c_state_put() schreibt
# ihn zurück. Danach ist der Zustand derselbe, als hätten die Funktionen oben gezogen.
# Nachgebildet sind die Arten, die dieses Modul kennt (Mersenne-Twister und
# L'Ecuyer-CMRG mit Inversion); sonst liefert c_state() None, und der Aufrufer rechnet
# mit dem reinen Python-Kern.

_RP_DOUBLES = ("b1", "b2", "c", "c0", "c1", "c2", "c3", "p0", "p", "q", "s", "d", "omega",
               "big_l", "muprev", "muprev2")


def c_state(rpois: bool = False):
    """Zustand für die C-Nachbildung als ``(ist, mt, pst)`` oder ``None`` (Art nicht nachgebildet).

    ``ist``: int32[12] mit kind, n01, mti, twisted, lec[0..5], rpois ``l``, ``m``; ``mt``:
    die 624 Wörter des Mersenne-Twisters als int32-Sicht auf ``_S.mt`` (die C-Seite ändert
    sie an Ort und Stelle); ``pst``: mit ``rpois`` float64[52] mit dem Zustand von
    :func:`rpois1` (``_RP``), sonst ``None``. Der Aufrufer hat vorher wie der reine
    Python-Kern ``_get_state()`` gerufen und gibt das Tupel nach dem Kern (auch nach einem
    Fehler) an :func:`c_state_put`.
    """
    S = _S
    if S.kind not in (MERSENNE_TWISTER, LECUYER_CMRG) or S.n01 != INVERSION:
        return None
    mt = S.mt
    if (not isinstance(mt, np.ndarray) or mt.dtype != np.uint32 or mt.shape != (_N,)
            or not mt.flags.c_contiguous or not mt.flags.writeable):
        return None
    if not (-2147483648 <= S.mti <= 2147483647) or len(S.lec) != 6:
        return None
    rp = _RP
    ist = np.array([S.kind, S.n01, S.mti, 0] + [_to_int32(v) for v in S.lec]
                   + [rp["l"], rp["m"]], dtype=np.int32)
    pst = None
    if rpois:
        pst = np.array([rp[k] for k in _RP_DOUBLES] + rp["pp"], dtype=np.float64)
    return ist, mt.view(np.int32), pst


def c_state_put(st) -> None:
    """Zustand aus :func:`c_state` nach dem C-Kern zurückschreiben."""
    ist, _mt, pst = st
    S = _S
    v = ist.tolist()
    S.mti = v[2]
    if v[3]:
        S._buf = np.empty(0)           # neu erzeugte Wörter: Ausgabepuffer neu berechnen
    S.lec = [x & _M32 for x in v[4:10]]
    if pst is not None:
        rp = _RP
        rp["l"], rp["m"] = v[10], v[11]
        w = pst.tolist()
        for k, x in zip(_RP_DOUBLES, w):
            rp[k] = x
        rp["pp"] = w[16:]


# ── R-Funktionen (vektorisiert, mit Recycling) ───────────────────────────

def _n_of(n):
    if isinstance(n, (list, tuple, np.ndarray)) and np.size(n) != 1:
        return int(np.size(n))
    n = float(np.asarray(n).ravel()[0])
    if math.isnan(n) or n < 0:
        raise ValueError("invalid arguments")
    return int(n)


def _arr(x):
    a = np.asarray(x, dtype=np.float64).ravel()
    return a


def _na_warn(out):
    if np.isnan(out).any():
        warnings.warn("NAs produced", stacklevel=3)


def _gen1(fn, n, a):
    n = _n_of(n)
    aa = _arr(a)
    if n == 0:
        return np.empty(0)
    if aa.size < 1:
        out = np.full(n, _NA_REAL)       # fillWithNAs
        _na_warn(out)
        return out
    _get_state()
    al = aa.tolist()
    na = len(al)
    out = np.fromiter((fn(al[i % na]) for i in range(n)), dtype=np.float64, count=n)
    _na_warn(out)
    return out


def _gen2(fn, n, a, b):
    n = _n_of(n)
    aa = _arr(a)
    bb = _arr(b)
    if n == 0:
        return np.empty(0)
    if aa.size < 1 or bb.size < 1:
        out = np.full(n, _NA_REAL)       # fillWithNAs
        _na_warn(out)
        return out
    _get_state()
    al, bl = aa.tolist(), bb.tolist()
    na, nb = len(al), len(bl)
    out = np.fromiter((fn(al[i % na], bl[i % nb]) for i in range(n)), dtype=np.float64, count=n)
    _na_warn(out)
    return out


def runif(n, min=0.0, max=1.0):  # noqa: A002 - R-Argumentnamen
    """``runif(n, min, max)``."""
    a = _arr(min)
    b = _arr(max)
    nn = _n_of(n)
    if a.size == 1 and b.size == 1 and nn > 0:
        lo, hi = float(a[0]), float(b[0])
        if math.isfinite(lo) and math.isfinite(hi) and lo < hi:
            _get_state()
            u = _unif_block(nn)
            if ((u <= 0) | (u >= 1)).any():     # bei den eingebauten Generatoren unmöglich
                raise AssertionError("unif_rand außerhalb (0,1)")
            return lo + (hi - lo) * u
    return _gen2(runif1, n, min, max)


def rnorm(n, mean=0.0, sd=1.0):
    """``rnorm(n, mean, sd)``."""
    a = _arr(mean)
    b = _arr(sd)
    nn = _n_of(n)
    if a.size == 1 and b.size == 1 and nn > 0 and _S.n01 == INVERSION:
        mu, sg = float(a[0]), float(b[0])
        if not math.isnan(mu) and math.isfinite(sg) and sg > 0 and math.isfinite(mu):
            _get_state()
            return mu + sg * _norm_block(nn)
    return _gen2(rnorm1, n, mean, sd)


def rexp(n, rate=1.0):
    """``rexp(n, rate)`` (C: ``rexp(1/rate)``)."""
    r = _arr(rate)
    return _gen1(rexp1, n, 1.0 / r)


def rgamma(n, shape, rate=1.0, scale=None):
    """``rgamma(n, shape, rate = 1, scale = 1/rate)``."""
    if scale is None:
        scale = 1.0 / _arr(rate)
    return _gen2(rgamma1, n, shape, scale)


def rchisq(n, df):
    """``rchisq(n, df)`` (zentral)."""
    return _gen1(rchisq1, n, df)


def rt(n, df):
    """``rt(n, df)`` (zentral)."""
    return _gen1(rt1, n, df)


def rpois(n, lam):
    """``rpois(n, lambda)``."""
    return _gen1(rpois1, n, lam)


def rgeom(n, prob):
    """``rgeom(n, prob)``."""
    return _gen1(rgeom1, n, prob)


# ── sample.int ───────────────────────────────────────────────────────────

def _revsort(a, ib):
    """R's ``revsort``: absteigend per Heapsort, ``ib`` parallel (sort.c)."""
    n = len(a)
    if n <= 1:
        return
    # 1-basierte Indizes wie im C-Code (a--, ib--)
    a.insert(0, 0.0)
    ib.insert(0, 0)
    l = (n >> 1) + 1
    ir = n
    while True:
        if l > 1:
            l -= 1
            ra = a[l]
            ii = ib[l]
        else:
            ra = a[ir]
            ii = ib[ir]
            a[ir] = a[1]
            ib[ir] = ib[1]
            ir -= 1
            if ir == 1:
                a[1] = ra
                ib[1] = ii
                break
        i = l
        j = l << 1
        while j <= ir:
            if j < ir and a[j] > a[j + 1]:
                j += 1
            if ra > a[j]:
                a[i] = a[j]
                ib[i] = ib[j]
                i = j
                j += j
            else:
                j = ir + 1
        a[i] = ra
        ib[i] = ii
    del a[0]
    del ib[0]


def _fixup_prob(p, require_k, replace):
    s = 0.0
    npos = 0
    for v in p:
        if not math.isfinite(v):
            raise ValueError("NA in probability vector")
        if v < 0.0:
            raise ValueError("negative probability")
        if v > 0.0:
            npos += 1
            s += v
    if npos == 0 or (not replace and require_k > npos):
        raise ValueError("too few positive probabilities")
    return [v / s for v in p]


def sample_int(n, size=None, replace=False, prob=None, use_hash=None):
    """``sample.int(n, size = n, replace = FALSE, prob = NULL, useHash)``.

    Liefert ein ``int64``-Array mit 1-basierten Indizes wie R."""
    dn = float(n)
    if size is None:
        size = dn
    k = int(size)
    if use_hash is None:
        use_hash = dn > 1e7 and not replace and prob is None and k <= dn / 2
    if use_hash:
        if not math.isfinite(dn) or dn < 0 or dn > 4.5e15 or (k > 0 and dn == 0):
            raise ValueError("invalid first argument")
        if k < 0:
            raise ValueError("invalid 'size' argument")
        if k > dn / 2:
            raise ValueError("This algorithm is for size <= n/2")
        _get_state()
        out = []
        seen = set()
        for _ in range(k):
            for _j in range(100):
                v = int(unif_index(dn) + 1)
                if v not in seen:
                    break
            seen.add(v)
            out.append(v)
        return np.array(out, dtype=np.int64)
    if prob is not None:
        ni = int(n)
        if ni < 0 or (k > 0 and ni == 0):
            raise ValueError("invalid first argument")
        if k < 0:
            raise ValueError("invalid 'size' argument")
        if not replace and k > ni:
            raise ValueError("cannot take a sample larger than the population when 'replace = FALSE'")
        p = [float(v) for v in np.asarray(prob, dtype=np.float64).ravel()]
        if len(p) != ni:
            raise ValueError("incorrect number of probabilities")
        _get_state()
        p = _fixup_prob(p, k, replace)
        if replace:
            nc = sum(1 for v in p if ni * v > 0.1)
            if nc > 200:
                return _walker(ni, p, k)
            perm = list(range(1, ni + 1))
            _revsort(p, perm)
            for i in range(1, ni):
                p[i] += p[i - 1]
            out = []
            for _ in range(k):
                rU = unif_rand()
                j = 0
                while j < ni - 1:
                    if rU <= p[j]:
                        break
                    j += 1
                out.append(perm[j])
            return np.array(out, dtype=np.int64)
        perm = list(range(1, ni + 1))
        _revsort(p, perm)
        out = []
        totalmass = 1.0
        n1 = ni - 1
        for _ in range(k):
            rT = totalmass * unif_rand()
            mass = 0.0
            j = 0
            while j < n1:
                mass += p[j]
                if rT <= mass:
                    break
                j += 1
            out.append(perm[j])
            totalmass -= p[j]
            for kk in range(j, n1):
                p[kk] = p[kk + 1]
                perm[kk] = perm[kk + 1]
            n1 -= 1
        return np.array(out, dtype=np.int64)
    if not math.isfinite(dn) or dn < 0 or dn > 4.5e15 or (k > 0 and dn == 0):
        raise ValueError("invalid first argument")
    if k < 0:
        raise ValueError("invalid 'size' argument")
    if not replace and k > dn:
        raise ValueError("cannot take a sample larger than the population when 'replace = FALSE'")
    _get_state()
    if replace or k < 2:
        return np.array([int(unif_index(dn) + 1) for _ in range(k)], dtype=np.int64)
    ni = int(dn)
    x = list(range(ni))
    out = []
    for _ in range(k):
        j = int(unif_index(ni))
        out.append(x[j] + 1)
        ni -= 1
        x[j] = x[ni]
    return np.array(out, dtype=np.int64)


def _walker(n, p, nans):
    q = [v * n for v in p]
    a = [0] * n
    HL = [0] * n
    H = -1
    L = n
    for i in range(n):
        if q[i] < 1.:
            H += 1
            HL[H] = i
        else:
            L -= 1
            HL[L] = i
    if H >= 0 and L < n:
        for k in range(n - 1):
            i = HL[k]
            j = HL[L]
            a[i] = j
            q[j] += q[i] - 1
            if q[j] < 1.:
                L += 1
            if L >= n:
                break
    for i in range(n):
        q[i] += i
    out = []
    for _ in range(nans):
        if _S.sample == ROUNDING:
            rU = unif_rand() * n
            k = int(rU)
        else:
            k = int(unif_index(n))
            rU = k + unif_rand()
        out.append(k + 1 if rU < q[k] else a[k] + 1)
    return np.array(out, dtype=np.int64)


def sample(x, size=None, replace=False, prob=None):
    """``sample(x, size, replace, prob)``."""
    xa = np.asarray(x)
    if xa.ndim == 0 or xa.size == 1:
        v = xa.ravel()[0]
        if np.issubdtype(xa.dtype, np.number) and v >= 1 and np.isfinite(v):
            return sample_int(float(v), size, replace, prob)
    xa = xa.ravel()
    if size is None:
        size = xa.size
    idx = sample_int(xa.size, size, replace, prob)
    return xa[idx - 1]
