# Herkunft:           übersetzt aus R 4.3.3, src/main/format.c, printutils.c, printvector.c,
#                     printarray.c, print.c, paste.c, sprintf.c, util.c; src/nmath/fround.c,
#                     fprec.c; nachgebildet nach R 4.3.3, src/library/base/R/format.R, dataframe.R,
#                     factor.R, dates.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); fprec.c: Übersetzung einer Fortran-Routine von
#                     W. Fullerton (Los Alamos); sprintf.c: ursprünglich Jonathan Rougier
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Datumsformat und -lesen rechnet der C-Kern
#                     core/slc_rbase_date.cpp; seit 1.6.0 round/signif, formatReal/encodeReal,
#                     as.character für Zahlen, formatC (str_signif) und sprintf der C-Kern
#                     core/slc_rbase_fmt.cpp (eine Fassung für Python und Julia).
"""Formatierung und Druckausgabe wie R 4.3.3.

Zeichengenaue Nachbildung von R's ``format``, ``formatC``,
``sprintf``, ``as.character``, ``paste``, ``round``/``signif`` und der
``print``-Ausgabe von Vektoren, Matrizen, data.frames und Faktoren
(Quellen: ``src/main/format.c``, ``printutils.c``, ``printvector.c``,
``printarray.c``, ``print.c``, ``paste.c``, ``sprintf.c``, ``util.c``,
``src/nmath/fround.c``, ``fprec.c``, ``src/library/base/R/format.R``,
``dataframe.R``, ``factor.R``, ``dates.R``).

Voreinstellungen wie ``options(digits = 7, scipen = 0, width = 80,
OutDec = ".")``, ``digits.secs`` nicht gesetzt (für ``%OS`` in
:func:`format_date`); änderbar über :func:`set_options`.

Abbildung der Python-Eingaben auf R-Typen
-----------------------------------------
==============================  ======================================
Python                          R
==============================  ======================================
``float``, float-Array          double (:data:`NA_REAL` = ``NA``,
                                jedes andere ``nan`` = ``NaN``)
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

Ganzzahlige R-Vektoren mit NA kommen aus den R-Referenzfällen als float an;
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

import bisect
import datetime as _dt
import math
import re
import struct

import numpy as np
import pandas as pd

from . import _wctype as _wct   # glibc-Zeichenklasse print (seit 1.6.4, C-047)

__all__ = [
    "NA_REAL", "set_options", "r_round", "signif", "fround", "fprec", "as_character", "paste", "format",
    "format_date", "formatC", "sprintf", "nchar", "print_vector", "print_matrix", "print_data_frame",
    "format_data_frame",
]

# ── Optionen ────────────────────────────────────────────────────────────────

_OPT = {"digits": 7, "scipen": 0, "width": 80, "OutDec": ".", "digits.secs": None}


_NA_INT_ = -2147483648


def _isnan_num(v):
    """Zahl NaN/NA (für Vergleiche wie in R, die dann NA ergeben)."""
    try:
        return isinstance(v, (float, np.floating)) and math.isnan(float(v))
    except (TypeError, ValueError):
        return False


def _r_as_int1(v):
    """``asInteger`` von R für ein Argument: erstes Element, Wahrheitswert 0/1, Zahl zur Null hin, Text wie
    ``as.integer``; NA, NaN und Werte außerhalb des int-Bereichs als ``None`` (außerhalb mit der Warnung von R).
    Seit 1.6.4 (C-012) für die Prüfung von ``digits``/``nsmall`` wie R."""
    import warnings
    if isinstance(v, (list, tuple, np.ndarray, pd.Series)):
        a = list(np.asarray(v, dtype=object).ravel()) if not isinstance(v, pd.Series) else list(v)
        if not a:
            return None
        v = a[0]
    if v is None or v is pd.NA or v is pd.NaT:
        return None
    if isinstance(v, (bool, np.bool_)):
        return int(bool(v))
    if isinstance(v, str):
        # seit 1.6.5 (CR2-Q-3) wie R's IntegerFromString: leerer Text NA ohne Warnung, sonst R_strtod (Hex, Ziffern nur
        # ASCII) mit Rest nur aus Leerraum; NaN ohne Warnung, außerhalb des int-Bereichs (auch Inf) die Bereichswarnung
        # (bis 1.6.4 Python-float(): "0x10" NA, "1_0" 10, Warnungen anders als R)
        from .rnum import r_strtod
        ws = " \t\n\v\f\r"
        if not v.strip(ws):
            return None
        f, end = r_strtod(v, 0)
        if end == 0 or v[end:].strip(ws):
            warnings.warn("NAs introduced by coercion")
            return None
        v = f
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if math.isnan(f):
        return None
    if not abs(f) < 2147483648.0 or math.trunc(f) == -2147483648:
        warnings.warn("NAs introduced by coercion to integer range")
        return None
    return int(math.trunc(f))


def _r_as_lgl1(v):
    """``asLogical`` von R für ein Argument: erstes Element; Zahl ungleich 0 TRUE, NaN NA; Text "TRUE"/"true"/"True"/
    "T" bzw. "FALSE"/"false"/"False"/"F", sonst NA; leer NA. Ergebnis True, False oder None (NA). Seit 1.6.4 (C-056)."""
    if isinstance(v, (list, tuple, np.ndarray, pd.Series)):
        a = list(np.asarray(v, dtype=object).ravel()) if not isinstance(v, pd.Series) else list(v)
        if not a:
            return None
        v = a[0]
    if v is None or v is pd.NA:
        return None
    if isinstance(v, (bool, np.bool_)):
        return bool(v)
    if isinstance(v, str):
        return True if v in ("TRUE", "true", "True", "T") else False if v in ("FALSE", "false", "False", "F") else None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return None if math.isnan(f) else f != 0


def _r_lgl_arg(v, what):
    """Wahrheitswert eines Arguments wie R ``asLogical`` mit Abbruch „invalid 'what' argument“ bei NA (seit 1.6.4,
    C-056; bis 1.6.3 bool(), das NaN und "no" als TRUE las)."""
    b = _r_as_lgl1(v)
    if b is None:
        raise ValueError("invalid '%s' argument" % what)
    return b


def _r_match_arg(arg, choices):
    """``match.arg(arg, choices)`` von R (seit 1.6.4, C-056): NULL bzw. alle Wahlwerte ergeben den ersten, sonst ein
    Text, eindeutiger Teilanfang erlaubt; Meldungen wie R."""
    choices = tuple(choices)
    if arg is None:
        return choices[0]
    a = list(arg) if isinstance(arg, (list, tuple, np.ndarray)) else [arg]
    if not all(isinstance(t, str) for t in a):
        raise ValueError("'arg' must be NULL or a character vector")
    if tuple(a) == choices:
        return choices[0]
    if len(a) > 1:
        raise ValueError("'arg' must be of length 1")
    hits = [c for c in choices if a and c == a[0]] or [c for c in choices if a and a[0] and c.startswith(a[0])]
    # mehrdeutiger Teilanfang wie R's pmatch: kein Treffer (seit 1.6.4, RP; bis dahin „there is more than one match“)
    if len(hits) != 1:
        raise ValueError("'arg' should be one of %s" % ", ".join("\u201c%s\u201d" % c for c in choices))
    return hits[0]


def _chk_digits(digits, kind="format"):
    """``digits`` wie R prüfen (seit 1.6.4, C-012, Entscheidung 77): 1 bis 22; ``kind`` "format" (format(),
    format.data.frame) oder "print" (print.default). ``None`` bleibt ``None``. Ergebnis: ganze Zahl."""
    if digits is None:
        return None
    d = _r_as_int1(digits)
    if d is None or d < 1 or d > 22:
        dv = _NA_INT_ if d is None else d
        if kind == "print":
            raise ValueError("invalid printing digits %d" % dv)
        raise ValueError("invalid value %d for 'digits' argument" % dv)
    return d


def _chk_nsmall(nsmall):
    """``nsmall`` wie R prüfen (seit 1.6.4, C-012, Entscheidung 77): ganze Zahl 0 bis 20."""
    n = _r_as_int1(nsmall)
    if n is None or n < 0 or n > 20:
        raise ValueError("invalid 'nsmall' argument")
    return n


def set_options(**kw):
    """Wie ``options()``: ``digits``, ``scipen``, ``width``, ``OutDec``, ``digits_secs`` (R: ``digits.secs``,
    Ziffern für ``%OS`` ohne Ziffer in :func:`format_date`; ``None`` = nicht gesetzt wie in R). ``digits`` wie R 1
    bis 22 (seit 1.6.4, sonst Fehler „invalid 'digits' parameter, allowed 1...22“).

    Liefert die alten Werte (für ``set_options(**alt)``)."""
    old = {}
    for k, v in kw.items():
        k = "digits.secs" if k == "digits_secs" else k
        if k not in _OPT:
            raise KeyError(k)
        if k == "digits.secs" and not (v is None or isinstance(v, (bool, int, float, np.integer, np.floating))):
            raise TypeError("digits_secs: None oder eine Zahl")
        if k == "digits":   # seit 1.6.4 (C-012, Entscheidung 77) wie R options(digits =)
            d = _r_as_int1(v)
            if d is None or d < 1 or d > 22:
                raise ValueError("invalid 'digits' parameter, allowed 1...22")
            v = d
        old[k] = _OPT[k]
        _OPT[k] = v
    return old


def _digits_secs():
    """``getOption("digits.secs")`` wie bei R's ``%OS``: ganzzahlig (zur Null hin), nicht gesetzt, NA, NaN oder
    außerhalb des int-Bereichs 0, dann auf 0..6 begrenzt (die Begrenzung macht der Kern)."""
    v = _OPT["digits.secs"]
    if v is None:
        return 0
    v = float(v)
    if not (abs(v) < 2147483648.0):
        return 0
    return int(v)


# ── NA / NaN ────────────────────────────────────────────────────────────────

# R's ``NA_real_`` (NaN mit der Nutzlast 1954) ist zentral in ``rnum`` definiert.
# R's ``NaN`` ist ein gewöhnliches ``nan``: wie in R gilt jedes NaN ohne die
# NA-Nutzlast als NaN.
from .rnum import NA_REAL, r_string_to_real  # noqa: E402
from .. import _ext  # noqa: E402


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
    # übrig: kinds ⊆ {"logical", "nanfloat"} mit "logical" oder leer ({"nanfloat"} allein fängt der double-Zweig;
    # seit 1.6.4 ohne die dafür unerreichbare Bedingung und den TypeError)
    na = np.array([_is_na_scalar(x) for x in vals], bool)
    a = np.array([False if na[i] else bool(vals[i]) for i in range(n)], dtype=bool)
    return _V("logical", a, na, names=names, scalar=scalar)


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


def _r_strtod(s):
    """String -> double wie ``String2Real``: (Wert, NA, NaN, Warnung). über
    :func:`simlev._r.rnum.r_string_to_real` (R_strtod mit dem C-Kern ``sl_r_strtod_num``, long double wie R;
    vorher Python-``float``, korrekt gerundet und damit bei mehr als 17 Ziffern teils anders als R)."""
    if s is None:
        return math.nan, True, False, False
    v, bad = r_string_to_real(s)
    if bad:
        return math.nan, True, False, True
    if v != v:
        if _is_rnan(v):
            return v, False, True, False
        return math.nan, True, False, False
    return v, False, False, False


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



def fround(x, digits):
    """R's ``fround`` (R >= 4.0.0) für ein double ``x`` (C-Kern ``sl_r_fround``, seit 1.6.0)."""
    return _ext.slc_r_fround(float(x), float(digits))


def fprec(x, digits):
    """R's ``fprec`` (signif) für ein double ``x`` (C-Kern ``sl_r_fprec``, seit 1.6.0)."""
    return _ext.slc_r_fprec(float(x), float(digits))


def _m2_text(v):
    return isinstance(v, (str, bytes)) or (isinstance(v, (list, tuple, np.ndarray)) and
                                           any(isinstance(t, (str, bytes)) for t in np.asarray(v, dtype=object).ravel()))


def _m2_digits(digits):
    """digits von round/signif wie R's Math2 (seit 1.6.4, C-040): NULL und Länge 0 „invalid second argument of length
    0“, Text „non-numeric argument to mathematical function“; NA (None, nan) bleibt NA."""
    from .rlist import RList
    if digits is None or isinstance(digits, RList):
        if digits is None:
            raise ValueError("invalid second argument of length 0")
        raise ValueError("non-numeric argument to mathematical function")
    if _m2_text(digits):
        raise ValueError("non-numeric argument to mathematical function")
    d = np.asarray(digits, dtype=object).ravel()
    if d.size == 0:
        raise ValueError("invalid second argument of length 0")
    return np.array([NA_REAL if (t is None or t is pd.NA) else float(t) for t in d], dtype=np.float64)


def _m2_values(a):
    """Werte von x als double (None, pd.NA, NaT -> NA); Text ist ein Fehler wie R."""
    if a.dtype.kind in "OUS":
        if _m2_text(a):
            raise ValueError("non-numeric argument to mathematical function")
        return np.array([NA_REAL if (t is None or t is pd.NA) else float(t) for t in a.ravel()],
                        dtype=np.float64).reshape(a.shape)
    return np.ascontiguousarray(a, dtype=np.float64)


def _math2(f, x, digits):
    from .rlist import RList
    if isinstance(x, pd.DataFrame):
        # seit 1.6.4 wie R Math.data.frame (C-040): nur Zahlen- und logische Spalten, sonst „non-numeric-alike
        # variable(s) in data frame: …“ (bis 1.6.3 Python-Fehler aus float())
        # Typen je Spaltenposition (x[c] wäre bei doppelten Spaltennamen ein DataFrame)
        bad = [str(c) for c, dt in zip(x.columns, x.dtypes) if isinstance(dt, pd.CategoricalDtype)
               or not (pd.api.types.is_numeric_dtype(dt) or pd.api.types.is_bool_dtype(dt))]
        if bad:
            raise ValueError("non-numeric-alike variable(s) in data frame: " + ", ".join(bad))
        return x.apply(lambda c: pd.Series(_math2(f, c.to_numpy(dtype=np.float64, na_value=NA_REAL), digits),
                                           index=c.index))
    if isinstance(x, pd.Series):
        if isinstance(x.dtype, pd.CategoricalDtype) or not (pd.api.types.is_numeric_dtype(x.dtype)
                                                             or pd.api.types.is_bool_dtype(x.dtype)):
            raise ValueError("non-numeric argument to mathematical function")
        return pd.Series(_math2(f, x.to_numpy(dtype=np.float64, na_value=NA_REAL), digits), index=x.index,
                         name=x.name)
    # seit 1.6.4 wie R (C-040): NULL, Text, Faktor und Listen sind ein Fehler, NA bleibt NA, digits wird auch bei einem
    # Skalar recycelt; ganze Zahlen bleiben nur bei digits >= 0 unverändert (bis 1.6.3 auch bei digits < 0, z. B.
    # round(15L, -1) = 15 statt 20)
    if x is None or isinstance(x, (RList, pd.Categorical)) or isinstance(x, (str, bytes)):
        raise ValueError("non-numeric argument to mathematical function")
    d = _m2_digits(digits)
    keep_int = f is fround and d.size == 1 and d[0] >= 0
    if np.isscalar(x) or x is pd.NA:
        if x is pd.NA:
            x = NA_REAL
        if isinstance(x, (int, np.integer)) and not isinstance(x, (bool, np.bool_)) and keep_int:
            return x  # round() auf integer bleibt integer
        if d.size == 1:
            return f(float(x), float(d[0]))
        x = np.array([float(x)])
    a = np.asarray(x)
    if a.dtype.kind in "iu" and keep_int:
        return a.copy()
    a = _m2_values(a)
    flat = a.ravel()
    n = max(flat.size, d.size) if flat.size and d.size else 0
    out = np.empty(n)
    _ext.slc_r_round(1 if f is fprec else 0, flat, d, out)   # C-Kern sl_r_round_vec (seit 1.6.0)
    if d.size == 1:
        return out.reshape(a.shape)
    return out


def r_round(x, digits=0):
    """``round(x, digits)`` wie R >= 4.0.0 (Algorithmus aus ``fround.c``).

    Akzeptiert Skalare, Arrays, Series und DataFrames (elementweise)."""
    return _math2(fround, x, digits)


def signif(x, digits=6):
    """``signif(x, digits)`` wie R (``fprec.c``)."""
    return _math2(fprec, x, digits)


# ── formatReal / scientific ────────────────────────────────────────────────

def _format_real(x, na, digits=None, nsmall=0, scipen=None):
    """``formatReal``: (w, d, e) für das float-Array ``x`` (C-Kern ``sl_r_format_real``, seit 1.6.0).

    na: Maske der NA (in ``x`` nan; jedes andere nan ist NaN). Seit 1.6.4 ohne den ungelesenen Parameter ``nan``."""
    if digits is None:
        digits = _OPT["digits"]
    if scipen is None:
        scipen = _OPT["scipen"]
    x = np.ascontiguousarray(x, dtype=np.float64)
    return _ext.slc_r_format_real(x, np.ascontiguousarray(na, dtype=np.uint8), int(digits), int(nsmall), int(scipen))


def _encode_real(x, w, d, e, dec=".", na=False, nan=False, na_string="NA"):
    """``EncodeReal0`` für ein double (C-Kern ``sl_r_encode_real``, seit 1.6.0); nan ohne Kennung ``nan`` gilt als NA."""
    m = np.array([bool(na) or not nan], dtype=np.uint8)
    return _ext.slc_r_encode_real(np.array([x], dtype=np.float64), m, int(w), int(d), int(e), dec, na_string, False)[0]


def _encode_reals(v, w, d, e, dec="."):
    m = np.ascontiguousarray(v.na | ~v.nan, dtype=np.uint8)
    return _ext.slc_r_encode_real(np.ascontiguousarray(v.v, dtype=np.float64), m, int(w), int(d), int(e), dec, "NA",
                                  False)


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

# Anzeigebreite eines Zeichens wie R 4.3.3 (Ri18n_wcwidth mit den Tabellen aus src/main/rlocale_widths.h) unter
# C.UTF-8 (seit 1.6.3; bis 1.6.2 aus unicodedata, also aus dem Unicode-Stand von Python, mit über 450 Abweichungen
# von R, z. B. Steuerzeichen, Hangul-Jamo U+1160-U+11FF, neuere Zeichen). Bereiche (erster, letzter Codepunkt,
# Breite) mit Breite 0 oder 2, alle übrigen Codepunkte haben Breite 1 (wie in R auch nicht vergebene). Gewonnen aus
# nchar(intToUtf8(k), type = "width") für alle Codepunkte; gleiche Tabelle in julia/src/r/_fmt_core.jl.
_WC_RANGES = (
    (0x0000, 0x001F, 0), (0x007F, 0x009F, 0), (0x0300, 0x036F, 0), (0x0483, 0x0489, 0), (0x0591, 0x05BD, 0),
    (0x05BF, 0x05BF, 0), (0x05C1, 0x05C2, 0), (0x05C4, 0x05C5, 0), (0x05C7, 0x05C7, 0), (0x0600, 0x0605, 0),
    (0x0610, 0x061A, 0), (0x061C, 0x061C, 0), (0x064B, 0x065F, 0), (0x0670, 0x0670, 0), (0x06D6, 0x06DD, 0),
    (0x06DF, 0x06E4, 0), (0x06E7, 0x06E8, 0), (0x06EA, 0x06ED, 0), (0x070F, 0x070F, 0), (0x0711, 0x0711, 0),
    (0x0730, 0x074A, 0), (0x07A6, 0x07B0, 0), (0x07EB, 0x07F3, 0), (0x07FD, 0x07FD, 0), (0x0816, 0x0819, 0),
    (0x081B, 0x0823, 0), (0x0825, 0x0827, 0), (0x0829, 0x082D, 0), (0x0859, 0x085B, 0), (0x08D3, 0x0902, 0),
    (0x093A, 0x093A, 0), (0x093C, 0x093C, 0), (0x0941, 0x0948, 0), (0x094D, 0x094D, 0), (0x0951, 0x0957, 0),
    (0x0962, 0x0963, 0), (0x0981, 0x0981, 0), (0x09BC, 0x09BC, 0), (0x09C1, 0x09C4, 0), (0x09CD, 0x09CD, 0),
    (0x09E2, 0x09E3, 0), (0x09FE, 0x09FE, 0), (0x0A01, 0x0A02, 0), (0x0A3C, 0x0A3C, 0), (0x0A41, 0x0A42, 0),
    (0x0A47, 0x0A48, 0), (0x0A4B, 0x0A4D, 0), (0x0A51, 0x0A51, 0), (0x0A70, 0x0A71, 0), (0x0A75, 0x0A75, 0),
    (0x0A81, 0x0A82, 0), (0x0ABC, 0x0ABC, 0), (0x0AC1, 0x0AC5, 0), (0x0AC7, 0x0AC8, 0), (0x0ACD, 0x0ACD, 0),
    (0x0AE2, 0x0AE3, 0), (0x0AFA, 0x0AFF, 0), (0x0B01, 0x0B01, 0), (0x0B3C, 0x0B3C, 0), (0x0B3F, 0x0B3F, 0),
    (0x0B41, 0x0B44, 0), (0x0B4D, 0x0B4D, 0), (0x0B55, 0x0B56, 0), (0x0B62, 0x0B63, 0), (0x0B82, 0x0B82, 0),
    (0x0BC0, 0x0BC0, 0), (0x0BCD, 0x0BCD, 0), (0x0C00, 0x0C00, 0), (0x0C04, 0x0C04, 0), (0x0C3E, 0x0C40, 0),
    (0x0C46, 0x0C48, 0), (0x0C4A, 0x0C4D, 0), (0x0C55, 0x0C56, 0), (0x0C62, 0x0C63, 0), (0x0C81, 0x0C81, 0),
    (0x0CBC, 0x0CBC, 0), (0x0CBF, 0x0CBF, 0), (0x0CC6, 0x0CC6, 0), (0x0CCC, 0x0CCD, 0), (0x0CE2, 0x0CE3, 0),
    (0x0D00, 0x0D01, 0), (0x0D3B, 0x0D3C, 0), (0x0D41, 0x0D44, 0), (0x0D4D, 0x0D4D, 0), (0x0D62, 0x0D63, 0),
    (0x0D81, 0x0D81, 0), (0x0DCA, 0x0DCA, 0), (0x0DD2, 0x0DD4, 0), (0x0DD6, 0x0DD6, 0), (0x0E31, 0x0E31, 0),
    (0x0E34, 0x0E3A, 0), (0x0E47, 0x0E4E, 0), (0x0EB1, 0x0EB1, 0), (0x0EB4, 0x0EBC, 0), (0x0EC8, 0x0ECD, 0),
    (0x0F18, 0x0F19, 0), (0x0F35, 0x0F35, 0), (0x0F37, 0x0F37, 0), (0x0F39, 0x0F39, 0), (0x0F71, 0x0F7E, 0),
    (0x0F80, 0x0F84, 0), (0x0F86, 0x0F87, 0), (0x0F8D, 0x0F97, 0), (0x0F99, 0x0FBC, 0), (0x0FC6, 0x0FC6, 0),
    (0x102D, 0x1030, 0), (0x1032, 0x1037, 0), (0x1039, 0x103A, 0), (0x103D, 0x103E, 0), (0x1058, 0x1059, 0),
    (0x105E, 0x1060, 0), (0x1071, 0x1074, 0), (0x1082, 0x1082, 0), (0x1085, 0x1086, 0), (0x108D, 0x108D, 0),
    (0x109D, 0x109D, 0), (0x1100, 0x115F, 2), (0x1160, 0x11FF, 0), (0x135D, 0x135F, 0), (0x1712, 0x1714, 0),
    (0x1732, 0x1734, 0), (0x1752, 0x1753, 0), (0x1772, 0x1773, 0), (0x17B4, 0x17B5, 0), (0x17B7, 0x17BD, 0),
    (0x17C6, 0x17C6, 0), (0x17C9, 0x17D3, 0), (0x17DD, 0x17DD, 0), (0x180B, 0x180E, 0), (0x1885, 0x1886, 0),
    (0x18A9, 0x18A9, 0), (0x1920, 0x1922, 0), (0x1927, 0x1928, 0), (0x1932, 0x1932, 0), (0x1939, 0x193B, 0),
    (0x1A17, 0x1A18, 0), (0x1A1B, 0x1A1B, 0), (0x1A56, 0x1A56, 0), (0x1A58, 0x1A5E, 0), (0x1A60, 0x1A60, 0),
    (0x1A62, 0x1A62, 0), (0x1A65, 0x1A6C, 0), (0x1A73, 0x1A7C, 0), (0x1A7F, 0x1A7F, 0), (0x1AB0, 0x1AC0, 0),
    (0x1B00, 0x1B03, 0), (0x1B34, 0x1B34, 0), (0x1B36, 0x1B3A, 0), (0x1B3C, 0x1B3C, 0), (0x1B42, 0x1B42, 0),
    (0x1B6B, 0x1B73, 0), (0x1B80, 0x1B81, 0), (0x1BA2, 0x1BA5, 0), (0x1BA8, 0x1BA9, 0), (0x1BAB, 0x1BAD, 0),
    (0x1BE6, 0x1BE6, 0), (0x1BE8, 0x1BE9, 0), (0x1BED, 0x1BED, 0), (0x1BEF, 0x1BF1, 0), (0x1C2C, 0x1C33, 0),
    (0x1C36, 0x1C37, 0), (0x1CD0, 0x1CD2, 0), (0x1CD4, 0x1CE0, 0), (0x1CE2, 0x1CE8, 0), (0x1CED, 0x1CED, 0),
    (0x1CF4, 0x1CF4, 0), (0x1CF8, 0x1CF9, 0), (0x1DC0, 0x1DF9, 0), (0x1DFB, 0x1DFF, 0), (0x200B, 0x200F, 0),
    (0x202A, 0x202E, 0), (0x2060, 0x2064, 0), (0x2066, 0x206F, 0), (0x20D0, 0x20F0, 0), (0x231A, 0x231B, 2),
    (0x2329, 0x232A, 2), (0x23E9, 0x23EC, 2), (0x23F0, 0x23F0, 2), (0x23F3, 0x23F3, 2), (0x25FD, 0x25FE, 2),
    (0x2614, 0x2615, 2), (0x2648, 0x2653, 2), (0x267F, 0x267F, 2), (0x2693, 0x2693, 2), (0x26A1, 0x26A1, 2),
    (0x26AA, 0x26AB, 2), (0x26BD, 0x26BE, 2), (0x26C4, 0x26C5, 2), (0x26CE, 0x26CE, 2), (0x26D4, 0x26D4, 2),
    (0x26EA, 0x26EA, 2), (0x26F2, 0x26F3, 2), (0x26F5, 0x26F5, 2), (0x26FA, 0x26FA, 2), (0x26FD, 0x26FD, 2),
    (0x2705, 0x2705, 2), (0x270A, 0x270B, 2), (0x2728, 0x2728, 2), (0x274C, 0x274C, 2), (0x274E, 0x274E, 2),
    (0x2753, 0x2755, 2), (0x2757, 0x2757, 2), (0x2795, 0x2797, 2), (0x27B0, 0x27B0, 2), (0x27BF, 0x27BF, 2),
    (0x2B1B, 0x2B1C, 2), (0x2B50, 0x2B50, 2), (0x2B55, 0x2B55, 2), (0x2CEF, 0x2CF1, 0), (0x2D7F, 0x2D7F, 0),
    (0x2DE0, 0x2DFF, 0), (0x2E80, 0x2E99, 2), (0x2E9B, 0x2EF3, 2), (0x2F00, 0x2FD5, 2), (0x2FF0, 0x2FFB, 2),
    (0x3000, 0x3029, 2), (0x302A, 0x302D, 0), (0x302E, 0x303E, 2), (0x3041, 0x3096, 2), (0x3099, 0x309A, 0),
    (0x309B, 0x30FF, 2), (0x3105, 0x312F, 2), (0x3131, 0x318E, 2), (0x3190, 0x31E3, 2), (0x31F0, 0x321E, 2),
    (0x3220, 0x3247, 2), (0x3250, 0x4DBF, 2), (0x4E00, 0xA48C, 2), (0xA490, 0xA4C6, 2), (0xA66F, 0xA672, 0),
    (0xA674, 0xA67D, 0), (0xA69E, 0xA69F, 0), (0xA6F0, 0xA6F1, 0), (0xA802, 0xA802, 0), (0xA806, 0xA806, 0),
    (0xA80B, 0xA80B, 0), (0xA825, 0xA826, 0), (0xA82C, 0xA82C, 0), (0xA8C4, 0xA8C5, 0), (0xA8E0, 0xA8F1, 0),
    (0xA8FF, 0xA8FF, 0), (0xA926, 0xA92D, 0), (0xA947, 0xA951, 0), (0xA960, 0xA97C, 2), (0xA980, 0xA982, 0),
    (0xA9B3, 0xA9B3, 0), (0xA9B6, 0xA9B9, 0), (0xA9BC, 0xA9BD, 0), (0xA9E5, 0xA9E5, 0), (0xAA29, 0xAA2E, 0),
    (0xAA31, 0xAA32, 0), (0xAA35, 0xAA36, 0), (0xAA43, 0xAA43, 0), (0xAA4C, 0xAA4C, 0), (0xAA7C, 0xAA7C, 0),
    (0xAAB0, 0xAAB0, 0), (0xAAB2, 0xAAB4, 0), (0xAAB7, 0xAAB8, 0), (0xAABE, 0xAABF, 0), (0xAAC1, 0xAAC1, 0),
    (0xAAEC, 0xAAED, 0), (0xAAF6, 0xAAF6, 0), (0xABE5, 0xABE5, 0), (0xABE8, 0xABE8, 0), (0xABED, 0xABED, 0),
    (0xAC00, 0xD7A3, 2), (0xF900, 0xFAFF, 2), (0xFB1E, 0xFB1E, 0), (0xFE00, 0xFE0F, 0), (0xFE10, 0xFE19, 2),
    (0xFE20, 0xFE2F, 0), (0xFE30, 0xFE52, 2), (0xFE54, 0xFE66, 2), (0xFE68, 0xFE6B, 2), (0xFEFF, 0xFEFF, 0),
    (0xFF01, 0xFF60, 2), (0xFFE0, 0xFFE6, 2), (0xFFF9, 0xFFFB, 0), (0x101FD, 0x101FD, 0), (0x102E0, 0x102E0, 0),
    (0x10376, 0x1037A, 0), (0x10A01, 0x10A03, 0), (0x10A05, 0x10A06, 0), (0x10A0C, 0x10A0F, 0),
    (0x10A38, 0x10A3A, 0), (0x10A3F, 0x10A3F, 0), (0x10AE5, 0x10AE6, 0), (0x10D24, 0x10D27, 0),
    (0x10EAB, 0x10EAC, 0), (0x10F46, 0x10F50, 0), (0x11001, 0x11001, 0), (0x11038, 0x11046, 0),
    (0x1107F, 0x11081, 0), (0x110B3, 0x110B6, 0), (0x110B9, 0x110BA, 0), (0x110BD, 0x110BD, 0),
    (0x110CD, 0x110CD, 0), (0x11100, 0x11102, 0), (0x11127, 0x1112B, 0), (0x1112D, 0x11134, 0),
    (0x11173, 0x11173, 0), (0x11180, 0x11181, 0), (0x111B6, 0x111BE, 0), (0x111C9, 0x111CC, 0),
    (0x111CF, 0x111CF, 0), (0x1122F, 0x11231, 0), (0x11234, 0x11234, 0), (0x11236, 0x11237, 0),
    (0x1123E, 0x1123E, 0), (0x112DF, 0x112DF, 0), (0x112E3, 0x112EA, 0), (0x11300, 0x11301, 0),
    (0x1133B, 0x1133C, 0), (0x11340, 0x11340, 0), (0x11366, 0x1136C, 0), (0x11370, 0x11374, 0),
    (0x11438, 0x1143F, 0), (0x11442, 0x11444, 0), (0x11446, 0x11446, 0), (0x1145E, 0x1145E, 0),
    (0x114B3, 0x114B8, 0), (0x114BA, 0x114BA, 0), (0x114BF, 0x114C0, 0), (0x114C2, 0x114C3, 0),
    (0x115B2, 0x115B5, 0), (0x115BC, 0x115BD, 0), (0x115BF, 0x115C0, 0), (0x115DC, 0x115DD, 0),
    (0x11633, 0x1163A, 0), (0x1163D, 0x1163D, 0), (0x1163F, 0x11640, 0), (0x116AB, 0x116AB, 0),
    (0x116AD, 0x116AD, 0), (0x116B0, 0x116B5, 0), (0x116B7, 0x116B7, 0), (0x1171D, 0x1171F, 0),
    (0x11722, 0x11725, 0), (0x11727, 0x1172B, 0), (0x1182F, 0x11837, 0), (0x11839, 0x1183A, 0),
    (0x1193B, 0x1193C, 0), (0x1193E, 0x1193E, 0), (0x11943, 0x11943, 0), (0x119D4, 0x119D7, 0),
    (0x119DA, 0x119DB, 0), (0x119E0, 0x119E0, 0), (0x11A01, 0x11A0A, 0), (0x11A33, 0x11A38, 0),
    (0x11A3B, 0x11A3E, 0), (0x11A47, 0x11A47, 0), (0x11A51, 0x11A56, 0), (0x11A59, 0x11A5B, 0),
    (0x11A8A, 0x11A96, 0), (0x11A98, 0x11A99, 0), (0x11C30, 0x11C36, 0), (0x11C38, 0x11C3D, 0),
    (0x11C3F, 0x11C3F, 0), (0x11C92, 0x11CA7, 0), (0x11CAA, 0x11CB0, 0), (0x11CB2, 0x11CB3, 0),
    (0x11CB5, 0x11CB6, 0), (0x11D31, 0x11D36, 0), (0x11D3A, 0x11D3A, 0), (0x11D3C, 0x11D3D, 0),
    (0x11D3F, 0x11D45, 0), (0x11D47, 0x11D47, 0), (0x11D90, 0x11D91, 0), (0x11D95, 0x11D95, 0),
    (0x11D97, 0x11D97, 0), (0x11EF3, 0x11EF4, 0), (0x13430, 0x13438, 0), (0x16AF0, 0x16AF4, 0),
    (0x16B30, 0x16B36, 0), (0x16F4F, 0x16F4F, 0), (0x16F8F, 0x16F92, 0), (0x16FE0, 0x16FE3, 2),
    (0x16FE4, 0x16FE4, 0), (0x16FF0, 0x16FF1, 2), (0x17000, 0x187F7, 2), (0x18800, 0x18CD5, 2),
    (0x18D00, 0x18D08, 2), (0x1B000, 0x1B11E, 2), (0x1B150, 0x1B152, 2), (0x1B164, 0x1B167, 2),
    (0x1B170, 0x1B2FB, 2), (0x1BC9D, 0x1BC9E, 0), (0x1BCA0, 0x1BCA3, 0), (0x1D167, 0x1D169, 0),
    (0x1D173, 0x1D182, 0), (0x1D185, 0x1D18B, 0), (0x1D1AA, 0x1D1AD, 0), (0x1D242, 0x1D244, 0),
    (0x1DA00, 0x1DA36, 0), (0x1DA3B, 0x1DA6C, 0), (0x1DA75, 0x1DA75, 0), (0x1DA84, 0x1DA84, 0),
    (0x1DA9B, 0x1DA9F, 0), (0x1DAA1, 0x1DAAF, 0), (0x1E000, 0x1E006, 0), (0x1E008, 0x1E018, 0),
    (0x1E01B, 0x1E021, 0), (0x1E023, 0x1E024, 0), (0x1E026, 0x1E02A, 0), (0x1E130, 0x1E136, 0),
    (0x1E2EC, 0x1E2EF, 0), (0x1E8D0, 0x1E8D6, 0), (0x1E944, 0x1E94A, 0), (0x1F004, 0x1F004, 2),
    (0x1F0CF, 0x1F0CF, 2), (0x1F18E, 0x1F18E, 2), (0x1F191, 0x1F19A, 2), (0x1F200, 0x1F202, 2),
    (0x1F210, 0x1F23B, 2), (0x1F240, 0x1F248, 2), (0x1F250, 0x1F251, 2), (0x1F260, 0x1F265, 2),
    (0x1F300, 0x1F320, 2), (0x1F32D, 0x1F335, 2), (0x1F337, 0x1F37C, 2), (0x1F37E, 0x1F393, 2),
    (0x1F3A0, 0x1F3CA, 2), (0x1F3CF, 0x1F3D3, 2), (0x1F3E0, 0x1F3F0, 2), (0x1F3F4, 0x1F3F4, 2),
    (0x1F3F8, 0x1F43E, 2), (0x1F440, 0x1F440, 2), (0x1F442, 0x1F4FC, 2), (0x1F4FF, 0x1F53D, 2),
    (0x1F54B, 0x1F54E, 2), (0x1F550, 0x1F567, 2), (0x1F57A, 0x1F57A, 2), (0x1F595, 0x1F596, 2),
    (0x1F5A4, 0x1F5A4, 2), (0x1F5FB, 0x1F64F, 2), (0x1F680, 0x1F6C5, 2), (0x1F6CC, 0x1F6CC, 2),
    (0x1F6D0, 0x1F6D2, 2), (0x1F6D5, 0x1F6D7, 2), (0x1F6EB, 0x1F6EC, 2), (0x1F6F4, 0x1F6FC, 2),
    (0x1F7E0, 0x1F7EB, 2), (0x1F90C, 0x1F93A, 2), (0x1F93C, 0x1F945, 2), (0x1F947, 0x1F978, 2),
    (0x1F97A, 0x1F9CB, 2), (0x1F9CD, 0x1F9FF, 2), (0x1FA70, 0x1FA74, 2), (0x1FA78, 0x1FA7A, 2),
    (0x1FA80, 0x1FA86, 2), (0x1FA90, 0x1FAA8, 2), (0x1FAB0, 0x1FAB6, 2), (0x1FAC0, 0x1FAC2, 2),
    (0x1FAD0, 0x1FAD6, 2), (0x20000, 0x3FFFF, 2), (0xE0001, 0xE0001, 0), (0xE0020, 0xE007F, 0),
    (0xE0100, 0xE01EF, 0),
)
_WC_LO = tuple(r[0] for r in _WC_RANGES)


def _wcwidth(k):
    if 0x20 <= k < 0x7F:
        return 1
    i = bisect.bisect_right(_WC_LO, k) - 1
    return _WC_RANGES[i][2] if i >= 0 and k <= _WC_RANGES[i][1] else 1


def _printable(k):
    """Druckbar wie R unter Linux (glibc 2.39 iswprint in C.UTF-8; seit 1.6.4 feste Tabelle, C-047; bis 1.6.3 nach der
    Unicode-Fassung von Python, mit Unicode 15.1 gleich)."""
    return _wct.iswprint(k)


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


def nchar(x, type="chars"):
    """``nchar(x, type)``: 'chars', 'bytes' oder 'width' (seit 1.6.4 wie R: Teilanfang erlaubt, sonst „invalid 'type'
    argument“; ein Faktor ist ein Fehler; C-049, C-056)."""
    if isinstance(x, pd.Categorical) or (isinstance(x, pd.Series) and isinstance(x.dtype, pd.CategoricalDtype)):
        raise ValueError("'nchar()' requires a character vector")
    t = type if isinstance(type, str) else None
    hit = [k for k in ("bytes", "chars", "width") if t and k.startswith(t)]
    if not hit:
        raise ValueError("invalid 'type' argument")
    type = hit[0]
    v = _as_v(x, "character")
    res = []
    for s in v.v:
        if s is None:
            # seit 1.6.4 wie R (keepNA = NA, C-039): NA ergibt für "chars" und "bytes" NA (dann double mit NA_REAL wie
            # ganze Zahlen mit NA in RExpr), für "width" 2; bis 1.6.3 immer 2
            res.append(2 if type == "width" else None)
        elif type == "bytes":
            res.append(len(s.encode("utf-8")))
        elif type == "width":
            res.append(sum(_wcwidth(ord(c)) for c in s))
        else:
            res.append(len(s))
    if any(r is None for r in res):
        res = [NA_REAL if r is None else float(r) for r in res]
        return res[0] if v.scalar else np.array(res, dtype=np.float64)
    if v.scalar:
        return res[0]
    return np.array(res, dtype=np.int64)


# ── as.character / paste ───────────────────────────────────────────────────


def _as_character_list(v):
    t = v.type
    if t == "character":
        return list(v.v)
    if t == "double":
        r = _ext.slc_r_as_character_real(np.ascontiguousarray(v.v, dtype=np.float64), int(_OPT["scipen"]), _OPT["OutDec"])
        bad = (v.na | ~v.nan) & np.isnan(np.asarray(v.v, dtype=np.float64))
        return [None if bad[i] else r[i] for i in range(len(r))]
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


def _paste_str1(v, msg):
    """``sep``/``collapse`` wie R's do_paste: Text (erster Wert eines Textvektors), nicht NA, sonst R's Meldung."""
    if isinstance(v, (list, tuple, np.ndarray, pd.Series)):
        vv = list(v)
        if not vv or not all(isinstance(t, str) or t is None for t in vv):
            raise ValueError(msg)
        v = vv[0]
    if not isinstance(v, str):
        raise ValueError(msg)
    return v


def paste(*args, sep=" ", collapse=None):
    """``paste(..., sep, collapse)`` (NA wird zu "NA"). Seit 1.6.4 wie R (RP, C-056): ``sep`` und ``collapse`` nur
    Text (erster Wert), sonst „invalid separator“ bzw. „invalid 'collapse' argument“ (bis 1.6.3 Python-Fehler)."""
    sep = _paste_str1(sep, "invalid separator")
    if collapse is not None:
        collapse = _paste_str1(collapse, "invalid 'collapse' argument")
    vecs = []
    for a in args:
        v = _as_v(a)
        if v.type == "NULL":   # seit 1.6.5 (CR2-R-6) wie R ein leerer Vektor ("" neben anderen; bis 1.6.4 übergangen)
            vecs.append([])
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


# ── format() ───────────────────────────────────────────────────────────────



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
        w, d, e = _format_real(v.v, v.na, digits, nsmall, scipen)
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


class _DefaultStr(str):
    """Standardwert, der als gewöhnlicher Text erscheint, aber erkennbar bleibt, ob er übergeben wurde."""
    __slots__ = ()


# seit 1.6.4 (RP): format() erkennt so den Standard von justify; bei DataFrames gilt dann wie in R's
# format.data.frame "none" (Textspalten ohne Auffüllen), sonst "left" wie format.default
_JUSTIFY_LEFT = _DefaultStr("left")


def format(x, format=None, *, trim=False, digits=None, nsmall=0, justify=_JUSTIFY_LEFT, width=None,
           na_encode=True, scientific=None, big_mark="", big_interval=3, small_mark="",
           small_interval=5, decimal_mark=None, zero_print=None, drop0trailing=False,
           type=None):
    """``format(x, ...)`` wie R's ``format.default``/``format.Date``/``format.factor``.

    Args:
        x: Vektor (siehe Modul-Doku), Series (benannt), Skalar oder DataFrame (wie
            ``format.data.frame``: ``justify`` ist dort standardmäßig "none").
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
        if justify is _JUSTIFY_LEFT:
            justify = "none"           # seit 1.6.4 wie R format.data.frame (bis 1.6.3 "left": Text aufgefüllt)
        extra = (format, trim, nsmall, width, scientific, big_mark, big_interval, small_mark, small_interval,
                 decimal_mark, zero_print, drop0trailing, type)
        if any(not _is_default(a, b)
               for a, b in zip(extra, (None, False, 0, None, None, "", 3, "", 5, None, None, False, None))):
            # seit 1.6.4 wie R format.data.frame (C-041): alle Angaben gehen an format() jeder Spalte (bis 1.6.3 nur
            # digits, na.encode und justify; width, nsmall usw. fielen still weg)
            def col(c):
                r = globals()["format"](x[c].reset_index(drop=True), format, trim=trim, digits=digits, nsmall=nsmall,
                                        justify=justify, width=width, na_encode=na_encode, scientific=scientific,
                                        big_mark=big_mark, big_interval=big_interval, small_mark=small_mark,
                                        small_interval=small_interval, decimal_mark=decimal_mark,
                                        zero_print=zero_print, drop0trailing=drop0trailing, type=type)
                return [r] if isinstance(r, str) else list(np.asarray(r, dtype=object))
            return pd.DataFrame({c: col(c) for c in x.columns}, index=x.index)
        if x.shape[1]:
            digits = _chk_digits(digits)   # seit 1.6.4 wie R (format.data.frame formatiert jede Spalte; C-012)
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
        res = _date_nan(_format_date_list(v.v, [format or "%Y-%m-%d"]), v)
        return _out(res, v)
    # seit 1.6.4 (C-012, C-056, Entscheidung 77) wie R format.default/do_format: justify über match.arg, dann trim,
    # digits (1 bis 22), nsmall (0 bis 20), width, na.encode und scientific in dieser Reihenfolge mit R's Meldungen
    # (bis 1.6.3 lasen die Tabellen des Kerns außerhalb, bool() las NaN und "no" als TRUE)
    justify = _r_match_arg(justify, ("left", "right", "centre", "none"))
    trim = _r_lgl_arg(trim, "trim")
    digits = _chk_digits(digits)
    nsmall = _chk_nsmall(nsmall)
    if width is not None:
        width = _r_as_int1(width)
        if width is None:
            raise ValueError("invalid 'width' argument")
    na_encode = _r_lgl_arg(na_encode, "na.encode")
    if scientific is not None:
        sa = list(scientific) if isinstance(scientific, (list, tuple, np.ndarray)) else [scientific]
        if len(sa) != 1 or isinstance(sa[0], str):
            raise ValueError("invalid 'scientific' argument")
        sv = sa[0]
        if isinstance(sv, (bool, np.bool_)):
            scientific = bool(sv)
        elif isinstance(sv, (float, np.floating)) and math.isnan(sv):
            scientific = None            # NA wie R (logisch NA: Voreinstellung)
        else:
            si = _r_as_int1(sv)
            scientific = -2147483648 if si is None else si
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
                        drop0trailing=drop0trailing)
    return _out(r, v)


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
                    zero_print=None, replace_zero=False, drop0trailing=False, not_char=False):
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


# ── formatC ────────────────────────────────────────────────────────────────


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
        elif _isnan_num(width):   # seit 1.6.4 wie R (width < 0L ist NA)
            raise ValueError("missing value where TRUE/FALSE needed")
        elif width < 0:
            flag = "-"
            width = -width
        cv = _V("character", strs, np.array([s is None for s in strs], bool))
        if width is not None and _r_as_int1(width) is None:   # seit 1.6.4 wie R do_format (asInteger(width) NA)
            raise ValueError("invalid 'width' argument")
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
    if v.type == "logical":   # seit 1.6.4 wie R (C-049): formatC(<logisch>) ist ein Fehler
        raise ValueError("unsupported type ")
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
    elif _isnan_num(width):   # seit 1.6.4 wie R (width == 0L ist NA)
        raise ValueError("missing value where TRUE/FALSE needed")
    elif width == 0:
        width = digits
    # seit 1.6.4 (C-011, FW6-6) wie R: width außerhalb des int-Bereichs wird NA (Warnung bei as.integer in i.strlen
    # und bei asInteger im Kern), und R kann dann bzw. ab i.strlen >= 2147483645 den Puffer nicht anlegen; bis 1.6.3
    # Absturz bzw. leerer Text
    if _r_as_int1(width) is None:
        import warnings
        warnings.warn("NAs introduced by coercion to integer range")
        raise ValueError("cannot allocate memory block of size 16777216 Tb")
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
    if istrlen and max(istrlen) >= 2147483645:   # seit 1.6.4 wie R (Größe des Puffers läuft über)
        raise ValueError("cannot allocate memory block of size 16777216 Tb")
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
                            replace_zero=replace_zero, drop0trailing=drop0trailing)
    return _out(r, v)


def _str_signif(vals, type, width, digits, format, flag, istrlen):
    """``str_signif`` aus util.c (C-Kern ``sl_r_str_signif`` über snprintf, seit 1.6.0)."""
    try:
        return _ext.slc_r_str_signif(np.ascontiguousarray(vals, dtype=np.float64), type == "integer", int(width),
                                     int(digits), format, flag, np.ascontiguousarray(istrlen, dtype=np.int64))
    except ValueError as e:
        raise ValueError(str(e)) from None


# ── sprintf ────────────────────────────────────────────────────────────────

_SP_TYPE = {"logical": 0, "integer": 1, "double": 2, "character": 3, "factor": 4, "Date": 5}
_NA_INT = -2147483648


def _sp_arg(v):
    """Argument von sprintf für den C-Kern: (Typ, Daten, Texte)."""
    t = v.type
    if t == "character":
        return (3, None, list(v.v))
    if t in ("double", "Date"):
        x = np.array(v.v, dtype=np.float64)
        x[v.na] = NA_REAL
        return (_SP_TYPE[t], x, _format_date_list(v.v, ["%Y-%m-%d"]) if t == "Date" else None)
    if t == "factor":
        c = np.asarray(v.v, dtype=np.int64)
        iv = np.where(c < 0, _NA_INT, c + 1).astype(np.int32)
        return (4, iv, [None if q < 0 else v.levels[int(q)] for q in c.tolist()])
    if t in ("integer", "logical"):
        iv = np.asarray(v.v, dtype=np.int64)
        iv = np.where(v.na, _NA_INT, iv).astype(np.int32)
        return (_SP_TYPE[t], iv, None)
    if t == "NULL":
        return (2, np.zeros(0), None)
    raise ValueError("unsupported type")


def _sprintf_warn(nunused, nfmt, f0):
    import warnings
    if nfmt == 1:
        f0 = "NA" if f0 is None else f0
        if nunused == 1:
            warnings.warn("one argument not used by format '%s'" % f0)
        else:
            warnings.warn("%d arguments not used by format '%s'" % (nunused, f0))
    else:
        warnings.warn("one argument not used by format" if nunused == 1 else "%d arguments not used by format" % nunused)


def sprintf(fmt, *args):
    """``sprintf(fmt, ...)`` mit R's Vektorsemantik.

    Recycling über ``fmt`` und alle Argumente; NA -> "NA" (mit Breite),
    ``Inf``/``-Inf``/``NaN`` wie R; ``%s`` von Zahlen = as.character (15
    Stellen); ``%d`` nur für ganzzahlige Werte; Breiten bei ``%s`` in Bytes
    (wie C). Liefert str, wenn alles Länge 1 ist, sonst ein object-Array."""
    fv = _as_v(fmt, "character")
    vs = [_as_v(a) for a in args]
    try:   # C-Kern sl_r_sprintf (seit 1.6.0): Umwandlungen über snprintf wie R
        res, nunused = _ext.slc_r_sprintf(list(fv.v), [_sp_arg(v) for v in vs], int(_OPT["scipen"]), _OPT["OutDec"])
    except ValueError as e:
        raise ValueError(str(e)) from None
    if nunused:
        _sprintf_warn(nunused, len(fv), fv.v[0] if len(fv) else None)
    if fv.scalar and all(v.scalar for v in vs) and len(res) == 1:
        return res[0]
    a = np.empty(len(res), dtype=object)
    a[:] = res
    return a


# ── Datum ──────────────────────────────────────────────────────────────────
# format.Date/strftime (C-Locale) rechnet der gemeinsame Kern core/slc_rbase_date.cpp (wie Julia).


def _format_date_list(days, fmts):
    """format.Date für Tage seit 1970-01-01 (Länge max(n, nf) mit Wiederholung); NA/NaN/±Inf, ``None`` -> ``None``.
    ``%OS`` ohne Ziffer nach ``digits.secs`` (:func:`set_options`); Ergebnis über 2048 Bytes: ValueError wie R.
    Seit 1.6.4 (C-057) wie R 4.3.3: Inf und -Inf als "Inf", "-Inf" bei jeder Vorlage; NaN (nicht NA) ergänzt der
    Aufrufer über die NA-Maske (_date_nan)."""
    d = np.ascontiguousarray(days, dtype=np.float64)
    out = _ext.slc_r_format_date(d, list(fmts), _digits_secs())
    if d.size and np.isinf(d).any():
        n = d.size
        for i in range(len(out)):
            t = float(d[i % n])
            if math.isinf(t):
                out[i] = "Inf" if t > 0 else "-Inf"
    return out


def _date_nan(out, v):
    """NaN-Tage (nicht NA) wie R als "NaN" (seit 1.6.4, C-057)."""
    n = len(v.v)
    for i in range(len(out)):
        k = i % n
        if v.v[k] != v.v[k] and not v.na[k]:
            out[i] = "NaN"
    return out


def format_date(x, fmt="%Y-%m-%d"):
    """``format(<Date>, fmt)`` wie ``format.Date``/``strftime`` in der C-Locale.

    ``x``: datetime64, ``date``, Tage seit 1970-01-01 (Zahl) oder Vektor davon.
    NA -> ``None``."""
    v = _as_v(x)
    if v.type in ("double", "integer"):
        v = _coerce(v, "Date")
    elif v.type == "character":
        # Text wie as.Date() (seit 1.6.4, C-021/P12-R17: Format nach dem ersten Element ungleich NA, "%Y-%m-%d" oder
        # "%Y/%m/%d", sonst Fehler wie R; bis 1.6.3 nur ISO je Element, sonst still NA)
        from .rexpr import CHR, _as_date
        dd = _as_date(CHR(list(v.v)))   # Tage als double, NA = NA_REAL (seit 1.6.4, C-003)
        days = [math.nan if d != d else float(d) for d in dd]
        v = _V("Date", np.array(days, np.float64), np.array([d != d for d in dd], bool), names=v.names, scalar=v.scalar)
    # seit 1.6.4 (C-057) wie R format.POSIXlt: NA in der Vorlage „missing value where TRUE/FALSE needed“, keine bzw. keine
    # Textvorlage „invalid 'format' argument“ (bis 1.6.3 wurde z. B. TRUE als Vorlage "TRUE" gelesen)
    if fmt is None:
        fmt = "%Y-%m-%d"
    fl = list(fmt) if isinstance(fmt, (list, tuple, np.ndarray)) else [fmt]
    if any(t is None or (isinstance(t, float) and t != t) for t in fl):
        raise ValueError("missing value where TRUE/FALSE needed")
    if not fl or not all(isinstance(t, str) for t in fl):
        raise ValueError("invalid 'format' argument")
    fv = _as_v(fmt, "character")
    return _out(_date_nan(_format_date_list(v.v, list(fv.v)), v), v)


# ── Druckausgabe: Vektoren ─────────────────────────────────────────────────

def _vec_label(i, labwidth):
    return " " * (labwidth - _index_width(i) - 2) + "[%d]" % i


def _type0(v):
    return {"logical": "logical(0)", "integer": "integer(0)", "double": "numeric(0)",
            "character": "character(0)"}.get(v.type, "NULL")


def _encode_elems(v, digits=None):
    """(Breite, Liste der Elemente kodiert mit dieser Breite) – ohne Lücke."""
    t = v.type
    n = len(v)
    if t == "double":
        w, d, e = _format_real(v.v, v.na, digits)
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
        # seit 1.6.4 wie R names<- (C-058): zu lange Namen sind ein Fehler, zu kurze werden mit NA ergänzt
        if len(v.names) > len(v):
            from .linalg import RError
            raise RError("'names' attribute [%d] must be the same length as the vector [%d]" % (len(v.names), len(v)))
        v.names = v.names + [None] * (len(v) - len(v.names))
    digits = _chk_digits(digits, "print")   # seit 1.6.4 wie R print.default (C-012, Entscheidung 77)
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
            wj, dj, ej = _format_real(col.v, col.na, digits)
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

    dcache = {}   # double-Spalten einmal je Spalte kodiert (seit 1.6.3; gleicher Kern, gleiche Maske wie je Zelle)

    def cell(i, j):
        col = cols[j]
        if is_str:
            return " " * gap + _encode_string(col.v[i], w[j], quote, "right" if right else "left")
        if ctype == "double":
            s = dcache.get(j)
            if s is None:
                dj, ej = enc[j]
                s = dcache[j] = _encode_reals(col, w[j], dj, ej, _OPT["OutDec"])
            return s[i]
        if ctype == "integer":
            return _encode_integer(int(col.v[i]), bool(col.na[i]), w[j])
        return _encode_logical(bool(col.v[i]), bool(col.na[i]), w[j])

    lines = []

    def head():
        if cn is not None:
            lines.append(" " * rlabw + cn)
        if rn is not None:
            # seit 1.6.4 wie R printMatrix (C-038): Rprintf("%*s", -rlabw, rn) füllt nach Bytes auf (bis 1.6.3 nach
            # Zeichen: bei Umlauten ein Leerzeichen mehr als R)
            return rn + " " * max(0, rlabw - len(rn.encode("utf-8", "surrogateescape")))
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
    for k, (lab, ext) in enumerate(((rl, r), (cl, c)), start=1):   # seit 1.6.4 wie R dimnames<- (C-058)
        if lab is not None and len(lab) != ext:
            from .linalg import RError
            raise RError("length of 'dimnames' [%d] not equal to array extent" % k)
    digits = _chk_digits(digits, "print")   # seit 1.6.4 wie R print.default (C-012, Entscheidung 77)
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


def _is_default(a, b):
    """a ist der Standardwert b (gleicher Typ und Wert; für C-041)."""
    import builtins
    return a is b or (b is not None and builtins.type(a) is builtins.type(b) and a == b)


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


def format_data_frame(df, digits=None, types=None):
    """``format.data.frame``: Liste formatierter Spalten (str/None); wie R mit ``na.encode = FALSE``,
    ``justify = "none"`` (seit 1.6.3 ohne die nie übergebenen Argumente dafür)."""
    if df.shape[1]:
        digits = _chk_digits(digits)   # seit 1.6.4 wie R format() je Spalte (C-012, Entscheidung 77)
    types = types or {}
    return [_fmt_column(df.iloc[:, j], digits, False, "none", types.get(df.columns[j]))
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
