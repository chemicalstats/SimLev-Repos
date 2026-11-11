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
import decimal as _decimal
import fractions as _fractions
import math
import re
from typing import Any, Sequence

import numpy as np
import pandas as pd

from . import fmt as _fmt
from .. import _ext   # C-Kern sl_r_sprintf (core/slc_rbase_fmt.cpp, seit 1.6.0)
from .rnum import NA_REAL, r_isna, r_isna_arr

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
    return _fmt._format_real(x, np.isnan(x) & ~nan, digits, nsmall, scipen)


def _encode_real(x: float, w: int, d: int, e: int) -> str:
    na = r_isna(x)
    return _fmt._encode_real(x, w, d, e, ".", na, x != x and not na)


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


def _flt(v) -> float:
    """``float(v)`` wie R's double: ganze Zahlen über dem Zahlbereich ergeben ±Inf (seit 1.6.4, RP, C-049; bis 1.6.3
    OverflowError)."""
    try:
        return float(v)
    except OverflowError:
        return math.inf if v > 0 else -math.inf


def _rp_vals(vals, who):
    """Werte für r_format/r_deparse (seit 1.6.4, RP, C-049): Decimal und Fraction gelten wie R als double (bis 1.6.3
    als Text ``Decimal('1.5')``/``1/3``); Werte ohne Gegenstück in R (Bytes, komplexe Zahlen) ergeben einen Fehler.
    Gemischte Zahlen und Wahrheitswerte wie R's ``c()``: Wahrheitswerte als 1/0."""
    out = []
    for v in vals:
        if isinstance(v, (_decimal.Decimal, _fractions.Fraction)):
            v = _flt(v)
        elif isinstance(v, (bytes, bytearray, memoryview, complex, np.complexfloating)):
            from .._meldungen import EINGABE
            raise ValueError(EINGABE["rp.wert_typ"] % who)
        out.append(v)
    if any(isinstance(v, (bool, np.bool_)) for v in out) and any(_is_num(v) for v in out) \
            and all(v is None or _is_num(v) or isinstance(v, (bool, np.bool_)) for v in out):
        out = [int(v) if isinstance(v, (bool, np.bool_)) else v for v in out]
    return out


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
    vals = _rp_vals(vals, "r_format")
    # seit 1.6.4 (C-012, Entscheidung 77) digits 1 bis 22 und nsmall 0 bis 20 wie R format()
    dg = 7 if digits is None else _fmt._chk_digits(digits)
    nsmall = _fmt._chk_nsmall(nsmall)
    # scientific: Wahrheitswert oder (seit 1.6.4 wie R und Julia, C-048) Zahl als Strafpunkte wie options(scipen)
    if scientific is None:
        scipen = 0
    elif isinstance(scientific, (bool, np.bool_)):
        scipen = -99 if scientific else 310
    else:
        scipen = int(scientific)
    if all(_is_num(v) or v is None for v in vals) and any(_is_num(v) for v in vals):
        fv = [NA_REAL if v is None else _flt(v) for v in vals]
        if all(v is None or (isinstance(v, (int, np.integer)) and not isinstance(v, (bool, np.bool_))
                             and abs(int(v)) < 2 ** 31) for v in vals):
            # seit 1.6.4 ganze Zahlen (|x| < 2^31) wie R-integer (Entscheidung 63, C-090; bis 1.6.3 wie double)
            out = ["NA" if v is None else str(int(v)) for v in vals]
            ww = max(len(s) for s in out)
            out = [s.rjust(ww) for s in out]
        else:
            w, d, e = _format_real(fv, dg, nsmall, scipen)
            # in einem Aufruf (seit 1.6.4, C-070, wie Julia seit 1.6.3; bis dahin je Wert): gleicher Kern
            # sl_r_encode_real, gleiche Maske wie _encode_real (NA oder keine NaN)
            a = np.array(fv, dtype=np.float64)
            m = np.ascontiguousarray(r_isna_arr(a) | ~np.isnan(a), dtype=np.uint8)
            out = list(_ext.slc_r_encode_real(a, m, int(w), int(d), int(e), ".", "NA", False))
        # seit 1.6.5 (CR2-D-13) wie R format.default: erst die Breite (.Internal(format)), dann die Tausenderzeichen
        # (prettyNum, gemeinsame Breite); bis 1.6.4 umgekehrt (mit big_mark und width zu schmal)
        if width:
            out = [s.rjust(width) for s in out]
        if big_mark:
            out = [_insert_big_mark(s, big_mark) for s in out]
            ww = max(len(s) for s in out)
            out = [s.rjust(ww) for s in out]
        return out
    if all(isinstance(v, (bool, np.bool_)) or v is None for v in vals):
        out = ["NA" if v is None else ("TRUE" if v else "FALSE") for v in vals]
        w = max(width or 0, max(len(s) for s in out))   # seit 1.6.5 mit width wie R (CR2-D-13)
        return [s.rjust(w) for s in out]
    out = [_as_str(v) for v in vals]
    if all(v is None or (isinstance(v, _dt.date) and not isinstance(v, _dt.datetime))
           or (isinstance(v, np.datetime64) and np.datetime_data(v.dtype)[0] == "D") for v in vals):
        return out   # Datumswerte ohne gemeinsame Breite wie R format.Date (seit 1.6.4 mit Jahren ohne Auffüllen, C-005)
    # Anzeigebreite wie R (seit 1.6.5, CR2-D-13: _fmt._strwid statt Zeichenzahl; breite Zeichen zählen 2)
    wd = [_fmt._strwid(s) for s in out]
    w = max(width or 0, max(wd))
    return [s + " " * (w - k) for s, k in zip(out, wd)]


def r_format1(x: Any, **kw) -> str:
    """``format(x)`` für einen einzelnen Wert."""
    r = r_format(x, **kw)
    return r[0] if r else "character(0)"


def _r_date_text(z: int) -> str:
    """Datumstext wie R as.character/format für Tage seit 1970-01-01: ``"%d-%02d-%02d"`` mit dem Jahr ohne Auffüllen
    (``"53-06-19"``, ``"-1-01-01"``, ``"12345-01-01"``). Seit 1.6.4 (C-005, Entscheidung 97); bis 1.6.3 ISO-Text mit
    vierstelligem Jahr bzw. Fehler außerhalb 1–9999."""
    z += 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return "%d-%02d-%02d" % (yoe + era * 400 + (m <= 2), m, d)


def _date_days(v: Any) -> int:
    """Tage seit 1970-01-01 eines date/datetime/datetime64 (Uhrzeit abgeschnitten)."""
    if isinstance(v, np.datetime64):
        return int(v.astype("datetime64[D]").astype(np.int64))
    if isinstance(v, _dt.datetime):
        v = v.date()
    return v.toordinal() - _dt.date(1970, 1, 1).toordinal()


def _as_str(v: Any) -> str:
    if v is None or v is pd.NaT:   # pd.NaT wie NA (seit 1.6.5, CR2-X8-3; bis 1.6.4 Rohfehler aus toordinal)
        return "NA"
    if isinstance(v, str):
        return v
    if isinstance(v, (bool, np.bool_)):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (_dt.date, np.datetime64)):
        if isinstance(v, np.datetime64):
            if np.isnat(v):
                return "NA"
            d = v.astype("datetime64[D]")
            if v == d:
                return _r_date_text(_date_days(d))
            v = _dt.datetime(1970, 1, 1) + _dt.timedelta(microseconds=int(v.astype("datetime64[us]").astype(np.int64)))
        if isinstance(v, _dt.datetime):   # seit 1.6.4 wie R as.character(<POSIXct>) (C-050)
            if (v.hour, v.minute, v.second, v.microsecond) == (0, 0, 0, 0):
                return _r_date_text(_date_days(v))
            return _r_date_text(_date_days(v)) + v.strftime(" %H:%M:%S")
        return _r_date_text(_date_days(v))
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
    # C-Kern sl_r_as_character_real mit scipen fest 0 und "." (seit 1.6.4; bis 1.6.3 formatReal + encodeReal + Drop0
    # hier nachgebaut, gleiche Texte)
    return _ext.slc_r_as_character_real(np.array([xf], dtype=np.float64), 0, ".")[0]


_DEP_ESC = {"\a": "\\a", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t", "\v": "\\v",
            "\\": "\\\\", '"': '\\"'}


def r_deparse_str(s: str) -> str:
    """Text in Anführungszeichen wie R ``deparse`` (EncodeString in UTF-8; seit 1.6.4, C-089): ``\\``, ``\"`` und
    ``\\a \\b \\f \\n \\r \\t \\v``, andere ASCII-Steuerzeichen oktal (``\\001``), nicht druckbare Zeichen als
    ``\\uxxxx``/``\\Uxxxxxxxx``, ungültige Bytes (als Ersatzzeichen U+DC80 … U+DCFF) als ``\\xNN``; ``$`` bleibt."""
    from ._wctype import iswprint
    out = ['"']
    for ch in s:
        e = _DEP_ESC.get(ch)
        if e is not None:
            out.append(e)
            continue
        k = ord(ch)
        if 0xDC80 <= k <= 0xDCFF:       # Byte aus surrogateescape (ungültiges UTF-8)
            out.append("\\x%02x" % (k - 0xDC00))
        elif k < 0x80:
            out.append(ch if 0x20 <= k < 0x7F else "\\%03o" % k)
        elif iswprint(k):
            out.append(ch)
        else:
            out.append("\\U%08x" % k if k > 0xFFFF else "\\u%04x" % k)
    out.append('"')
    return "".join(out)


def r_deparse(x: Any) -> str:
    """``paste(deparse(x), collapse = "")`` für einfache Werte (Zahlen, Text, Wahrheitswerte, Vektoren)."""
    def one(v, all_na=False):
        if v is None:
            return "NA"
        if isinstance(v, str):   # seit 1.6.4 wie R mit Steuerzeichen (C-089)
            return r_deparse_str(v)
        if isinstance(v, (bool, np.bool_)):
            return "TRUE" if v else "FALSE"
        if isinstance(v, (_dt.date, np.datetime64)):
            return '"%s"' % _as_str(v)
        if isinstance(v, (int, np.integer)) and abs(int(v)) < 2 ** 31:   # wie R-integer (Entscheidung 63, C-090)
            return str(int(v))
        if _is_num(v):
            f = _flt(v)
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
    if not isinstance(x, (dict, list, tuple, np.ndarray)):
        x = _rp_vals([x], "r_deparse")[0]
        if _is_day(x):                    # seit 1.6.4 wie R (RP, C-049): structure(<Tage>, class = "Date")
            return 'structure(%s, class = "Date")' % one(NA_REAL if _day_na(x) else float(_date_days(x)), True)
    if isinstance(x, dict):
        if not x:
            return "list()"
        return "list(" + ", ".join("%s = %s" % (k, r_deparse(v)) for k, v in x.items()) + ")"
    if isinstance(x, (list, tuple, np.ndarray)):
        vals = list(x)
        if not vals:
            if isinstance(x, (list, tuple)):
                return "NULL"
            # seit 1.6.5 (CR2-C-11): leeres Feld nach Elementtyp wie R (bis 1.6.4 immer "numeric(0)")
            k = x.dtype.kind
            if k == "M":
                return 'structure(numeric(0), class = "Date")'
            return {"b": "logical(0)", "i": "integer(0)", "u": "integer(0)", "U": "character(0)", "S": "character(0)",
                    "O": "character(0)"}.get(k, "numeric(0)")
        if any(isinstance(v, (list, tuple, dict)) for v in vals):
            return "list(" + ", ".join(r_deparse(v) for v in vals) + ")"
        vals = _rp_vals(vals, "r_deparse")
        # seit 1.6.4 wie R (RP, C-049): Datumsvektor als structure(c(<Tage>), class = "Date"); mit Text wie c() alles
        # als Text (bis 1.6.3 Datum als Text in Anführungszeichen, Zahlen neben Text ohne Anführungszeichen)
        if all(v is None or _is_day(v) for v in vals) and any(v is not None for v in vals):
            d = [NA_REAL if v is None or _day_na(v) else float(_date_days(v)) for v in vals]
            dna = all(r_isna(t) for t in d)
            inner = one(d[0], dna) if len(d) == 1 else "c(" + ", ".join(one(t, dna) for t in d) + ")"
            return 'structure(%s, class = "Date")' % inner
        if any(isinstance(v, str) for v in vals) and not any(isinstance(v, (_dt.date, np.datetime64)) for v in vals):
            vals = [v if v is None or isinstance(v, str) else _as_str(v) for v in vals]
        all_na = all(_is_num(v) and r_isna(float(v)) for v in vals)
        if len(vals) == 1:
            return one(vals[0], all_na)
        return "c(" + ", ".join(one(v, all_na) for v in vals) + ")"
    return one(x, True)


def _is_day(v) -> bool:
    """Datum ohne Uhrzeit (date, datetime64[D] oder NaT)."""
    if isinstance(v, np.datetime64):
        return np.isnat(v) or np.datetime_data(v.dtype)[0] == "D"
    return isinstance(v, _dt.date) and not isinstance(v, _dt.datetime)


def _day_na(v) -> bool:
    return isinstance(v, np.datetime64) and bool(np.isnat(v))


_NA_INT = _fmt._NA_INT


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
        if isinstance(v, np.datetime64) and np.isnat(v):   # NaT wie bis 1.6.3 (eigener Befund)
            return (5, float((_dt.date.fromisoformat(s) - _dt.date(1970, 1, 1)).days), [s])
        return (5, float(_date_days(v)), [s])   # seit 1.6.4 ohne date.fromisoformat (C-005)
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
