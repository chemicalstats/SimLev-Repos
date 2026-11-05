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
#                     core/slc_rbase_date.cpp.
"""R-kompatible Textausgabe und Rundung (Engine).

Gegenstück zu ``julia/src/r/rformat.jl``. Nachbildungen von R-Funktionen,
deren Ergebnis in Ausgaben oder Rechnungen sichtbar wird: ``round()``
(``nmath/fround.c``), ``signif()`` (``fprec.c``),
``format()``/``as.character()``/``deparse()`` für Zahlen
(``formatReal``/``scientific`` aus ``main/format.c``) und ``sprintf()`` mit
R-Verhalten für ``NA``/``NaN``/``Inf``. Seit 1.5.2 eine dünne Hülle: Rundung
(``fround``, ``fprec``) und ``formatReal``/``encodeReal`` rechnet
:mod:`simlev._r.fmt` (bis 1.5.1 eine zweite Nachbildung hier); dort steht auch
die volle Formatierung (``format``, ``formatC``, ``print``). ``r_sprintf`` ist
seit 1.6.0 nur noch der skalare Zugang (``None`` = NA) zum selben C-Kern
``sl_r_sprintf`` wie :func:`simlev._r.fmt.sprintf` (bis 1.5.2 eine zweite
Nachbildung mit Python-Formaten).
"""
from __future__ import annotations

import datetime as _dt
import math
import re
from typing import Any, Sequence

import numpy as np

from . import fmt as _fmt
from .. import _ext   # C-Kern sl_r_sprintf (core/slc_rbase_fmt.cpp, seit 1.6.0)
from .rnum import NA_REAL, r_isna

__all__ = ["r_round", "r_signif", "r_format", "r_format1", "r_as_character", "r_deparse", "r_sprintf"]


def r_round(x: float, digits: float = 0.0) -> float:
    """``round(x, digits)`` wie R >= 4.0.0 (``nmath/fround.c``; Rechnung :func:`simlev._r.fmt.fround`)."""
    return _fmt.fround(float(x), float(digits))


def r_signif(x: float, digits: float = 6) -> float:
    """``signif(x, digits)`` wie R (``nmath/fprec.c``; Rechnung :func:`simlev._r.fmt.fprec`, ``digits`` wie R
    mit C-``round()``)."""
    return _fmt.fprec(float(x), digits)


# ═══════════════════════════════════════════════════════════════════════════
# Zahlenformatierung wie R (format.c, printutils.c): formatReal/encodeReal aus simlev._r.fmt
# ═══════════════════════════════════════════════════════════════════════════

def _format_real(xs: Sequence[float], digits: int = 7, nsmall: int = 0, scipen: int = 0):
    """``formatReal()``: gemeinsame Breite w, Nachkommastellen d, Exponentformat e."""
    x = np.asarray(xs, dtype=np.float64)
    nan = _fmt._nan_mask(x)
    return _fmt._format_real(x, np.isnan(x) & ~nan, nan, digits, nsmall, scipen)


def _encode_real(x: float, w: int, d: int, e: int, drop0: bool = False) -> str:
    na = r_isna(x)
    s = _fmt._encode_real(x, w, d, e, ".", na, x != x and not na)
    return _fmt._drop0(s) if drop0 and math.isfinite(x) else s


def _insert_big_mark(s: str, mark: str) -> str:
    m = re.match(r"^(\s*[-+]?)(\d+)(.*)$", s)
    if not m or len(m.group(2)) < 4:
        return s
    digs = m.group(2)
    rev = digs[::-1]
    parts = [rev[i:i + 3] for i in range(0, len(rev), 3)]
    return m.group(1) + mark[::-1].join(parts)[::-1] + m.group(3)


def _is_num(x) -> bool:
    return isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_))


def r_format(x: Any, digits: int | None = None, nsmall: int = 0, big_mark: str = "",
             scientific: bool | None = None, width: int | None = None) -> list[str]:
    """``format(x, ...)`` für einen Vektor wie R (gemeinsame Breite).

    ``x`` darf eine Zahl, ein Wahrheitswert, ein Text, ein Datum oder eine Folge davon
    sein. Rückgabe: Liste der formatierten Elemente.
    """
    if x is None:
        return []
    vals = list(x) if isinstance(x, (list, tuple, np.ndarray)) else [x]
    if not vals:
        return []
    dg = 7 if digits is None else int(digits)
    scipen = 0 if scientific is None else (-99 if scientific else 310)
    if all(_is_num(v) or v is None for v in vals) and any(_is_num(v) for v in vals):
        fv = [NA_REAL if v is None else float(v) for v in vals]
        w, d, e = _format_real(fv, dg, nsmall, scipen)
        out = [_encode_real(v, w, d, e) for v in fv]
        if big_mark:
            out = [_insert_big_mark(s, big_mark) for s in out]
            ww = max(len(s) for s in out)
            out = [s.rjust(ww) for s in out]
        if width:
            out = [s.rjust(width) for s in out]
        return out
    if all(isinstance(v, (bool, np.bool_)) or v is None for v in vals):
        out = ["NA" if v is None else ("TRUE" if v else "FALSE") for v in vals]
        w = max(len(s) for s in out)
        return [s.rjust(w) for s in out]
    out = [_as_str(v) for v in vals]
    w = max(width or 0, max(len(s) for s in out))
    return [s.ljust(w) for s in out]


def r_format1(x: Any, **kw) -> str:
    """``format(x)`` für einen einzelnen Wert."""
    r = r_format(x, **kw)
    return r[0] if r else "character(0)"


def _as_str(v: Any) -> str:
    if v is None:
        return "NA"
    if isinstance(v, str):
        return v
    if isinstance(v, (bool, np.bool_)):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (_dt.date, np.datetime64)):
        if isinstance(v, np.datetime64):
            return str(v.astype("datetime64[D]"))
        if isinstance(v, _dt.datetime):
            return v.date().isoformat()
        return v.isoformat()
    if _is_num(v):
        return r_as_character(v)
    return str(v)


def r_as_character(x: Any) -> str:
    """``as.character(x)`` für eine Zahl (15 signifikante Stellen, ohne Endnullen)."""
    if isinstance(x, (bool, np.bool_)):
        return "TRUE" if x else "FALSE"
    if isinstance(x, (int, np.integer)) and not isinstance(x, (bool, np.bool_)) and abs(int(x)) < 2 ** 31:
        return str(int(x))
    xf = float(x)
    if math.isnan(xf):
        return "NA" if r_isna(xf) else "NaN"
    w, d, e = _format_real([xf], 15, 0, 0)
    return _encode_real(xf, w, d, e, drop0=True)


def r_deparse(x: Any) -> str:
    """``paste(deparse(x), collapse = "")`` für einfache Werte (Zahlen, Text, Wahrheitswerte, Vektoren)."""
    def one(v, all_na=False):
        if v is None:
            return "NA"
        if isinstance(v, str):
            return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
        if isinstance(v, (bool, np.bool_)):
            return "TRUE" if v else "FALSE"
        if isinstance(v, (_dt.date, np.datetime64)):
            return '"%s"' % _as_str(v)
        if _is_num(v):
            f = float(v)
            if math.isnan(f):
                if not r_isna(f):
                    return "NaN"
                # Ein Double-Vektor nur aus NA: NA_real_ (sonst wäre er logisch)
                return "NA_real_" if all_na else "NA"
            if math.isinf(f):
                return "Inf" if f > 0 else "-Inf"
            w, d, e = _format_real([f], 15, 0, 0)
            return _encode_real(f, w, d, e)
        return repr(v)
    if x is None:
        return "NULL"
    if isinstance(x, dict):
        if not x:
            return "list()"
        return "list(" + ", ".join("%s = %s" % (k, r_deparse(v)) for k, v in x.items()) + ")"
    if isinstance(x, (list, tuple, np.ndarray)):
        vals = list(x)
        if not vals:
            return "NULL" if isinstance(x, (list, tuple)) else "numeric(0)"
        if any(isinstance(v, (list, tuple, dict)) for v in vals):
            return "list(" + ", ".join(r_deparse(v) for v in vals) + ")"
        all_na = all(_is_num(v) and r_isna(float(v)) for v in vals)
        if len(vals) == 1:
            return one(vals[0], all_na)
        return "c(" + ", ".join(one(v, all_na) for v in vals) + ")"
    return one(x, True)


_NA_INT = -2147483648


def _sp_scalar(v: Any):
    """Skalares Argument für den C-Kern ``sl_r_sprintf``: (Typ, Wert, Texte)."""
    if v is None:
        return (0, _NA_INT, None)
    if isinstance(v, (bool, np.bool_)):
        return (0, int(v), None)
    if isinstance(v, (int, np.integer)):
        return (1, int(v), None) if abs(int(v)) < 2 ** 31 else (2, float(v), None)
    if isinstance(v, (float, np.floating)):
        return (2, float(v), None)
    if isinstance(v, str):
        return (3, None, [v])
    if isinstance(v, (_dt.date, np.datetime64)):
        s = _as_str(v)
        return (5, float((_dt.date.fromisoformat(s) - _dt.date(1970, 1, 1)).days), [s])
    return (3, None, [str(v)])


def r_sprintf(fmt: str, *args: Any) -> str:
    """``sprintf(fmt, ...)`` für Skalare (``None`` = NA): schneller Weg zum C-Kern ``sl_r_sprintf`` (seit 1.6.0 dieselbe
    Rechnung wie :func:`simlev._r.fmt.sprintf`, ohne Umwandlung in Vektoren)."""
    try:
        res, nunused = _ext.slc_r_sprintf([fmt], [_sp_scalar(a) for a in args], int(_fmt._OPT["scipen"]),
                                          _fmt._OPT["OutDec"])
    except ValueError as e:
        raise ValueError(str(e)) from None
    if nunused:
        _fmt._sprintf_warn(nunused, 1, fmt)
    return res[0]
