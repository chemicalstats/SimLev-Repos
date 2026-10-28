"""R-kompatible Textausgabe und Rundung (Engine).

Gegenstück zu ``julia/src/r/rformat.jl``. Nachbildungen von R-Funktionen,
deren Ergebnis in Ausgaben oder Rechnungen sichtbar wird: ``round()``
(``nmath/fround.c``), ``signif()`` (``fprec.c``),
``format()``/``as.character()``/``deparse()`` für Zahlen
(``formatReal``/``scientific`` aus ``main/format.c``) und ``sprintf()`` mit
R-Verhalten für ``NA``/``NaN``/``Inf``. Baut nur auf :mod:`simlev._r.rnum`
auf; die volle Formatierung (``format``, ``formatC``, ``print``) steht in
:mod:`simlev._r.fmt`.
"""
from __future__ import annotations

import datetime as _dt
import math
import re
from typing import Any, Sequence

import numpy as np

from .rnum import LD, NA_REAL, r_isna, r_pow

__all__ = ["r_round", "r_signif", "r_format", "r_format1", "r_as_character", "r_deparse", "r_sprintf"]


def _ffloor(x: float) -> float:
    return float(np.floor(x))


def _fceil(x: float) -> float:
    return float(np.ceil(x))


def _r_pow_di(x: float, n: int) -> float:
    """``R_pow_di``: x hoch ganzzahliges n durch wiederholtes Quadrieren."""
    xn = 1.0
    if math.isnan(x):
        return x
    if n != 0:
        if not math.isfinite(x):
            return r_pow(x, float(n))
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


_M_LOG10_2 = 0.301029995663981195213738894724


def r_round(x: float, digits: float = 0.0) -> float:
    """``round(x, digits)`` wie R >= 4.0.0 (``nmath/fround.c``)."""
    x = float(x)
    digits = float(digits)
    max10e = 308
    if math.isnan(x) or math.isnan(digits):
        return x + digits
    if not math.isfinite(x):
        return x
    if digits > 308 + 15 or x == 0.0:
        return x
    if digits < -max10e:
        return 0.0
    if digits == 0.0:
        return float(np.rint(x))
    dig = int(_ffloor(digits + 0.5))
    sgn = 1.0
    if x < 0.0:
        sgn = -1.0
        x = -x
    logb = math.frexp(x)[1] - 1
    l10x = _M_LOG10_2 * (0.5 + logb)
    if l10x + dig > 15:
        return sgn * x
    if dig <= max10e:
        pow10 = _r_pow_di(10.0, dig)
        x10 = x * pow10
        i10 = _ffloor(x10)
        xd = i10 / pow10
        xu = _fceil(x10) / pow10
    else:
        e10 = dig - max10e
        p10 = _r_pow_di(10.0, e10)
        pow10 = _r_pow_di(10.0, max10e)
        x10 = (x * pow10) * p10
        i10 = _ffloor(x10)
        xd = i10 / pow10 / p10
        xu = _fceil(x10) / pow10 / p10
    du = xu - x
    dd = x - xd
    return sgn * (xu if (du < dd or (math.fmod(i10, 2.0) == 1 and du == dd)) else xd)


def r_signif(x: float, digits: float = 6) -> float:
    """``signif(x, digits)`` wie R (``nmath/fprec.c``)."""
    x = float(x)
    max10e = 308
    if math.isnan(x) or math.isnan(digits):
        return x + digits
    if not math.isfinite(x):
        return x
    if not math.isfinite(digits):
        if digits > 0:
            return x
        digits = 1.0
    if x == 0:
        return x
    dig = int(round(digits))
    if dig > 22:
        return x
    if dig < 1:
        dig = 1
    sgn = 1.0
    if x < 0.0:
        sgn = -sgn
        x = -x
    l10 = math.log10(x)
    e10 = int(dig - 1 - _ffloor(l10))
    if abs(l10) < max10e - 2:
        p10 = 1.0
        if e10 > max10e:
            p10 = _r_pow_di(10.0, e10 - max10e)
            e10 = max10e
        if e10 > 0:
            pow10 = _r_pow_di(10.0, e10)
            return sgn * (float(np.rint((x * pow10) * p10)) / pow10) / p10
        pow10 = _r_pow_di(10.0, -e10)
        return sgn * (float(np.rint(x / pow10)) * pow10)
    do_round = max10e - l10 >= _r_pow_di(10.0, -dig)
    e2 = dig + (1 if e10 > 0 else -1) * 22
    p10 = _r_pow_di(10.0, e2)
    x *= p10
    P10 = _r_pow_di(10.0, e10 - e2)
    x *= P10
    if do_round:
        x += 0.5
    x = _ffloor(x) / p10
    return sgn * x / P10


# ═══════════════════════════════════════════════════════════════════════════
# Zahlenformatierung wie R (format.c, printutils.c)
# ═══════════════════════════════════════════════════════════════════════════

_TBL = [LD("1e%d" % k) for k in range(28)]
_KP_MAX = 27


def _scientific(x: float, digits: int):
    """``scientific()`` aus R's format.c: (neg, kpower, nsig, roundingwidens)."""
    if x == 0.0:
        return 0, 0, 1, False
    if x < 0.0:
        neg, r = 1, -x
    else:
        neg, r = 0, x
    if digits >= 16:
        s = "%#.*e" % (digits - 1, r)
        mant, ex = s.split("e")
        kpower = int(ex)
        digs = mant.replace(".", "")
        i = digits
        while i >= 2 and digs[i - 1] == "0":
            i -= 1
        return neg, kpower, i, False
    kp = int(math.floor(math.log10(r))) - digits + 1
    r_prec = LD(r)
    if abs(kp) <= _KP_MAX:
        if kp > 0:
            r_prec = r_prec / _TBL[kp]
        elif kp < 0:
            r_prec = r_prec * _TBL[-kp]
    else:
        r_prec = r_prec / np.power(LD(10.0), LD(kp))
    if r_prec < _TBL[digits - 1]:
        r_prec = r_prec * LD(10.0)
        kp -= 1
    alpha = float(np.rint(r_prec))
    nsig = digits
    for _ in range(1, digits + 1):
        alpha /= 10.0
        if alpha == math.floor(alpha):
            nsig -= 1
        else:
            break
    if nsig == 0 and digits > 0:
        nsig = 1
        kp += 1
    kpower = kp + digits - 1
    rgt = digits - kpower
    rgt = 0 if rgt < 0 else (_KP_MAX if rgt > _KP_MAX else rgt)
    fuzz = 0.5 / float(_TBL[rgt])
    rw = 0 < kpower <= _KP_MAX and LD(r) < _TBL[kpower] - LD(fuzz)
    return neg, kpower, nsig, bool(rw)


def _format_real(xs: Sequence[float], digits: int = 7, nsmall: int = 0, scipen: int = 0):
    """``formatReal()``: gemeinsame Breite w, Nachkommastellen d, Exponentformat e."""
    naflag = nanflag = posinf = neginf = False
    neg = 0
    mnl = 10 ** 9
    mxl = rgt = mxsl = mxns = -10 ** 9
    for x in xs:
        if not math.isfinite(x):
            if math.isnan(x):
                if r_isna(x):
                    naflag = True
                else:
                    nanflag = True
            elif x > 0:
                posinf = True
            else:
                neginf = True
            continue
        neg_i, kpower, nsig, rw = _scientific(x, digits)
        left = kpower + 1
        if rw:
            left -= 1
        sleft = neg_i + (1 if left <= 0 else left)
        right = nsig - left
        if neg_i:
            neg = 1
        rgt = max(rgt, right)
        mxl = max(mxl, left)
        mnl = min(mnl, left)
        mxsl = max(mxsl, sleft)
        mxns = max(mxns, nsig)
    if digits == 0:
        rgt = 0
    if mxl < 0:
        mxsl = 1 + neg
    if rgt < 0:
        rgt = 0
    wF = mxsl + rgt + (1 if rgt != 0 else 0)
    e = 2 if (mxl > 100 or mnl <= -99) else 1
    if mxns != -10 ** 9:
        d = mxns - 1
        w = neg + (1 if d > 0 else 0) + d + 4 + e
        if wF <= w + scipen:
            e = 0
            if nsmall > rgt:
                rgt = nsmall
                wF = mxsl + rgt + (1 if rgt != 0 else 0)
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


def _encode_real(x: float, w: int, d: int, e: int, na: str = "NA", drop0: bool = False) -> str:
    if x == 0.0:
        x = 0.0
    if not math.isfinite(x):
        s = (na if r_isna(x) else "NaN") if math.isnan(x) else ("Inf" if x > 0 else "-Inf")
        return s.rjust(w)
    if e:
        s = ("%#*.*e" % (w, d, x)) if d else ("%*.*e" % (w, d, x))
    else:
        s = "%*.*f" % (w, d, x)
    if drop0 and "." in s:
        m = re.match(r"^(.*?\.)(\d*)(.*)$", s)
        head, digs, tail = m.group(1), m.group(2), m.group(3)
        digs = digs.rstrip("0")
        s = (head + digs if digs else head[:-1]) + tail
    return s


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


_SPEC = re.compile(r"%(?P<flags>[-+ #0]*)(?P<width>\*|\d+)?(?:\.(?P<prec>\*|\d+))?(?P<conv>[diouxXeEfFgGaAcs%])")


def r_sprintf(fmt: str, *args: Any) -> str:
    """``sprintf(fmt, ...)`` mit R-Verhalten für Skalare.

    Zahlen werden wie in R behandelt: ``NA``/``NaN``/``Inf`` in Gleitkomma-Formaten
    als Text (gleiche Breite), ganze Doubles in ``%d``, Zahlen in ``%s`` über
    ``as.character()``; Datumswerte in ``%s`` als JJJJ-MM-TT.
    """
    out = []
    pos = 0
    ai = 0
    for m in _SPEC.finditer(fmt):
        out.append(fmt[pos:m.start()])
        pos = m.end()
        conv = m.group("conv")
        if conv == "%":
            out.append("%")
            continue
        flags = m.group("flags") or ""
        width = m.group("width")
        prec = m.group("prec")
        if width == "*":
            width = str(int(args[ai]))
            ai += 1
        if prec == "*":
            prec = str(int(args[ai]))
            ai += 1
        v = args[ai]
        ai += 1
        spec = "%" + flags + (width or "") + ("." + prec if prec is not None else "")
        if conv in "eEfFgGaA":
            if v is None or (_is_num(v) and not math.isfinite(float(v))):
                if v is None or math.isnan(float(v)):
                    s = "NA" if (v is None or r_isna(float(v))) else "NaN"
                    s = " " + s if " " in flags else s
                elif float(v) > 0:
                    s = "+Inf" if "+" in flags else (" Inf" if " " in flags else "Inf")
                else:
                    s = "-Inf"
                out.append(("%" + flags.replace("0", "").replace("+", "").replace(" ", "")
                            + (width or "") + "s") % s)
            else:
                out.append((spec + conv) % float(v))
        elif conv in "dioxX":
            if v is None or (isinstance(v, float) and math.isnan(v)):
                out.append(("%" + flags.replace("0", "") + (width or "") + "s") % "NA")
            elif isinstance(v, (bool, np.bool_)):
                out.append((spec + conv) % int(v))
            else:
                fv = float(v)
                if fv != int(fv):
                    raise ValueError("invalid format '%s'; use format %%f, %%e, %%g or %%a for numeric objects"
                                     % (spec + conv))
                out.append((spec + conv) % int(fv))
        elif conv == "s":
            out.append((spec + "s") % _as_str(v))
        else:
            out.append((spec + conv) % v)
    out.append(fmt[pos:])
    return "".join(out)
