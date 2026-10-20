"""Ausdrücke in R-Syntax als Text auswerten (wie ``eval(parse(text = s), data, env)``).

Gemeinsamer Auswerter für Bedingungen als Text in
:func:`simlev.bootstrap_probability`, :func:`simlev.regime_subset`,
:func:`simlev.view_prob`/:func:`simlev.entropy_pooling` und
:func:`simlev.tactical_rules`; 1:1-Übersetzung von ``julia/src/r/rexpr.jl``.

Zerlegen wie R 4.3 (``src/main/gram.y``): derselbe Lexer (Zahlen,
Zeichenketten mit Escapes, ``%op%``, Rohzeichenketten, Kommentare,
kontextabhängige Zeilenenden einschließlich ``if … \\n else`` in Klammern) und
dieselbe Grammatik mit R's Vorrang (niedrig → hoch)::

    ?  <  = (rechts)  <  <- (rechts)  <  ->  <  ~  <  | ||  <  & &&
    <  einstelliges !  <  Vergleiche (nicht assoziativ)  <  + -  <  * /
    <  %% %/% %in% |>  <  :  <  einstelliges - +  <  ^ (rechts)
    <  $ @  <  ::  <  Aufruf f(…), Indizierung x[…], x[[…]]

Syntaxfehler mit R's Meldung (``<text>:Zeile:Spalte: unexpected …`` samt
Kontextzeilen und ``^``), Fehler des Lexers wie
``'\\q' is an unrecognized escape … (<input>:1:4)``.

Werte sind intern Vektoren wie in R (Listen-Unterklassen ``LGL``, ``INT``,
``NUM``, ``CHR``, ``DAT``; NA als ``None`` bzw. ``NA_REAL``, NULL als leerer
logischer Vektor); alle Operationen elementweise mit Recycling und
dreiwertiger NA-Logik, Ganzzahlarithmetik mit Überlauf → NA und Warnung,
Zahlen wie R (``^`` über ``R_POW``, ``%%``/``%/%`` wie ``myfmod``/``myfloor``,
Literale und ``as.numeric`` über R_strtod mit long double, Summen/Mittel über
:mod:`simlev._r.base`, ``median``, ``var``, ``sd``, ``quantile`` über
:mod:`simlev._r.stats`, Funktionen über :mod:`simlev._r.libm`),
Zeichenkettenvergleiche über :func:`simlev._r.stats.str_collate` (ICU wie R).

Ergebnis von :func:`eval_r`: logisch → ``ndarray`` (``object``: ``True``,
``False``, ``None``), ganzzahlig → ``int64`` (mit NA: ``float64`` und
``nan``), numerisch → ``float64`` (NA = ``nan``, NaN = ``fmt.R_NAN``),
Zeichen → ``ndarray`` (``object``, NA = ``None``), Datum →
``datetime64[D]``.
"""
from __future__ import annotations

import datetime as _dt
import inspect
import math
import struct
import threading
import unicodedata
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import base as _base
from . import fmt as _fmt
from . import libm as _libm
from . import stats as _stats

__all__ = ["parse_r", "eval_r", "r_strtod", "from_python", "to_python", "as_numeric", "as_logical"]

LD = np.longdouble
_IMAX = 2147483647
NA_REAL = _fmt.NA_REAL
_DEFAULT_NAN = struct.unpack("<d", struct.pack("<Q", 0xFFF8000000000000))[0]
_EPOCH = _dt.date(1970, 1, 1)
_EPOCH_ORD = _EPOCH.toordinal()


class LGL(list):
    """Logischer Vektor (``True``, ``False``, ``None`` = NA)."""


class INT(list):
    """Ganzzahliger Vektor (``int`` im Wertebereich von R, ``None`` = NA)."""


class NUM(list):
    """Numerischer Vektor (``float``; NA = ``NA_REAL``, NaN = andere NaN)."""


class CHR(list):
    """Zeichenvektor (``str``, ``None`` = NA)."""


class DAT(list):
    """Datumsvektor (Tage seit 1970-01-01, ``None`` = NA)."""


def _warn(msg):
    warnings.warn(msg, UserWarning, stacklevel=2)


class RError(ValueError):
    """Fehler mit R's Meldungstext."""


def _error(msg):
    raise RError(msg)


def _bits(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def _d(b):
    return struct.unpack("<d", struct.pack("<Q", b))[0]


def isna_strict(x):
    """True für R's NA_real_ (NaN mit Nutzlast 1954), False für andere NaN."""
    return x != x and (_bits(x) & 0xFFFFFFFF) == 1954


def _isnan(x):
    return x != x


# ═══════════════════════════════════════════════════════════════════════════
# R_strtod (arithmetic.c/util.c, R_strtod5 mit NA = FALSE, long double)
# ═══════════════════════════════════════════════════════════════════════════

def _isdig(c):
    return "0" <= c <= "9"


def _isspace_c(c):
    return c in " \t\n\v\f\r"


def r_strtod(cs, i0=0):
    """R's ``R_strtod`` auf den Zeichen von ``cs`` ab Index ``i0`` (0-basiert).

    Rückgabe ``(Wert, Endindex)``; bei ungültiger Eingabe ``(NA, i0)``.
    """
    n = len(cs)

    def at(k):
        return cs[k] if k < n else "\0"

    p = i0
    while _isspace_c(at(p)):
        p += 1
    sign = 1.0
    if at(p) == "-":
        sign = -1.0
        p += 1
    elif at(p) == "+":
        p += 1

    def low(k, m):
        return "".join(cs[k:min(n, k + m)]).lower()

    if low(p, 3) == "nan":
        return (math.nan, p + 3)
    if low(p, 8) == "infinity":
        return (sign * math.inf, p + 8)
    if low(p, 3) == "inf":
        return (sign * math.inf, p + 3)
    ans = LD(0.0)
    expn = 0
    if n - p > 2 and at(p) == "0" and at(p + 1) in "xX":
        exph = -1
        p += 2
        while True:
            c = at(p)
            if _isdig(c):
                ans = LD(16.0) * ans + LD(float(ord(c) - 48))
            elif "a" <= c <= "f":
                ans = LD(16.0) * ans + LD(float(ord(c) - 97 + 10))
            elif "A" <= c <= "F":
                ans = LD(16.0) * ans + LD(float(ord(c) - 65 + 10))
            elif c == ".":
                exph = 0
                p += 1
                continue
            else:
                break
            if exph >= 0:
                exph += 4
            p += 1
        if at(p) in "pP" and at(p) != "\0":
            expsign = 1
            p += 1
            if at(p) == "-":
                expsign = -1
                p += 1
            elif at(p) == "+":
                p += 1
            m = 0
            while _isdig(at(p)):
                m = m * 10 + (ord(at(p)) - 48) if m < 9999 else m
                p += 1
            if ans != LD(0.0):
                expn += expsign * m
                p2 = LD(2.0)
                if exph > 0:
                    if expn - exph < -122:
                        fac = LD(1.0)
                        k = exph
                        while k != 0:
                            if k & 1:
                                fac *= p2
                            k >>= 1
                            p2 *= p2
                        ans /= fac
                        p2 = LD(2.0)
                    else:
                        expn -= exph
                fac = LD(1.0)
                k = abs(expn)
                while k != 0:
                    if k & 1:
                        fac *= p2
                    k >>= 1
                    p2 *= p2
                ans = ans / fac if expn < 0 else ans * fac
        return (sign * float(ans), p)
    nd = 0
    while _isdig(at(p)):
        ans = LD(10.0) * ans + LD(float(ord(at(p)) - 48))
        p += 1
        nd += 1
    if at(p) == ".":
        p += 1
        while _isdig(at(p)):
            ans = LD(10.0) * ans + LD(float(ord(at(p)) - 48))
            p += 1
            nd += 1
            expn -= 1
    if nd == 0:
        return (NA_REAL, i0)
    if at(p) in "eE" and at(p) != "\0":
        expsign = 1
        p += 1
        if at(p) == "-":
            expsign = -1
            p += 1
        elif at(p) == "+":
            p += 1
        m = 0
        while _isdig(at(p)):
            m = m * 10 + (ord(at(p)) - 48) if m < 9999 else m
            p += 1
        expn += expsign * m
    if expn + nd < -300:
        for _ in range(nd):
            ans /= LD(10.0)
        expn += nd
    p10 = LD(10.0)
    fac = LD(1.0)
    with np.errstate(all="ignore"):
        if expn < -307:
            k = -expn
            while k != 0:
                if k & 1:
                    fac /= p10
                k >>= 1
                p10 *= p10
            ans *= fac
        elif expn < 0:
            k = -expn
            while k != 0:
                if k & 1:
                    fac *= p10
                k >>= 1
                p10 *= p10
            ans /= fac
        elif ans != LD(0.0):
            k = expn
            while k != 0:
                if k & 1:
                    fac *= p10
                k >>= 1
                p10 *= p10
            ans *= fac
        v = float(ans)
    if v > 1.7976931348623157e308:
        return (math.inf if sign > 0 else -math.inf, p)
    return (sign * v, p)


def _isblank_str(cs, i):
    return all(_isspace_c(c) for c in cs[i:])


def _str2num(s):
    """``String_to_real``: (Wert, ungültig?) – leere Zeichenkette und NA ohne Warnung."""
    if s is None:
        return (NA_REAL, False)
    cs = list(s)
    if _isblank_str(cs, 0):
        return (NA_REAL, False)
    v, e = r_strtod(cs, 0)
    if _isblank_str(cs, e):
        return (v, False)
    return (NA_REAL, True)


# ═══════════════════════════════════════════════════════════════════════════
# Lexer (gram.y: xxgetc, token, yylex)
# ═══════════════════════════════════════════════════════════════════════════

class Tok:
    __slots__ = ("kind", "val", "line", "col")

    def __init__(self, kind, val, line, col):
        self.kind = kind
        self.val = val
        self.line = line
        self.col = col


class Lexer:
    def __init__(self, s):
        self.cs = list(s)
        self.pos = 0
        self.line = 1
        self.col = 0
        self.hist = []
        self.ctxline = 1
        self.cstack = [" "]
        self.eat = False
        self.saved = None
        self.warns = []


_EOF = "\0"


def _getc(L):
    if L.pos >= len(L.cs):
        L.hist.append((L.line, L.col, 0))
        return _EOF
    c = L.cs[L.pos]
    L.pos += 1
    L.hist.append((L.line, L.col, 1))
    if c == "\n":
        L.line += 1
        L.col = 0
    else:
        L.col += 1
    if c == "\t":
        L.col = (L.col + 7) & ~7
    L.ctxline = L.line
    return c


def _ungetc(L):
    l, c, k = L.hist.pop()
    L.line = l
    L.col = c
    L.ctxline = l
    L.pos -= k


def _nextchar(L, e):
    c = _getc(L)
    if c == e:
        return True
    _ungetc(L)
    return False


def _nbytes(ch):
    return len(ch.encode("utf-8", "surrogateescape"))


def _ctx_lines(L):
    """Kontextzeilen der Fehlermeldung (source.c: getParseContext, tabExpand)."""
    s = "".join(L.cs[:L.pos])
    nb = len(s.encode("utf-8", "surrogateescape"))
    if nb > 256:
        tot = 0
        k = len(s)
        while k > 0 and tot + _nbytes(s[k - 1]) <= 256:
            tot += _nbytes(s[k - 1])
            k -= 1
        s = s[k:]
    lines = s.split("\n") if s else []
    cl = L.ctxline
    if lines and lines[-1] == "":
        lines.pop()
        cl -= 1
    out = []
    for ln in lines:
        b = []
        w = 0
        for ch in ln:
            if w >= 192:
                break
            if ch == "\t":
                while True:
                    b.append(" ")
                    w += 1
                    if (w & 7) == 0:
                        break
            else:
                b.append(ch)
                w += _nbytes(ch)
        out.append("".join(b))
    return out, cl


def _parse_errmsg(L, line, col, msg):
    lines, cl = _ctx_lines(L)
    head = "<text>:%d:%d: %s" % (line, col, msg)
    if not lines:
        return head
    if len(lines) == 1:
        w = len("%d: " % cl)
        return head + "\n%d: " % cl + lines[0] + "\n" + "^".rjust(w + col + 1)
    w = len("%d:" % cl)
    return head + "\n%d: " % (cl - 1) + lines[-2] + "\n%d: " % cl + lines[-1] + "\n" + "^".rjust(w + col + 1)


def _lexerr(L, msg):
    _error("%s (<input>:%d:%d)" % (msg, L.line, L.col))


_TOKNAME = {
    "END": "end of input", "ERROR": "input", "STR": "string constant", "NUM": "numeric constant",
    "SYMBOL": "symbol", "LEFT_ASSIGN": "assignment", "NL": "end of line", "NULL": "'NULL'",
    "FUNCTION": "'function'", "EQ_ASSIGN": "'='", "RIGHT_ASSIGN": "'->'", "LBB": "'[['",
    "FOR": "'for'", "IN": "'in'", "IF": "'if'", "ELSE": "'else'", "WHILE": "'while'",
    "NEXT": "'next'", "BREAK": "'break'", "REPEAT": "'repeat'", "GT": "'>'", "GE": "'>='",
    "LT": "'<'", "LE": "'<='", "EQ": "'=='", "NE": "'!='", "AND": "'&'", "OR": "'|'",
    "AND2": "'&&'", "OR2": "'||'", "NS_GET": "'::'", "NS_GET_INT": "':::'", "PIPE": "'|>'",
    "PIPEBIND": "'=>'", "PLACEHOLDER": "input", "INCOMPLETE_STRING": "INCOMPLETE_STRING",
    "SPECIAL": "SPECIAL", "SEMI": "';'", "COMMA": "','", "LPAREN": "'('", "RPAREN": "')'",
    "LBRACKET": "'['", "RBRACKET": "']'", "LBRACE": "'{'", "RBRACE": "'}'", "PLUS": "'+'",
    "MINUS": "'-'", "STAR": "'*'", "SLASH": "'/'", "CARET": "'^'", "TILDE": "'~'",
    "QUESTION": "'?'", "BANG": "'!'", "COLON": "':'", "DOLLAR": "'$'", "AT": "'@'",
    "BACKSLASH": "'\\\\'", "UNDEF": "input"}

_KEYWORDS = {"NULL": "NULL", "NA": "NUM", "TRUE": "NUM", "FALSE": "NUM", "Inf": "NUM", "NaN": "NUM",
             "NA_integer_": "NUM", "NA_real_": "NUM", "NA_character_": "NUM", "NA_complex_": "NUM",
             "function": "FUNCTION", "while": "WHILE", "repeat": "REPEAT", "for": "FOR", "if": "IF",
             "in": "IN", "else": "ELSE", "next": "NEXT", "break": "BREAK"}


def _kwvalue(s):
    if s == "NA":
        return LGL([None])
    if s == "TRUE":
        return LGL([True])
    if s == "FALSE":
        return LGL([False])
    if s == "Inf":
        return NUM([math.inf])
    if s == "NaN":
        return NUM([math.nan])
    if s == "NA_integer_":
        return INT([None])
    if s == "NA_real_":
        return NUM([NA_REAL])
    if s == "NA_character_":
        return CHR([None])
    return "complex"


def _isblank_u(c):
    return c in "  　" or (" " <= c <= " ") or (" " <= c <= " ")


def _isletter(c):
    return unicodedata.category(c).startswith("L")


def _isalpha_u(c):
    return _isletter(c)


def _isalnum_u(c):
    return _isletter(c) or _isdig(c) or (c >= "\x80" and unicodedata.category(c) == "Nd")


def _skipspace(L):
    while True:
        c = _getc(L)
        if c in " \t\f":
            continue
        if c == "\n" or c == _EOF:
            return c
        if c < "\x80":
            return c
        if not _isblank_u(c):
            return c


def _skipcomment(L):
    c = "#"
    while c != "\n" and c != _EOF:
        c = _getc(L)
    return c


def _numeric(L, c, fl, fc):
    buf = [c]
    seendot = 1 if c == "." else 0
    seenexp = False
    last = c
    nd = 0
    asnum = False
    count = 1

    def err():
        return Tok("ERROR", None, fl, fc)

    while True:
        c = _getc(L)
        if not (_isdig(c) or c in ".eExXL") or c == _EOF:
            break
        count += 1
        if c == "L":
            buf.append(c)
            break
        if c in "xX":
            if count > 2 or last != "0":
                break
            buf.append(c)
            while True:
                c = _getc(L)
                if not (_isdig(c) or ("a" <= c <= "f") or ("A" <= c <= "F") or c == "."):
                    break
                if c == ".":
                    if seendot != 0:
                        return err()
                    seendot = 1
                buf.append(c)
                nd += 1
            if nd == 0:
                return err()
            if c in "pP" and c != _EOF:
                seenexp = True
                buf.append(c)
                c = _getc(L)
                if not _isdig(c) and c != "+" and c != "-":
                    return err()
                if c == "+" or c == "-":
                    buf.append(c)
                    c = _getc(L)
                nd = 0
                while _isdig(c):
                    buf.append(c)
                    c = _getc(L)
                    nd += 1
                if nd == 0:
                    return err()
            if seendot != 0 and not seenexp:
                return err()
            if c == "L":
                buf.append(c)
            break
        if c in "eE":
            if seenexp:
                break
            seenexp = True
            seendot = seendot if seendot == 1 else 2
            buf.append(c)
            c = _getc(L)
            if not _isdig(c) and c != "+" and c != "-":
                return err()
            if c == "+" or c == "-":
                buf.append(c)
                c = _getc(L)
                if not _isdig(c):
                    return err()
        if c == ".":
            if seendot != 0:
                break
            seendot = 1
        buf.append(c)
        last = c
    if c == "i":
        buf.append(c)
    txt = "".join(buf)
    if c == "L":
        a = r_strtod(buf, 0)[0]
        b = math.trunc(a) if (math.isfinite(a) and -2.147483649e9 < a < 2.147483648e9) else -2.147483648e9
        if a != b:
            if seendot == 1 and not seenexp:
                L.warns.append("integer literal %s contains decimal; using numeric value" % txt)
            else:
                L.warns.append("non-integer value %s qualified with L; using numeric value" % txt)
            asnum = True
            seenexp = True
    if c == "i":
        return Tok("NUM", "complex", fl, fc)
    if c == "L" and not asnum:
        if seendot == 1 and not seenexp:
            L.warns.append("integer literal %s contains unnecessary decimal point" % txt)
        a = r_strtod(buf, 0)[0]
        return Tok("NUM", INT([int(math.trunc(a))]), fl, fc)
    if c != "L":
        _ungetc(L)
    return Tok("NUM", NUM([r_strtod(buf, 0)[0]]), fl, fc)


def _hexval(c):
    if _isdig(c):
        return ord(c) - 48
    if "A" <= c <= "F":
        return ord(c) - 65 + 10
    if "a" <= c <= "f":
        return ord(c) - 97 + 10
    return -1


_SIMPLE_ESC = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\",
               '"': '"', "'": "'", "`": "`", " ": " ", "\n": "\n"}


def _string(L, quote, forsym, fl, fc):
    buf = bytearray()
    oct_or_hex = False
    use_wcs = False
    c = quote
    while True:
        c = _getc(L)
        if c == _EOF or c == quote:
            break
        if c == "\n":
            _ungetc(L)
            c = "\\"
        if c == "\\":
            c = _getc(L)
            if "0" <= c <= "7":
                octal = ord(c) - 48
                c = _getc(L)
                if "0" <= c <= "7":
                    octal = 8 * octal + ord(c) - 48
                    c = _getc(L)
                    if "0" <= c <= "7":
                        octal = 8 * octal + ord(c) - 48
                    else:
                        _ungetc(L)
                else:
                    _ungetc(L)
                if octal == 0:
                    _lexerr(L, "nul character not allowed")
                if octal > 0xFF:
                    _lexerr(L, "\\%o exceeds maximum allowed octal value \\377" % octal)
                buf.append(octal)
                oct_or_hex = True
                continue
            elif c == "x":
                val = 0
                for i in range(2):
                    c = _getc(L)
                    ext = _hexval(c)
                    if ext < 0:
                        _ungetc(L)
                        if i == 0:
                            _lexerr(L, "'\\x' used without hex digits in character string")
                        break
                    val = 16 * val + ext
                if val == 0:
                    _lexerr(L, "nul character not allowed")
                buf.append(val)
                oct_or_hex = True
                continue
            elif c == "u" or c == "U":
                big = c == "U"
                if forsym:
                    _lexerr(L, "\\Uxxxxxxxx sequences not supported inside backticks" if big else
                            "\\uxxxx sequences not supported inside backticks")
                delim = False
                c = _getc(L)
                if c == "{":
                    delim = True
                else:
                    _ungetc(L)
                val = 0
                for i in range(8 if big else 4):
                    c = _getc(L)
                    ext = _hexval(c)
                    if ext < 0:
                        _ungetc(L)
                        if i == 0:
                            _lexerr(L, "'\\U' used without hex digits in character string" if big else
                                    "'\\u' used without hex digits in character string")
                        break
                    val = 16 * val + ext
                if delim:
                    c = _getc(L)
                    if c != "}":
                        if big:
                            _lexerr(L, "invalid \\U{xxxxxxxx} sequence")
                        _error("invalid \\u{xxxx} sequence (line %d)" % L.line)
                if val == 0:
                    _lexerr(L, "nul character not allowed")
                if big and val > 0x10FFFF:
                    _lexerr(L, ("invalid \\U{xxxxxxxx} value %6x" if delim else "invalid \\Uxxxxxxxx value %6x") % val)
                buf.extend(chr(val).encode("utf-8", "surrogatepass"))
                use_wcs = True
                continue
            else:
                e = _SIMPLE_ESC.get(c)
                if e is None:
                    _lexerr(L, "'\\%s' is an unrecognized escape in character string" % c)
                buf.extend(e.encode("utf-8"))
                continue
        buf.extend(c.encode("utf-8", "surrogateescape"))
    if c == _EOF:
        return Tok("INCOMPLETE_STRING", None, fl, fc)
    s = bytes(buf).decode("utf-8", "surrogateescape")
    if forsym:
        return Tok("SYMBOL", s, fl, fc)
    if use_wcs and oct_or_hex:
        _lexerr(L, "mixing Unicode and octal/hex escapes in a string is not allowed")
    return Tok("STR", s, fl, fc)


def _rawstring(L, quote, fl, fc):
    ndash = 0
    c = _getc(L)
    while c == "-":
        ndash += 1
        c = _getc(L)
    close = {"(": ")", "[": "]", "{": "}"}.get(c, "\0")
    if close == "\0":
        _lexerr(L, "malformed raw string literal")
    buf = []
    while True:
        c = _getc(L)
        if c == _EOF:
            return Tok("INCOMPLETE_STRING", None, fl, fc)
        if c == close:
            k = 0
            hist = [c]
            while k < ndash:
                d = _getc(L)
                if d == _EOF:
                    return Tok("INCOMPLETE_STRING", None, fl, fc)
                hist.append(d)
                if d != "-":
                    break
                k += 1
            if k == ndash:
                d = _getc(L)
                if d == quote:
                    return Tok("STR", "".join(buf), fl, fc)
                if d == _EOF:
                    return Tok("INCOMPLETE_STRING", None, fl, fc)
                hist.append(d)
            buf.extend(hist[:-1])
            _ungetc(L)
            continue
        buf.append(c)


def _special(L, fl, fc):
    buf = ["%"]
    c = "%"
    while True:
        c = _getc(L)
        if c == _EOF or c == "%":
            break
        if c == "\n":
            _ungetc(L)
            return Tok("ERROR", None, fl, fc)
        buf.append(c)
    if c == "%":
        buf.append(c)
    return Tok("SPECIAL", "".join(buf), fl, fc)


def _symbol(L, c, fl, fc):
    buf = [c]
    while True:
        c = _getc(L)
        if c == _EOF:
            break
        if not (c == "." or c == "_" or _isalnum_u(c)):
            break
        buf.append(c)
    _ungetc(L)
    s = "".join(buf)
    kw = _KEYWORDS.get(s)
    if kw == "NUM":
        return Tok("NUM", _kwvalue(s), fl, fc)
    if kw is not None:
        return Tok(kw, s, fl, fc)
    return Tok("SYMBOL", s, fl, fc)


_SIMPLE_TOK = {"{": "LBRACE", "}": "RBRACE", "(": "LPAREN", ")": "RPAREN", "]": "RBRACKET", "?": "QUESTION",
               "+": "PLUS", "/": "SLASH", "^": "CARET", "~": "TILDE", "$": "DOLLAR", "@": "AT",
               "\\": "BACKSLASH", "\n": "NL", ";": "SEMI", ",": "COMMA"}


def _token(L):
    if L.saved is not None:
        t = L.saved
        L.saved = None
        return t
    c = _skipspace(L)
    if c == "#":
        c = _skipcomment(L)
    fl, fc = L.line, L.col
    if c == _EOF:
        return Tok("END", None, fl, fc)

    def T(k, v=None):
        return Tok(k, v, fl, fc)

    if c == ".":
        d = _getc(L)
        _ungetc(L)
        if not _isdig(d):
            return _symbol(L, c, fl, fc)
        return _numeric(L, c, fl, fc)
    if _isdig(c):
        return _numeric(L, c, fl, fc)
    if c == "r" or c == "R":
        if _nextchar(L, '"'):
            return _rawstring(L, '"', fl, fc)
        if _nextchar(L, "'"):
            return _rawstring(L, "'", fl, fc)
    if c == '"' or c == "'":
        return _string(L, c, False, fl, fc)
    if c == "%":
        return _special(L, fl, fc)
    if c == "`":
        return _string(L, c, True, fl, fc)
    if c == "_":
        return T("PLACEHOLDER")
    if _isalpha_u(c):
        return _symbol(L, c, fl, fc)
    if c == "<":
        if _nextchar(L, "="):
            return T("LE")
        if _nextchar(L, "-"):
            return T("LEFT_ASSIGN", "<-")
        if _nextchar(L, "<"):
            if _nextchar(L, "-"):
                return T("LEFT_ASSIGN", "<<-")
            return T("ERROR")
        return T("LT")
    if c == "-":
        if _nextchar(L, ">"):
            if _nextchar(L, ">"):
                return T("RIGHT_ASSIGN", "<<-")
            return T("RIGHT_ASSIGN", "<-")
        return T("MINUS")
    if c == ">":
        if _nextchar(L, "="):
            return T("GE")
        return T("GT")
    if c == "!":
        if _nextchar(L, "="):
            return T("NE")
        return T("BANG")
    if c == "=":
        if _nextchar(L, "="):
            return T("EQ")
        if _nextchar(L, ">"):
            return T("PIPEBIND")
        return T("EQ_ASSIGN")
    if c == ":":
        if _nextchar(L, ":"):
            if _nextchar(L, ":"):
                return T("NS_GET_INT")
            return T("NS_GET")
        if _nextchar(L, "="):
            return T("LEFT_ASSIGN", ":=")
        return T("COLON")
    if c == "&":
        if _nextchar(L, "&"):
            return T("AND2")
        return T("AND")
    if c == "|":
        if _nextchar(L, "|"):
            return T("OR2")
        if _nextchar(L, ">"):
            return T("PIPE")
        return T("OR")
    if c == "[":
        if _nextchar(L, "["):
            return T("LBB")
        return T("LBRACKET")
    if c == "*":
        if _nextchar(L, "*"):
            return T("CARET")
        return T("STAR")
    k = _SIMPLE_TOK.get(c)
    if k is not None:
        return T(k)
    return T("UNDEF")


def _ctop(L):
    return L.cstack[-1] if L.cstack else " "


def _cpop(L):
    if L.cstack:
        L.cstack.pop()


def _ifpop(L):
    if _ctop(L) == "i":
        L.cstack.pop()


def _ifpush(L):
    if _ctop(L) in "{[(i":
        L.cstack.append("i")


_EATS = {"PLUS", "MINUS", "STAR", "SLASH", "CARET", "LT", "LE", "GE", "GT", "EQ", "NE", "OR", "AND", "OR2",
         "AND2", "PIPE", "PIPEBIND", "SPECIAL", "FUNCTION", "WHILE", "REPEAT", "FOR", "IN", "QUESTION",
         "BANG", "EQ_ASSIGN", "COLON", "TILDE", "DOLLAR", "AT", "LEFT_ASSIGN", "RIGHT_ASSIGN"}
_NOEAT = {"SYMBOL", "PLACEHOLDER", "STR", "NUM", "NULL", "NEXT", "BREAK"}


def _yylex(L):
    while True:
        tok = _token(L)
        if tok.kind == "NL":
            if L.eat or _ctop(L) == "[" or _ctop(L) == "(":
                continue
            if _ctop(L) == "i":
                while tok.kind == "NL":
                    tok = _token(L)
                if tok.kind in ("RBRACE", "RPAREN", "RBRACKET"):
                    while _ctop(L) == "i":
                        _ifpop(L)
                    _cpop(L)
                    return tok
                if tok.kind == "COMMA":
                    _ifpop(L)
                    return tok
                if tok.kind == "ELSE":
                    L.eat = True
                    _ifpop(L)
                    return tok
                _ifpop(L)
                L.saved = tok
                return Tok("NL", None, tok.line, tok.col)
            return tok
        k = tok.kind
        if k in _EATS:
            L.eat = True
        elif k == "IF":
            _ifpush(L)
            L.eat = True
        elif k == "ELSE":
            _ifpop(L)
            L.eat = True
        elif k == "SEMI" or k == "COMMA":
            _ifpop(L)
        elif k in _NOEAT:
            L.eat = False
        elif k == "LBB":
            L.cstack.append("[")
            L.cstack.append("[")
        elif k == "LBRACKET":
            L.cstack.append("[")
        elif k == "LBRACE":
            L.cstack.append("{")
            L.eat = True
        elif k == "LPAREN":
            L.cstack.append("(")
        elif k == "RBRACKET" or k == "RPAREN":
            while _ctop(L) == "i":
                _ifpop(L)
            _cpop(L)
            L.eat = False
        elif k == "RBRACE":
            while _ctop(L) == "i":
                _ifpop(L)
            _cpop(L)
        return tok


# ═══════════════════════════════════════════════════════════════════════════
# Parser (Vorrangklettern mit R's Grammatik)
# ═══════════════════════════════════════════════════════════════════════════

class Node:
    """Knoten des Syntaxbaums: ``const`` (val = R-Wert), ``sym`` (Name), ``call``
    (val = Funktionsname), ``callx`` (val = Ausdruck der Funktion), ``empty``,
    ``placeholder``."""
    __slots__ = ("head", "val", "args", "names", "line", "col")

    def __init__(self, head, val, args=None, names=None, line=0, col=0):
        self.head = head
        self.val = val
        self.args = args if args is not None else []
        self.names = names if names is not None else []
        self.line = line
        self.col = col


def _mkcall(f, args, line=0, col=0):
    return Node("call", f, list(args), [None] * len(args), line, col)


_EMPTY = Node("empty", None)
#: NULL (eindeutiges Objekt; leerer logischer Vektor)
_NULLV = LGL()


class Parser:
    def __init__(self, L):
        self.L = L
        self.la = None


def _peek(P):
    if P.la is None:
        P.la = _yylex(P.L)
    return P.la


def _next(P):
    t = _peek(P)
    P.la = None
    return t


def _synerr(P, t):
    _error(_parse_errmsg(P.L, t.line, t.col, "unexpected " + _TOKNAME[t.kind]))


_BINOP = {"QUESTION": (1, "left"), "LEFT_ASSIGN": (5, "right"), "EQ_ASSIGN": (6, "right"),
          "RIGHT_ASSIGN": (7, "left"), "TILDE": (8, "left"), "OR": (9, "left"), "OR2": (9, "left"),
          "AND": (10, "left"), "AND2": (10, "left"), "GT": (12, "non"), "GE": (12, "non"), "LT": (12, "non"),
          "LE": (12, "non"), "EQ": (12, "non"), "NE": (12, "non"), "PLUS": (13, "left"), "MINUS": (13, "left"),
          "STAR": (14, "left"), "SLASH": (14, "left"), "SPECIAL": (15, "left"), "PIPE": (15, "left"),
          "PIPEBIND": (16, "left"), "COLON": (17, "left"), "CARET": (19, "right"), "DOLLAR": (20, "left"),
          "AT": (20, "left")}
_OPNAME = {"QUESTION": "?", "EQ_ASSIGN": "=", "TILDE": "~", "OR": "|", "OR2": "||", "AND": "&", "AND2": "&&",
           "GT": ">", "GE": ">=", "LT": "<", "LE": "<=", "EQ": "==", "NE": "!=", "PLUS": "+", "MINUS": "-",
           "STAR": "*", "SLASH": "/", "COLON": ":", "CARET": "^", "DOLLAR": "$", "AT": "@"}
_CMPK = {"GT", "GE", "LT", "LE", "EQ", "NE"}
_CMP = ("<", ">", "<=", ">=", "==", "!=")

#: Symbole mit R's IS_SPECIAL_SYMBOL (names.c) – nicht als rechte Seite von |>
_SPECIAL_SYMS = {"if", "while", "repeat", "for", "break", "next", "return", "function", "(", "{",
                 "+", "-", "*", "/", "^", "%%", "%/%", "%*%", ":", "==", "!=", "<", ">", "<=", ">=", "&", "|", "&&",
                 "||", "!", "<-", "<<-", "=", "$", "[", "[[", "$<-", "[<-", "[[<-"}


def _expr(P, minbp, ctx, first=None):
    t0 = _next(P) if first is None else first
    lhs = _primary(P, t0)
    while True:
        t = _peek(P)
        k = t.kind
        if k in ("LPAREN", "LBRACKET", "LBB"):
            _next(P)
            lhs = _postfix(P, lhs, t)
            continue
        info = _BINOP.get(k)
        if info is None:
            break
        bp, assoc = info
        if not bp > minbp:
            break
        if k == "EQ_ASSIGN" and ctx != "assign":
            break
        if k == "QUESTION" and ctx == "expr":
            break
        _next(P)
        if k == "DOLLAR" or k == "AT":
            r = _next(P)
            if r.kind not in ("SYMBOL", "STR"):
                _synerr(P, r)
            lhs = _mkcall(_OPNAME[k], [lhs, Node("sym", r.val) if r.kind == "SYMBOL" else Node("const", CHR([r.val]))],
                          t.line, t.col)
            continue
        if k == "PIPEBIND":
            _error("'=>' is disabled; set '_R_USE_PIPEBIND_' envvar to a true value to enable it (<input>:%d:%d)"
                   % (t.line, t.col))
        rctx = "assign" if k == "EQ_ASSIGN" else (ctx if k == "QUESTION" else "expr")
        rbp = bp - 1 if assoc == "right" else bp
        r1 = _peek(P)
        rhs = _expr(P, rbp, rctx)
        if k == "LEFT_ASSIGN":
            lhs = _mkcall(t.val, [lhs, rhs], t.line, t.col)
        elif k == "RIGHT_ASSIGN":
            lhs = _mkcall(t.val, [rhs, lhs], t.line, t.col)
        elif k == "SPECIAL":
            lhs = _mkcall(t.val, [lhs, rhs], t.line, t.col)
        elif k == "PIPE":
            lhs = _pipe(lhs, rhs, r1)
        else:
            lhs = _mkcall(_OPNAME[k], [lhs, rhs], t.line, t.col)
        if k in _CMPK:
            t2 = _peek(P)
            if t2.kind in _CMPK:
                _synerr(P, t2)
    return lhs


def _pipe(lhs, rhs, r1):
    loc = "(<input>:%d:%d)" % (r1.line, r1.col)
    if rhs.head not in ("call", "callx"):
        _error("The pipe operator requires a function call as RHS " + loc)
    ph = [i for i, a in enumerate(rhs.args) if a.head == "placeholder"]
    if ph:
        if len(ph) > 1:
            _error("pipe placeholder may only appear once " + loc)
        i = ph[0]
        if rhs.names[i] is None:
            _error("pipe placeholder can only be used as a named argument " + loc)
        args = list(rhs.args)
        args[i] = lhs
        return Node(rhs.head, rhs.val, args, list(rhs.names), rhs.line, rhs.col)
    if rhs.head == "call" and rhs.val in _SPECIAL_SYMS:
        _error("function '%s' not supported in RHS call of a pipe %s" % (rhs.val, loc))
    if rhs.head == "callx" and rhs.val.head == "call" and rhs.val.val == "function":
        _error("function 'function' not supported in RHS call of a pipe " + loc)
    return Node(rhs.head, rhs.val, [lhs] + list(rhs.args), [None] + list(rhs.names), rhs.line, rhs.col)


def _expect(P, k):
    t = _next(P)
    if t.kind != k:
        _synerr(P, t)
    return t


def _primary(P, t):
    k = t.kind
    if k == "NUM":
        return Node("const", t.val, line=t.line, col=t.col)
    if k == "STR" or k == "SYMBOL":
        n = _peek(P)
        if n.kind in ("NS_GET", "NS_GET_INT"):
            _next(P)
            r = _next(P)
            if r.kind not in ("SYMBOL", "STR"):
                _synerr(P, r)
            return _mkcall("::" if n.kind == "NS_GET" else ":::", [Node("sym", t.val), Node("sym", r.val)],
                           t.line, t.col)
        if k == "STR":
            return Node("const", CHR([t.val]), line=t.line, col=t.col)
        return Node("sym", t.val, line=t.line, col=t.col)
    if k == "NULL":
        return Node("const", _NULLV, line=t.line, col=t.col)
    if k == "PLACEHOLDER":
        return Node("placeholder", None, line=t.line, col=t.col)
    if k == "LBRACE":
        items = []
        while True:
            n = _peek(P)
            if n.kind == "RBRACE":
                _next(P)
                break
            if n.kind in ("SEMI", "NL"):
                _next(P)
                continue
            items.append(_expr(P, 0, "assign"))
            n = _peek(P)
            if n.kind not in ("SEMI", "NL", "RBRACE"):
                _synerr(P, n)
        P.L.eat = False
        return _mkcall("{", items, t.line, t.col)
    if k == "LPAREN":
        e = _expr(P, 0, "assign")
        _expect(P, "RPAREN")
        return _mkcall("(", [e], t.line, t.col)
    if k in ("MINUS", "PLUS"):
        return _mkcall("-" if k == "MINUS" else "+", [_expr(P, 18, "expr")], t.line, t.col)
    if k == "BANG":
        return _mkcall("!", [_expr(P, 11, "expr")], t.line, t.col)
    if k == "TILDE":
        return _mkcall("~", [_expr(P, 8, "expr")], t.line, t.col)
    if k == "QUESTION":
        return _mkcall("?", [_expr(P, 1, "assign")], t.line, t.col)
    if k in ("FUNCTION", "BACKSLASH"):
        _expect(P, "LPAREN")
        formals = []
        defs = []
        if _peek(P).kind != "RPAREN":
            while True:
                s = _next(P)
                if s.kind != "SYMBOL":
                    _synerr(P, s)
                formals.append(s.val)
                if _peek(P).kind == "EQ_ASSIGN":
                    _next(P)
                    defs.append(_expr(P, 0, "help"))
                else:
                    defs.append(_EMPTY)
                n = _peek(P)
                if n.kind == "COMMA":
                    _next(P)
                    continue
                if n.kind == "RPAREN":
                    break
                _synerr(P, n)
        _expect(P, "RPAREN")
        P.L.eat = True
        body = _expr(P, 2, "assign")
        return Node("call", "function", [body] + defs, [None] + formals, t.line, t.col)
    if k == "IF":
        _expect(P, "LPAREN")
        cond = _expr(P, 0, "help")
        _expect(P, "RPAREN")
        P.L.eat = True
        yes = _expr(P, 2, "assign")
        if _peek(P).kind == "ELSE":
            _next(P)
            no = _expr(P, 4, "assign")
            return _mkcall("if", [cond, yes, no], t.line, t.col)
        return _mkcall("if", [cond, yes], t.line, t.col)
    if k == "FOR":
        _expect(P, "LPAREN")
        s = _expect(P, "SYMBOL")
        _expect(P, "IN")
        seq = _expr(P, 0, "help")
        _expect(P, "RPAREN")
        P.L.eat = True
        body = _expr(P, 2, "assign")
        return _mkcall("for", [Node("sym", s.val), seq, body], t.line, t.col)
    if k == "WHILE":
        _expect(P, "LPAREN")
        cond = _expr(P, 0, "help")
        _expect(P, "RPAREN")
        P.L.eat = True
        body = _expr(P, 2, "assign")
        return _mkcall("while", [cond, body], t.line, t.col)
    if k == "REPEAT":
        return _mkcall("repeat", [_expr(P, 2, "assign")], t.line, t.col)
    if k in ("NEXT", "BREAK"):
        return _mkcall(t.val, [], t.line, t.col)
    _synerr(P, t)


def _sublist(P, closer):
    args = []
    nms = []
    while True:
        t = _peek(P)
        if t.kind == "COMMA" or t.kind == closer:
            args.append(_EMPTY)
            nms.append(None)
        elif t.kind in ("SYMBOL", "STR", "NULL"):
            _next(P)
            if _peek(P).kind == "EQ_ASSIGN":
                _next(P)
                nm = "NULL" if t.kind == "NULL" else t.val
                t3 = _peek(P)
                if t3.kind == "COMMA" or t3.kind == closer:
                    args.append(_EMPTY)
                else:
                    args.append(_expr(P, 0, "help"))
                nms.append(nm)
            else:
                args.append(_expr(P, 0, "help", t))
                nms.append(None)
        else:
            args.append(_expr(P, 0, "help"))
            nms.append(None)
        t = _next(P)
        if t.kind == "COMMA":
            continue
        if t.kind == closer:
            break
        _synerr(P, t)
    return args, nms


def _postfix(P, lhs, t):
    if t.kind == "LPAREN":
        args, nms = _sublist(P, "RPAREN")
        if len(args) == 1 and args[0].head == "empty" and nms[0] is None:
            args, nms = [], []
        if lhs.head == "sym":
            return Node("call", lhs.val, args, nms, lhs.line, lhs.col)
        if lhs.head == "const" and isinstance(lhs.val, CHR) and len(lhs.val) == 1 and lhs.val[0] is not None:
            return Node("call", lhs.val[0], args, nms, lhs.line, lhs.col)
        return Node("callx", lhs, args, nms, lhs.line, lhs.col)
    args, nms = _sublist(P, "RBRACKET")
    if t.kind == "LBB":
        _expect(P, "RBRACKET")
    return Node("call", "[[" if t.kind == "LBB" else "[", [lhs] + args, [None] + nms, t.line, t.col)


def _has_placeholder(e):
    if e.head == "placeholder":
        return True
    if e.head == "callx" and _has_placeholder(e.val):
        return True
    return any(_has_placeholder(a) for a in e.args)


def _parse_all(s):
    L = Lexer(s + "\n")
    P = Parser(L)
    exprs = []
    while True:
        L.cstack = [" "]
        L.saved = None
        L.eat = False
        P.la = None
        t = _peek(P)
        if t.kind == "END":
            break
        if t.kind == "NL":
            _next(P)
            continue
        e = _expr(P, 0, "assign")
        t = _next(P)
        if t.kind not in ("NL", "SEMI"):
            _synerr(P, t)
        if _has_placeholder(e):
            _error("invalid use of pipe placeholder (<input>:%d:%d)" % (L.line - 1 if t.kind == "NL" else L.line, L.col))
        exprs.append(e)
    return exprs, L.warns


_CACHE = {}
_CACHE_LOCK = threading.Lock()


def parse_r(s):
    """Text in R-Syntax zerlegen wie ``parse(text = s)``.

    Mehrere Elemente einer Liste/eines Arrays werden zeilenweise verbunden.
    Syntaxfehler → :class:`RError` (``ValueError``) mit R's Meldung;
    Warnungen des Lexers (z. B. zu ``1.5L``) bei jedem Aufruf. Ergebnisse
    werden zwischengespeichert.
    """
    if not isinstance(s, str):
        s = "\n".join(str(x) for x in s)
    with _CACHE_LOCK:
        hit = _CACHE.get(s)
    if hit is None:
        hit = _parse_all(s)
        with _CACHE_LOCK:
            _CACHE[s] = hit
    exprs, warns = hit
    for w in warns:
        _warn(w)
    return exprs


# ═══════════════════════════════════════════════════════════════════════════
# Werte und Umwandlungen
# ═══════════════════════════════════════════════════════════════════════════

def _int_ok(x):
    return -_IMAX <= x <= _IMAX


def _f2na(x):
    """Python-Konvention → R: ``nan`` ist NA, ``fmt.R_NAN`` ist NaN."""
    x = float(x)
    if x != x and not _fmt._is_rnan(x):
        return NA_REAL
    return x


def _day_of(x):
    if x is None or x is pd.NaT:
        return None
    if isinstance(x, np.datetime64):
        if np.isnat(x):
            return None
        return int(x.astype("datetime64[D]").astype(np.int64))
    if isinstance(x, pd.Timestamp):
        return x.date().toordinal() - _EPOCH_ORD
    if isinstance(x, _dt.datetime):
        return x.date().toordinal() - _EPOCH_ORD
    if isinstance(x, _dt.date):
        return x.toordinal() - _EPOCH_ORD
    return None


def _is_na_obj(x):
    return x is None or x is pd.NA or x is pd.NaT


def _nanlike(x):
    return x is None or x is pd.NA or x is pd.NaT or (isinstance(x, (float, np.floating)) and x != x)


def _from_seq(v):
    v = list(v)
    nonna = [x for x in v if not _nanlike(x)]
    isnum = [isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_)) for x in nonna]
    if not nonna:
        if any(isinstance(x, (float, np.floating)) for x in v):
            return NUM([_f2na(x) if isinstance(x, (float, np.floating)) else NA_REAL for x in v])
        return LGL([None for _ in v])
    if all(isinstance(x, (bool, np.bool_)) for x in nonna):
        return LGL([None if _nanlike(x) else bool(x) for x in v])
    if all(isnum) and all(isinstance(x, (int, np.integer)) for x in nonna):
        if all(_int_ok(int(x)) for x in nonna):
            return INT([None if _nanlike(x) else int(x) for x in v])
        return NUM([NA_REAL if _nanlike(x) and not isinstance(x, (float, np.floating)) else _f2na(x) for x in v])
    if all(isnum):
        return NUM([NA_REAL if (x is None or x is pd.NA or x is pd.NaT) else _f2na(x) for x in v])
    if all(isinstance(x, str) for x in nonna):
        return CHR([None if _nanlike(x) else str(x) for x in v])
    if all(isinstance(x, (_dt.date, np.datetime64, pd.Timestamp)) for x in nonna):
        return DAT([None if _nanlike(x) else _day_of(x) for x in v])
    return None


def from_python(v):
    """Python-Wert → R-Vektor (``None``, wenn der Wert keine Daten sind)."""
    if isinstance(v, (LGL, INT, NUM, CHR, DAT)):
        return v
    if v is None:
        return _NULLV
    if v is pd.NA or v is pd.NaT:
        return LGL([None])
    if isinstance(v, (bool, np.bool_)):
        return LGL([bool(v)])
    if isinstance(v, (int, np.integer)):
        return INT([int(v)]) if _int_ok(int(v)) else NUM([float(v)])
    if isinstance(v, (float, np.floating)):
        return NUM([_f2na(v)])
    if isinstance(v, str):
        return CHR([v])
    if isinstance(v, (_dt.date, np.datetime64, pd.Timestamp)):
        return DAT([_day_of(v)])
    if isinstance(v, pd.Categorical):
        return CHR([None if _is_na_obj(x) or (isinstance(x, float) and x != x) else str(x)
                    for x in np.asarray(v, dtype=object)])
    if isinstance(v, (pd.Series, pd.Index)):
        if isinstance(v.dtype, pd.CategoricalDtype):
            return from_python(pd.Categorical(v))
        if v.dtype.kind == "M":
            return from_python(np.asarray(v.to_numpy(), dtype="datetime64[ns]").astype("datetime64[D]"))
        if v.dtype.kind in "biuf":
            return from_python(v.to_numpy())
        return from_python(v.to_numpy(dtype=object))
    if isinstance(v, tuple):
        v = list(v)
    if isinstance(v, list):
        return _from_seq(v)
    if isinstance(v, np.ndarray):
        a = v.ravel(order="F")
        k = a.dtype.kind
        if k == "b":
            return LGL([bool(x) for x in a.tolist()])
        if k in "iu":
            xs = a.tolist()
            if all(_int_ok(x) for x in xs):
                return INT(xs)
            return NUM([float(x) for x in xs])
        if k == "f":
            return NUM([_f2na(x) for x in a.tolist()])
        if k == "M":
            d = a.astype("datetime64[D]")
            return DAT([None if np.isnat(x) else int(x.astype(np.int64)) for x in d])
        if k in "US":
            return CHR([str(x) for x in a.tolist()])
        if k == "O":
            return _from_seq(a.tolist())
        return None
    return None


def to_python(v):
    """R-Vektor → natürliche Python-Form (numpy-Array)."""
    if isinstance(v, LGL):
        if any(x is None for x in v):
            a = np.empty(len(v), dtype=object)
            a[:] = list(v)
            return a
        return np.array(list(v), dtype=bool)
    if isinstance(v, INT):
        if any(x is None for x in v):
            return np.array([NA_REAL if x is None else float(x) for x in v], dtype=np.float64)
        return np.array(list(v), dtype=np.int64)
    if isinstance(v, NUM):
        return np.array([_fmt.R_NAN if (x != x and not isna_strict(x)) else x for x in v], dtype=np.float64)
    if isinstance(v, CHR):
        a = np.empty(len(v), dtype=object)
        a[:] = list(v)
        return a
    if isinstance(v, DAT):
        return np.array([np.datetime64("NaT", "D") if x is None else np.datetime64(int(x), "D") for x in v],
                        dtype="datetime64[D]")
    return v


def _as_lgl(v):
    if isinstance(v, LGL):
        return v
    if isinstance(v, INT):
        return LGL([None if x is None else x != 0 for x in v])
    if isinstance(v, NUM):
        return LGL([None if x != x else x != 0 for x in v])
    if isinstance(v, CHR):
        return LGL([_lgl_str(x) for x in v])
    return LGL([None if x is None else x != 0 for x in v])


def _lgl_str(x):
    if x is None:
        return None
    if x in ("TRUE", "true", "T", "True"):
        return True
    if x in ("FALSE", "false", "F", "False"):
        return False
    return None


def _as_num(v):
    if isinstance(v, NUM):
        return v
    if isinstance(v, (LGL, INT, DAT)):
        return NUM([NA_REAL if x is None else float(x) for x in v])
    bad = False
    out = NUM()
    for x in v:
        r, b = _str2num(x)
        bad = bad or b
        out.append(r)
    if bad:
        _warn("NAs introduced by coercion")
    return out


def _dbl2int(x, flag):
    if x != x:
        return None
    if x >= 2147483648.0 or x <= -2147483648.0:
        flag[0] = True
        return None
    return int(math.trunc(x))


def _as_int(v):
    if isinstance(v, INT):
        return v
    if isinstance(v, LGL):
        return INT([None if x is None else int(x) for x in v])
    if isinstance(v, NUM):
        f = [False]
        out = INT([_dbl2int(x, f) for x in v])
        if f[0]:
            _warn("NAs introduced by coercion to integer range")
        return out
    if isinstance(v, CHR):
        fna = False
        f = [False]
        out = INT()
        for s in v:
            x, b = _str2num(s)
            fna = fna or b
            out.append(_dbl2int(x, f))
        if fna:
            _warn("NAs introduced by coercion")
        if f[0]:
            _warn("NAs introduced by coercion to integer range")
        return out
    return _as_int(_as_num(v))


def _as_chr(v):
    if isinstance(v, CHR):
        return v
    if isinstance(v, NUM):
        if not v:
            return CHR()
        a = np.array([_fmt.R_NAN if (x != x and not isna_strict(x)) else x for x in v], dtype=np.float64)
        r = _fmt.as_character(a)
        if not isinstance(r, np.ndarray):
            r = [r]
        return CHR([None if x is None else str(x) for x in r])
    if isinstance(v, INT):
        return CHR([None if x is None else "%d" % x for x in v])
    if isinstance(v, LGL):
        return CHR([None if x is None else ("TRUE" if x else "FALSE") for x in v])
    return CHR([None if x is None else _date_str(x) for x in v])


def _date_str(d):
    return _dt.date.fromordinal(d + _EPOCH_ORD).isoformat() if 1 <= d + _EPOCH_ORD <= 3652059 else \
        _fmt.format_date(np.array([d], dtype="datetime64[D]"))[0]


def _parse_date1(x):
    import re
    m = re.match(r"^(\d{1,4})-(\d{1,2})-(\d{1,2})$", x)
    if m is None:
        return None
    try:
        return _dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3))).toordinal() - _EPOCH_ORD
    except ValueError:
        return None


def _as_date(v):
    if isinstance(v, DAT):
        return v
    if isinstance(v, CHR):
        out = DAT()
        for x in v:
            if x is None:
                out.append(None)
                continue
            d = _parse_date1(x.strip())
            if d is None:
                d = _parse_date1(x.strip().replace("/", "-"))
                if d is None:
                    _error("character string is not in a standard unambiguous format")
            out.append(d)
        return out
    n = _as_num(v)
    return DAT([None if x != x else int(math.floor(x)) for x in n])


def _na_of(v):
    return NA_REAL if isinstance(v, NUM) else None


def _isna_el(x):
    return x is None or (isinstance(x, float) and x != x)


def _rtype(v):
    if isinstance(v, LGL):
        return 1
    if isinstance(v, INT):
        return 2
    if isinstance(v, CHR):
        return 4
    return 3


def _coerce(v, t):
    if t == 1:
        return _as_lgl(v)
    if t == 2:
        return _as_int(v)
    if t == 3:
        return _as_num(v)
    return _as_chr(v)


def _rclass(v):
    return {LGL: "logical", INT: "integer", NUM: "numeric", CHR: "character", DAT: "Date"}[type(v)]


def _rtypeof(v):
    return {LGL: "logical", INT: "integer", NUM: "double", CHR: "character", DAT: "double"}[type(v)]


def _like(v, items):
    return type(v)(items)


def _rec(v, i):
    return v[i % len(v)]


def _len2(a, b):
    na, nb = len(a), len(b)
    if na == 0 or nb == 0:
        return 0
    n = max(na, nb)
    if n % min(na, nb) != 0:
        _warn("longer object length is not a multiple of shorter object length")
    return n


def _scoll(a, b):
    f = getattr(_stats, "str_collate", None)
    if f is not None:
        return f(a, b)
    return -1 if a < b else (1 if a > b else 0)


# ═══════════════════════════════════════════════════════════════════════════
# Operatoren
# ═══════════════════════════════════════════════════════════════════════════

_LDBL_EPS = 1.0842021724855044e-19   # LDBL_EPSILON (c_eps in arithmetic.c)


def _qnan(x):
    """NaN beruhigen (Ruhe-Bit setzen) wie SSE2."""
    return _d(_bits(x) | 0x0008000000000000)


def _nanop(x, y):
    """NaN-Operanden wie SSE2 auf x86-64 (R): der erste NaN-Operand setzt sich durch."""
    if x != x:
        return _qnan(x)
    return _qnan(y)


def _fdiv(x, y):
    if x != x or y != y:
        return _nanop(x, y)
    if y == 0.0:
        if x == 0.0:
            return _DEFAULT_NAN
        neg = (math.copysign(1.0, x) < 0) != (math.copysign(1.0, y) < 0)
        return -math.inf if neg else math.inf
    return x / y


def _fmul(x, y):
    if x != x or y != y:
        return _nanop(x, y)
    if (math.isinf(x) and y == 0.0) or (math.isinf(y) and x == 0.0):
        return _DEFAULT_NAN
    return x * y


def _fadd(x, y):
    if x != x or y != y:
        return _nanop(x, y)
    return x + y


def _fsub(x, y):
    if x != x or y != y:
        return _nanop(x, y)
    return x - y


def _floor(x):
    return float(np.floor(x))


def r_fmod(x1, x2):
    """R's ``myfmod(x1, x2)`` (``x1 %% x2``)."""
    if x2 == 0.0:
        return _DEFAULT_NAN
    if abs(x2) * _LDBL_EPS > 1 and math.isfinite(x1) and abs(x1) <= abs(x2):
        if abs(x1) == abs(x2):
            return 0.0
        return x1 + x2 if ((x1 < 0 and x2 > 0) or (x2 < 0 and x1 > 0)) else x1
    q = _fdiv(x1, x2)
    if math.isfinite(q) and abs(q) * _LDBL_EPS > 1:
        _warn("probable complete loss of accuracy in modulus")
    # NaN-Operanden: x87 liefert die NaN mit der größeren Mantisse, NA schlägt also NaN
    if x1 != x1 or x2 != x2:
        return NA_REAL if (isna_strict(x1) or isna_strict(x2)) else _DEFAULT_NAN
    with np.errstate(all="ignore"):
        tmp = LD(x1) - LD(_floor(q)) * LD(x2)
        return float(tmp - np.floor(tmp / LD(x2)) * LD(x2))


def r_idiv(x1, x2):
    """R's ``myfloor(x1, x2)`` (``x1 %/% x2``)."""
    q = _fdiv(x1, x2)
    if x2 == 0.0 or abs(q) * _LDBL_EPS > 1 or not math.isfinite(q):
        return q
    if abs(q) < 1:
        if q < 0:
            return -1.0
        return -1.0 if ((x1 < 0 and x2 > 0) or (x1 > 0 and x2 < 0)) else 0.0
    with np.errstate(all="ignore"):
        tmp = LD(x1) - LD(_floor(q)) * LD(x2)
        return float(LD(_floor(q)) + np.floor(tmp / LD(x2)))


def _iop(op, x, y, of):
    if op == "%%":
        if x is None or y is None or y == 0:
            return None
        return x % y if (x >= 0 and y > 0) else int(r_fmod(float(x), float(y)))
    if op == "%/%":
        if x is None or y is None or y == 0:
            return None
        return int(math.floor(float(x) / float(y)))
    if x is None or y is None:
        return None
    z = x + y if op == "+" else (x - y if op == "-" else x * y)
    if not _int_ok(z):
        of[0] = True
        return None
    return z


def _pow(x, y):
    if x != x or y != y:
        if y == 2.0:
            return _nanop(x, x)
        if x == 1.0 or y == 0.0:
            return 1.0
        return _nanop(x, y)
    return _base.r_pow(x, y)


def _arith(op, a, b):
    if isinstance(a, DAT) or isinstance(b, DAT):
        return _date_arith(op, a, b)
    if isinstance(a, CHR) or isinstance(b, CHR):
        _error("non-numeric argument to binary operator")
    isint = isinstance(a, (LGL, INT)) and isinstance(b, (LGL, INT))
    if isint and op in ("+", "-", "*", "%%", "%/%"):
        A = _as_int(a)
        B = _as_int(b)
        n = _len2(A, B)
        of = [False]
        out = INT([_iop(op, _rec(A, i), _rec(B, i), of) for i in range(n)])
        if of[0]:
            _warn("NAs produced by integer overflow")
        return out
    if isint and op == "^":
        A = _as_int(a)
        B = _as_int(b)
        n = _len2(A, B)
        out = NUM()
        for i in range(n):
            x = _rec(A, i)
            y = _rec(B, i)
            if x == 1 or y == 0:
                out.append(1.0)
            elif x is None or y is None:
                out.append(NA_REAL)
            else:
                out.append(_base.r_pow(float(x), float(y)))
        return out
    A = _as_num(a)
    B = _as_num(b)
    n = _len2(A, B)
    f = {"+": _fadd, "-": _fsub, "*": _fmul, "/": _fdiv, "^": _pow, "%%": r_fmod, "%/%": r_idiv}[op]
    return NUM([f(_rec(A, i), _rec(B, i)) for i in range(n)])


def _date_arith(op, a, b):
    if op == "-" and isinstance(a, DAT) and isinstance(b, DAT):
        return _arith("-", _as_num(a), _as_num(b))
    if op not in ("+", "-"):
        _error('%s not defined for "Date" objects' % op)
    if isinstance(a, DAT) and isinstance(b, DAT):
        _error('binary + is not defined for "Date" objects')
    if isinstance(b, DAT) and op == "-":
        _error('can only subtract from "Date" objects')
    r = _arith(op, _as_num(a), _as_num(b))
    return DAT([None if x != x else int(math.floor(x)) for x in r])


def _cmpres(op, c):
    if op == "<":
        return c < 0
    if op == ">":
        return c > 0
    if op == "<=":
        return c <= 0
    if op == ">=":
        return c >= 0
    if op == "==":
        return c == 0
    return c != 0


def _compare(op, a, b):
    if isinstance(a, DAT) or isinstance(b, DAT):
        a = _as_date(a) if isinstance(a, CHR) else a
        b = _as_date(b) if isinstance(b, CHR) else b
        return _compare(op, _as_num(a), _as_num(b))
    n = _len2(a, b)
    r = LGL()
    if isinstance(a, CHR) or isinstance(b, CHR):
        A = _as_chr(a)
        B = _as_chr(b)
        for i in range(n):
            x = _rec(A, i)
            y = _rec(B, i)
            if x is None or y is None:
                r.append(None)
            elif op in ("==", "!="):
                r.append((x == y) == (op == "=="))
            elif x == y:
                r.append(op in ("<=", ">="))
            else:
                r.append(_cmpres(op, _scoll(x, y)))
        return r
    A = _as_num(a)
    B = _as_num(b)
    for i in range(n):
        x = _rec(A, i)
        y = _rec(B, i)
        if x != x or y != y:
            r.append(None)
        elif op == "<":
            r.append(x < y)
        elif op == ">":
            r.append(x > y)
        elif op == "<=":
            r.append(x <= y)
        elif op == ">=":
            r.append(x >= y)
        elif op == "==":
            r.append(x == y)
        else:
            r.append(x != y)
    return r


def _check_logic(v, op):
    if isinstance(v, CHR):
        _error("operations are possible only for numeric, logical or complex types")
    if isinstance(v, DAT):
        _error('%s not defined for "Date" objects' % op)
    return _as_lgl(v)


def _logic(op, a, b):
    if isinstance(a, DAT) or isinstance(b, DAT):
        _error('%s not defined for "Date" objects' % op)
    A = _check_logic(a, op)
    B = _check_logic(b, op)
    n = _len2(A, B)
    r = LGL()
    for i in range(n):
        x = _rec(A, i)
        y = _rec(B, i)
        if op == "&":
            r.append(False if (x is False or y is False) else (None if (x is None or y is None) else True))
        else:
            r.append(True if (x is True or y is True) else (None if (x is None or y is None) else False))
    return r


def _scalar_lgl(v, op, which="x"):
    if len(v) > 1:
        _error("'length = %d' in coercion to 'logical(1)'" % len(v))
    if v is _NULLV or isinstance(v, CHR):
        _error("invalid '%s' type in 'x %s y'" % (which, op))
    if len(v) == 0:
        return None
    return _as_lgl(v)[0]


def _match_eq(x, y):
    """match(x, table) wie R: NA trifft nur NA, NaN nur NaN, -0 == 0."""
    if x != x or y != y:
        return x != x and y != y and isna_strict(x) == isna_strict(y)
    return x == y


def _in(a, b):
    if isinstance(a, CHR) or isinstance(b, CHR):
        A = _as_chr(a)
        B = _as_chr(b)
        st = set(B)
        return LGL([x in st for x in A])
    A = _as_num(a)
    B = _as_num(b)
    return LGL([any(_match_eq(x, y) for y in B) for x in A])


def _asreal1(v):
    if isinstance(v, CHR):
        return _as_num(CHR([v[0]]))[0]
    return _as_num(v)[0]


def _colon(a, b):
    na, nb = len(a), len(b)
    if na != 1 or nb != 1:
        if na == 0 or nb == 0:
            _error("argument of length 0")
        _warn("numerical expression has %d elements: only the first used" % (na if na > 1 else nb))
    n1 = _asreal1(a)
    n2 = _asreal1(b)
    if n1 != n1 or n2 != n2:
        _error("NA/NaN argument")
    r = abs(n2 - n1)
    if r >= 4.503599627370496e15:
        _error("result would be too long a vector")

    def inr(v):
        return -2147483648.0 < v <= 2147483647.0

    if n1 == math.trunc(n1) and n2 == math.trunc(n2):
        lo, hi = int(n1), int(n2)
        if inr(n1) and inr(n2):
            return INT(range(lo, hi + 1) if lo <= hi else range(lo, hi - 1, -1))
        nn = int(r) + 1
        return NUM([n1 + i if n1 <= n2 else n1 - i for i in range(nn)])
    nn = int(math.floor(r + 1 + 1.1920928955078125e-07))
    useint = n1 <= 2147483647.0 and n1 == math.trunc(n1)
    if useint:
        if n1 <= -2147483648.0 or n1 > 2147483647.0:
            useint = False
        else:
            rr = n1 + ((nn - 1) if n1 <= n2 else -(nn - 1))
            if rr <= -2147483648.0 or rr > 2147483647.0:
                useint = False
    if useint:
        s = int(n1)
        return INT([s + i if n1 <= n2 else s - i for i in range(nn)])
    return NUM([n1 + i if n1 <= n2 else n1 - i for i in range(nn)])


def _not(v):
    if isinstance(v, CHR) or v is _NULLV:
        _error("invalid argument type")
    if isinstance(v, DAT):
        _error('unary ! not defined for "Date" objects')
    if isinstance(v, LGL):
        return LGL([None if x is None else not x for x in v])
    if isinstance(v, INT):
        return LGL([None if x is None else x == 0 for x in v])
    return LGL([None if x != x else x == 0 for x in v])


def _unary(op, v):
    if isinstance(v, CHR) or v is _NULLV:
        _error("invalid argument to unary operator")
    if isinstance(v, DAT):
        if op == "+":
            return v
        _error('unary - is not defined for "Date" objects')
    if isinstance(v, (LGL, INT)):
        x = _as_int(v)
        return INT([None if t is None else -t for t in x]) if op == "-" else x
    return NUM([-t for t in v]) if op == "-" else v


# ═══════════════════════════════════════════════════════════════════════════
# Indizierung (subscript.c)
# ═══════════════════════════════════════════════════════════════════════════

def _subscript(s, nx):
    """Index-Vektor (1-basiert, ``None`` = NA) für x[s] mit length(x) == nx."""
    if isinstance(s, LGL):
        ns = len(s)
        if ns == 0:
            return []
        nmax = max(ns, nx)
        out = []
        for i in range(nmax):
            v = s[i % ns]
            if v is None:
                out.append(None)
            elif v:
                out.append(i + 1)
        return out
    if isinstance(s, CHR):
        return [None for _ in s]
    if isinstance(s, INT):
        neg = False
        isna = False
        mx = 0
        for v in s:
            if v is None:
                isna = True
            elif v < 0:
                neg = True
            elif v > mx:
                mx = v
        if neg:
            if not (mx == 0 and not isna):
                _error("only 0's may be mixed with negative subscripts")
            keep = [True] * nx
            for v in s:
                if v is not None and v < 0 and -v <= nx:
                    keep[-v - 1] = False
            return [i + 1 for i in range(nx) if keep[i]]
        return [v for v in s if v is None or v != 0]
    d = _as_num(s)
    mn = 0.0
    mx = 0.0
    isna = False
    for v in d:
        if math.isfinite(v):
            if v < mn:
                mn = v
            if v > mx:
                mx = v
        else:
            isna = True
    if mn <= -1:
        if not (mx < 1 and not isna):
            _error("only 0's may be mixed with negative subscripts")
        keep = [True] * nx
        for v in d:
            if math.isfinite(v) and v <= -1 and -v < nx + 1.0:
                keep[int(math.trunc(-v)) - 1] = False
        return [i + 1 for i in range(nx) if keep[i]]
    out = []
    for v in d:
        if not math.isfinite(v):
            out.append(None)
        elif math.trunc(v) != 0:
            out.append(int(math.trunc(v)))
    return out


def _index(x, s):
    nx = len(x)
    idx = _subscript(s, nx)
    na = _na_of(x)
    return _like(x, [na if (i is None or i > nx) else x[i - 1] for i in idx])


def _index2(x, s):
    ls = len(s)
    if ls > 1:
        _error("attempt to select more than one element in vectorIndex")
    if ls < 1:
        _error("attempt to select less than one element in get1index")
    nx = len(x)
    indx = -1
    if isinstance(s, (LGL, INT)):
        i = None if s[0] is None else int(s[0])
        if i is not None:
            if i > 0:
                indx = i - 1
            elif i == 0 or nx < 2:
                _error("attempt to select less than one element in integerOneIndex")
            elif nx == 2 and i > -3:
                indx = 2 + i
            else:
                _error("attempt to select more than one element in integerOneIndex")
    elif isinstance(s, (NUM, DAT)):
        d = _as_num(s)[0]
        if d == d:
            if d >= 1:
                if math.isfinite(d):
                    indx = int(math.trunc(d - 1))
            elif d > -1 or nx < 2:
                _error("invalid negative subscript in get1index <real>" if d <= -1 else
                       "attempt to select less than one element in get1index <real>")
            elif nx == 2 and d > -3:
                indx = 2 + int(math.trunc(d))
            else:
                _error("invalid negative subscript in get1index <real>" if d <= -1 else
                       "attempt to select more than one element in get1index <real>")
    if indx < 0 or indx >= nx:
        _error("subscript out of bounds")
    return _like(x, [x[indx]])


# ═══════════════════════════════════════════════════════════════════════════
# Funktionen
# ═══════════════════════════════════════════════════════════════════════════

def _deparse(e):
    """Ausdruck → Text wie deparse (für Fehlermeldungen)."""
    if e.head == "empty":
        return ""
    if e.head == "placeholder":
        return "_"
    if e.head == "sym":
        return e.val
    if e.head == "const":
        v = e.val
        if len(v) == 0:
            return "NULL"
        x = v[0]
        if isinstance(v, LGL):
            return "NA" if x is None else ("TRUE" if x else "FALSE")
        if isinstance(v, INT):
            return "NA_integer_" if x is None else "%dL" % x
        if isinstance(v, CHR):
            return "NA_character_" if x is None else _jl_repr(x)
        if isinstance(v, NUM):
            if x != x:
                return "NA_real_" if isna_strict(x) else "NaN"
            return _as_chr(NUM([x]))[0]
        return "?"
    args = [("" if nm is None else nm + " = ") + _deparse(a) for a, nm in zip(e.args, e.names)]
    if e.head == "call":
        f = e.val
        if len(e.args) == 2 and (f in _CMP or f in ("+", "-", "*", "/", "&", "|", "&&", "||", "<-", "=", "~")
                                 or f.startswith("%")):
            return _deparse(e.args[0]) + " %s " % f + _deparse(e.args[1])
        if len(e.args) == 2 and f in ("^", ":", "$", "@"):
            return _deparse(e.args[0]) + f + _deparse(e.args[1])
        if len(e.args) == 1 and f in ("-", "+", "!", "~"):
            return f + _deparse(e.args[0])
        if f == "(":
            return "(" + _deparse(e.args[0]) + ")"
        if f in ("[", "[["):
            cl = "]" if f == "[" else "]]"
            return _deparse(e.args[0]) + f + ", ".join(args[1:]) + cl
        return f + "(" + ", ".join(args) + ")"
    return _deparse(e.val) + "(" + ", ".join(args) + ")"


def _jl_repr(s):
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "$":
            out.append("\\$")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _bind(fname, args, nms, exprs, formals):
    """Argumente an Formale binden (R's Regeln: exakt, partiell, Position)."""
    nf = len(formals)
    dots = formals.index("...") if "..." in formals else None
    val = [None] * nf
    used = [False] * len(args)
    rest = []
    restn = []
    for i, nm in enumerate(nms):
        if nm is None:
            continue
        if nm in formals and nm != "...":
            j = formals.index(nm)
            if val[j] is not None:
                _error('formal argument "%s" matched by multiple actual arguments' % nm)
            val[j] = args[i]
            used[i] = True
    lim = nf if dots is None else dots
    for i, nm in enumerate(nms):
        if nm is None or used[i]:
            continue
        cand = [j for j in range(lim) if val[j] is None and formals[j].startswith(nm)]
        if len(cand) == 1:
            val[cand[0]] = args[i]
            used[i] = True
    j = 0
    for i in range(len(args)):
        if used[i]:
            continue
        if nms[i] is None:
            while j < lim and val[j] is not None:
                j += 1
            if j < lim:
                val[j] = args[i]
                used[i] = True
                j += 1
                continue
        if dots is not None:
            rest.append(args[i])
            restn.append(nms[i])
            used[i] = True
    if not all(used):
        un = [("" if nms[i] is None else nms[i] + " = ") + _deparse(exprs[i]) for i in range(len(args)) if not used[i]]
        _error(("unused argument (" if len(un) == 1 else "unused arguments (") + ", ".join(un) + ")")
    return val, rest, restn


def _missing_arg(nm):
    _error('argument "%s" is missing, with no default' % nm)


def _flag(v, dflt):
    if v is None:
        return dflt
    return len(v) >= 1 and _as_lgl(v)[0] is True


def _nan_warn(x, r):
    if any(r[i] != r[i] and x[i] == x[i] for i in range(len(r))):
        _warn("NaNs produced")
    return r


def _prim1(fname, args, nms):
    if len(args) != 1:
        _error("%d arguments passed to '%s' which requires 1" % (len(args), fname))
    a = args[0]
    if a is None:
        _missing_arg("x")
    return a


def _math1(fname, f):
    def g(args, nms, ex):
        a = _prim1(fname, args, nms)
        if isinstance(a, (CHR, DAT)):
            _error("non-numeric argument to mathematical function")
        x = _as_num(a)
        return _nan_warn(x, NUM([f(v) for v in x]))
    return g


def _sqrt(x):
    if x != x:
        return x
    if x < 0:
        return _DEFAULT_NAN
    return math.sqrt(x)


def _lm1(fname):
    f = getattr(_libm, fname)

    def g(x):
        if x != x:
            return x
        r = f(x)
        if r != r:
            return _DEFAULT_NAN
        return float(r)
    return g


def _ffloor_(x):
    return x if (x != x or math.isinf(x)) else float(math.floor(x))


def _fceil_(x):
    return x if (x != x or math.isinf(x)) else float(math.ceil(x))


def _ftrunc_(x):
    return x if (x != x or math.isinf(x)) else float(math.trunc(x))


def _fsign_(x):
    if x != x:
        return x
    return 1.0 if x > 0 else (-1.0 if x < 0 else 0.0)


def _f_abs(args, nms, ex):
    a = _prim1("abs", args, nms)
    if isinstance(a, (CHR, DAT)):
        _error("non-numeric argument to mathematical function")
    if isinstance(a, (LGL, INT)):
        return INT([None if x is None else abs(x) for x in _as_int(a)])
    return NUM([abs(v) for v in a])


def _log1(x):
    if x != x:
        return x
    r = float(_libm.log(x))
    return _DEFAULT_NAN if r != r else r


def _f_log(args, nms, ex):
    v, _, _ = _bind("log", args, nms, ex, ["x", "base"])
    x, b = v
    if x is None:
        _missing_arg("x")
    if isinstance(x, (CHR, DAT)):
        _error("non-numeric argument to mathematical function")
    xn = _as_num(x)
    if b is None:
        r = NUM([_log1(t) for t in xn])
    else:
        bb = _as_num(b)[0]
        r = NUM([_logb(t, bb) for t in xn])
    return _nan_warn(xn, r)


def _logb(x, b):
    if x != x:
        return x
    r = float(_libm.log(x, b))
    return _DEFAULT_NAN if r != r else r


def _f_round(args, nms, ex, signif=False):
    v, _, _ = _bind("signif" if signif else "round", args, nms, ex, ["x", "digits"])
    x, d = v
    if x is None:
        _missing_arg("x")
    if isinstance(x, (CHR, DAT)):
        _error("non-numeric argument to mathematical function")
    xn = _as_num(x)
    dv = (6.0 if signif else 0.0) if d is None else _as_num(d)[0]
    if signif:
        return NUM([float(_fmt.signif(t, dv)) for t in xn])
    return NUM([float(_fmt.r_round(t, dv)) for t in xn])


def _f_isna(args, nms, ex):
    v = _prim1("is.na", args, nms)
    if isinstance(v, NUM):
        return LGL([x != x for x in v])
    return LGL([x is None for x in v])


def _f_isnan(args, nms, ex):
    v = _prim1("is.nan", args, nms)
    if isinstance(v, NUM):
        return LGL([x != x and not isna_strict(x) for x in v])
    return LGL([False for _ in v])


def _f_isfinite(args, nms, ex):
    v = _prim1("is.finite", args, nms)
    if isinstance(v, NUM):
        return LGL([math.isfinite(x) for x in v])
    if isinstance(v, (LGL, INT)):
        return LGL([x is not None for x in v])
    return LGL([False for _ in v])


def _f_isinfinite(args, nms, ex):
    v = _prim1("is.infinite", args, nms)
    if isinstance(v, NUM):
        return LGL([math.isinf(x) for x in v])
    return LGL([False for _ in v])


def _f_ifelse(args, nms, ex):
    v, _, _ = _bind("ifelse", args, nms, ex, ["test", "yes", "no"])
    test, yes, no = v
    if test is None:
        _missing_arg("test")
    t = _as_lgl(test)
    ans = list(t)
    kind = 1
    ypos = [i for i in range(len(t)) if t[i] is True]
    npos = [i for i in range(len(t)) if t[i] is False]
    if ypos:
        if yes is None:
            _missing_arg("yes")
        if len(yes) == 0:
            _error("replacement has length zero")
        kind = max(kind, _rtype(yes))
        for i in ypos:
            ans[i] = (yes, _rec(yes, i))
    if npos:
        if no is None:
            _missing_arg("no")
        if len(no) == 0:
            _error("replacement has length zero")
        kind = max(kind, _rtype(no))
        for i in npos:
            ans[i] = (no, _rec(no, i))

    def el(a):
        if a is None:
            return None
        return _coerce(_like(a[0], [a[1]]), kind)[0]

    if kind == 4:
        return CHR([el(a) for a in ans])
    if kind == 3:
        return NUM([NA_REAL if a is None else el(a) for a in ans])
    if kind == 2:
        return INT([el(a) for a in ans])
    return LGL([el(a) for a in ans])


def _f_pminmax(args, nms, ex, greater):
    narm = False
    xs = []
    for a, nm in zip(args, nms):
        if nm == "na.rm":
            narm = _flag(a, False)
        elif a is not None:
            xs.append(a)
    if not xs:
        _error("no arguments")
    if any(isinstance(x, (CHR, DAT)) for x in xs):
        _error("invalid input type")
    kind = max(_rtype(x) for x in xs)
    if any(len(x) == 0 for x in xs):
        return NUM() if kind == 3 else INT()
    arrs = [np.array(_as_num(x), dtype=np.float64) for x in xs]
    r = _base.pmax(*arrs, na_rm=narm) if greater else _base.pmin(*arrs, na_rm=narm)
    r = NUM([float(t) for t in np.atleast_1d(np.asarray(r, dtype=np.float64))])
    if kind == 3:
        return r
    return INT([None if t != t else int(t) for t in r])


def _summary_args(args, nms):
    narm = False
    vals = []
    for a, nm in zip(args, nms):
        if nm == "na.rm":
            narm = _flag(a, False)
        else:
            if a is None:
                _error("argument is missing, with no default")
            vals.append(a)
    return vals, narm


def _f_anyall(args, nms, ex, isany):
    vals, narm = _summary_args(args, nms)
    res = not isany
    sawna = False
    for v in vals:
        if isinstance(v, (CHR, NUM, DAT)):
            if isinstance(v, DAT):
                _error('%s not defined for "Date" objects' % ("any" if isany else "all"))
            if len(v):
                _warn("coercing argument of type '%s' to logical" % _rtypeof(v))
        for x in _as_lgl(v):
            if x is None:
                if not narm:
                    sawna = True
            elif x == isany:
                return LGL([isany])
    return LGL([None if sawna else res])


def _f_sum(args, nms, ex):
    vals, narm = _summary_args(args, nms)
    for v in vals:
        if isinstance(v, CHR):
            _error("invalid 'type' (character) of argument")
        if isinstance(v, DAT):
            _error('sum not defined for "Date" objects')
    real = any(isinstance(v, NUM) for v in vals)
    anstype = 3 if real else 2
    icum = 0
    zcum = 0.0
    for v in vals:
        if len(v) == 0:
            continue
        if isinstance(v, (LGL, INT)):
            s = 0
            hasna = False
            for x in v:
                if x is None:
                    if not narm:
                        hasna = True
                        break
                else:
                    s += int(x)
            if hasna:
                return INT([None]) if anstype == 2 else NUM([NA_REAL])
            if anstype == 2:
                t = float(icum) + float(s)
                if t > _IMAX or t < -_IMAX:
                    anstype = 3
                    zcum = t
                else:
                    icum += s
            else:
                zcum = _fadd(zcum, float(s))
        else:
            if anstype == 2:
                anstype = 3
                zcum = float(icum)
            zcum = _fadd(zcum, float(_base.r_sum(np.array(v, dtype=np.float64), na_rm=narm)))
    if anstype == 2:
        return INT([icum])
    return NUM([zcum])


def _real_upd(zcum, tmp, ismax):
    if isna_strict(zcum):
        return zcum
    if tmp != tmp:
        return tmp if isna_strict(tmp) else _fadd(zcum, tmp)
    if (tmp > zcum) if ismax else (tmp < zcum):
        return tmp
    return zcum


def _str_upd(scum, stmp, empty, ismax):
    if empty:
        return stmp
    if scum is None:
        return scum
    if stmp is None:
        return stmp
    if stmp != scum and ((_scoll(stmp, scum) > 0) if ismax else (_scoll(stmp, scum) < 0)):
        return stmp
    return scum


def _f_minmax(args, nms, ex, ismax):
    vals, narm = _summary_args(args, nms)
    if vals and all(isinstance(v, DAT) for v in vals):
        r = _f_minmax([_as_num(v) for v in vals] + [LGL([narm])], [None] * len(vals) + ["na.rm"], ex, ismax)
        return _as_date(r) if isinstance(r, NUM) else r
    anstype = 2
    icum = -_IMAX - 1 if ismax else _IMAX
    icum_na = False
    zcum = -math.inf if ismax else math.inf
    scum = None
    empty = True
    for v in vals:
        if isinstance(v, DAT):
            v = _as_num(v)
        if len(v) == 0:
            if isinstance(v, CHR):
                if not empty and anstype == 2:
                    scum = None if icum_na else "%d" % icum
                elif not empty and anstype == 3:
                    scum = _as_chr(NUM([zcum]))[0]
                anstype = 4
            elif _rtype(v) > anstype and anstype != 4:
                if not empty and anstype == 2:
                    zcum = NA_REAL if icum_na else float(icum)
                anstype = _rtype(v)
            continue
        updated = False
        if isinstance(v, (LGL, INT)):
            s = 0
            isna = False
            for x in v:
                if x is None:
                    if not narm:
                        isna = True
                        updated = True
                        break
                elif not updated or ((x > s) if ismax else (x < s)):
                    s = int(x)
                    updated = True
            if updated:
                if anstype == 2:
                    if icum_na:
                        pass
                    elif isna or ((s > icum) if ismax else (s < icum)):
                        if isna:
                            icum_na = True
                        else:
                            icum = s
                elif anstype == 3:
                    tmp = NA_REAL if isna else float(s)
                    zcum = _real_upd(zcum, tmp, ismax)
                else:
                    stmp = None if isna else "%d" % s
                    scum = _str_upd(scum, stmp, empty, ismax)
        elif isinstance(v, NUM):
            if anstype == 2:
                anstype = 3
                if not empty:
                    zcum = NA_REAL if icum_na else float(icum)
            s = 0.0
            for x in v:
                if x != x:
                    if not narm:
                        if not isna_strict(s):
                            s = x
                        updated = True
                elif not updated or ((x > s) if ismax else (x < s)):
                    s = x
                    updated = True
            if updated:
                if anstype == 3:
                    zcum = _real_upd(zcum, s, ismax)
                else:
                    scum = _str_upd(scum, _as_chr(NUM([s]))[0], empty, ismax)
        else:
            if not empty and anstype == 2:
                scum = None if icum_na else "%d" % icum
            elif not empty and anstype == 3:
                scum = _as_chr(NUM([zcum]))[0]
            anstype = 4
            ss = None
            for x in v:
                if x is not None:
                    if not updated or (ss != x and ((_scoll(ss, x) < 0) if ismax else (_scoll(ss, x) > 0))):
                        ss = x
                        updated = True
                elif not narm:
                    ss = None
                    updated = True
                    break
            if updated:
                scum = _str_upd(scum, ss, empty, ismax)
        if empty and updated:
            empty = False
    if empty:
        if anstype == 4:
            _warn("no non-missing arguments, returning NA")
        else:
            _warn("no non-missing arguments to max; returning -Inf" if ismax else
                  "no non-missing arguments to min; returning Inf")
            anstype = 3
    if anstype == 2:
        return INT([None if icum_na else icum])
    if anstype == 3:
        return NUM([zcum])
    return CHR([scum])


def _drop_na(x):
    return _like(x, [t for t in x if not _isna_el(t)])


def _f_mean(args, nms, ex):
    v, rest, _ = _bind("mean", args, nms, ex, ["x", "trim", "na.rm", "..."])
    x = v[0]
    if x is None:
        _missing_arg("x")
    if isinstance(x, DAT):
        r = _f_mean([_as_num(x), v[1], v[2]], [None, "trim", "na.rm"], ex)
        return _as_date(r)
    if isinstance(x, CHR) or x is _NULLV:
        _warn("argument is not numeric or logical: returning NA")
        return NUM([NA_REAL])
    narm = _flag(v[2], False)
    if v[1] is None:
        trim = 0.0
    elif len(v[1]) == 1 and not isinstance(v[1], CHR):
        trim = _as_num(v[1])[0]
    else:
        _error("'trim' must be numeric of length one")
    if narm:
        x = _drop_na(x)
    n = len(x)
    if trim > 0 and n > 0:
        if any(_isna_el(t) for t in x):
            return NUM([NA_REAL])
        if trim >= 0.5:
            return _f_median([x], [None], ex)
        lo = int(math.floor(n * trim)) + 1
        hi = n + 1 - lo
        part = [lo] if lo == hi else [lo, hi]
        xs = _stats.sort_partial(np.array(_as_num(x), dtype=np.float64), part)
        if isinstance(x, (LGL, INT)):
            return NUM([float(_base.r_mean_int(np.array(xs[lo - 1:hi], dtype=np.float64).astype(np.int64)))])
        return NUM([float(_base.r_mean(np.array(xs[lo - 1:hi], dtype=np.float64)))])
    if isinstance(x, (LGL, INT)):
        if any(t is None for t in x):
            return NUM([NA_REAL])
        return NUM([float(_base.r_mean_int(np.array([int(t) for t in x], dtype=np.int64)))])
    return NUM([float(_base.r_mean(np.array(x, dtype=np.float64)))])


def _f_median(args, nms, ex):
    v, _, _ = _bind("median", args, nms, ex, ["x", "na.rm", "..."])
    x = v[0]
    if x is None:
        _missing_arg("x")
    narm = _flag(v[1], False)
    if isinstance(x, DAT):
        r = _f_median([_as_num(x), v[1]], [None, "na.rm"], ex)
        return _as_date(r)
    if narm:
        x = _drop_na(x)
    elif any(_isna_el(t) for t in x):
        return NUM([NA_REAL]) if isinstance(x, NUM) else _like(x, [None])
    n = len(x)
    if n == 0:
        return NUM([NA_REAL]) if isinstance(x, NUM) else _like(x, [None])
    half = (n + 1) // 2
    if isinstance(x, CHR):
        if n % 2 == 1:
            import functools
            xs = sorted(x, key=functools.cmp_to_key(_scoll))
            return CHR([xs[half - 1]])
        _warn("argument is not numeric or logical: returning NA")
        return NUM([NA_REAL])
    if isinstance(x, (LGL, INT)):
        r = _stats.median(np.array([int(t) for t in x], dtype=np.int64))
        if not isinstance(r, (int, np.integer)):
            return NUM([float(r)])
        return LGL([r != 0]) if isinstance(x, LGL) else INT([int(r)])
    return NUM([float(_stats.median(np.array(x, dtype=np.float64)))])


def _num_arg(x):
    return np.array(_as_num(x), dtype=np.float64)


def _f_var(args, nms, ex):
    v, _, _ = _bind("var", args, nms, ex, ["x", "y", "na.rm", "use"])
    x = v[0]
    if x is None:
        _missing_arg("x")
    if v[1] is not None:
        _error("RExpr: var(x, y) wird nicht unterstützt")
    narm = _flag(v[2], False)
    if isinstance(x, DAT):
        _error("is.atomic(x) is not TRUE")
    return NUM([float(_stats.var(_num_arg(x), na_rm=narm))])


def _f_sd(args, nms, ex):
    v, _, _ = _bind("sd", args, nms, ex, ["x", "na.rm"])
    x = v[0]
    if x is None:
        _missing_arg("x")
    narm = _flag(v[1], False)
    return NUM([float(_stats.sd(_num_arg(x), na_rm=narm))])


def _f_quantile(args, nms, ex):
    v, _, _ = _bind("quantile", args, nms, ex, ["x", "probs", "na.rm", "names", "type", "digits", "..."])
    x = v[0]
    if x is None:
        _missing_arg("x")
    probs = [0.0, 0.25, 0.5, 0.75, 1.0] if v[1] is None else list(_as_num(v[1]))
    narm = _flag(v[2], False)
    typ = 7 if v[4] is None else int(_as_num(v[4])[0])
    if isinstance(x, CHR):
        xn = CHR([t for t in x if t is not None]) if narm else x
        if any(t is None for t in xn):
            _error("missing values and NaN's not allowed if 'na.rm' is FALSE")
        _error("non-numeric argument to binary operator")
    xv = np.array(_as_num(x), dtype=np.float64)
    r = _stats.quantile(xv, np.array(probs, dtype=np.float64), na_rm=narm, names=False, type=typ)
    r = NUM([float(t) for t in np.atleast_1d(np.asarray(r, dtype=np.float64))])
    return _as_date(r) if isinstance(x, DAT) else r


def _f_c(args, nms, ex):
    vals = [a for a in args if a is not None and not (isinstance(a, LGL) and len(a) == 0)]
    if not vals:
        return _NULLV
    if isinstance(args[0], DAT):
        out = DAT()
        for a in vals:
            out.extend(_as_date(a))
        return out
    kind = max(_rtype(v) for v in vals)
    out = []
    for v in vals:
        out.extend(_coerce(_as_num(v) if isinstance(v, DAT) else v, kind))
    return {1: LGL, 2: INT, 3: NUM, 4: CHR}[kind](out)


def _f_length(args, nms, ex):
    v = _prim1("length", args, nms)
    return INT([len(v)])


def _textwidth(s):
    w = 0
    for ch in s:
        cat = unicodedata.category(ch)
        if cat in ("Mn", "Me") or ch == "​":
            continue
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def _f_nchar(args, nms, ex):
    v, _, _ = _bind("nchar", args, nms, ex, ["x", "type", "allowNA", "keepNA"])
    x = v[0]
    if x is None:
        _missing_arg("x")
    tp = "chars" if v[1] is None else _as_chr(v[1])[0]
    types = ["bytes", "chars", "width"]
    m = [] if (tp is None or tp == "") else [i for i in range(3) if types[i].startswith(tp)]
    if not m:
        _error("invalid 'type' argument")
    t = types[m[0]]
    kv = None if v[3] is None else _as_lgl(v[3])[0]
    keep = (t != "width") if kv is None else kv
    s = x if isinstance(x, CHR) else _as_chr(_as_num(x) if isinstance(x, DAT) else x)
    out = INT()
    for z in s:
        if z is None:
            out.append(None if keep else 2)
        elif t == "bytes":
            out.append(len(z.encode("utf-8", "surrogateescape")))
        elif t == "chars":
            out.append(len(z))
        else:
            out.append(_textwidth(z))
    return out


def _f_asnum(args, nms, ex):
    v, _, _ = _bind("as.numeric", args, nms, ex, ["x", "..."])
    return NUM() if v[0] is None else _as_num(v[0])


def _f_asint(args, nms, ex):
    v, _, _ = _bind("as.integer", args, nms, ex, ["x", "..."])
    return INT() if v[0] is None else _as_int(v[0])


def _f_aslgl(args, nms, ex):
    v, _, _ = _bind("as.logical", args, nms, ex, ["x", "..."])
    return LGL() if v[0] is None else _as_lgl(v[0])


def _f_aschr(args, nms, ex):
    v, _, _ = _bind("as.character", args, nms, ex, ["x", "..."])
    return CHR() if v[0] is None else _as_chr(v[0])


def _f_asdate(args, nms, ex):
    v, _, _ = _bind("as.Date", args, nms, ex, ["x", "..."])
    x = v[0]
    if x is None:
        _missing_arg("x")
    if isinstance(x, (CHR, DAT)):
        return _as_date(x)
    if isinstance(x, LGL) and all(t is None for t in x):
        return DAT([None for _ in x])
    return _as_date(_as_num(x))


def _f_cumsum(args, nms, ex):
    x = _prim1("cumsum", args, nms)
    if isinstance(x, (LGL, INT)):
        out = INT([None] * len(x))
        s = 0.0
        for i in range(len(x)):
            if x[i] is None:
                break
            s += float(x[i])
            if s > _IMAX or s < -_IMAX:
                _warn("integer overflow in 'cumsum'; use 'cumsum(as.numeric(.))'")
                break
            out[i] = int(s)
        return out
    xs = np.array(_as_num(x), dtype=np.float64)
    if xs.size == 0:
        return NUM()
    r = [float(t) for t in _base.r_cumsum(xs)]
    if r[-1] != r[-1]:
        # handleNaN (cum.c): ab dem ersten NaN/NA NA, sobald ein NA vorkam, sonst NaN
        hasna = hasnan = False
        for i, t in enumerate(xs.tolist()):
            hasnan = hasnan or t != t
            hasna = hasna or (hasnan and isna_strict(t))
            if hasna:
                r[i] = NA_REAL
            elif hasnan:
                r[i] = _DEFAULT_NAN
    return NUM(r)


def _f_xor(args, nms, ex):
    v, _, _ = _bind("xor", args, nms, ex, ["x", "y"])
    if v[0] is None:
        _missing_arg("x")
    if v[1] is None:
        _missing_arg("y")
    a = _logic("|", v[0], v[1])
    b = _logic("&", v[0], v[1])
    return LGL([None if (p is None or q is None) else (p and not q) for p, q in zip(a, b)])


def _f_istf(args, nms, ex, val):
    v, _, _ = _bind("isTRUE" if val else "isFALSE", args, nms, ex, ["x"])
    x = v[0]
    if x is None:
        _missing_arg("x")
    return LGL([isinstance(x, LGL) and len(x) == 1 and x[0] is val])


def _f_identity(args, nms, ex):
    v, _, _ = _bind("identity", args, nms, ex, ["x"])
    if v[0] is None:
        _missing_arg("x")
    return v[0]


def _f_vector(fname, mk):
    def g(args, nms, ex):
        v, _, _ = _bind(fname, args, nms, ex, ["length"])
        n = NUM([0.0]) if v[0] is None else _as_num(v[0])
        if len(n) != 1 or n[0] != n[0] or n[0] < 0:
            _error("invalid 'length' argument")
        return mk(int(math.trunc(n[0])))
    return g


def _f_rep(args, nms, ex):
    v, _, _ = _bind("rep", args, nms, ex, ["x", "times", "length.out", "each"])
    x = v[0]
    if x is None:
        return LGL()
    each = 1
    if v[3] is not None:
        e = _as_num(v[3])
        each = 1 if (not e or e[0] != e[0]) else int(math.trunc(e[0]))
    if each < 0:
        _error("invalid 'each' argument")
    if each != 1:
        x = _like(x, [t for t in x for _ in range(each)])
    lo = None
    if v[2] is not None:
        lv = _as_num(v[2])
        lo = None if (not lv or lv[0] != lv[0]) else int(math.trunc(lv[0]))
    if lo is not None:
        if len(x) == 0:
            return _like(x, [_na_of(x)] * lo)
        return _like(x, [x[i % len(x)] for i in range(lo)])
    tn = _as_num(INT([1]) if v[1] is None else v[1])
    if len(tn) == 1:
        if tn[0] != tn[0] or tn[0] < 0:
            _error("invalid 'times' argument")
        return _like(x, list(x) * int(math.trunc(tn[0])))
    if len(tn) != len(x):
        _error("invalid 'times' argument")
    if any(t != t or t < 0 for t in tn):
        _error("invalid 'times' argument")
    return _like(x, [x[i] for i in range(len(x)) for _ in range(int(math.trunc(tn[i])))])


_FUNS = {
    "logical": _f_vector("logical", lambda n: LGL([False] * n)),
    "integer": _f_vector("integer", lambda n: INT([0] * n)),
    "numeric": _f_vector("numeric", lambda n: NUM([0.0] * n)),
    "double": _f_vector("double", lambda n: NUM([0.0] * n)),
    "character": _f_vector("character", lambda n: CHR([""] * n)),
    "rep": _f_rep,
    "abs": _f_abs, "sqrt": _math1("sqrt", _sqrt),
    "exp": _math1("exp", _lm1("exp")), "expm1": _math1("expm1", _lm1("expm1")),
    "log1p": _math1("log1p", _lm1("log1p")), "log2": _math1("log2", _lm1("log2")),
    "log10": _math1("log10", _lm1("log10")),
    "sin": _math1("sin", _lm1("sin")), "cos": _math1("cos", _lm1("cos")),
    "tan": _math1("tan", _lm1("tan")), "tanh": _math1("tanh", _lm1("tanh")),
    "atan": _math1("atan", _lm1("atan")),
    "floor": _math1("floor", _ffloor_), "ceiling": _math1("ceiling", _fceil_), "trunc": _math1("trunc", _ftrunc_),
    "sign": _math1("sign", _fsign_),
    "log": _f_log, "round": _f_round, "signif": lambda a, n, e: _f_round(a, n, e, signif=True),
    "is.na": _f_isna, "is.nan": _f_isnan, "is.finite": _f_isfinite, "is.infinite": _f_isinfinite,
    "ifelse": _f_ifelse,
    "pmin": lambda a, n, e: _f_pminmax(a, n, e, False), "pmax": lambda a, n, e: _f_pminmax(a, n, e, True),
    "min": lambda a, n, e: _f_minmax(a, n, e, False), "max": lambda a, n, e: _f_minmax(a, n, e, True),
    "sum": _f_sum, "mean": _f_mean, "median": _f_median, "var": _f_var, "sd": _f_sd,
    "quantile": _f_quantile,
    "any": lambda a, n, e: _f_anyall(a, n, e, True), "all": lambda a, n, e: _f_anyall(a, n, e, False),
    "length": _f_length, "c": _f_c, "nchar": _f_nchar, "xor": _f_xor,
    "isTRUE": lambda a, n, e: _f_istf(a, n, e, True), "isFALSE": lambda a, n, e: _f_istf(a, n, e, False),
    "as.numeric": _f_asnum, "as.double": _f_asnum, "as.integer": _f_asint,
    "as.logical": _f_aslgl, "as.character": _f_aschr, "as.Date": _f_asdate,
    "cumsum": _f_cumsum, "identity": _f_identity,
}


# ═══════════════════════════════════════════════════════════════════════════
# Auswertung
# ═══════════════════════════════════════════════════════════════════════════

class Ctx:
    __slots__ = ("cols", "env", "locals")

    def __init__(self, cols, env, locals_):
        self.cols = cols
        self.env = env
        self.locals = locals_


_NOTFOUND = object()


def _env_get(env, name):
    if env is None:
        return _NOTFOUND
    if isinstance(env, Mapping):
        return env[name] if name in env else _NOTFOUND
    if inspect.ismodule(env) or hasattr(env, "__dict__"):
        return getattr(env, name, _NOTFOUND)
    return _NOTFOUND


_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
           "October", "November", "December"]


def _is_data(v):
    return not (callable(v) or inspect.ismodule(v) or isinstance(v, type))


def _lookup(name, c):
    if name in c.locals:
        return c.locals[name]
    if name in c.cols:
        return c.cols[name]
    v = _env_get(c.env, name)
    if v is not _NOTFOUND and _is_data(v):
        r = from_python(v)
        if r is not None:
            return r
    if name == "T":
        return LGL([True])
    if name == "F":
        return LGL([False])
    if name == "pi":
        return NUM([math.pi])
    if name == "letters":
        return CHR([chr(97 + i) for i in range(26)])
    if name == "LETTERS":
        return CHR([chr(65 + i) for i in range(26)])
    if name == "month.name":
        return CHR(_MONTHS)
    if name == "month.abb":
        return CHR([m[:3] for m in _MONTHS])
    _error("object '%s' not found" % name)


def _cond1(v):
    if isinstance(v, LGL) and len(v) == 1 and v[0] is not None:
        return v[0]
    if isinstance(v, INT) and len(v) == 1 and v[0] is not None:
        return v[0] != 0
    n = len(v)
    if n > 1:
        _error("the condition has length > 1")
    cond = None
    if n > 0:
        cond = _lgl_str(v[0]) if isinstance(v, CHR) else _as_lgl(v)[0]
    if cond is None:
        _error("argument is of length zero" if n == 0 else
               ("missing value where TRUE/FALSE needed" if isinstance(v, LGL) else
                "argument is not interpretable as logical"))
    return cond


_UNSUPPORTED = {"function", "for", "while", "repeat", "next", "break", "~", "?", "::", ":::", "<<-"}

#: Primitive (ohne Argumentabgleich): leeres Argument ist ein Fehler
_PRIMS = {"c", "sum", "min", "max", "any", "all", "length", "abs", "sqrt", "exp", "expm1", "log1p",
          "log2", "log10", "sin", "cos", "tan", "tanh", "atan", "floor", "ceiling", "trunc", "sign",
          "is.na", "is.nan", "is.finite", "is.infinite", "as.numeric", "as.double", "as.integer",
          "as.logical", "as.character", "cumsum", "rep"}


def _ev(e, c):
    h = e.head
    if h == "const":
        return e.val
    if h == "sym":
        return _lookup(e.val, c)
    if h == "empty":
        _error("argument is missing, with no default")
    if h == "callx":
        _error("attempt to apply non-function")
    f = e.val
    a = e.args
    if f == "(":
        return _ev(a[0], c)
    if f == "{":
        r = _NULLV
        for x in a:
            r = _ev(x, c)
        return r
    if f == "if":
        if _cond1(_ev(a[0], c)):
            return _ev(a[1], c)
        return _ev(a[2], c) if len(a) == 3 else _NULLV
    if f in ("<-", "="):
        lhs = a[0]
        if lhs.head == "sym":
            nm = lhs.val
        elif lhs.head == "const" and isinstance(lhs.val, CHR) and len(lhs.val) == 1 and lhs.val[0] is not None:
            nm = lhs.val[0]
        elif lhs.head == "call":
            _error("RExpr: Zuweisung an '%s' wird nicht unterstützt" % _deparse(lhs))
        else:
            _error("invalid (do_set) left-hand side to assignment")
        v = _ev(a[1], c)
        c.locals[nm] = v
        return v
    if f == "!" and len(a) == 1:
        return _not(_ev(a[0], c))
    if f in ("-", "+") and len(a) == 1:
        return _unary(f, _ev(a[0], c))
    if f in ("&&", "||"):
        x = _scalar_lgl(_ev(a[0], c), f)
        if f == "&&" and x is False:
            return LGL([False])
        if f == "||" and x is True:
            return LGL([True])
        y = _scalar_lgl(_ev(a[1], c), f, "y")
        return _logic("&" if f == "&&" else "|", LGL([x]), LGL([y]))
    if f in ("&", "|") and len(a) == 2:
        return _logic(f, _ev(a[0], c), _ev(a[1], c))
    if f in _CMP and len(a) == 2:
        return _compare(f, _ev(a[0], c), _ev(a[1], c))
    if f in ("+", "-", "*", "/", "^", "%%", "%/%") and len(a) == 2:
        return _arith(f, _ev(a[0], c), _ev(a[1], c))
    if f == "%in%" and len(a) == 2:
        return _in(_ev(a[0], c), _ev(a[1], c))
    if f == ":" and len(a) == 2:
        return _colon(_ev(a[0], c), _ev(a[1], c))
    if f == "[":
        x = _ev(a[0], c)
        subs = a[1:]
        if len(subs) == 1 and subs[0].head == "empty":
            return x
        if len(subs) != 1:
            _error("incorrect number of dimensions")
        return _index(x, _ev(subs[0], c))
    if f == "[[":
        x = _ev(a[0], c)
        subs = a[1:]
        if len(subs) != 1:
            _error("incorrect number of subscripts")
        if subs[0].head == "empty":
            _error("missing subscript")
        return _index2(x, _ev(subs[0], c))
    if f == "$":
        _ev(a[0], c)
        _error("$ operator is invalid for atomic vectors")
    if f == "@":
        x = _ev(a[0], c)
        _error('no applicable method for `@` applied to an object of class "%s"' % _rclass(x))
    if f in _UNSUPPORTED:
        _error("RExpr: '%s' wird in Ausdrücken nicht unterstützt" % f)
    fn = _FUNS.get(f)
    if fn is not None:
        if f in _PRIMS:
            for k, x in enumerate(a):
                if x.head == "empty":
                    _error("argument %d is empty" % (k + 1))
        args = [None if x.head == "empty" else _ev(x, c) for x in a]
        return fn(args, e.names, a)
    g = _env_get(c.env, f)
    if g is not _NOTFOUND and callable(g):
        args = [_ev(x, c) for x in a]
        pargs = [to_python(x) for x, nm in zip(args, e.names) if nm is None]
        kw = {nm.replace(".", "_"): to_python(x) for x, nm in zip(args, e.names) if nm is not None}
        r = from_python(g(*pargs, **kw))
        if r is None:
            _error("Funktion '%s' lieferte keinen Vektor." % f)
        return r
    _error('could not find function "%s"' % f)


def _columns(data):
    d = {}
    if data is None:
        return d
    if isinstance(data, pd.DataFrame):
        for k in data.columns:
            r = from_python(data[k])
            if r is not None:
                d[str(k)] = r
        return d
    if isinstance(data, Mapping):
        for k, v in data.items():
            r = from_python(v)
            if r is not None:
                d[str(k)] = r
        return d
    if isinstance(data, (list, tuple)) and len(data) == 0:
        return d
    _error("data muss ein data.frame (DataFrame oder dict) sein.")


def _caller_env(depth=2):
    fr = inspect.currentframe()
    try:
        for _ in range(depth):
            fr = fr.f_back
        env = dict(fr.f_globals)
        env.update(fr.f_locals)
        return env
    finally:
        del fr


def eval_r(expr, data=None, env=None, raw=False):
    """Ausdruck ``expr`` (Text in R-Syntax, Liste von Zeilen oder Ergebnis von
    :func:`parse_r`) wie ``eval(parse(text = expr), data, env)`` auswerten.

    Mehrere Ausdrücke werden nacheinander ausgewertet, Ergebnis ist das des
    letzten (leerer Text → NULL).

    Args:
        expr: Text in R-Syntax.
        data: ``DataFrame`` oder ``dict`` (Spalten als Variablen).
        env: Mapping (oder Modul/Objekt) für weitere Variablen und Funktionen;
            Voreinstellung: Namensraum des Aufrufers (globale und lokale Namen).
        raw: ``True`` liefert den internen R-Vektor (``LGL``, ``INT``, ``NUM``,
            ``CHR``, ``DAT``) statt eines numpy-Arrays.

    Returns:
        ``ndarray`` (siehe Modulbeschreibung).
    """
    if env is None:
        env = _caller_env()
    if isinstance(expr, Node):
        exprs = [expr]
    elif isinstance(expr, list) and expr and all(isinstance(x, Node) for x in expr):
        exprs = expr
    else:
        exprs = parse_r(expr)
    c = Ctx(_columns(data), env, {})
    r = _NULLV
    with np.errstate(all="ignore"):
        for e in exprs:
            r = _ev(e, c)
    return r if raw else to_python(r)


def as_numeric(v):
    """``as.numeric(v)`` wie R (Zeichen über R_strtod mit Warnung „NAs introduced by coercion“)."""
    r = from_python(v)
    if r is None:
        _error("Bedingung lieferte keinen Vektor.")
    return to_python(_as_num(r))


def as_logical(v):
    """``as.logical(v)`` wie R (Ergebnis ``object``-Array mit ``True``/``False``/``None``)."""
    r = from_python(v)
    if r is None:
        _error("Bedingung lieferte keinen Vektor.")
    a = np.empty(len(r), dtype=object)
    a[:] = list(_as_lgl(r))
    return a
