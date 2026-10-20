"""Formatierung und Druckausgabe wie R 4.3.3.

Zeichengenaue Nachbildung von R's ``format``, ``formatC``, ``prettyNum``,
``sprintf``, ``as.character``, ``paste``, ``round``/``signif`` und der
``print``-Ausgabe von Vektoren, Matrizen, data.frames, Faktoren und Listen
(Quellen: ``src/main/format.c``, ``printutils.c``, ``printvector.c``,
``printarray.c``, ``print.c``, ``paste.c``, ``sprintf.c``, ``util.c``,
``src/nmath/fround.c``, ``fprec.c``, ``src/library/base/R/format.R``,
``dataframe.R``, ``factor.R``, ``dates.R``).

Voreinstellungen wie ``options(digits = 7, scipen = 0, width = 80,
OutDec = ".")``; änderbar über :func:`set_options`.

Abbildung der Python-Eingaben auf R-Typen
-----------------------------------------
==============================  ======================================
Python                          R
==============================  ======================================
``float``, float-Array          double (``nan`` = ``NA``; R's ``NaN``
                                über :data:`R_NAN`)
``int``, Ganzzahl-Array         integer
``bool``, bool-Array,           logical (``None`` = ``NA``)
object-Array aus bool/None
``str``, object-Array aus       character (``None`` = ``NA``)
str/None
``datetime64``, ``date``        Date (``NaT`` = ``NA``)
``pandas.Categorical``          factor
``pandas.Series``               benannter Vektor (Index = Namen; ein
                                ``RangeIndex`` gilt als unbenannt)
==============================  ======================================

Ganzzahlige R-Vektoren mit NA kommen aus ``reftree.decode`` als float an;
dann ``type="integer"`` (bzw. ``types={"spalte": "integer"}`` bei
data.frames) angeben oder ``pandas.array(..., dtype="Int64")`` verwenden –
R druckt integer und double verschieden (``100000`` gegenüber ``1e+05``).

Zeilennamen von DataFrames: ganzzahliger Index ``i`` -> ``"i+1"`` (pandas
zählt ab 0, R ab 1; ``df.iloc[2:4]`` druckt wie ``d[3:4, ]``), sonst
``str(index)``.

Alle ``print_*``-Funktionen liefern den Text, den R mit
``paste(capture.output(print(x)), collapse = "\\n")`` erzeugt (ohne
abschließenden Zeilenumbruch).
"""
from __future__ import annotations

import datetime as _dt
import math
import re
import struct
import sys
import unicodedata

import numpy as np
import pandas as pd

__all__ = [
    "R_NAN", "NA_REAL", "set_options", "get_option",
    "r_round", "signif", "fround", "fprec",
    "as_character", "paste", "paste0", "to_string",
    "format", "format_date", "format_info", "formatC", "prettyNum", "sprintf",
    "nchar", "encode_string",
    "print_vector", "print_matrix", "print_data_frame", "format_data_frame", "print_factor",
    "print_list", "print_default", "r_cat", "cat_str",
]

# ── Optionen ────────────────────────────────────────────────────────────────

_OPT = {"digits": 7, "scipen": 0, "width": 80, "OutDec": "."}


def set_options(**kw):
    """Wie ``options()``: ``digits``, ``scipen``, ``width``, ``OutDec``.

    Liefert die alten Werte (für ``set_options(**alt)``)."""
    old = {}
    for k, v in kw.items():
        if k not in _OPT:
            raise KeyError(k)
        old[k] = _OPT[k]
        _OPT[k] = v
    return old


def get_option(name):
    return _OPT[name]


# ── NA / NaN ────────────────────────────────────────────────────────────────

def _bits2d(b):
    return struct.unpack("<d", struct.pack("<Q", b))[0]


#: R's ``NA_real_`` (Bitmuster wie in R: NaN mit der Nutzlast 1954 im unteren Wort).
NA_REAL = _bits2d(0x7FF00000000007A2)
#: R's ``NaN`` (gewöhnliches NaN). Wie in R gilt jedes NaN ohne die NA-Nutzlast als NaN.
R_NAN = _bits2d(0x7FF8000000000000)


def _is_rnan(x):
    """True für R's ``NaN`` (NaN ohne die NA-Nutzlast 1954), wie ``ISNAN(x) && !R_IsNA(x)``."""
    if x == x:
        return False
    return (struct.unpack("<Q", struct.pack("<d", x))[0] & 0xFFFFFFFF) != 1954


def _nan_mask(a):
    """Maske der NaN-Werte, die nicht NA sind (R's ``NaN``)."""
    a = np.ascontiguousarray(a, dtype=np.float64)
    return np.isnan(a) & ((a.view(np.uint64) & np.uint64(0xFFFFFFFF)) != np.uint64(1954))


# ── R-Vektoren ──────────────────────────────────────────────────────────────

_EPOCH = np.datetime64("1970-01-01", "D")


class _V:
    """Interne Darstellung eines atomaren R-Vektors.

    type   : 'double' | 'integer' | 'logical' | 'character' | 'Date' | 'factor' | 'NULL'
    v      : double/Date -> float64-Array (nan = NA); integer -> int64; logical -> bool;
             character -> Liste aus str/None; factor -> int64-Codes (0-basiert, -1 = NA)
    na     : bool-Array (NA-Positionen)
    nan    : bool-Array (nur double: R-NaN)
    names  : Liste aus str/None oder None
    levels : nur factor
    """

    __slots__ = ("type", "v", "na", "nan", "names", "levels", "ordered", "scalar")

    def __init__(self, type, v, na=None, nan=None, names=None, levels=None, ordered=False, scalar=False):
        self.type = type
        self.v = v
        n = len(v)
        self.na = np.zeros(n, bool) if na is None else na
        self.nan = np.zeros(n, bool) if nan is None else nan
        self.names = names
        self.levels = levels
        self.ordered = ordered
        self.scalar = scalar

    def __len__(self):
        return len(self.v)

    def subset(self, idx):
        idx = np.asarray(idx, dtype=np.int64)
        if self.type == "character":
            v = [self.v[i] for i in idx]
        else:
            v = self.v[idx]
        names = None if self.names is None else [self.names[i] for i in idx]
        return _V(self.type, v, self.na[idx], self.nan[idx], names, self.levels, self.ordered)


def _is_na_scalar(x):
    if x is None or x is pd.NA or x is pd.NaT:
        return True
    if isinstance(x, float) and x != x:
        return True
    if isinstance(x, np.floating) and x != x:
        return True
    if isinstance(x, np.datetime64) and np.isnat(x):
        return True
    return False


def _date_days(x):
    if isinstance(x, np.datetime64):
        if np.isnat(x):
            return math.nan
        return float((x.astype("datetime64[D]") - _EPOCH).astype(np.int64))
    if isinstance(x, pd.Timestamp):
        return float((np.datetime64(x.date(), "D") - _EPOCH).astype(np.int64))
    if isinstance(x, _dt.datetime):
        x = x.date()
    return float(x.toordinal() - 719163)


def _from_seq(vals, names=None, scalar=False):
    """Liste von Python-Werten -> _V (Typ aus den Werten)."""
    kinds = set()
    for x in vals:
        if _is_na_scalar(x):
            if isinstance(x, (float, np.floating)):
                kinds.add("nanfloat")
            continue
        if isinstance(x, (bool, np.bool_)):
            kinds.add("logical")
        elif isinstance(x, (int, np.integer)):
            kinds.add("integer")
        elif isinstance(x, (float, np.floating)):
            kinds.add("double")
        elif isinstance(x, str):
            kinds.add("character")
        elif isinstance(x, (_dt.date, np.datetime64, pd.Timestamp)):
            kinds.add("Date")
        else:
            kinds.add("character")
    n = len(vals)
    if "character" in kinds:
        v = [None if _is_na_scalar(x) else (x if isinstance(x, str) else str(x)) for x in vals]
        return _V("character", v, np.array([s is None for s in v], bool), names=names, scalar=scalar)
    if "Date" in kinds:
        a = np.array([math.nan if _is_na_scalar(x) else _date_days(x) for x in vals], dtype=np.float64)
        return _V("Date", a, np.isnan(a), names=names, scalar=scalar)
    if "double" in kinds or ("nanfloat" in kinds and kinds - {"nanfloat"} != {"logical"}):
        a = np.array([float(x) if isinstance(x, (float, np.floating)) else
                      (math.nan if _is_na_scalar(x) else float(x)) for x in vals], dtype=np.float64)
        nan = _nan_mask(a)
        return _V("double", a, np.isnan(a) & ~nan, nan, names=names, scalar=scalar)
    if "integer" in kinds and any(abs(int(x)) > 2147483647 for x in vals if not _is_na_scalar(x)):
        a = np.array([math.nan if _is_na_scalar(x) else float(x) for x in vals], dtype=np.float64)
        return _V("double", a, np.isnan(a), names=names, scalar=scalar)
    if "integer" in kinds:
        na = np.array([_is_na_scalar(x) for x in vals], bool)
        a = np.array([0 if na[i] else int(vals[i]) for i in range(n)], dtype=np.int64)
        return _V("integer", a, na, names=names, scalar=scalar)
    if "logical" in kinds or not kinds or kinds == {"nanfloat"}:
        na = np.array([_is_na_scalar(x) for x in vals], bool)
        a = np.array([False if na[i] else bool(vals[i]) for i in range(n)], dtype=bool)
        return _V("logical", a, na, names=names, scalar=scalar)
    raise TypeError("nicht unterstützter Typ")


def _names_from_index(idx):
    if isinstance(idx, pd.RangeIndex):
        return None
    return [None if _is_na_scalar(x) else str(x) for x in idx]


def _as_v(x, type=None):
    """Python-Objekt -> _V. ``type`` erzwingt einen R-Typ ('integer', 'double', …)."""
    if isinstance(x, _V):
        v = x
    elif x is None:
        if type is not None and type != "NULL":
            v = _V("logical", np.zeros(1, bool), np.ones(1, bool), scalar=True)
        else:
            v = _V("NULL", np.zeros(0))
    elif isinstance(x, pd.Series):
        names = _names_from_index(x.index)
        if isinstance(x.dtype, pd.CategoricalDtype):
            v = _from_categorical(pd.Categorical(x), names)
        else:
            v = _from_array(x.to_numpy(dtype=object if x.dtype.kind not in "biufM" else None), names, x.dtype)
    elif isinstance(x, pd.Categorical):
        v = _from_categorical(x, None)
    elif isinstance(x, pd.api.extensions.ExtensionArray):
        v = _from_array(np.asarray(x, dtype=object), None, x.dtype)
    elif isinstance(x, (pd.Index,)):
        v = _from_array(x.to_numpy(), None, x.dtype)
    elif isinstance(x, np.ndarray):
        v = _from_array(x.ravel(order="F"), None, x.dtype)
    elif isinstance(x, (list, tuple)):
        v = _from_seq(list(x))
    elif isinstance(x, dict):
        v = _from_seq(list(x.values()), [str(k) for k in x.keys()])
    else:
        v = _from_seq([x], scalar=True)
    if type is not None and v.type != type:
        v = _coerce(v, type)
    return v


def _from_categorical(c, names):
    codes = np.asarray(c.codes, dtype=np.int64)
    levels = [str(l) for l in c.categories]
    return _V("factor", codes, codes < 0, names=names, levels=levels, ordered=bool(c.ordered))


def _from_array(a, names, dtype=None):
    a = np.asarray(a)
    k = a.dtype.kind
    if dtype is not None and not isinstance(dtype, np.dtype):
        # pandas-Erweiterungstypen (Int64, boolean, string, Float64)
        name = str(dtype)
        vals = list(a)
        if name.startswith("Int") or name.startswith("UInt"):
            na = np.array([_is_na_scalar(x) for x in vals], bool)
            return _V("integer", np.array([0 if m else int(x) for x, m in zip(vals, na)], np.int64), na, names=names)
        if name == "boolean":
            na = np.array([_is_na_scalar(x) for x in vals], bool)
            return _V("logical", np.array([False if m else bool(x) for x, m in zip(vals, na)], bool), na, names=names)
        if name.startswith("Float"):
            f = np.array([math.nan if _is_na_scalar(x) else float(x) for x in vals], np.float64)
            nan = _nan_mask(f)
            return _V("double", f, np.isnan(f) & ~nan, nan, names=names)
        if name.startswith("datetime64"):
            a = np.asarray(pd.Series(vals).to_numpy(dtype="datetime64[ns]"))
            k = "M"
        elif name.startswith("string") or name == "str":
            s = [None if _is_na_scalar(x) else str(x) for x in vals]
            return _V("character", s, np.array([q is None for q in s], bool), names=names)
        else:
            k = a.dtype.kind
    if k == "f":
        f = a.astype(np.float64)
        nan = _nan_mask(f)
        return _V("double", f, np.isnan(f) & ~nan, nan, names=names)
    if k in "iu":
        if len(a) and (a.max() > 2147483647 or a.min() < -2147483647):
            f = a.astype(np.float64)
            return _V("double", f, np.zeros(len(a), bool), names=names)
        return _V("integer", a.astype(np.int64), np.zeros(len(a), bool), names=names)
    if k == "b":
        return _V("logical", a.astype(bool), np.zeros(len(a), bool), names=names)
    if k == "M":
        d = a.astype("datetime64[D]")
        nat = np.isnat(d)
        f = (d - _EPOCH).astype(np.int64).astype(np.float64)
        f[nat] = math.nan
        return _V("Date", f, nat, names=names)
    if k in "US":
        s = [str(x) for x in a]
        return _V("character", s, np.zeros(len(s), bool), names=names)
    if len(a) == 0:
        return _V("character", [], np.zeros(0, bool), names=names)
    return _from_seq(list(a), names)


_NUM_RE = re.compile(r"^[ \t\n\r\f\v]*([+-]?)(?:(0[xX][0-9a-fA-F]*\.?[0-9a-fA-F]*(?:[pP][+-]?[0-9]+)?)|"
                     r"((?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)|(Inf|inf|infinity|Infinity|INF)|(NaN))"
                     r"[ \t\n\r\f\v]*$")


def _r_strtod(s):
    """String -> double wie ``String2Real``: (Wert, NA, NaN, Warnung)."""
    if s is None or s == "NA":
        return math.nan, True, False, False
    m = _NUM_RE.match(s)
    if not m:
        return math.nan, True, False, True
    sign = -1.0 if m.group(1) == "-" else 1.0
    if m.group(2):
        h = m.group(2)
        if "p" not in h.lower():
            h += "p0"
        try:
            return sign * float.fromhex(h), False, False, False
        except (ValueError, OverflowError):
            return math.nan, True, False, True
    if m.group(3):
        return sign * float(m.group(3)), False, False, False
    if m.group(4):
        return sign * math.inf, False, False, False
    return math.nan, False, True, False


def _coerce(v, type):
    """Typumwandlung wie as.<type>()."""
    if v.type == type:
        return v
    r = _coerce0(v, type)
    r.scalar = v.scalar
    return r


def _coerce0(v, type):
    if v.type == "logical" and v.na.all() and type != "character":
        n = len(v)
        if type in ("double", "Date"):
            return _V(type, np.full(n, math.nan), np.ones(n, bool), names=v.names)
        if type == "integer":
            return _V("integer", np.zeros(n, np.int64), np.ones(n, bool), names=v.names)
        if type == "factor":
            return _V("factor", np.full(n, -1, np.int64), np.ones(n, bool), names=v.names, levels=[])
    if type == "character":
        return _V("character", _as_character_list(v), v.na.copy(), names=v.names)
    if type == "double":
        if v.type in ("integer", "logical", "Date"):
            f = v.v.astype(np.float64)
            f[v.na] = math.nan
            return _V("double", f, v.na.copy(), names=v.names)
        if v.type == "factor":
            f = v.v.astype(np.float64) + 1
            f[v.na] = math.nan
            return _V("double", f, v.na.copy(), names=v.names)
        if v.type == "character":
            f, na, nan, warn = [], [], [], False
            for s in v.v:
                z, isna, isnan, bad = _r_strtod(s)
                f.append(z)
                na.append(isna)
                nan.append(isnan)
                warn = warn or bad
            if warn:
                import warnings
                warnings.warn("NAs introduced by coercion")
            return _V("double", np.array(f, np.float64), np.array(na, bool), np.array(nan, bool), names=v.names)
    if type == "integer":
        if v.type == "double":
            na = v.na | v.nan | ~np.isfinite(v.v)
            big = np.isfinite(v.v) & (np.abs(v.v) >= 2147483648.0)
            if (big | np.isinf(v.v)).any():
                import warnings
                warnings.warn("NAs introduced by coercion to integer range")
            na = na | big
            iv = np.zeros(len(v), np.int64)
            ok = ~na
            iv[ok] = np.trunc(v.v[ok]).astype(np.int64)
            return _V("integer", iv, na, names=v.names)
        if v.type == "logical":
            return _V("integer", v.v.astype(np.int64), v.na.copy(), names=v.names)
        if v.type == "character":
            return _coerce0(_coerce0(v, "double"), "integer")
        if v.type == "factor":
            return _V("integer", v.v + 1, v.na.copy(), names=v.names)
    if type == "logical":
        if v.type in ("double", "integer"):
            na = v.na | v.nan
            return _V("logical", (v.v != 0) & ~na, na, names=v.names)
    if type == "Date" and v.type in ("double", "integer"):
        f = v.v.astype(np.float64)
        f[v.na] = math.nan
        return _V("Date", f, v.na.copy(), names=v.names)
    raise TypeError("Umwandlung %s -> %s nicht unterstützt" % (v.type, type))


def _out(strs, v, na_none=True):
    """Ergebnis von format() & Co.: str (Skalar), ndarray oder Series (benannt)."""
    if v.scalar and len(strs) == 1:
        return strs[0]
    a = np.empty(len(strs), dtype=object)
    a[:] = strs
    if v.names is not None:
        return pd.Series(a, index=v.names, dtype=object)
    return a


# ── Zahlen: round / signif ─────────────────────────────────────────────────

_M_LOG10_2 = 0.301029995663981195213738894724
_DBL_DIG = 15
_MAX10E = 308


def _pow_di(x, n):
    """R_pow_di: x^n durch wiederholtes Quadrieren (double)."""
    xn = 1.0
    if x != x:
        return x
    if n != 0:
        if not math.isfinite(x):
            return math.pow(x, float(n))
        neg = n < 0
        if neg:
            n = -n
        while True:
            if n & 1:
                xn *= x
            n >>= 1
            if n:
                x *= x
            else:
                break
        if neg:
            xn = 1.0 / xn
    return xn


def _nearbyint(x):
    # Python round() auf float: Runden auf gerade Zahl, exakt wie nearbyint
    r = float(round(x))
    if r == 0.0:
        return math.copysign(0.0, x)
    return r


def _logb(x):
    m, e = math.frexp(x)
    return float(e - 1)


def fround(x, digits):
    """R's ``fround`` (R >= 4.0.0) für ein double ``x``."""
    max_digits = 308 + 15
    if x != x or digits != digits:
        return x + digits
    if not math.isfinite(x):
        return x
    if digits > max_digits or x == 0.0:
        return x
    if digits < -_MAX10E:
        return 0.0
    if digits == 0.0:
        return _nearbyint(x)
    dig = int(math.floor(digits + 0.5))
    sgn = 1.0
    if x < 0.0:
        sgn = -1.0
        x = -x
    l10x = _M_LOG10_2 * (0.5 + _logb(x))
    if l10x + dig > _DBL_DIG:
        return sgn * x
    if dig <= _MAX10E:
        pow10 = _pow_di(10.0, dig)
        x10 = x * pow10
        i10 = math.floor(x10)
        xd = i10 / pow10
        xu = math.ceil(x10) / pow10
    else:
        e10 = dig - _MAX10E
        p10 = _pow_di(10.0, e10)
        pow10 = _pow_di(10.0, _MAX10E)
        x10 = (x * pow10) * p10
        i10 = math.floor(x10)
        xd = i10 / pow10 / p10
        xu = math.ceil(x10) / pow10 / p10
    du = xu - x
    dd = x - xd
    return sgn * (xu if (du < dd or (math.fmod(i10, 2.0) == 1 and du == dd)) else xd)


def fprec(x, digits):
    """R's ``fprec`` (signif) für ein double ``x``."""
    max_digits = 22
    if x != x or digits != digits:
        return x + digits
    if not math.isfinite(x):
        return x
    if not math.isfinite(digits):
        if digits > 0.0:
            return x
        digits = 1.0
    if x == 0:
        return x
    dig = int(math.floor(abs(digits) + 0.5)) * (1 if digits >= 0 else -1)  # C round()
    if dig > max_digits:
        return x
    elif dig < 1:
        dig = 1
    sgn = 1.0
    if x < 0.0:
        sgn = -sgn
        x = -x
    l10 = math.log10(x)
    e10 = int(dig - 1 - math.floor(l10))
    if abs(l10) < _MAX10E - 2:
        p10 = 1.0
        if e10 > _MAX10E:
            p10 = _pow_di(10.0, e10 - _MAX10E)
            e10 = _MAX10E
        if e10 > 0:
            pow10 = _pow_di(10.0, e10)
            return sgn * (_nearbyint((x * pow10) * p10) / pow10) / p10
        else:
            pow10 = _pow_di(10.0, -e10)
            return sgn * (_nearbyint(x / pow10) * pow10)
    else:
        do_round = _MAX10E - l10 >= _pow_di(10.0, -dig)
        e2 = dig + (1 if e10 > 0 else -1) * max_digits
        p10 = _pow_di(10.0, e2)
        x *= p10
        P10 = _pow_di(10.0, e10 - e2)
        x *= P10
        if do_round:
            x += 0.5
        x = math.floor(x) / p10
        return sgn * x / P10


def _math2(f, x, digits):
    if isinstance(x, pd.DataFrame):
        return x.apply(lambda c: pd.Series(_math2(f, c.to_numpy(dtype=np.float64), digits), index=c.index))
    if isinstance(x, pd.Series):
        return pd.Series(_math2(f, x.to_numpy(dtype=np.float64), digits), index=x.index, name=x.name)
    if np.isscalar(x) or x is None:
        if x is None:
            return math.nan
        if isinstance(x, (int, np.integer)) and not isinstance(x, (bool, np.bool_)) and f is fround:
            return x  # round() auf integer bleibt integer
        return f(float(x), float(digits))
    a = np.asarray(x)
    if a.dtype.kind in "iu" and f is fround:
        return a.copy()
    a = a.astype(np.float64)
    flat = a.ravel().tolist()
    d = np.asarray(digits, dtype=np.float64).ravel().tolist()
    if len(d) == 1:
        dd = float(d[0])
        out = [f(v, dd) for v in flat]
    else:
        n = max(len(flat), len(d))
        out = [f(flat[i % len(flat)], d[i % len(d)]) for i in range(n)]
        return np.array(out, np.float64)
    return np.array(out, np.float64).reshape(a.shape)


def r_round(x, digits=0):
    """``round(x, digits)`` wie R >= 4.0.0 (Algorithmus aus ``fround.c``).

    Akzeptiert Skalare, Arrays, Series und DataFrames (elementweise)."""
    return _math2(fround, x, digits)


def signif(x, digits=6):
    """``signif(x, digits)`` wie R (``fprec.c``)."""
    return _math2(fprec, x, digits)


# ── formatReal / scientific ────────────────────────────────────────────────

# Die Tabelle in format.c besteht aus double-Literalen (1e23 … 1e27 sind
# daher nicht exakt), die nach long double gewandelt werden.
_TBL = [np.longdouble(float("1e%d" % _k)) for _k in range(28)]
_TBL_ARR = np.array(_TBL, dtype=np.longdouble)
_TBL_D = [float(t) for t in _TBL]
_KP_MAX = 27


def _scientific(r, digits):
    """``scientific()`` aus format.c, vektorisiert für |x| > 0 (endlich).

    r: float64-Array (Beträge, > 0). Liefert (kpower, nsig, roundingwidens)."""
    n = len(r)
    if n == 0:
        z = np.zeros(0, np.int64)
        return z, z, np.zeros(0, bool)
    if digits >= _DBL_DIG + 1:
        kpw = np.empty(n, np.int64)
        nsg = np.empty(n, np.int64)
        for i, ri in enumerate(r.tolist()):
            buff = "%#.*e" % (digits - 1, ri)
            kpw[i] = int(buff[digits + 2:])
            j = digits
            while j >= 2:
                if buff[j] != "0":
                    break
                j -= 1
            nsg[i] = j
        return kpw, nsg, np.zeros(n, bool)
    kp = np.array([math.floor(math.log10(v)) for v in r.tolist()], dtype=np.int64) - digits + 1
    rp = r.astype(np.longdouble)
    small = np.abs(kp) <= _KP_MAX
    m = small & (kp > 0)
    if m.any():
        rp[m] = rp[m] / _TBL_ARR[kp[m]]
    m = small & (kp < 0)
    if m.any():
        rp[m] = rp[m] * _TBL_ARR[-kp[m]]
    m = ~small
    if m.any():
        rp[m] = rp[m] / np.power(np.longdouble(10), kp[m].astype(np.longdouble))
    m = rp < _TBL[digits - 1]
    if m.any():
        rp[m] = rp[m] * np.longdouble(10)
        kp[m] -= 1
    alpha = np.rint(rp).astype(np.float64)
    nsig = np.full(n, digits, np.int64)
    active = np.ones(n, bool)
    for _ in range(digits):
        alpha = alpha / 10.0
        isint = alpha == np.floor(alpha)
        dec = active & isint
        nsig[dec] -= 1
        active &= isint
        if not active.any():
            break
    m = nsig == 0
    if m.any() and digits > 0:
        nsig[m] = 1
        kp[m] += 1
    kpower = kp + digits - 1
    rgt = np.clip(digits - kpower, 0, _KP_MAX)
    fuzz = np.array([0.5 / _TBL_D[g] for g in rgt.tolist()], dtype=np.float64)
    rw = np.zeros(n, bool)
    cand = (kpower > 0) & (kpower <= _KP_MAX)
    if cand.any():
        idx = np.nonzero(cand)[0]
        lhs = r[idx].astype(np.longdouble)
        rhs = _TBL_ARR[kpower[idx]] - fuzz[idx].astype(np.longdouble)
        rw[idx] = lhs < rhs
    return kpower, nsig, rw


def _format_real(x, na, nan, digits=None, nsmall=0, scipen=None):
    """``formatReal``: (w, d, e) für das float-Array ``x``.

    na/nan: Masken für NA bzw. NaN (beide sind in ``x`` nan)."""
    if digits is None:
        digits = _OPT["digits"]
    if scipen is None:
        scipen = _OPT["scipen"]
    x = np.asarray(x, dtype=np.float64)
    fin = np.isfinite(x)
    naflag = bool((na & ~fin).any()) if len(x) else False
    nanflag = bool((~na & np.isnan(x)).any()) if len(x) else False
    posinf = bool((x == math.inf).any())
    neginf = bool((x == -math.inf).any())
    xf = x[fin]
    neg = 0
    if len(xf):
        r = np.abs(xf)
        nz = r != 0.0
        kpower = np.zeros(len(xf), np.int64)
        nsig = np.ones(len(xf), np.int64)
        rw = np.zeros(len(xf), bool)
        negi = (xf < 0).astype(np.int64)
        if nz.any():
            kp_, ns_, rw_ = _scientific(r[nz], digits)
            kpower[nz] = kp_
            nsig[nz] = ns_
            rw[nz] = rw_
        left = kpower + 1
        left = left - rw.astype(np.int64)
        sleft = negi + np.where(left <= 0, 1, left)
        right = nsig - left
        if negi.any():
            neg = 1
        rgt = int(right.max())
        mxl = int(left.max())
        mnl = int(left.min())
        mxsl = int(sleft.max())
        mxns = int(nsig.max())
    else:
        rgt = mxl = mxsl = mxns = None
        mnl = None
    if mxns is not None:
        if digits == 0:
            rgt = 0
        if mxl < 0:
            mxsl = 1 + neg
        if rgt < 0:
            rgt = 0
        wF = mxsl + rgt + (rgt != 0)
        e = 2 if (mxl > 100 or mnl <= -99) else 1
        d = mxns - 1
        w = neg + (d > 0) + d + 4 + e
        if wF <= w + scipen:
            e = 0
            if nsmall > rgt:
                rgt = nsmall
                wF = mxsl + rgt + (rgt != 0)
            d = rgt
            w = wF
    else:
        w = d = e = 0
    if naflag and w < 2:
        w = 2
    if nanflag and w < 3:
        w = 3
    if posinf and w < 3:
        w = 3
    if neginf and w < 4:
        w = 4
    return w, d, e


def _encode_real(x, w, d, e, dec=".", na=False, nan=False, na_string="NA"):
    """``EncodeReal0`` für ein double."""
    if not math.isfinite(x):
        if x != x:
            s = "NaN" if (nan and not na) else na_string
        elif x > 0:
            s = "Inf"
        else:
            s = "-Inf"
        return s.rjust(w)
    if x == 0.0:
        x = 0.0
    if e:
        if d:
            s = "%#*.*e" % (w, d, x)
        else:
            s = "%*.*e" % (w, d, x)
    else:
        s = "%*.*f" % (w, d, x)
    if dec != ".":
        s = s.replace(".", dec)
    return s


def _drop0(s):
    """Nachkomma-Nullen entfernen wie ``EncodeRealDrop0``."""
    p = s.find(".")
    if p < 0:
        return s
    q = p + 1
    replace = p
    while q < len(s) and "0" <= s[q] <= "9":
        if s[q] != "0":
            replace = q + 1
        q += 1
    return s[:replace] + s[q:]


def _encode_reals(v, w, d, e, dec="."):
    xs = v.v.tolist()
    na = v.na.tolist()
    nan = v.nan.tolist()
    return [_encode_real(xs[i], w, d, e, dec, na[i], nan[i]) for i in range(len(xs))]


def _index_width(n):
    return int(math.log10(n + 0.5) + 1)


def _format_integer(v):
    """``formatInteger``: Feldbreite."""
    ok = ~v.na
    w = 2 if v.na.any() else 1
    if ok.any():
        vals = v.v[ok]
        xmin = int(vals.min())
        xmax = int(vals.max())
        if xmin < 0:
            w = max(w, _index_width(-xmin) + 1)
        if xmax > 0:
            w = max(w, _index_width(xmax))
    return w


def _encode_integer(x, na, w, na_string="NA"):
    if na:
        return na_string.rjust(w)
    return ("%d" % x).rjust(w)


def _format_logical(v):
    w = 1
    for i in range(len(v)):
        if v.na[i]:
            if w < 2:
                w = 2
        elif v.v[i] and w < 4:
            w = 4
        elif not v.v[i] and w < 5:
            w = 5
            break
    return w


def _encode_logical(x, na, w, na_string="NA"):
    if na:
        return na_string.rjust(w)
    return ("TRUE" if x else "FALSE").rjust(w)


# ── Zeichenketten: Breite und Kodierung ────────────────────────────────────

def _wcwidth(k):
    c = chr(k)
    cat = unicodedata.category(c)
    if cat in ("Mn", "Me") or k == 0x200B:
        return 0
    if cat == "Cf" and k != 0xAD:
        return 0
    if unicodedata.east_asian_width(c) in ("W", "F"):
        return 2
    return 1


def _printable(k):
    cat = unicodedata.category(chr(k))
    return cat not in ("Cc", "Cn", "Cs", "Zl", "Zp")


def _strwid(s, quote=0):
    """``Rstrwid``: Anzeigebreite in Zeichen (Escapes mitgezählt)."""
    if s.isascii() and s.isprintable() and "\\" not in s and (not quote or quote not in s):
        return len(s)
    n = 0
    for c in s:
        k = ord(c)
        if 0x20 <= k < 0x7F:
            if c == "\\":
                n += 2
            elif c in "'\"`":
                n += 2 if quote == c else 1
            else:
                n += 1
        elif k < 0x80:
            n += 2 if c in "\a\b\f\n\r\t\v\0" else 4
        else:
            if _printable(k):
                n += _wcwidth(k)
            else:
                n += 10 if k > 0xFFFF else 6
    return n


_ESC = {"\a": "\\a", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t", "\v": "\\v", "\0": "\\0"}


def _escape(s, quote=0):
    if s.isascii() and s.isprintable() and "\\" not in s and (not quote or quote not in s):
        return s
    out = []
    for c in s:
        k = ord(c)
        if 0x20 <= k < 0x7F:
            if c == "\\":
                out.append("\\\\")
            elif c in "'\"`" and quote == c:
                out.append("\\" + c)
            else:
                out.append(c)
        elif k < 0x80:
            out.append(_ESC.get(c, "\\%03o" % k))
        else:
            if _printable(k):
                out.append(c)
            elif k > 0xFFFF:
                out.append("\\U{%06x}" % k)
            else:
                out.append("\\u%04x" % k)
    return "".join(out)


def _encode_string(s, w, quote=0, justify="left", na_quote="NA", na_noquote="<NA>"):
    """``EncodeString``: s (None = NA), Feldbreite w, quote = '"' oder 0."""
    if s is None:
        p = na_quote if quote else na_noquote
        i = len(p)
        quote = 0
    else:
        i = _strwid(s, quote)
        p = _escape(s, quote)
    b = w - i - (2 if quote else 0)
    if justify == "none":
        b = 0
    left = right = ""
    if b > 0 and justify != "left":
        b0 = b // 2 if justify == "centre" else b
        left = " " * b0
        b -= b0
    if b > 0 and justify != "right":
        right = " " * b
    if quote:
        p = quote + p + quote
    return left + p + right


def _format_string(strs, quote=0):
    """``formatString``: maximale Breite."""
    w = 0
    for s in strs:
        if s is None:
            l = 2 if quote else 4
        else:
            l = _strwid(s, quote) + (2 if quote else 0)
        if l > w:
            w = l
    return w


def encode_string(x, width=0, quote="", justify="left", na_encode=True):
    """``encodeString``: Escapes, Anführungszeichen, Auffüllen."""
    v = _as_v(x, "character")
    q = quote if quote else 0
    if width is None:
        width = max([(_strwid(s, q) + (2 if q else 0)) if s is not None else 2 for s in v.v] or [0])
    out = []
    for s in v.v:
        if s is None and not na_encode:
            out.append(None)
        elif s is None:
            out.append("NA".ljust(width) if justify == "left" else "NA".rjust(width))
        else:
            out.append(_encode_string(s, width, q, justify))
    return _out(out, v)


def nchar(x, type="chars"):
    """``nchar(x, type)``: 'chars', 'bytes' oder 'width'."""
    v = _as_v(x, "character")
    res = []
    for s in v.v:
        if s is None:
            res.append(2)
        elif type == "bytes":
            res.append(len(s.encode("utf-8")))
        elif type == "width":
            res.append(sum(_wcwidth(ord(c)) if ord(c) >= 0x80 else 1 for c in s))
        else:
            res.append(len(s))
    if v.scalar:
        return res[0]
    return np.array(res, dtype=np.int64)


# ── as.character / paste ───────────────────────────────────────────────────

def _real_to_str(x, na=False, nan=False):
    """``StringFromReal`` mit 15 Stellen (as.character für double)."""
    if x != x:
        return None if (na or not nan) else "NaN"
    w, d, e = _format_real(np.array([x]), np.array([False]), np.array([False]), digits=15)
    return _drop0(_encode_real(x, w, d, e, _OPT["OutDec"]))


def _as_character_list(v):
    t = v.type
    if t == "character":
        return list(v.v)
    if t == "double":
        xs = v.v.tolist()
        return [None if v.na[i] else _real_to_str(xs[i], False, bool(v.nan[i])) for i in range(len(xs))]
    if t == "integer":
        return [None if v.na[i] else "%d" % int(v.v[i]) for i in range(len(v))]
    if t == "logical":
        return [None if v.na[i] else ("TRUE" if v.v[i] else "FALSE") for i in range(len(v))]
    if t == "Date":
        return _format_date_list(v.v, ["%Y-%m-%d"])
    if t == "factor":
        return [None if v.na[i] else v.levels[int(v.v[i])] for i in range(len(v))]
    if t == "NULL":
        return []
    raise TypeError(t)


def as_character(x):
    """``as.character(x)``; double mit 15 signifikanten Stellen (R 4.3).

    Namen entfallen wie in R; NA -> ``None``."""
    v = _as_v(x)
    res = _as_character_list(v)
    if v.scalar:
        return res[0]
    a = np.empty(len(res), dtype=object)
    a[:] = res
    return a


def paste(*args, sep=" ", collapse=None):
    """``paste(..., sep, collapse)`` (NA wird zu "NA")."""
    vecs = []
    for a in args:
        v = _as_v(a)
        if v.type == "NULL":
            continue
        s = ["NA" if q is None else q for q in _as_character_list(v)]
        vecs.append(s)
    if not vecs:
        return "" if collapse is not None else np.empty(0, dtype=object)
    n = max(len(s) for s in vecs)
    if n == 0:
        res = []
    else:
        vecs = [s if len(s) else [""] for s in vecs]
        res = [sep.join(s[i % len(s)] for s in vecs) for i in range(n)]
    if collapse is not None:
        return collapse.join(res)
    if n == 1 and all(_as_v(a).scalar for a in args if a is not None):
        return res[0]
    a = np.empty(len(res), dtype=object)
    a[:] = res
    return a


def paste0(*args, collapse=None):
    """``paste0(..., collapse)``."""
    return paste(*args, sep="", collapse=collapse)


def to_string(x, sep=", "):
    """``toString(x)``."""
    return paste(x, collapse=sep)


# ── format() ───────────────────────────────────────────────────────────────

_JUST = {"left": 0, "right": 1, "centre": 2, "none": 3}


def _format_internal(v, trim=False, digits=None, nsmall=0, width=None, justify="left",
                     na_encode=True, scientific=None, decimal_mark=None):
    """``.Internal(format(...))`` (do_format) -> Liste von Zeichenketten (None = NA)."""
    if digits is None:
        digits = _OPT["digits"]
    scipen = _OPT["scipen"]
    if scientific is not None:
        if isinstance(scientific, (bool, np.bool_)):
            scipen = -99 if scientific else 310
        else:
            scipen = int(scientific)
    dec = _OPT["OutDec"] if decimal_mark is None else decimal_mark
    wd = 0 if width is None else int(width)
    n = len(v)
    if n == 0:
        return []
    t = v.type
    if t == "logical":
        w = 0 if trim else _format_logical(v)
        w = max(w, wd)
        return [_encode_logical(bool(v.v[i]), bool(v.na[i]), w) for i in range(n)]
    if t == "integer":
        w = 0 if trim else _format_integer(v)
        w = max(w, wd)
        return [_encode_integer(int(v.v[i]), bool(v.na[i]), w) for i in range(n)]
    if t == "double":
        w, d, e = _format_real(v.v, v.na, v.nan, digits, nsmall, scipen)
        if trim:
            w = 0
        w = max(w, wd)
        return _encode_reals(v, w, d, e, dec)
    if t == "character":
        adj = justify
        w = wd
        if adj != "none":
            for s in v.v:
                if s is not None:
                    w = max(w, _strwid(s, 0))
                elif na_encode:
                    w = max(w, 2)
        else:
            w = 0
        out = []
        for s in v.v:
            if not na_encode and s is None:
                out.append(None)
                continue
            s0 = "NA" if s is None else s
            il = _strwid(s0, 0)
            b = w - il
            left = right = ""
            if b > 0 and adj != "left":
                b0 = b // 2 if adj == "centre" else b
                left = " " * b0
                b -= b0
            if b > 0 and adj != "right":
                right = " " * b
            out.append(left + s0 + right)
        return out
    raise TypeError(t)


def format(x, format=None, *, trim=False, digits=None, nsmall=0, justify="left", width=None,
           na_encode=True, scientific=None, big_mark="", big_interval=3, small_mark="",
           small_interval=5, decimal_mark=None, zero_print=None, drop0trailing=False,
           type=None):
    """``format(x, ...)`` wie R's ``format.default``/``format.Date``/``format.factor``.

    Args:
        x: Vektor (siehe Modul-Doku), Series (benannt) oder Skalar.
        format: nur für Datumswerte: Formatangabe wie ``strftime`` (z. B. "%d.%m.%Y").
        trim, digits, nsmall, justify, width, na_encode, scientific, big_mark,
        big_interval, small_mark, small_interval, decimal_mark, zero_print,
        drop0trailing: wie in R (Punkte im Namen -> ``_``).
        type: R-Typ erzwingen ('integer', 'double', …), z. B. für ganzzahlige
            Spalten mit NA.

    Returns:
        str bei Skalaren, sonst object-Array bzw. Series (benannt); NA (bei
        ``na_encode=False``) als ``None``.
    """
    if isinstance(format, (bool, np.bool_)):
        trim, format = bool(format), None
    if isinstance(x, pd.DataFrame):
        return pd.DataFrame({c: _fmt_column(x[c], digits=digits, na_encode=na_encode, justify=justify)
                             for c in x.columns}, index=x.index)
    if isinstance(x, np.ndarray) and x.ndim >= 2:
        return _keep_dim(x, globals()["format"](x.ravel(order="F"), format, trim=trim, digits=digits, nsmall=nsmall,
                                   justify=justify, width=width, na_encode=na_encode, scientific=scientific,
                                   big_mark=big_mark, big_interval=big_interval, small_mark=small_mark,
                                   small_interval=small_interval, decimal_mark=decimal_mark,
                                   zero_print=zero_print, drop0trailing=drop0trailing, type=type))
    v = _as_v(x, type)
    if v.type == "Date":
        res = _format_date_list(v.v, [format or "%Y-%m-%d"])
        return _out(res, v)
    if v.type == "factor":
        cv = _V("character", _as_character_list(v), v.na.copy(), names=v.names, scalar=v.scalar)
        v = cv
    if v.type == "NULL":
        return "NULL"
    if v.type == "character":
        res = _format_internal(v, trim, digits, nsmall, width, justify, na_encode, scientific)
        return _out(res, v)
    dec = _OPT["OutDec"] if decimal_mark is None else decimal_mark
    r = _format_internal(v, trim, digits, nsmall, width, "right", na_encode, scientific, dec)
    r = _pretty_num_chr(r, big_mark=big_mark, big_interval=big_interval, small_mark=small_mark,
                        small_interval=small_interval, decimal_mark=dec, input_d_mark=dec,
                        preserve_width="individual" if trim else "common", zero_print=zero_print,
                        drop0trailing=drop0trailing, is_cmplx=False)
    return _out(r, v)


def format_info(x, digits=None, nsmall=0):
    """``format.info(x)``: [w] bzw. [w, d, e] für double."""
    v = _as_v(x)
    if v.type == "double":
        return list(_format_real(v.v, v.na, v.nan, digits, nsmall))
    if v.type == "integer":
        return [_format_integer(v)]
    if v.type == "logical":
        return [_format_logical(v)]
    return [_format_string(_as_character_list(v), 0)]


# ── prettyNum ──────────────────────────────────────────────────────────────

def _format_zeros(x, zero_print, replace=False):
    """``.format.zeros``."""
    if zero_print is None:
        return x
    nx = [_r_strtod(s)[0] for s in x]
    i0 = [i for i, z in enumerate(nx) if z == 0]
    if not i0:
        return x
    if isinstance(zero_print, bool):
        zero_print = "0" if zero_print else " "
    x = list(x)
    nz = len(zero_print)
    if not replace and any(len(x[i]) < nz for i in i0):
        import warnings
        warnings.warn("'zero.print' is truncated to fit into formatted zeros; consider 'replace=TRUE'")
    for i in i0:
        s = x[i]
        if replace:
            x[i] = zero_print
            continue
        nc = len(s)
        ind0 = s.find("0") + 1
        if ind0 == 0:
            ind0 = -1
        i2 = min(nc, nz - 1 + ind0)
        i1 = max(1, i2 - nz + 1)
        # substr(x, i1, i2) <- zero.print  (ersetzt höchstens i2-i1+1 Zeichen)
        k = i2 - i1 + 1
        if k > 0:
            s = s[:i1 - 1] + zero_print[:k] + s[i1 - 1 + k:]
        if nc > i2:
            s = s[:i2] + " " * (nc - i2)
        x[i] = s
    return x


def _strsplit_fixed(s, sep):
    """strsplit(s, sep, fixed = TRUE)[[1]] (ohne leeres Endstück)."""
    out = []
    while s:
        p = s.find(sep)
        if p < 0:
            out.append(s)
            break
        out.append(s[:p])
        s = s[p + len(sep):]
    return out


def _rev(s):
    return s[::-1]


def _pretty_num_chr(x, big_mark="", big_interval=3, small_mark="", small_interval=5,
                    decimal_mark=".", input_d_mark=None, preserve_width="common",
                    zero_print=None, replace_zero=False, drop0trailing=False, is_cmplx=None,
                    not_char=False):
    """prettyNum für eine Liste von Zeichenketten (None = NA)."""
    if input_d_mark is None:
        input_d_mark = decimal_mark
    n_mark = big_mark == "" and small_mark == "" and (not_char or decimal_mark == input_d_mark)
    if big_mark == decimal_mark and big_mark != "":
        import warnings
        warnings.warn("'big.mark' and 'decimal.mark' are both '%s', which could be confusing" % big_mark)
    n_zero = zero_print is None and not drop0trailing
    if n_mark and n_zero:
        return x
    if n_mark and not drop0trailing:
        return _format_zeros(x, zero_print, replace=replace_zero)
    xs = ["NA" if s is None else s for s in x]
    B, A, iN = [], [], []
    for s in xs:
        parts = _strsplit_fixed(s, input_d_mark)
        if len(parts) > 2:
            parts = [input_d_mark.join(parts[:-1]), parts[-1]]
        B.append(parts[0] if parts else "NA")
        if len(parts) >= 2:
            A.append(parts[1])
            iN.append(False)
        else:
            A.append("")
            iN.append(True)
    if big_mark:
        pat = re.compile("[0-9]{%d,}" % (big_interval + 1))
        sub = re.compile("([0-9]{%d})\\B" % big_interval)
        rb = _rev(big_mark).replace("\\", "\\\\")
        for i, b in enumerate(B):
            if pat.search(b):
                B[i] = _rev(sub.sub("\\1" + rb, _rev(b)))
    if small_mark:
        pat = re.compile("[0-9]{%d,}" % (small_interval + 1))
        sub = re.compile("([0-9]{%d}\\B)" % small_interval)
        sm = small_mark.replace("\\", "\\\\")
        for i, a in enumerate(A):
            if pat.search(a):
                A[i] = sub.sub("\\1" + sm, a)
    if drop0trailing:
        idx = [i for i in range(len(A)) if not iN[i]]
        a = [A[i] for i in idx]
        has_e = [j for j, s in enumerate(a) if "e" in s]
        if has_e:
            for j in range(len(a)):
                if j in has_e:
                    a[j] = re.sub("e[+-]0+$", "", a[j])
                else:
                    a[j] = re.sub("0+$", "", a[j])
        else:
            a = [re.sub("0+$", "", s) for s in a]
        for j, i in enumerate(idx):
            A[i] = a[j]
        iN = [s == "" for s in A]
    res = [B[i] + ("" if iN[i] else decimal_mark) + A[i] for i in range(len(B))]
    res = _format_zeros(res, zero_print, replace=replace_zero)
    if preserve_width != "none":
        dlen = [len(res[i]) - len(xs[i]) for i in range(len(res))]
        if any(d > 0 for d in dlen):
            if preserve_width == "individual":
                for i, d in enumerate(dlen):
                    if d > 0:
                        res[i] = re.sub("^ {1,%d}" % d, "", res[i])
            elif preserve_width == "common":
                w = max(_strwid(s, 0) for s in res)
                res = [" " * (w - _strwid(s, 0)) + s for s in res]
    return res


def prettyNum(x, big_mark="", big_interval=3, small_mark="", small_interval=5,
              decimal_mark=None, input_d_mark=None, preserve_width="common",
              zero_print=None, replace_zero=False, drop0trailing=False, **kw):
    """``prettyNum(x, ...)``: Tausender-/Dezimaltrenner in formatierte Zahlen."""
    dec = _OPT["OutDec"] if decimal_mark is None else decimal_mark
    v = _as_v(x)
    if v.type != "character":
        strs = []
        for i in range(len(v)):
            strs.append(format(v.subset([i]), big_mark=big_mark, big_interval=big_interval,
                               small_mark=small_mark, small_interval=small_interval,
                               decimal_mark=dec, zero_print=zero_print,
                               drop0trailing=drop0trailing, **kw)[0])
        res = _pretty_num_chr(strs, big_mark, big_interval, small_mark, small_interval, dec,
                              dec if input_d_mark is None else input_d_mark, preserve_width,
                              zero_print, replace_zero, drop0trailing, not_char=True)
    else:
        res = _pretty_num_chr(list(v.v), big_mark, big_interval, small_mark, small_interval, dec,
                              dec if input_d_mark is None else input_d_mark, preserve_width,
                              zero_print, replace_zero, drop0trailing)
    return _out(res, v)


# ── formatC ────────────────────────────────────────────────────────────────

def _c_flags(flag):
    # Python kennt "'" und "I" nicht (in der C-Locale wirkungslos)
    return "".join(c for c in flag if c in "-+ #0")


def _keep_dim(x, res):
    """Ergebnis wie das Eingabe-Objekt formen (Matrix -> Matrix, DataFrame -> DataFrame)."""
    if isinstance(x, pd.DataFrame):
        a = np.asarray(res, dtype=object).reshape(x.shape, order="F")
        return pd.DataFrame(a, index=x.index, columns=x.columns)
    if isinstance(x, np.ndarray) and x.ndim >= 2:
        return np.asarray(res, dtype=object).reshape(x.shape, order="F")
    return res


def formatC(x, width=None, digits=None, format=None, flag="", mode=None, big_mark="",
            big_interval=3, small_mark="", small_interval=5, decimal_mark=None,
            preserve_width="individual", zero_print=None, replace_zero=True,
            drop0trailing=False):
    """``formatC(x, width, digits, format, flag, mode, big.mark, …)`` wie R.

    ``format``: "d", "f", "e", "E", "g", "G", "fg" oder "s". Matrizen
    (2-D-Array, DataFrame) behalten ihre Form."""
    if isinstance(x, pd.DataFrame) or (isinstance(x, np.ndarray) and x.ndim >= 2):
        xa = x.to_numpy() if isinstance(x, pd.DataFrame) else x
        if isinstance(x, pd.DataFrame) and all(k in "fiu" for k in x.dtypes.map(lambda d: d.kind)):
            xa = x.to_numpy(dtype=np.float64)
        return _keep_dim(x, formatC(xa.ravel(order="F"), width, digits, format, flag, mode, big_mark,
                                    big_interval, small_mark, small_interval, decimal_mark,
                                    preserve_width, zero_print, replace_zero, drop0trailing))
    dec = _OPT["OutDec"] if decimal_mark is None else decimal_mark
    v = _as_v(x)
    if v.type == "factor":
        v = _V("integer", v.v + 1, v.na, names=v.names, scalar=v.scalar)
    if v.type == "Date":
        v = _V("double", v.v, v.na, names=v.names, scalar=v.scalar)
    flag = str(flag)
    nf = list(flag)
    if not all(c in "0+- #'I" for c in nf):
        raise ValueError("'flag' should contain only characters from [0+- #'I]")

    def format_char(strs, width, flag):
        if width is None:
            width = 0
        elif width < 0:
            flag = "-"
            width = -width
        cv = _V("character", strs, np.array([s is None for s in strs], bool))
        return _format_internal(cv, width=width, justify="left" if flag == "-" else "right")

    n = len(v)
    if n == 0:
        return np.empty(0, dtype=object)
    if mode is None:
        mode = {"double": "double", "integer": "integer", "logical": "logical",
                "character": "character"}[v.type]
    elif mode in ("double", "real", "integer"):
        if mode == "real":
            mode = "double"
        v = _coerce(v, mode)
    elif mode != "character":
        raise ValueError("'mode' must be \"double\" (\"real\"), \"integer\" or \"character\"")
    if mode == "character" or format == "s":
        if mode != "character":
            import warnings
            warnings.warn('coercing argument to "character" for format="s"')
        strs = _as_character_list(v)
        return _out(format_char(strs, width, flag), v)
    if format is None:
        format = "d" if mode == "integer" else "g"
    else:
        if format in ("f", "e", "E", "g", "G", "fg"):
            if mode == "integer":
                mode = "double"
                v = _coerce(v, "double")
        elif format == "d":
            if mode != "integer":
                mode = "integer"
                v = _coerce(v, "integer")
        else:
            raise ValueError('\'format\' must be one of {"f","e","E","g","G", "fg", "s"}')
    if v.type == "logical":
        v = _coerce(v, "integer")
        mode = "integer"
    if mode == "integer":
        vals = [float(i) for i in v.v.tolist()]
        ok = (~v.na).tolist()
    else:
        vals = v.v.tolist()
        ok = np.isfinite(v.v).tolist()
    some_special = not all(ok)
    rQ = None
    if some_special:
        sub = v.subset([i for i in range(n) if not ok[i]])
        rQ = ["NA" if s is None else s for s in _as_character_list(sub)]
        vals = [vals[i] if ok[i] else 0.0 for i in range(n)]
    if width is None and digits is None:
        width = 1
    if digits is None:
        digits = 2 if mode == "integer" else 4
    elif digits < 0:
        digits = 6
    else:
        max_digits = 50 if format != "f" else 324
        if digits > max_digits:
            import warnings
            warnings.warn("'digits' reduced to %d" % max_digits)
            digits = max_digits
    if width is None:
        width = digits + 1
    elif width == 0:
        width = digits
    # i.strlen
    istrlen = []
    for xv in vals:
        if format in ("fg", "f"):
            xEx = int(math.floor(math.log10(abs(xv + (xv == 0)))))
            base = int(xv < 0 or flag != "") + digits
            if format == "f":
                base += 2 + max(xEx, 0)
            else:
                base += 1 + max(xEx, digits, digits + (-xEx) + 1) + len(nf)
            istrlen.append(max(abs(int(width)), base))
        else:
            istrlen.append(max(abs(int(width)), digits + 8))
    if digits > 0 and "#" in nf:
        digits = -digits
    r = _str_signif(vals, mode, int(width), int(digits), format, flag, istrlen)
    if some_special:
        fc = format_char(rQ, width, flag)
        j = 0
        for i in range(n):
            if not ok[i]:
                r[i] = fc[j]
                j += 1
    if big_mark or small_mark or dec != "." or zero_print is not None or drop0trailing:
        r = _pretty_num_chr(r, big_mark=big_mark, big_interval=big_interval, small_mark=small_mark,
                            small_interval=small_interval, decimal_mark=dec, input_d_mark=".",
                            preserve_width=preserve_width, zero_print=zero_print,
                            replace_zero=replace_zero, drop0trailing=drop0trailing, is_cmplx=False)
    return _out(r, v)


def _fl_w(flag, width):
    # negative Feldbreite über '*' wirkt in C wie das Flag '-'
    return flag + "-" if width < 0 else flag


def _str_signif(vals, type, width, digits, format, flag, istrlen):
    """``str_signif`` aus util.c."""
    dig = abs(digits)
    rm_trailing_0 = digits >= 0
    do_fg = format == "fg"
    if width == 0:
        raise ValueError("width cannot be zero")
    out = []
    if format == "d":
        if type != "integer":
            raise ValueError("'type' must be \"integer\" for  \"d\"-format")
        for i, xv in enumerate(vals):
            out.append(_c_printf(_fl_w(flag, width), abs(width), None, "d", int(xv))[:istrlen[i] + 2])
        return out
    conv = "g" if do_fg else format
    for i, xx in enumerate(vals):
        lim = istrlen[i] + 2
        if do_fg:
            if xx == 0.0:
                out.append("0")
                continue
            xxx = abs(xx)
            iex = int(math.floor(math.log10(xxx) + 1e-12))
            X = fround(xxx / math.pow(10.0, float(iex)) + 1e-12, float(dig - 1))
            if iex > 0 and X >= 10:
                xx = X * math.pow(10.0, float(iex))
                iex += 1
            if iex == -4 and abs(xx) < 1e-4:
                iex = -5
            if iex < -4:
                s = _c_printf(flag, 0, dig - 1 + -iex, "f", xx)[:lim]
                if rm_trailing_0:
                    j = len(s) - 1
                    while j >= 0 and s[j] == "0":
                        j -= 1
                    s = s[:j + 1]
                out.append(s)
            else:
                out.append(_c_printf(_fl_w(flag, width), abs(width), (iex + 1) if iex >= dig else dig,
                                     "g", xx)[:lim])
        else:
            out.append(_c_printf(_fl_w(flag, width), abs(width), dig, conv, xx)[:lim])
    return out


# ── sprintf ────────────────────────────────────────────────────────────────

_CONV = "diosfeEgGxXaA"


def _hexfloat(x, prec, upper, flags, width):
    """C-``%a`` (glibc)."""
    if x != x or math.isinf(x):
        s = "nan" if x != x else "inf"
        sign = "-" if math.copysign(1.0, x) < 0 else ("+" if "+" in flags else (" " if " " in flags else ""))
        s = sign + s
    else:
        sign = "-" if math.copysign(1.0, x) < 0 else ("+" if "+" in flags else (" " if " " in flags else ""))
        a = abs(x)
        if a == 0.0:
            lead, mant, exp = 0, 0, 0
        else:
            m, e = math.frexp(a)  # a = m * 2^e, m in [0.5, 1)
            if e < -1021:  # subnormal
                lead = 0
                mant = int(a / 2.0 ** -1074)  # Vielfaches von 2^-1074, 52 bit
                exp = -1022
            else:
                ival = int(m * 2.0 ** 53)  # 53 bit
                lead = 1
                mant = ival - (1 << 52)
                exp = e - 1
        nd = 13
        digs = "%013x" % mant
        if prec is not None and prec < nd:
            full = (lead << 52) | mant
            shift = 4 * (nd - prec)
            q, rem = divmod(full, 1 << shift)
            half = 1 << (shift - 1)
            if rem > half or (rem == half and (q & 1)):
                q += 1
            lead = q >> (4 * prec)
            mant = q & ((1 << (4 * prec)) - 1)
            digs = ("%0*x" % (prec, mant)) if prec > 0 else ""
            if lead >= 2:
                lead //= 2
                # glibc normalisiert nicht, sondern schreibt "0x2p..." – selten
                lead, exp = 1, exp + 1
                digs = "0" * prec
        else:
            if prec is None:
                digs = digs.rstrip("0")
            else:
                digs = digs + "0" * (prec - nd)
        body = "0x%d" % lead
        if digs or "#" in flags:
            body += "." + digs
        body += "p%+d" % exp
        s = sign + body
    if upper:
        s = s.upper()
    if width and len(s) < width:
        if "-" in flags:
            s = s.ljust(width)
        elif "0" in flags and x == x and not math.isinf(x):
            pre = 3 if s[0] in "+- " else 2
            s = s[:pre] + "0" * (width - len(s)) + s[pre:]
        else:
            s = s.rjust(width)
    return s


_SPEC_RE = re.compile(r"^%([-+ #0'I]*)(\*|\d+)?(?:\.(\*|\d*))?([a-zA-Z])$")


def _c_format(spec, val):
    """Eine C-Formatangabe (ohne '*') auf einen Wert anwenden."""
    m = _SPEC_RE.match(spec)
    if not m:
        raise ValueError("unrecognised format specification '%s'" % spec)
    flags, w, p, conv = m.groups()
    width = int(w) if w else 0
    prec = None if p is None else (int(p) if p != "" else 0)
    return _c_printf(flags, width, prec, conv, val)


def _glibc_alt_g(flags, width, prec, conv, x):
    """glibc-Eigenheit bei ``%#g``: rundet x auf 10^P hoch, obwohl der
    Exponent vorher P-1 war, schreibt glibc "1.e+P" (ohne Nullen)."""
    import decimal
    P = 6 if prec is None else (prec if prec > 0 else 1)
    a = abs(x)
    X0 = decimal.Decimal(a).adjusted()
    if X0 != P - 1:
        return None
    s = "%.*e" % (P - 1, a)
    X = int(s[s.index("e") + 1:])
    if X != P:
        return None
    sign = "-" if x < 0 or (x == 0 and math.copysign(1.0, x) < 0) else ("+" if "+" in flags else (" " if " " in flags else ""))
    body = "1." + ("E" if conv == "G" else "e") + ("%+03d" % X)
    out = sign + body
    if len(out) < width:
        if "-" in flags:
            out = out.ljust(width)
        elif "0" in flags:
            out = out[:len(sign)] + "0" * (width - len(out)) + out[len(sign):]
        else:
            out = out.rjust(width)
    return out


def _c_printf(flags, width, prec, conv, val):
    """C-printf (glibc) für eine Umwandlung; width/prec als Zahlen (prec None = keine)."""
    pyfl = _c_flags(flags)
    if conv in "gG" and "#" in flags and isinstance(val, float) and math.isfinite(val) and val != 0:
        r = _glibc_alt_g(flags, width, prec, conv, val)
        if r is not None:
            return r
    if conv == "s":
        s = val
        if prec is not None:
            b = s.encode("utf-8")[:prec]
            s = b.decode("utf-8", errors="ignore")
        nb = len(s.encode("utf-8"))
        if nb < width:
            pad = " " * (width - nb)
            s = s + pad if "-" in flags else pad + s
        return s
    if conv in "aA":
        return _hexfloat(val, prec, conv == "A", flags, width)
    if conv in "xXo" and val < 0:
        val = val & 0xFFFFFFFF
    ps = "%" + pyfl + (str(width) if width else "") + ("" if prec is None else "." + str(prec)) + \
        ("d" if conv == "i" else conv)
    return ps % val


def sprintf(fmt, *args):
    """``sprintf(fmt, ...)`` mit R's Vektorsemantik.

    Recycling über ``fmt`` und alle Argumente; NA -> "NA" (mit Breite),
    ``Inf``/``-Inf``/``NaN`` wie R; ``%s`` von Zahlen = as.character (15
    Stellen); ``%d`` nur für ganzzahlige Werte; Breiten bei ``%s`` in Bytes
    (wie C). Liefert str, wenn alles Länge 1 ist, sonst ein object-Array."""
    fv = _as_v(fmt, "character")
    vs = [_as_v(a) for a in args]
    nfmt = len(fv)
    if nfmt == 0:
        return np.empty(0, dtype=object)
    for v in vs:
        if len(v) == 0:
            return np.empty(0, dtype=object)
    maxlen = max([nfmt] + [len(v) for v in vs])
    if maxlen % nfmt or any(maxlen % len(v) for v in vs):
        raise ValueError("arguments cannot be recycled to the same length")
    used = [False] * len(vs)
    coerced = {}
    results = []
    for ns in range(maxlen):
        f = fv.v[ns % nfmt]
        if f is None:
            f = "NA"
        out = []
        cur = 0
        cnt = 0
        n = len(f)
        while cur < n:
            if f[cur] == "%":
                if cur < n - 1 and f[cur + 1] == "%":
                    out.append("%")
                    cur += 2
                    continue
                j = cur + 1
                while j < n and f[j] not in _CONV:
                    j += 1
                if j >= n:
                    raise ValueError("unrecognised format specification '%s'" % f[cur:])
                spec = f[cur:j + 1]
                cur = j + 1
                nthis = -1
                mm = re.match(r"^%(\d{1,2})\$", spec)
                if mm and len(spec) > 3:
                    k = int(mm.group(1))
                    if k > len(vs):
                        raise ValueError("reference to non-existent argument %d" % k)
                    nthis = k - 1
                    spec = "%" + spec[mm.end():]
                star = None
                if "*" in spec:
                    si = spec.index("*")
                    nstar = -1
                    mm = re.match(r"^\*(\d{1,2})\$", spec[si:])
                    if mm:
                        k = int(mm.group(1))
                        if k > len(vs):
                            raise ValueError("reference to non-existent argument %d" % k)
                        nstar = k - 1
                        spec = spec[:si + 1] + spec[si + mm.end():]
                    if nstar < 0:
                        if cnt >= len(vs):
                            raise ValueError("too few arguments")
                        nstar = cnt
                        cnt += 1
                    if "*" in spec[si + 1:]:
                        raise ValueError("at most one asterisk '*' is supported in each conversion specification")
                    sv = vs[nstar]
                    used[nstar] = True
                    if sv.type == "double":
                        sv = _coerce(sv, "integer")
                    if sv.type not in ("integer", "logical") or sv.na[ns % len(sv)]:
                        raise ValueError("argument for '*' conversion specification must be a number")
                    star = int(sv.v[ns % len(sv)])
                    spec = spec.replace("*", str(star))
                if nthis < 0:
                    if cnt >= len(vs):
                        raise ValueError("too few arguments")
                    nthis = cnt
                    cnt += 1
                used[nthis] = True
                conv = spec[-1]
                if nthis not in coerced:
                    v = vs[nthis]
                    if conv in "dioxX":
                        if v.type == "double":
                            ok = all((v.na[i] or (math.isfinite(v.v[i]) and not v.nan[i]
                                                   and float(int(v.v[i])) == v.v[i] and abs(v.v[i]) < 2**31))
                                     for i in range(len(v)))
                            if ok:
                                v = _coerce(v, "integer")
                    elif conv in "aAfeEgG":
                        if v.type not in ("double", "character"):
                            v = _coerce(v, "double")
                    elif conv == "s":
                        if v.type != "character":
                            v = _V("character", _as_character_list(v), v.na.copy())
                    coerced[nthis] = v
                    vs[nthis] = v
                v = vs[nthis]
                i = ns % len(v)
                t = v.type
                if t == "factor":
                    v = _coerce(v, "integer")
                    t = "integer"
                if t == "logical":
                    if conv not in "di":
                        raise ValueError("invalid format '%s'; use format %%d or %%i for logical objects" % spec)
                    if v.na[i]:
                        out.append(_c_format(spec[:-1] + "s", "NA"))
                    else:
                        out.append(_c_format(spec, int(bool(v.v[i]))))
                elif t == "integer":
                    if conv not in "dioxX":
                        raise ValueError("invalid format '%s'; use format %%d, %%i, %%o, %%x or %%X for integer objects" % spec)
                    if v.na[i]:
                        out.append(_c_format(spec[:-1] + "s", "NA"))
                    else:
                        out.append(_c_format(spec, int(v.v[i])))
                elif t in ("double", "Date"):
                    if conv not in "aAfeEgG":
                        raise ValueError("invalid format '%s'; use format %%f, %%e, %%g or %%a for numeric objects" % spec)
                    xv = float(v.v[i])
                    if math.isfinite(xv):
                        out.append(_c_format(spec, xv))
                    else:
                        p = spec.find(".")
                        sp = spec[:p] + "s" if p >= 0 else spec[:-1] + "s"
                        if xv != xv:
                            word = "NaN" if (v.nan[i] and not v.na[i]) else "NA"
                            out.append(_c_format(sp, (" " + word) if " " in sp else word))
                        elif xv > 0:
                            out.append(_c_format(sp, "+Inf" if "+" in sp else (" Inf" if " " in sp else "Inf")))
                        else:
                            out.append(_c_format(sp, "-Inf"))
                elif t == "character":
                    if conv != "s":
                        raise ValueError("invalid format '%s'; use format %%s for character objects" % spec)
                    s = v.v[i]
                    s = "NA" if s is None else s
                    if spec[1] != "s":
                        out.append(_c_format(spec, s))
                    else:
                        out.append(s)
                else:
                    raise ValueError("unsupported type")
            else:
                j = f.find("%", cur)
                if j < 0:
                    j = n
                out.append(f[cur:j])
                cur = j
        results.append("".join(out))
    nunused = sum(1 for u in used if not u)
    if nunused:
        import warnings
        if nfmt == 1:
            if nunused == 1:
                warnings.warn("one argument not used by format '%s'" % fv.v[0])
            else:
                warnings.warn("%d arguments not used by format '%s'" % (nunused, fv.v[0]))
        else:
            warnings.warn("one argument not used by format" if nunused == 1 else
                          "%d arguments not used by format" % nunused)
    scal = fv.scalar and all(v.scalar for v in [_as_v(a) for a in args])
    if scal and len(results) == 1:
        return results[0]
    a = np.empty(len(results), dtype=object)
    a[:] = results
    return a


# ── Datum ──────────────────────────────────────────────────────────────────

_MON = ["January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December"]
_WDAY = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]


def _civil(z):
    """Tage seit 1970-01-01 -> (Jahr, Monat, Tag) (proleptisch gregorianisch)."""
    z += 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return (y + (m <= 2), m, d)


def _days_from_civil(y, m, d):
    y -= m <= 2
    era = y // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _isleap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def _iso_week(z, y, yday, wday):
    """(ISO-Jahr, ISO-Woche) wie glibc %G/%V."""
    # Montag = 0
    wd = (wday + 6) % 7
    # Donnerstag derselben Woche
    th = z - wd + 3
    ty, _, _ = _civil(th)
    jan1 = _days_from_civil(ty, 1, 1)
    week = (th - jan1) // 7 + 1
    return ty, week


_COMPOSITE = {"F": "%Y-%m-%d", "D": "%m/%d/%y", "x": "%m/%d/%y", "T": "%H:%M:%S", "X": "%H:%M:%S",
              "R": "%H:%M", "r": "%I:%M:%S %p", "c": "%a %b %e %H:%M:%S %Y"}


def _strftime1(z, fmt):
    """glibc-``strftime`` (C-Locale) für ein Datum (Tage seit 1970-01-01, 00:00 UTC)."""
    y, m, d = _civil(z)
    wday = (z + 4) % 7  # 0 = Sonntag
    yday = z - _days_from_civil(y, 1, 1)  # 0-basiert
    out = []
    i = 0
    n = len(fmt)
    while i < n:
        c = fmt[i]
        if c != "%":
            out.append(c)
            i += 1
            continue
        start = i
        i += 1
        pad = None
        upcase = swcase = False
        while i < n and fmt[i] in "-_0^#":
            if fmt[i] == "^":
                upcase = True
            elif fmt[i] == "#":
                swcase = True
            else:
                pad = fmt[i]
            i += 1
        width = 0
        while i < n and fmt[i].isdigit():
            width = width * 10 + int(fmt[i])
            i += 1
        if i < n and fmt[i] in "EO":
            i += 1
        if i >= n:
            out.append(fmt[start:])
            break
        k = fmt[i]
        i += 1

        def num(v, digits, fill="0"):
            neg = v < 0
            s = "%d" % abs(v)
            if pad == "-":
                return ("-" if neg else "") + s
            if pad == "_":
                fill = " "
            elif pad == "0":
                fill = "0"
            tw = max(width, digits) - (1 if neg else 0)
            if fill == "0":
                return ("-" if neg else "") + s.rjust(tw, "0")
            return (("-" if neg else "") + s).rjust(tw + (1 if neg else 0))

        def yearish(v):
            if pad == "-" or width == 0:
                return "%d" % v
            return num(v, 1)

        def text(t, swap_lower=False):
            if upcase:
                t = t.upper()
            elif swcase:
                t = t.lower() if swap_lower else t.upper()
            if width > len(t):
                t = ("0" if pad == "0" else " ") * (width - len(t)) + t
            return t
        if k == "Y":
            out.append(yearish(y))
        elif k == "C":
            out.append(yearish(y // 100))
        elif k == "G" or k == "g" or k == "V":
            gy, gw = _iso_week(z, y, yday, wday)
            out.append(yearish(gy) if k == "G" else num(gy % 100 if k == "g" else gw, 2))
        elif k == "y":
            out.append(num(y % 100, 2))
        elif k == "m":
            out.append(num(m, 2))
        elif k == "d":
            out.append(num(d, 2))
        elif k == "e":
            out.append(num(d, 2, " "))
        elif k == "j":
            out.append(num(yday + 1, 3))
        elif k == "u":
            out.append(num(7 if wday == 0 else wday, 1))
        elif k == "w":
            out.append(num(wday, 1))
        elif k == "U":
            out.append(num((yday + 7 - wday) // 7, 2))
        elif k == "W":
            out.append(num((yday + 7 - (wday + 6) % 7) // 7, 2))
        elif k in "HMS":
            out.append(num(0, 2))
        elif k == "I":
            out.append(num(12, 2))
        elif k == "k":
            out.append(num(0, 2, " "))
        elif k == "l":
            out.append(num(12, 2, " "))
        elif k == "s":
            out.append(num(z * 86400, 1))
        elif k in "bh":
            out.append(text(_MON[m - 1][:3]))
        elif k == "B":
            out.append(text(_MON[m - 1]))
        elif k == "a":
            out.append(text(_WDAY[wday][:3]))
        elif k == "A":
            out.append(text(_WDAY[wday]))
        elif k == "p":
            out.append(text("AM", swap_lower=True))
        elif k == "P":
            out.append(text("am"))
        elif k == "Z":
            out.append(text("UTC", swap_lower=True))
        elif k == "z":
            out.append("+0000")
        elif k in _COMPOSITE:
            out.append(text(_strftime1(z, _COMPOSITE[k])))
        elif k == "n":
            out.append("\n")
        elif k == "t":
            out.append("\t")
        elif k == "%":
            out.append("%")
        else:
            out.append(fmt[start:i])
    return "".join(out)


def _format_date_list(days, fmts):
    days = np.asarray(days, dtype=np.float64)
    n = len(days)
    if n == 0:
        return []
    out = []
    nf = len(fmts)
    for i in range(max(n, nf)):
        z = days[i % n]
        f = fmts[i % nf]
        if z != z or f is None or not math.isfinite(z):
            out.append(None)
        else:
            out.append(_strftime1(int(math.floor(z)), f))
    return out


def format_date(x, fmt="%Y-%m-%d"):
    """``format(<Date>, fmt)`` wie ``format.Date``/``strftime`` in der C-Locale.

    ``x``: datetime64, ``date``, Tage seit 1970-01-01 (Zahl) oder Vektor davon.
    NA -> ``None``."""
    v = _as_v(x)
    if v.type in ("double", "integer"):
        v = _coerce(v, "Date")
    elif v.type == "character":
        # ISO-Text wie as.Date()
        days = []
        for s in v.v:
            try:
                days.append(_date_days(_dt.date.fromisoformat(s[:10])) if s is not None else math.nan)
            except ValueError:
                days.append(math.nan)
        v = _V("Date", np.array(days, np.float64), names=v.names, scalar=v.scalar)
    fv = _as_v(fmt, "character")
    return _out(_format_date_list(v.v, list(fv.v)), v)


# ── Druckausgabe: Vektoren ─────────────────────────────────────────────────

def _vec_label(i, labwidth):
    return " " * (labwidth - _index_width(i) - 2) + "[%d]" % i


def _type0(v):
    return {"logical": "logical(0)", "integer": "integer(0)", "double": "numeric(0)",
            "character": "character(0)"}.get(v.type, "NULL")


def _encode_elems(v, digits=None, quote=0, na_print=None):
    """(Breite, Liste der Elemente kodiert mit dieser Breite) – ohne Lücke."""
    t = v.type
    n = len(v)
    if t == "double":
        w, d, e = _format_real(v.v, v.na, v.nan, digits)
        return w, (lambda ww: _encode_reals_w(v, ww, d, e))
    if t == "integer":
        w = _format_integer(v)
        return w, (lambda ww: [_encode_integer(int(v.v[i]), bool(v.na[i]), ww) for i in range(n)])
    if t == "logical":
        w = _format_logical(v)
        return w, (lambda ww: [_encode_logical(bool(v.v[i]), bool(v.na[i]), ww) for i in range(n)])
    raise TypeError(t)


def _encode_reals_w(v, w, d, e):
    return _encode_reals(v, w, d, e, _OPT["OutDec"])


def _print_vector_lines(v, quote=True, right=False, digits=None, indx=True):
    """printVector -> Liste von Zeilen."""
    n = len(v)
    width_opt = _OPT["width"]
    gap = 1
    if n == 0:
        return [_type0(v)]
    lines = []
    cur = ""
    if indx:
        labwidth = _index_width(n) + 2
        cur = _vec_label(1, labwidth)
        width = labwidth
    else:
        labwidth = 0
        width = 0
    if v.type == "character":
        q = '"' if quote else 0
        w = _format_string(v.v, q)
        just = "right" if right else "left"
        for i in range(n):
            if i > 0 and width + w + gap > width_opt:
                lines.append(cur)
                if indx:
                    cur = _vec_label(i + 1, labwidth)
                    width = labwidth
                else:
                    cur = ""
                    width = 0
            cur += " " + _encode_string(v.v[i], w, q, just)
            width += w + gap
    else:
        w, enc = _encode_elems(v, digits)
        w += gap
        strs = enc(w)
        for i in range(n):
            if i > 0 and width + w > width_opt:
                lines.append(cur)
                if indx:
                    cur = _vec_label(i + 1, labwidth)
                    width = labwidth
                else:
                    cur = ""
                    width = 0
            cur += strs[i]
            width += w
    lines.append(cur)
    return lines


def _print_named_vector_lines(v, names, quote=True, digits=None):
    n = len(v)
    gap = 1
    if n == 0:
        return ["named " + _type0(v)]
    if v.type == "character":
        q = '"' if quote else 0
        w = _format_string(v.v, q)
    else:
        w, enc = _encode_elems(v, digits)
    wn = _format_string(names, 0)
    if w < wn:
        w = wn
    if v.type == "character":
        strs = [_encode_string(s, w, q, "right") for s in v.v]
    else:
        strs = enc(w)
    nperline = _OPT["width"] // (w + gap)
    if nperline <= 0:
        nperline = 1
    nlines = n // nperline + (1 if n % nperline else 0)
    lines = []
    for i in range(nlines):
        ks = range(i * nperline, min(n, (i + 1) * nperline))
        lines.append("".join(_encode_string(names[k], w, 0, "right") + " " for k in ks))
        lines.append("".join(strs[k] + " " for k in ks))
    return lines


def print_vector(x, names=None, digits=None, quote=None, right=False, type=None):
    """``print(x)`` eines atomaren Vektors (auch Date, factor).

    Args:
        x: Vektor; ``pandas.Series`` mit Nicht-RangeIndex gilt als benannt.
        names: Namen (überschreibt Series-Index).
        digits: signifikante Stellen (``print(x, digits = )``).
        quote: Zeichenketten in Anführungszeichen (Voreinstellung: ja, bei
            Faktoren nein).
        right: Zeichenketten rechtsbündig (unbenannte Vektoren).
        type: R-Typ erzwingen ('integer', 'double', …).
    """
    v = _as_v(x, type)
    if names is not None:
        v.names = [None if _is_na_scalar(s) else str(s) for s in names]
    return "\n".join(_print_vec_v(v, digits, quote, right))


def _print_vec_v(v, digits=None, quote=None, right=False):
    if v.type != "factor" and quote is None:
        quote = True
    if v.type == "NULL":
        return ["NULL"]
    if v.type == "factor":
        return _print_factor_lines(v, quote=bool(quote), right=right)
    if v.type == "Date":
        if len(v) == 0:
            return ["Date of length 0"]
        cv = _V("character", _format_date_list(v.v, ["%Y-%m-%d"]), v.na.copy(), names=v.names)
        v = cv
    if v.names is not None:
        # NA-Namen (None) erscheinen als "<NA>" (EncodeString ohne quote)
        return _print_named_vector_lines(v, list(v.names), quote, digits)
    return _print_vector_lines(v, quote, right, digits)


def _print_factor_lines(v, quote=False, max_levels=None, right=False):
    n = len(v)
    lines = []
    if n == 0:
        lines.append(("ordered" if v.ordered else "factor") + "()")
    else:
        cv = _V("character", _as_character_list(v), v.na.copy(), names=v.names)
        lines.extend(_print_vec_v(cv, None, quote, right))
    maxl = True if max_levels is None else max_levels
    if maxl:
        q = '"' if quote else 0
        lev = [_encode_string(s, 0, q, "none") for s in v.levels]
        nl = len(lev)
        colsep = " < " if v.ordered else " "
        T0 = "Levels: "
        if isinstance(maxl, bool):
            width = _OPT["width"] - (len(T0) + 3 + 1 + 3)
            lenl = np.cumsum([nchar(s, "width") + len(colsep) for s in lev]) if nl else []
            if nl <= 1 or lenl[nl - 1] <= width:
                maxl = nl
            else:
                maxl = max(1, int(np.argmax(np.asarray(lenl) > width)) + 1 - 1)
        drop = nl > maxl
        if drop:
            parts = lev[:max(1, maxl - 1)] + ["..."] + ([lev[nl - 1]] if maxl > 1 else [])
        else:
            parts = lev
        txt = (("%d " % nl) if drop else "") + T0 + colsep.join(parts)
        lines.extend(txt.split("\n"))
    return lines


def print_factor(x, quote=False, max_levels=None, levels=None, ordered=False, right=False):
    """``print(<factor>)``. ``x``: ``pandas.Categorical``/Series oder Werte mit ``levels``."""
    if levels is not None:
        c = pd.Categorical(np.asarray(x, dtype=object), categories=levels, ordered=ordered)
        v = _from_categorical(c, None)
    else:
        v = _as_v(x)
        if v.type != "factor":
            vals = _as_character_list(v)
            from ._collate import collate_key
            levs = sorted(dict.fromkeys(s for s in vals if s is not None), key=collate_key)
            c = pd.Categorical(vals, categories=levs, ordered=ordered)
            v = _from_categorical(c, v.names)
    return "\n".join(_print_factor_lines(v, quote, max_levels, right))


# ── Druckausgabe: Matrizen ─────────────────────────────────────────────────

def _matrix_lines(cols, ctype, r, c, rl, cl, rn=None, cn=None, quote=0, right=False, digits=None):
    """printMatrix. cols: Liste von _V je Spalte (gleicher Typ)."""
    if r == 0 and c == 0:
        return ["<0 x 0 matrix>"]
    gap = 1
    width_opt = _OPT["width"]
    if rl is not None:
        rlabw = _format_string(rl, 0)
    else:
        rlabw = _index_width(r + 1) + 3
    lbloff = 0
    if rn is not None:
        rnw = _strwid(rn, 0)
        if rnw < rlabw + 2:
            lbloff = 2
        else:
            lbloff = rnw - rlabw
        rlabw += lbloff
    w = []
    enc = []
    is_str = ctype == "character"
    for j in range(c):
        col = cols[j]
        if is_str:
            wj = _format_string(col.v, quote)
        elif ctype == "double":
            wj, dj, ej = _format_real(col.v, col.na, col.nan, digits)
            enc.append((dj, ej))
        elif ctype == "integer":
            wj = _format_integer(col)
        elif ctype == "logical":
            wj = _format_logical(col)
        else:
            raise TypeError(ctype)
        if cl is not None:
            clabw = 4 if cl[j] is None else _strwid(cl[j], 0)
        else:
            clabw = _index_width(j + 1) + 3
        if wj < clabw:
            wj = clabw
        if not is_str:
            wj += gap
        w.append(wj)

    def row_label(i):
        if rl is not None:
            s = rl[i]
            l = 4 if s is None else _strwid(s, 0)
            return " " * lbloff + _encode_string(s, l, 0, "left") + " " * (rlabw - l - lbloff)
        return " " * (rlabw - 3 - _index_width(i + 1)) + "[%d,]" % (i + 1)

    def col_label(j):
        if is_str:
            if cl is not None:
                s = cl[j]
                l = 4 if s is None else _strwid(s, 0)
                if right:
                    return " " * (gap + w[j] - l) + _encode_string(s, l, 0, "right")
                return " " * gap + _encode_string(s, l, 0, "left") + " " * (w[j] - l)
            lab = "[,%d]" % (j + 1)
            return " " * gap + lab + " " * (w[j] - _index_width(j + 1) - 3)
        if cl is not None:
            s = cl[j]
            l = 4 if s is None else _strwid(s, 0)
            return " " * (w[j] - l) + _encode_string(s, l, 0, "left")
        return " " * (w[j] - _index_width(j + 1) - 3) + "[,%d]" % (j + 1)

    def cell(i, j):
        col = cols[j]
        if is_str:
            return " " * gap + _encode_string(col.v[i], w[j], quote, "right" if right else "left")
        if ctype == "double":
            dj, ej = enc[j]
            return _encode_real(float(col.v[i]), w[j], dj, ej, _OPT["OutDec"], bool(col.na[i]), bool(col.nan[i]))
        if ctype == "integer":
            return _encode_integer(int(col.v[i]), bool(col.na[i]), w[j])
        return _encode_logical(bool(col.v[i]), bool(col.na[i]), w[j])

    lines = []

    def head():
        if cn is not None:
            lines.append(" " * rlabw + cn)
        if rn is not None:
            return rn.ljust(rlabw) if _strwid(rn, 0) < rlabw else rn
        return " " * rlabw

    extra = gap if is_str else 0
    if c == 0:
        cur = head()
        for i in range(r):
            lines.append(cur)
            cur = row_label(i)
        lines.append(cur)
        return lines
    jmin = 0
    while jmin < c:
        width = rlabw
        jmax = jmin
        while True:
            width += w[jmax] + extra
            jmax += 1
            if not (jmax < c and width + w[jmax] + extra < width_opt):
                break
        cur = head()
        cur += "".join(col_label(j) for j in range(jmin, jmax))
        for i in range(r):
            lines.append(cur)
            cur = row_label(i) + "".join(cell(i, j) for j in range(jmin, jmax))
        lines.append(cur)
        jmin = jmax
    return lines


def _labels(idx):
    if idx is None:
        return None
    if isinstance(idx, pd.RangeIndex):
        return None
    return [None if _is_na_scalar(s) else str(s) for s in idx]


def print_matrix(m, rownames=None, colnames=None, quote=True, right=False, digits=None,
                 type=None, dimnames_names=None):
    """``print(<matrix>)``.

    Args:
        m: 2-D ``numpy.ndarray`` oder ``pandas.DataFrame`` (Index/Spalten als
           dimnames; ``RangeIndex`` = keine Namen).
        rownames, colnames: dimnames (überschreiben die des DataFrame).
        quote, right, digits: wie ``print.default``.
        type: R-Typ der Matrix erzwingen ('integer', 'double', 'logical', 'character').
        dimnames_names: (Zeilentitel, Spaltentitel) = ``names(dimnames(m))``.
    """
    rl = cl = None
    if isinstance(m, pd.DataFrame):
        rl = _labels(m.index)
        cl = _labels(m.columns)
        a = m.to_numpy()
        if all(m.dtypes.map(lambda d: d.kind in "iu")) and len(m.columns):
            a = m.to_numpy(dtype=np.int64)
        elif all(m.dtypes.map(lambda d: d.kind in "fiu")) and len(m.columns):
            a = m.to_numpy(dtype=np.float64)
    else:
        a = np.asarray(m)
        if a.ndim == 1:
            a = a.reshape(-1, 1)
    if rownames is not None:
        rl = [None if _is_na_scalar(s) else str(s) for s in rownames]
    if colnames is not None:
        cl = [None if _is_na_scalar(s) else str(s) for s in colnames]
    r, c = a.shape
    whole = _as_v(a.ravel(order="F") if a.size else np.zeros(0), type)
    if a.size == 0 and type is None:
        whole = _V("logical", np.zeros(0, bool))
    ctype = whole.type
    if ctype == "factor":
        whole = _coerce(whole, "character")
        ctype = "character"
    if ctype == "Date":
        whole = _V("character", _format_date_list(whole.v, ["%Y-%m-%d"]), whole.na)
        ctype = "character"
    cols = [whole.subset(np.arange(j * r, (j + 1) * r)) for j in range(c)]
    rn, cn = (dimnames_names or (None, None))
    q = '"' if (quote is None or quote) else 0
    return "\n".join(_matrix_lines(cols, ctype, r, c, rl, cl, rn, cn, q, right, digits))


# ── Druckausgabe: data.frame ───────────────────────────────────────────────

def _df_rownames(df):
    idx = df.index
    if isinstance(idx, pd.RangeIndex) or (idx.dtype.kind in "iu"):
        return [str(int(i) + 1) for i in idx]
    return [None if _is_na_scalar(s) else str(s) for s in idx]


def _fmt_column(col, digits=None, na_encode=False, justify="none", type=None):
    """format() einer data.frame-Spalte (wie in format.data.frame) -> Liste str/None."""
    if isinstance(col, pd.Series):
        col = col.reset_index(drop=True)
    v = _as_v(col, type)
    v.names = None
    v.scalar = False
    if v.type == "Date":
        return _format_date_list(v.v, ["%Y-%m-%d"])
    if v.type == "factor":
        v = _V("character", _as_character_list(v), v.na.copy())
    if v.type == "character":
        return _format_internal(v, digits=digits, justify=justify, na_encode=na_encode)
    return _format_internal(v, digits=digits, justify="right", na_encode=na_encode)


def format_data_frame(df, digits=None, na_encode=False, justify="none", types=None):
    """``format.data.frame``: Liste formatierter Spalten (str/None)."""
    types = types or {}
    return [_fmt_column(df.iloc[:, j], digits, na_encode, justify, types.get(df.columns[j]))
            for j in range(df.shape[1])]


def print_data_frame(df, row_names=True, digits=None, right=True, quote=False, types=None):
    """``print(<data.frame>)`` wie ``print.data.frame``.

    Args:
        df: ``pandas.DataFrame``. Zeilennamen: ganzzahliger Index i -> "i+1"
            (pandas zählt ab 0, R ab 1), sonst ``str(index)``.
        row_names: True, False oder Liste eigener Zeilennamen.
        digits: signifikante Stellen für numerische Spalten.
        right: rechtsbündig (Voreinstellung wie R).
        types: dict Spaltenname -> R-Typ ('integer', 'double', 'logical',
            'character', 'Date', 'factor'), falls der pandas-Typ nicht passt
            (z. B. ganzzahlige R-Spalte mit NA, die als float ankommt).
    """
    if not isinstance(df, pd.DataFrame):
        df = pd.DataFrame(df)
    n = df.shape[0]
    if df.shape[1] == 0:
        return "data frame with 0 columns and %d row%s" % (n, "" if n == 1 else "s")
    if n == 0:
        names = [str(c) for c in df.columns]
        return print_vector(np.array(names, dtype=object), quote=False) + \
            "\n<0 rows> (or 0-length row.names)"
    cols = format_data_frame(df, digits=digits, types=types)
    if row_names is True:
        rl = _df_rownames(df)
    elif row_names is False or row_names is None:
        rl = [""] * n
    else:
        rl = [str(s) for s in row_names]
    cl = [str(c) for c in df.columns]
    vcols = [_V("character", c, np.array([s is None for s in c], bool)) for c in cols]
    q = '"' if quote else 0
    return "\n".join(_matrix_lines(vcols, "character", n, len(cl), rl, cl, None, None, q, right, None))


# ── Listen und Verteiler ───────────────────────────────────────────────────

_RESERVED = {"if", "else", "repeat", "while", "function", "for", "next", "break", "TRUE", "FALSE",
             "NULL", "Inf", "NaN", "NA", "NA_integer_", "NA_real_", "NA_character_", "NA_complex_", "in"}


def _is_valid_name(s):
    if not s:
        return False
    c = s[0]
    if not (c.isalpha() or c == "."):
        return False
    if c == "." and len(s) > 1 and s[1].isdigit():
        return False
    if not all(ch.isalnum() or ch in "._" for ch in s):
        return False
    if s == "...":
        return True
    if s in _RESERVED:
        return False
    if re.fullmatch(r"\.\.\d+", s):
        return False
    return True


def _own_format(x):
    """Objekt mit eigener print-Methode (RList-Unterklasse mit format())?"""
    try:
        from .rlist import RList
    except ImportError:  # pragma: no cover
        return False
    return isinstance(x, RList) and type(x).format is not RList.format


def _print_lines(x, tag="", digits=None, quote=None):
    """PrintValueRec -> Zeilen."""
    if x is None:
        return ["NULL"]
    if hasattr(x, "__r_print_lines__"):
        return x.__r_print_lines__()
    if _own_format(x):
        return x.format().split("\n")
    if isinstance(x, pd.DataFrame):
        return print_data_frame(x, digits=digits).split("\n")
    if isinstance(x, np.ndarray) and x.ndim == 2:
        return print_matrix(x, digits=digits, quote=quote).split("\n")
    if isinstance(x, (dict, list)):
        return _print_list_lines(x, tag, digits, quote)
    return _print_vec_v(_as_v(x), digits, quote)


def _print_list_lines(x, tag="", digits=None, quote=None):
    if isinstance(x, dict):
        items = [(None if k is None else str(k), v) for k, v in x.items()]
        named = True
    else:
        items = [(None, v) for v in x]
        named = False
    if not items:
        return ["named list()" if named else "list()"]
    lines = []
    for i, (nm, val) in enumerate(items):
        if i > 0:
            lines.append("")
        if named and nm is not None and nm != "":
            t = tag + ("$%s" % nm if _is_valid_name(nm) else "$`%s`" % nm)
        else:
            t = tag + "[[%d]]" % (i + 1)
        lines.append(t)
        if isinstance(val, (dict, list)) and not _own_format(val):
            lines.extend(_print_list_lines(val, t, digits, quote))
        else:
            lines.extend(_print_lines(val, t, digits, quote))
    lines.append("")
    return lines


def print_list(x, digits=None, quote=None):
    """``print(<list>)``: dict = benannte Liste, list = unbenannte Liste."""
    return "\n".join(_print_list_lines(x, "", digits, quote))


def print_default(x, digits=None, quote=None, right=False, row_names=True):
    """Verteiler wie ``print()``: DataFrame -> print.data.frame, 2-D-Array ->
    Matrix, dict/list -> Liste, Categorical -> factor, sonst Vektor."""
    if isinstance(x, pd.DataFrame):
        return print_data_frame(x, row_names=row_names, digits=digits)
    if isinstance(x, np.ndarray) and x.ndim == 2:
        return print_matrix(x, digits=digits, quote=quote, right=right)
    if _own_format(x):
        return x.format()
    if isinstance(x, (dict, list)):
        return print_list(x, digits=digits, quote=quote)
    if hasattr(x, "__r_print_lines__"):
        return "\n".join(x.__r_print_lines__())
    return print_vector(x, digits=digits, quote=quote, right=right)


# ── cat ────────────────────────────────────────────────────────────────────

def _cat_items(x):
    v = _as_v(x)
    t = v.type
    if t == "NULL":
        return []
    if t == "double":
        res = []
        for i in range(len(v)):
            xi = float(v.v[i])
            if v.na[i]:
                res.append("NA")
                continue
            w, d, e = _format_real(np.array([xi]), np.array([False]), v.nan[i:i + 1], None)
            res.append(_encode_real(xi, 0, d, e, _OPT["OutDec"], False, bool(v.nan[i])))
        return res
    if t == "integer":
        return ["NA" if v.na[i] else "%d" % int(v.v[i]) for i in range(len(v))]
    if t == "logical":
        return ["NA" if v.na[i] else ("TRUE" if v.v[i] else "FALSE") for i in range(len(v))]
    if t == "character":
        return ["NA" if s is None else s for s in v.v]
    if t == "Date":
        # cat() eines Date druckt die Zahl
        return _cat_items(_V("double", v.v, v.na))
    if t == "factor":
        return ["NA" if v.na[i] else "%d" % (int(v.v[i]) + 1) for i in range(len(v))]
    raise TypeError(t)


def cat_str(*args, sep=" ", fill=False):
    """Text, den ``cat(..., sep = sep)`` ausgäbe (Zahlen mit 7 signifikanten
    Stellen je Element, wie R)."""
    seps = [sep] if isinstance(sep, str) else list(sep)
    nlsep = any("\n" in s for s in seps)
    out = []
    ntot = 0
    for iobj, a in enumerate(args):
        if iobj != 0 and a is not None:
            out.append(seps[ntot % len(seps)])
            ntot += 1
        items = _cat_items(a)
        n = len(items)
        for i in range(n):
            out.append(items[i])
            if i < n - 1:
                out.append(seps[ntot % len(seps)])
                ntot += 1
    if fill or nlsep:
        out.append("\n")
    return "".join(out)


def r_cat(*args, sep=" ", fill=False, file=None):
    """Wie ``cat(...)``: schreibt nach ``sys.stdout`` (bzw. ``file``)."""
    s = cat_str(*args, sep=sep, fill=fill)
    (file or sys.stdout).write(s)
