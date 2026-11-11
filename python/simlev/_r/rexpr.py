# Herkunft:           nachgebildet nach R 4.3.3, src/main/gram.y (Grammatik und Vorrang) und der
#                     Semantik der Grundoperatoren
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); gram.y: zusätzlich Romain Francois (2009-2011)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
"""Ausdrücke in R-Syntax als Text auswerten (wie ``eval(parse(text = s), data, env)``).

Gemeinsamer Auswerter für Bedingungen als Text in
:func:`simlev.bootstrap_probability`, :func:`simlev.regime_subset`,
:func:`simlev.view_prob`/:func:`simlev.scenario_entropy_pooling` und
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
``NUM``, ``CHR``, ``DAT``; NA als ``None`` bzw. ``NA_REAL`` (``NUM``, ``DAT``), NULL als leerer
logischer Vektor); alle Operationen elementweise mit Recycling und
dreiwertiger NA-Logik, Ganzzahlarithmetik mit Überlauf → NA und Warnung,
Zahlen wie R (``^`` über ``R_POW``, ``%%``/``%/%`` wie ``myfmod``/``myfloor``,
Literale und ``as.numeric`` über R_strtod mit long double (long-double-Teile im
C-Kern ``core/slc_rbase_num.cpp`` über :mod:`simlev._ext`), Summen/Mittel über
:mod:`simlev._r.base`, ``median``, ``var``, ``sd``, ``quantile`` über
:mod:`simlev._r.stats`, Funktionen über :mod:`simlev._r.libm`),
Zeichenkettenvergleiche über :func:`simlev._r.stats.str_collate` (ICU wie R).

Ergebnis von :func:`eval_r`: logisch → ``ndarray`` (``object``: ``True``,
``False``, ``None``), ganzzahlig → ``int64`` (mit NA: ``float64`` und
``NA_REAL``), numerisch → ``float64`` (NA = ``NA_REAL``, NaN = ``nan``),
Zeichen → ``ndarray`` (``object``, NA = ``None``), Datum →
``datetime64[D]`` (Bruchteile abgerundet, NA, NaN und ±Inf als NaT).
"""
from __future__ import annotations

import datetime as _dt
import inspect
import itertools as _itertools
import math
import struct
import threading
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from .. import _ext
from . import base as _base
from . import fmt as _fmt
from . import libm as _libm
from . import stats as _stats
from . import rnum as _rnum
from . import _wctype as _wct   # glibc-Zeichenklassen (seit 1.6.4, C-026)
from . import rformat as _rformat   # r_deparse_str (seit 1.6.4, C-089)
from .linalg import RError   # eine Klasse für RExpr und stats (seit 1.6.3)
from .rnum import NA_REAL, _bits

__all__ = ["parse_r", "eval_r", "r_strtod", "from_python", "to_python", "as_numeric", "as_logical"]

_IMAX = 2147483647
_DEFAULT_NAN = struct.unpack("<d", struct.pack("<Q", 0xFFF8000000000000))[0]
_R_NAN = struct.unpack("<d", struct.pack("<Q", 0x7FF8000000000000))[0]   # R_NaN
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
    """Datumsvektor: Tage seit 1970-01-01 als double wie R (auch mit Bruchteilen und ±Inf; NA = ``NA_REAL``, NaN = andere
    NaN). Seit 1.6.4 (C-003, Entscheidung 97); bis 1.6.3 ganze Tage (``int``, abgerundet) mit ``None`` als NA."""


class DIF(list):
    """Zeitdifferenz in Tagen (schlanke Nachbildung von R's difftime mit units = "days", seit 1.6.4, Entscheidung 105):
    Ergebnis von Datum - Datum; Werte wie ``NUM``."""


def _warn(msg):
    warnings.warn(msg, UserWarning, stacklevel=2)


_MAX_LEN = 100000000   # seit 1.6.4 (C-006, Entscheidung 79): höchstens 1e8 Werte je Vektor (wie Entscheidung 16)


def _len_error():
    from .._meldungen import EINGABE
    _error(EINGABE["sp.rexpr_laenge"] % _MAX_LEN)


def _error(msg):
    raise RError(msg)


# ── Namen (seit 1.6.4, C-001, Entscheidung 97) ───────────────────────────────────────────────────────────────────────
# Ein Vektor trägt Namen wie in R als Attribut ``names`` (Liste von str, None = NA); ohne Namen fehlt das Attribut.
# Namen entstehen in c(), as.Date und quantile und laufen wie in R durch [, Operatoren, Math-Funktionen, is.na & Co.,
# ifelse, rep, cumsum, nchar, pmin/pmax; as.numeric & Co., [[, Zusammenfassungen und %in% lassen sie fallen. Nach außen
# (to_python) fallen sie weg. Bis 1.6.3 verwarf c() die Namen, x["b"] ergab NA und x[["b"]] einen Fehler.

def _nm(v):
    return getattr(v, "names", None)


def _setnm(v, nm):
    """Namen an ein neues Ergebnis hängen (nie an NULL)."""
    if nm is not None and v is not _NULLV:
        v.names = list(nm)
    return v


def _strip(v):
    """Kopie ohne Namen (as.vector-Regel), wenn v Namen trägt."""
    return type(v)(v) if _nm(v) is not None else v


def _cp(cls, r):
    """``cls(r)`` mit den Namen von r."""
    return _setnm(cls(r), _nm(r))


def _binnames(a, b, n):
    """Namen eines zweistelligen Operators wie R (arithmetic.c, relop.c, logic.c): die des ersten Operanden mit der
    Länge des Ergebnisses, sonst die des zweiten."""
    na, nb = _nm(a), _nm(b)
    if na is not None and len(a) == n:
        return na
    if nb is not None and len(b) == n:
        return nb
    return None


def _d(b):
    return struct.unpack("<d", struct.pack("<Q", b))[0]


def isna_strict(x):
    """True für R's NA_real_ (NaN mit Nutzlast 1954), False für andere NaN."""
    return x != x and (_bits(x) & 0xFFFFFFFF) == 1954


# ═══════════════════════════════════════════════════════════════════════════
# R_strtod (arithmetic.c/util.c, R_strtod5 mit NA = FALSE, long double)
# ═══════════════════════════════════════════════════════════════════════════

def _isdig(c):
    return "0" <= c <= "9"


# R_strtod und String_to_real stehen in simlev._r.rnum (gemeinsam mit fmt; Zahlteil im C-Kern)
r_strtod = _rnum.r_strtod
_str2num = _rnum.r_string_to_real


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
    """Anfang eines Namens wie R (glibc iswalpha in C.UTF-8; seit 1.6.4, C-026: auch Buchstabenziffern Nl wie Ⅳ und
    Ziffern anderer Schriften wie ٣, bis 1.6.3 nur Unicode-Kategorie L*)."""
    return _wct.iswalpha(c)


def _isalnum_u(c):
    """Weiteres Zeichen eines Namens wie R (glibc iswalnum in C.UTF-8; seit 1.6.4, C-026)."""
    return _wct.iswalnum(c)


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
        if not (_isdig(c) or c in ".eExXL"):   # _EOF ("\0") ist keins davon
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
            if c in "pP":
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
                if 0xD800 <= val <= 0xDFFF:   # seit 1.6.4 wie R (C-089, P11-B3)
                    L.warns.append("unpaired surrogate Unicode point %x" % val)
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
        if s == "":   # seit 1.6.4 wie R install("") beim Zerlegen (C-025)
            _error("attempt to use zero-length variable name")
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
    if _isletter(c):
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


# Kontextstapel wie R's gram.y (CONTEXTSTACK_SIZE 50): seit 1.6.4 (C-006) mit R's Grenze und Meldung
# „contextstack overflow (<input>:Zeile:Spalte)“; bis 1.6.3 ohne Grenze (Python RecursionError, Julia Stapelüberlauf)
_CONTEXTSTACK_SIZE = 50


def _cpush(L, c, k=1):
    if len(L.cstack) - 1 >= _CONTEXTSTACK_SIZE - (k - 1):
        _lexerr(L, "contextstack overflow")
    for _ in range(k):
        L.cstack.append(c)


def _ifpush(L):
    if _ctop(L) in "{[(i":
        _cpush(L, "i")


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
            _cpush(L, "[", 2)
        elif k == "LBRACKET":
            _cpush(L, "[")
        elif k == "LBRACE":
            _cpush(L, "{")
            L.eat = True
        elif k == "LPAREN":
            _cpush(L, "(")
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
        self.depth = 0   # Schachtelung von _expr (seit 1.6.4, C-006)


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


#: höchste Schachtelungstiefe eines Ausdrucks (seit 1.6.4, Entscheidung 75): Tiefe des Syntaxbaums wie R's
#: Aufrufbaum (jeder Aufruf, auch Operator, Klammer, Index, eine Ebene; Namen und Konstanten 0)
_MAX_DEPTH = 200


def _depth_error():
    from .._meldungen import EINGABE
    _error(EINGABE["sp.rexpr_tiefe"] % _MAX_DEPTH)


def _tree_depth(e):
    """Tiefe des Syntaxbaums ohne Rekursion (Aufruf 1 + Tiefe des tiefsten Kinds, auch der Funktion bei callx)."""
    best = 0
    stack = [(e, 0)]
    while stack:
        x, d = stack.pop()
        if x.head in ("call", "callx"):
            d += 1
            if d > best:
                best = d
            if d > _MAX_DEPTH:
                return d
            for a in x.args:
                stack.append((a, d))
            if x.head == "callx":
                stack.append((x.val, d))
    return best


def _expr(P, minbp, ctx, first=None):
    # seit 1.6.4 (C-006): mehr als _MAX_DEPTH + 1 geschachtelte Teilausdrücke ergeben einen Baum tiefer als _MAX_DEPTH
    P.depth += 1
    if P.depth > _MAX_DEPTH + 1:
        _depth_error()
    try:
        return _expr0(P, minbp, ctx, first)
    finally:
        P.depth -= 1


def _expr0(P, minbp, ctx, first=None):
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
        if k == "EQ_ASSIGN":   # seit 1.6.4 (C-024) wie R's Grammatik: rechts darf '<-' stehen (a = b <- 3)
            rbp = 4
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
        if isinstance(t.val, str):   # 1i, NA_complex_: seit 1.6.4 in allen drei Sprachen abgelehnt (Entscheidung 64)
            _error("RExpr: komplexe Zahlen werden nicht unterstützt")
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
                if s.val in formals:   # seit 1.6.4 wie R's CheckFormalArgs (C-024)
                    _error("repeated formal argument '%s' (<input>:%d:%d)" % (s.val, s.line, s.col))
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
        if _tree_depth(e) > _MAX_DEPTH:   # seit 1.6.4 (C-006, Entscheidung 75)
            _depth_error()
        if _has_placeholder(e):
            _error("invalid use of pipe placeholder (<input>:%d:%d)" % (L.line - 1 if t.kind == "NL" else L.line, L.col))
        exprs.append(e)
    return exprs, L.warns


_CACHE = {}
_CACHE_LOCK = threading.Lock()
_CACHE_MAX = 1000   # seit 1.6.4 (C-069): höchstens so viele Regeltexte, danach fällt der älteste weg (bis 1.6.3 ohne Grenze)


def parse_r(s):
    """Text in R-Syntax zerlegen wie ``parse(text = s)``.

    Mehrere Elemente einer Liste/eines Arrays werden zeilenweise verbunden.
    Syntaxfehler → :class:`RError` (``ValueError``) mit R's Meldung;
    Warnungen des Lexers (z. B. zu ``1.5L``) bei jedem Aufruf. Ergebnisse
    werden zwischengespeichert (seit 1.6.4 höchstens ``_CACHE_MAX`` Texte, C-069).
    """
    if not isinstance(s, str):
        s = "\n".join(str(x) for x in s)
    with _CACHE_LOCK:
        hit = _CACHE.get(s)
    if hit is None:
        hit = _parse_all(s)
        with _CACHE_LOCK:
            if s not in _CACHE:
                while len(_CACHE) >= _CACHE_MAX:
                    del _CACHE[next(iter(_CACHE))]
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
    """Python-Zahl → R-double: ``NA_REAL`` bleibt NA, jedes andere ``nan`` ist NaN."""
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
        return DAT([NA_REAL if _nanlike(x) else _dayf(_day_of(x)) for x in v])
    return None


def _dayf(d):
    return NA_REAL if d is None else float(d)


def from_python(v):
    """Python-Wert → R-Vektor (``None``, wenn der Wert keine Daten sind)."""
    if isinstance(v, (LGL, INT, NUM, CHR, DAT, DIF)):
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
        return DAT([_dayf(_day_of(v))])
    if isinstance(v, pd.Categorical):
        return CHR([None if _is_na_obj(x) or (isinstance(x, float) and x != x) else str(x)
                    for x in np.asarray(v, dtype=object)])
    if isinstance(v, (pd.Series, pd.Index)):
        if isinstance(v.dtype, pd.CategoricalDtype):
            return from_python(pd.Categorical(v))
        if v.dtype.kind == "M":
            return from_python(np.asarray(v.to_numpy(), dtype="datetime64[ns]").astype("datetime64[D]"))
        if pd.api.types.is_extension_array_dtype(v.dtype) and v.dtype.kind in "biuf":
            # seit 1.6.4 (C-027): Nullable-Spalten (Int64, Float64, boolean) mit pd.NA als NA wie R und Julia,
            # ganzzahlige bleiben ganzzahlig (bis 1.6.3 NaN bzw. Kommazahl)
            return _from_seq(list(v.to_numpy(dtype=object, na_value=None)))
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
            f = d.astype(np.int64).astype(np.float64)   # Tage als double (seit 1.6.4, C-003)
            f[np.isnat(d)] = NA_REAL
            return DAT(f.tolist())
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
    if isinstance(v, (NUM, DIF)):
        return np.array([math.nan if (x != x and not isna_strict(x)) else x for x in v], dtype=np.float64)
    if isinstance(v, CHR):
        a = np.empty(len(v), dtype=object)
        a[:] = list(v)
        return a
    if isinstance(v, DAT):
        # seit 1.6.4 (C-003): Bruchteile abgerundet; NA, NaN, ±Inf und Beträge über 1e15 Tage als NaT (bis 1.6.3 nur
        # ganze Tage im Vektor)
        if all(t is float for t in map(type, v)):
            # als Feld (seit 1.6.4, C-032; bis dahin je Element): floor exakt, |x| <= 1e15 < 2^53, dieselben Tage
            f = np.array(v, dtype=np.float64)
            with np.errstate(invalid="ignore"):
                ok = np.isfinite(f) & (np.abs(f) <= 1e15)
            out = np.full(f.shape[0], np.datetime64("NaT", "D"), dtype="datetime64[D]")
            out[ok] = np.floor(f[ok]).astype(np.int64).astype("datetime64[D]")
            return out
        return np.array([np.datetime64(int(math.floor(x)), "D") if (math.isfinite(x) and abs(x) <= 1e15)
                         else np.datetime64("NaT", "D")
                         for x in v], dtype="datetime64[D]")
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
    return LGL([None if x != x else x != 0 for x in v])   # DAT, DIF wie double (seit 1.6.4, C-003)


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
    if isinstance(v, (DAT, DIF)):
        return NUM(v)   # Tage als double, Bits unverändert (seit 1.6.4, C-003)
    if isinstance(v, (LGL, INT)):
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
    if isinstance(v, DIF):
        return _as_chr(NUM(v))
    if isinstance(v, NUM):
        if not v:
            return CHR()
        a = np.array([math.nan if (x != x and not isna_strict(x)) else x for x in v], dtype=np.float64)
        r = _fmt.as_character(a)
        if not isinstance(r, np.ndarray):
            r = [r]
        return CHR([None if x is None else str(x) for x in r])
    if isinstance(v, INT):
        return CHR([None if x is None else "%d" % x for x in v])
    if isinstance(v, LGL):
        return CHR([None if x is None else ("TRUE" if x else "FALSE") for x in v])
    return CHR([_date_chr(x) for x in v])


def _date_chr(x):
    """``as.character(<Date>)`` wie R 4.3.3 (as.character.POSIXt über Date2POSIXlt): ``"%d-%02d-%02d"`` mit dem Jahr
    ohne Auffüllen (``"53-06-19"``, ``"-1-01-01"``, ``"12345-01-01"``), Bruchteile abgerundet; NA bleibt NA, NaN, ±Inf
    und Jahre außerhalb von int als Zahltext (``"NaN"``, ``"Inf"``, ``"1e+15"``). Seit 1.6.4 (C-003, C-005,
    Entscheidung 97); bis 1.6.3 ISO-Text mit vierstelligem Jahr."""
    if x != x and isna_strict(x):
        return None
    if math.isfinite(x):
        y, m, d = _civil_from_days(int(math.floor(x)))
        if -2147483648 <= y - 1900 <= 2147483647:
            if y > 2147483647:
                _error("invalid format '%d'; use format %f, %e, %g or %a for numeric objects")
            return "%d-%02d-%02d" % (y, m, d)
    return _as_chr(NUM([x]))[0]


def _days_from_civil(y, m, d):
    """Tage seit 1970-01-01 im proleptischen gregorianischen Kalender (auch Jahr 0)."""
    y -= m <= 2
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468


def _strptime_ymd(x, sep):
    """R's strptime(x, "%Y<sep>%m<sep>%d") als Tageszahl oder None (R_strptime: vor jeder Zahl nur ASCII-Leerzeichen
    überspringen, %Y bis 4, %m/%d bis 2 ASCII-Ziffern, Rest des Textes egal; ungültiger Tag ergibt NA)."""
    n = len(x)

    def num(i, lo, hi, nd):
        while i < n and x[i] == " ":
            i += 1
        if i >= n or not ("0" <= x[i] <= "9"):
            return None, i
        v = k = 0
        while k < nd and i < n and "0" <= x[i] <= "9":
            v = v * 10 + ord(x[i]) - 48
            i += 1
            k += 1
        return (v if lo <= v <= hi else None), i

    y, i = num(0, 0, 9999, 4)
    if y is None or i >= n or x[i] != sep:
        return None
    m, i = num(i + 1, 1, 12, 2)
    if m is None or i >= n or x[i] != sep:
        return None
    d, i = num(i + 1, 1, 31, 2)
    if d is None:
        return None
    leap = y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)
    if d > ((29 if leap else 28) if m == 2 else 30 if m in (4, 6, 9, 11) else 31):
        return None
    return _days_from_civil(y, m, d)


# ── strptime wie R 4.3.3 (seit 1.6.4, C-002, Entscheidung 97) ────────────────────────────────────────────────────────
# Übertragung von w_strptime_internal (src/main/Rstrptime.h, Fassung für Mehrbyte-Locales wie C.UTF-8) und der
# Nachbearbeitung in do_strptime/glibc_fix/validate_tm/POSIXlt2Date (src/main/datetime.c), soweit sie das Datum
# bestimmt: Namen von Monat und Wochentag englisch (C-Locale), Groß-/Kleinschreibung nur ASCII, Leerraum im Format wie
# glibc iswspace; fehlen Jahr, Monat oder Tag, gelten die des heutigen Tags (lokale Zeit) wie R; %z verschiebt in UTC.

_WDAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
_MON_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
              "November", "December"]
_MON_YDAY = ((0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365),
             (0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366))
_MONTH_DAYS = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
_IWSPACE = frozenset("\t\n\x0b\x0c\r              "
                     " 　")   # glibc iswspace in C.UTF-8


def _cdivi(a, b):
    """Ganzzahldivision wie C (Richtung 0)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def _cmodi(a, b):
    return a - b * _cdivi(a, b)


def _isleap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def _dim(mon, yr):
    """days_in_month(mon, yr) von datetime.c (yr = Jahr - 1900)."""
    return 29 if (mon == 1 and _isleap(1900 + yr)) else _MONTH_DAYS[mon]


class _TM:
    __slots__ = ("sec", "min", "hour", "mday", "mon", "year", "wday", "yday")

    def __init__(self):
        self.sec = self.min = self.hour = 0
        self.mday = self.mon = self.year = self.wday = self.yday = None   # NA_INTEGER

    def copy(self):
        t = _TM()
        for k in _TM.__slots__:
            setattr(t, k, getattr(self, k))
        return t


def _yv(y):
    """tm_year mit NA_INTEGER wie C (für Rechnungen, die R auch ohne Jahr ausführt)."""
    return -2147483648 if y is None else y


def _wmatch(name, s, i):
    """Rwcsncasecmp: name am Anfang von s[i:], ohne Unterschied der Großschreibung (nur ASCII)."""
    n = len(name)
    if s[i:i + n].lower() == name.lower() and all(c < "\x80" for c in s[i:i + n]):
        return i + n
    return -1


def _day_of_the_week(tm):
    if tm.year is None or tm.mon is None or tm.mday is None:
        return
    cy = 1900 + tm.year - (tm.mon < 2)
    q4 = _cdivi(cy, 4)
    wday = (-473 + 365 * (tm.year - 70) + q4 - _cdivi(q4, 25) + (1 if _cmodi(q4, 25) < 0 else 0)
            + _cdivi(_cdivi(q4, 25), 4) + _MON_YDAY[0][tm.mon] + tm.mday - 1)
    tm.wday = _cmodi(_cmodi(wday, 7) + 7, 7)


def _day_of_the_year(tm):
    if tm.year is None or tm.mon is None or tm.mday is None:
        return
    tm.yday = _MON_YDAY[1 if _isleap(1900 + tm.year) else 0][tm.mon] + tm.mday - 1


_RE_STRTOD = None


def _wcstod(s, i):
    """wcstod für %OS: (Wert, Ende); ohne Zahl (0.0, i)."""
    global _RE_STRTOD
    import re
    if _RE_STRTOD is None:
        _RE_STRTOD = re.compile(r"[+-]?(?:0[xX](?:[0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)(?:[pP][+-]?[0-9]+)?"
                                r"|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|[iI][nN][fF](?:[iI][nN][iI][tT][yY])?"
                                r"|[nN][aA][nN](?:\([0-9A-Za-z_]*\))?)", re.ASCII)
    j = i
    while j < len(s) and s[j] in _IWSPACE:
        j += 1
    m = _RE_STRTOD.match(s, j)
    if not m:
        return 0.0, i
    t = m.group(0)
    try:
        if "x" in t or "X" in t:
            v = float.fromhex(t if ("p" in t or "P" in t) else t + "p0")
        elif t.lstrip("+-")[:1] in "nN":
            v = math.nan
        else:
            v = float(t)
    except (ValueError, OverflowError):
        v = math.inf
    return v, m.end()


def _strptime_w(s, i, fmt, tm, st):
    """w_strptime_internal: Index hinter dem gelesenen Teil von s oder -1 (NULL)."""
    n, nf = len(s), len(fmt)
    at = lambda k: s[k] if k < n else "\0"   # noqa: E731
    have_I = is_pm = 0
    century = -1
    want_century = 0
    have_wday = want_xday = have_yday = have_mon = have_mday = 0
    have_uweek = have_wweek = 0
    week_no = 0
    f = 0

    def num(lo, hi, nd):
        nonlocal i
        while at(i) == " ":
            i += 1
        if not ("0" <= at(i) <= "9"):
            return None
        v = 0
        while True:
            v = v * 10 + ord(at(i)) - 48
            i += 1
            nd -= 1
            if not (nd > 0 and "0" <= at(i) <= "9"):
                break
        return v if lo <= v <= hi else None

    while f < nf:
        c = fmt[f]
        if c in _IWSPACE:
            while at(i) in _IWSPACE and i < n:
                i += 1
            f += 1
            continue
        if c != "%":
            if at(i) != c:
                return -1
            i += 1
            f += 1
            continue
        f += 1
        c = fmt[f] if f < nf else "\0"
        f += 1
        if c == "E":
            c2 = fmt[f] if f < nf else "\0"
            if c2 not in "cCyYxX" or c2 == "\0":
                return -1
            c = c2
            f += 1
        if c == "%":
            if at(i) != "%":
                return -1
            i += 1
        elif c in "aA":
            k = -1
            for cnt, nm in enumerate(_WDAY_NAMES):
                k = _wmatch(nm, s, i)
                if k >= 0:
                    break
            if k < 0:
                for cnt, nm in enumerate(_WDAY_NAMES):
                    k = _wmatch(nm[:3], s, i)
                    if k >= 0:
                        break
            if k < 0:
                return -1
            i = k
            tm.wday = cnt
            have_wday = 1
        elif c in "bBh":
            k = -1
            for cnt, nm in enumerate(_MON_NAMES):
                k = _wmatch(nm, s, i)
                if k >= 0:
                    break
            if k < 0:
                for cnt, nm in enumerate(_MON_NAMES):
                    k = _wmatch(nm[:3], s, i)
                    if k >= 0:
                        break
            if k < 0:
                return -1
            i = k
            tm.mon = cnt
            want_xday = 1
        elif c in "cDxFrRTX":
            sub = {"c": "%a %b %e %H:%M:%S %Y", "D": "%y/%m/%d", "x": "%y/%m/%d", "F": "%Y-%m-%d",
                   "r": "%I:%M:%S %p", "R": "%H:%M", "T": "%H:%M:%S", "X": "%H:%M:%S"}[c]
            i = _strptime_w(s, i, sub, tm, st)
            if i < 0:
                return -1
            if c in "DxF":
                want_xday = 1
        elif c == "C":
            v = num(0, 99, 2)
            if v is None:
                return -1
            century = v
            want_xday = 1
        elif c in "de":
            v = num(1, 31, 2)
            if v is None:
                return -1
            tm.mday = v
            have_mday = want_xday = 1
        elif c in "kH":
            v = num(0, 24, 2)
            if v is None:
                return -1
            tm.hour = v
            have_I = 0
        elif c in "lI":
            v = num(1, 12, 2)
            if v is None:
                return -1
            tm.hour = v % 12
            have_I = 1
        elif c == "j":
            v = num(1, 366, 3)
            if v is None:
                return -1
            tm.yday = v - 1
            have_yday = 1
        elif c == "m":
            v = num(1, 12, 2)
            if v is None:
                return -1
            tm.mon = v - 1
            have_mon = want_xday = 1
        elif c == "M":
            v = num(0, 59, 2)
            if v is None:
                return -1
            tm.min = v
        elif c in "nt":
            while at(i) in _IWSPACE and i < n:
                i += 1
        elif c == "p":
            k = _wmatch("AM", s, i)
            if k < 0:
                k = _wmatch("PM", s, i)
                if k < 0:
                    return -1
                is_pm = 1
            i = k
        elif c == "s":
            if not ("0" <= at(i) <= "9"):
                return -1
            secs = 0
            while "0" <= at(i) <= "9":
                secs = secs * 10 + ord(at(i)) - 48
                i += 1
            import time as _time
            try:
                lt = _time.localtime(secs)
            except (OverflowError, OSError, ValueError):
                return -1
            tm.sec, tm.min, tm.hour, tm.mday = lt.tm_sec, lt.tm_min, lt.tm_hour, lt.tm_mday
            tm.mon, tm.year, tm.wday, tm.yday = lt.tm_mon - 1, lt.tm_year - 1900, (lt.tm_wday + 1) % 7, lt.tm_yday - 1
        elif c == "S":
            v = num(0, 61, 2)
            if v is None:
                return -1
            tm.sec = v
        elif c == "u":
            v = num(1, 7, 1)
            if v is None:
                return -1
            tm.wday = v % 7
            have_wday = 1
        elif c == "g":
            if num(0, 99, 2) is None:
                return -1
        elif c == "G":
            if not ("0" <= at(i) <= "9"):
                return -1
            while "0" <= at(i) <= "9":
                i += 1
        elif c in "UW":
            v = num(0, 53, 2)
            if v is None:
                return -1
            week_no = v
            if c == "U":
                have_uweek = 1
            else:
                have_wweek = 1
        elif c == "V":
            if num(0, 53, 2) is None:
                return -1
        elif c == "w":
            v = num(0, 6, 1)
            if v is None:
                return -1
            tm.wday = v
            have_wday = 1
        elif c == "y":
            v = num(0, 99, 2)
            if v is None:
                return -1
            tm.year = v if v >= 69 else v + 100
            want_century = want_xday = 1
        elif c == "Y":
            v = num(0, 9999, 4)
            if v is None:
                return -1
            tm.year = v - 1900
            want_century = 0
            want_xday = 1
        elif c == "z":
            while at(i) == " ":
                i += 1
            if at(i) not in "+-" or at(i) == "\0":
                return -1
            neg = at(i) == "-"
            i += 1
            k = v = 0
            while k < 4 and "0" <= at(i) <= "9":
                v = v * 10 + ord(at(i)) - 48
                i += 1
                k += 1
            if k != 4 or v % 100 >= 60:
                return -1
            v = (v // 100) * 100 + ((v % 100) * 50) // 30
            if v > 1400:
                _warn("values for %z outside +/-1400 are an error")
                return -1
            off = (v * 3600) // 100
            st[1] = -off if neg else off
        elif c == "Z":
            _error("use of %Z for input is not supported")
        elif c == "O":
            c2 = fmt[f] if f < nf else "\0"
            f += 1
            if c2 in "de" and c2 != "\0":
                v = num(1, 31, 2)
                if v is None:
                    return -1
                tm.mday = v
                have_mday = want_xday = 1
            elif c2 == "H":
                v = num(0, 23, 2)
                if v is None:
                    return -1
                tm.hour = v
                have_I = 0
            elif c2 == "I":
                v = num(1, 12, 2)
                if v is None:
                    return -1
                tm.hour = v % 12
                have_I = 1
            elif c2 == "m":
                v = num(1, 12, 2)
                if v is None:
                    return -1
                tm.mon = v - 1
                have_mon = want_xday = 1
            elif c2 == "M":
                v = num(0, 59, 2)
                if v is None:
                    return -1
                tm.min = v
            elif c2 == "S":
                sv, e = _wcstod(s, i)
                if 0.0 <= sv <= 61.0:
                    tm.sec = int(sv)
                    st[0] = sv
                i = e
            elif c2 in "UW" and c2 != "\0":
                v = num(0, 53, 2)
                if v is None:
                    return -1
                week_no = v
                if c2 == "U":
                    have_uweek = 1
                else:
                    have_wweek = 1
            elif c2 == "V":
                if num(0, 53, 2) is None:
                    return -1
            elif c2 == "w":
                v = num(0, 6, 1)
                if v is None:
                    return -1
                tm.wday = v
                have_wday = 1
            elif c2 == "y":
                v = num(0, 99, 2)
                if v is None:
                    return -1
                tm.year = v if v >= 69 else v + 100
                want_xday = 1
            else:
                return -1
        else:
            return -1

    if have_I and is_pm:
        tm.hour += 12
    if century != -1:
        tm.year = (tm.year % 100 + (century - 19) * 100) if want_century else (century - 19) * 100
    if want_xday and not have_wday:
        if not (have_mon and have_mday) and have_yday:
            yr = 1900 + _yv(tm.year)
            lp = 1 if _isleap(yr) else 0
            if tm.yday > (365 if lp else 364):
                _warn("day-of-year %d in year %d is invalid\n" % (tm.yday + 1, yr))
                t_mon = 12
            else:
                t_mon = 0
                while _MON_YDAY[lp][t_mon] <= tm.yday:
                    t_mon += 1
            if not have_mon:
                tm.mon = t_mon - 1
            if not have_mday:
                tm.mday = tm.yday - _MON_YDAY[lp][t_mon - 1] + 1
        _day_of_the_week(tm)
    if want_xday and not have_yday:
        _day_of_the_year(tm)
    if (have_uweek or have_wweek) and have_wday:
        save_wday, save_mday, save_mon = tm.wday, tm.mday, tm.mon
        w_offset = 0 if have_uweek else 1
        tm.mday = 1
        tm.mon = 0
        _day_of_the_week(tm)
        if have_mday:
            tm.mday = save_mday
        if have_mon:
            tm.mon = save_mon
        if not have_yday:
            tm.yday = (_cmodi(7 - (tm.wday - w_offset), 7) + (week_no - 1) * 7 + save_wday - w_offset)
            if tm.yday < 0:
                tm.yday += 7
        if not have_mday or not have_mon:
            yr = 1900 + _yv(tm.year)
            lp = 1 if _isleap(yr) else 0
            if tm.yday > (365 if lp else 364):
                _warn("(0-based) yday %d in year %d is invalid\n" % (tm.yday, yr))
                t_mon = 12
            else:
                t_mon = 0
                while _MON_YDAY[lp][t_mon] <= tm.yday:
                    t_mon += 1
            if not have_mon:
                tm.mon = t_mon - 1
            if not have_mday:
                tm.mday = tm.yday - _MON_YDAY[lp][t_mon - 1] + 1
        tm.wday = save_wday
    return i


def _validate_tm(tm):
    """validate_tm von datetime.c: 0 gültig, -1 ungültig, > 0 Zahl der Korrekturen (tm wird angepasst)."""
    res = 0
    if tm.sec < 0 or tm.sec > 60:
        res += 1
        tmp = _cdivi(tm.sec, 60)
        tm.sec -= 60 * tmp
        tm.min += tmp
        if tm.sec < 0:
            tm.sec += 60
            tm.min -= 1
    if tm.min < 0 or tm.min > 59:
        res += 1
        tmp = _cdivi(tm.min, 60)
        tm.min -= 60 * tmp
        tm.hour += tmp
        if tm.min < 0:
            tm.min += 60
            tm.hour -= 1
    if tm.hour == 24 and tm.min == 0 and tm.sec == 0:
        tm.hour = 0
        tm.mday += 1
        if 0 <= tm.mon <= 11 and tm.mday > _dim(tm.mon, tm.year):
            tm.mon += 1
            tm.mday = 1
            if tm.mon == 12:
                tm.year += 1
                tm.mon = 0
    elif tm.hour < 0 or tm.hour > 23:
        res += 1
        tmp = _cdivi(tm.hour, 24)
        tm.hour -= 24 * tmp
        tm.mday += tmp
        if tm.hour < 0:
            tm.hour += 24
            tm.mday -= 1
    if tm.mon < 0 or tm.mon > 11:
        res += 1
        tmp = _cdivi(tm.mon, 12)
        tm.mon -= 12 * tmp
        tm.year += tmp
        if tm.mon < 0:
            tm.mon += 12
            tm.year -= 1
    if tm.mday < -1000000 or tm.mday > 1000000:
        return -1
    if abs(tm.mday) > 366:
        res += 1
        while tm.mon > 0:
            tm.mon -= 1
            tm.mday += _dim(tm.mon, tm.year)
        while tm.mday < 1:
            tm.year -= 1
            tm.mday += 366 if _isleap(1900 + tm.year) else 365
        while True:
            tmp = 366 if _isleap(1900 + tm.year) else 365
            if tm.mday <= tmp:
                break
            tm.mday -= tmp
            tm.year += 1
    while tm.mday < 1:
        res += 1
        tm.mon -= 1
        if tm.mon < 0:
            tm.mon += 12
            tm.year -= 1
        tm.mday += _dim(tm.mon, tm.year)
    while True:
        tmp = _dim(tm.mon, tm.year)
        if tm.mday <= tmp:
            break
        res += 1
        tm.mon += 1
        if tm.mon > 11:
            tm.mon -= 12
            tm.year += 1
        tm.mday -= tmp
    return res


def _glibc_fix(tm):
    """glibc_fix von datetime.c: fehlendes Jahr, fehlender Monat oder Tag aus dem heutigen Datum (lokale Zeit); False,
    wenn nur der Tag fehlt."""
    import time as _time
    lt = _time.localtime()
    if tm.year is None:
        tm.year = lt.tm_year - 1900
    if tm.mon is not None and tm.mday is not None:
        return True
    if tm.yday is not None:
        yday, mon = tm.yday, 0
        while True:
            if mon > 11:   # in R über das Monatsende hinaus (undefiniert); hier ungültig
                return False
            tmp = _dim(mon, tm.year)
            if yday < tmp:
                break
            yday -= tmp
            mon += 1
        tm.mon = mon
        tm.mday = yday + 1
        return True
    if tm.mday is None:
        if tm.mon is not None:
            return False
        tm.mday = lt.tm_mday
    if tm.mon is None:
        tm.mon = lt.tm_mon - 1
    return True


def _strptime1(x, fmt, utc=True):
    """Ein Element von as.Date(strptime(x, fmt, tz)): Tage seit 1970-01-01 (float) oder NA_REAL; ``utc`` für tz = "GMT"
    (mit format), sonst wie R die Systemzeitzone (tryFormats; nur für %z wirksam, Entscheidung 108)."""
    if x is None or fmt is None:
        return NA_REAL
    if len(x) > 1000:
        _error("input string is too long")
    if len(fmt) > 1000:
        _error("format string is too long")
    tm = _TM()
    st = [0.0, None]   # psecs, offset
    if _strptime_w(x, 0, fmt, tm, st) < 0:
        return NA_REAL
    if tm.mday == 0:
        tm.mday = None
    if tm.mon is None or tm.mday is None or tm.year is None:
        if not _glibc_fix(tm):
            return NA_REAL
    ptm = tm
    if st[1] is not None:
        tm2 = tm.copy()
        if _validate_tm(tm2) < 0:
            return NA_REAL
        t0 = (tm2.sec + tm2.min * 60 + tm2.hour * 3600
              + _days_from_civil(1900 + tm2.year, tm2.mon + 1, tm2.mday) * 86400)
        if t0 == -1:
            return NA_REAL
        t0 -= st[1]
        ptm = _TM()
        if utc:
            y, m, d = _civil_from_days(t0 // 86400)
        else:   # localtime0(&t0, 1): Systemzeitzone (TZ wie in R)
            import time as _time
            try:
                lt = _time.localtime(t0)
            except (OverflowError, OSError, ValueError):
                return NA_REAL
            y, m, d = lt.tm_year, lt.tm_mon, lt.tm_mday
        ptm.year, ptm.mon, ptm.mday = y - 1900, m - 1, d
    if _validate_tm(tm) != 0:
        return NA_REAL
    if ptm is tm:
        if _validate_tm(tm) < 0:
            return NA_REAL
    return float(_days_from_civil(1900 + ptm.year, ptm.mon + 1, ptm.mday))


def _strptime_vec(xs, fmts, utc=True):
    """as.Date(strptime(x, format)) mit Recycling wie do_strptime (Länge max(n, m), 0 bei n = 0)."""
    n, m = len(xs), len(fmts)
    if m == 0:
        _error("invalid 'format' argument")
    N = 0 if n == 0 else max(n, m)
    return [_strptime1(xs[i % n], fmts[i % m], utc) for i in range(N)]


def _strptime_secs(x, fmt):
    """Sekunden von strptime(x, fmt) (lokal, fehlendes Datum heute) seit Mitternacht des heutigen Tags, für
    as.difftime(x, format) gegen strptime("0:0:0", format); NA_REAL, wenn x nicht passt."""
    if x is None:
        return NA_REAL
    tm = _TM()
    if _strptime_w(x, 0, fmt, tm, [0.0, None]) < 0:
        return NA_REAL
    if tm.mon is None or tm.mday is None or tm.year is None:
        if not _glibc_fix(tm):
            return NA_REAL
    if _validate_tm(tm) != 0:
        return NA_REAL
    t0 = _TM()
    _glibc_fix(t0)
    return float((_days_from_civil(1900 + tm.year, tm.mon + 1, tm.mday) - _days_from_civil(1900 + t0.year, t0.mon + 1,
                                                                                            t0.mday)) * 86400
                 + tm.hour * 3600 + tm.min * 60 + tm.sec)


def _civil_from_days(z):
    """Tage seit 1970-01-01 (ganze Zahl) → (Jahr, Monat, Tag), proleptisch gregorianisch."""
    z += 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return y + (m <= 2), m, d


_MISSING = object()


def _ymd_fast(x, sep):
    """``_strptime_ymd`` als Tag (float) oder NA_REAL, mit R's Längengrenze für den Text."""
    if len(x) > 1000:
        _error("input string is too long")
    t = _strptime_ymd(x, sep)
    return NA_REAL if t is None else float(t)


def _fmt_list(f):
    """Formatangabe für strptime: nur Text (NA wird wie in R als "NA" gelesen), sonst Fehler wie do_strptime."""
    if not isinstance(f, CHR) or len(f) == 0:
        _error("invalid 'format' argument")
    return ["NA" if t is None else t for t in f]


def _as_date_chr(v, fmt=_MISSING, try_formats=None, optional=None):
    """as.Date.character wie R 4.3.3: mit ``format`` strptime je Element (Recycling), sonst charToDate: "" ist NA, das
    erste Element ungleich NA bestimmt das Format aus ``try_formats`` (Standard "%Y-%m-%d", "%Y/%m/%d"), alle werden
    damit gelesen; passt keines, Fehler oder mit ``optional = TRUE`` NA. Seit 1.6.4 mit format, tryFormats und optional
    (C-002, Entscheidung 97; bis 1.6.3 nur die beiden Standardformate)."""
    if fmt is not _MISSING:
        return DAT(_strptime_vec(list(v), _fmt_list(fmt)))
    xs = [None if (x is None or x == "") else x for x in v]
    first = next((x for x in xs if x is not None), None)
    if first is None:
        return DAT([NA_REAL] * len(xs))
    tf = CHR(["%Y-%m-%d", "%Y/%m/%d"]) if try_formats is None else try_formats
    for ff in tf:
        f1 = _fmt_list(_like(tf, [ff]))[0]
        if f1 in ("%Y-%m-%d", "%Y/%m/%d"):   # schneller Weg, gleich strptime für diese Formate (C-021)
            sep = f1[2]
            t = _ymd_fast(first, sep)
            if t == t:
                return DAT([NA_REAL if x is None else _ymd_fast(x, sep) for x in xs])
        elif _strptime1(first, f1) == _strptime1(first, f1):
            return DAT(_strptime_vec(xs, [f1], utc=False))   # strptime(x, ff) ohne tz: Systemzeitzone
    if optional is not None and _cond1(optional):
        return DAT([NA_REAL] * len(xs))
    _error("character string is not in a standard unambiguous format")


def _as_date(v, what="x"):
    """as.Date(v) wie R (Methode nach der Klasse): Datum bleibt, Text über as.Date.character, Zahlen unverändert als
    Tage (seit 1.6.4 ohne Abrunden, C-003), logisch nur aus lauter NA (sonst der Fehler von as.Date.default mit
    ``what`` als Ausdruck)."""
    if isinstance(v, DAT):
        return v
    if isinstance(v, CHR):
        return _as_date_chr(v)
    if isinstance(v, LGL):
        if any(x is not None for x in v):
            _error("do not know how to convert '%s' to class \u201cDate\u201d" % what)
        return DAT([NA_REAL] * len(v))
    if isinstance(v, DIF):
        _error("do not know how to convert '%s' to class \u201cDate\u201d" % what)
    return DAT(_as_num(v))


def _undate(v):
    """unclass(<Date>), unclass(<difftime>): Tage als double mit den Namen (andere Vektoren unverändert)."""
    return _cp(NUM, v) if isinstance(v, (DAT, DIF)) else v


def _na_of(v):
    return NA_REAL if isinstance(v, (NUM, DAT, DIF)) else None


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
    return {LGL: "logical", INT: "integer", NUM: "numeric", CHR: "character", DAT: "Date", DIF: "difftime"}[type(v)]


def _rtypeof(v):
    return {LGL: "logical", INT: "integer", NUM: "double", CHR: "character", DAT: "double", DIF: "double"}[type(v)]


def _like(v, items):
    return type(v)(items)


# seit 1.6.4 (C-006, Entscheidung 111): rep und die Konstruktoren füllen den Ergebnisvektor direkt, ohne zweite Liste
# (bis dahin Liste und Kopie in die Klasse, also doppelter Speicher an der Spitze); dieselben Elemente
def _rep_inplace(r, n):
    r *= n
    return r


def _like_iter(v, it):
    r = type(v)()
    r.extend(it)
    return r


_REP_BLOCK = 1024     # Quellwerte je Teilliste
_REP_TEIL = 65536     # höchstens so viele Werte je Teilliste, darüber itertools.repeat


def _rep_each(x, k, each):
    """x[0 … k-1], jeder Wert ``each``-mal hintereinander, als neuer Vektor vom Typ von x (ohne Namen); Teillisten
    höchstens ``_REP_TEIL`` Werte (seit 1.6.4, Entscheidung 111)."""
    r = type(x)()
    if each <= 0 or k <= 0:
        return r
    if each * _REP_BLOCK <= _REP_TEIL:
        for s in range(0, k, _REP_BLOCK):
            r.extend([x[i] for i in range(s, min(k, s + _REP_BLOCK)) for _ in range(each)])
    else:
        r.extend(_itertools.chain.from_iterable(_itertools.repeat(x[i], each) for i in range(k)))
    return r


def _rep_counts(x, tn):
    """x[i] je ``tn[i]``-mal hintereinander (tn ganze Zahlen >= 0, so lang wie x); Teillisten wie bei _rep_each."""
    r = type(x)()
    n = len(tn)
    for s in range(0, n, _REP_BLOCK):
        e = min(n, s + _REP_BLOCK)
        if sum(tn[s:e]) <= _REP_TEIL:
            r.extend([x[i] for i in range(s, e) for _ in range(tn[i])])
        else:
            r.extend(_itertools.chain.from_iterable(_itertools.repeat(x[i], tn[i]) for i in range(s, e)))
    return r


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
    return _stats.str_collate(a, b)   # stets vorhanden (stats.py; seit 1.6.4 ohne Rückfall, wie Julia)


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


def r_fmod(x1, x2):
    """R's ``myfmod(x1, x2)`` (``x1 %% x2``)."""
    if x2 == 0.0:
        return _R_NAN   # R_NaN (positiv), auch bei NA in x1
    if abs(x2) * _LDBL_EPS > 1 and math.isfinite(x1) and abs(x1) <= abs(x2):
        if abs(x1) == abs(x2):
            return 0.0
        return x1 + x2 if ((x1 < 0 and x2 > 0) or (x2 < 0 and x1 > 0)) else x1
    q = _fdiv(x1, x2)
    if math.isfinite(q) and abs(q) * _LDBL_EPS > 1:
        _warn("probable complete loss of accuracy in modulus")
    # long-double-Teil im C-Kern core/slc_rbase_num.cpp; NaN-Operanden nach der dort beschriebenen Regel
    return _ext.slc_r_fmod_ld(x1, x2)


def r_idiv(x1, x2):
    """R's ``myfloor(x1, x2)`` (``x1 %/% x2``)."""
    q = _fdiv(x1, x2)
    if x2 == 0.0 or abs(q) * _LDBL_EPS > 1 or not math.isfinite(q):
        return q
    if abs(q) < 1:
        if q < 0:
            return -1.0
        return -1.0 if ((x1 < 0 and x2 > 0) or (x1 > 0 and x2 < 0)) else 0.0
    return _ext.slc_r_idiv_ld(x1, x2)   # long-double-Teil im C-Kern core/slc_rbase_num.cpp


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
        return _nanop(y, x)   # seit 1.6.4 wie R_pow (T4-B2): der NaN von y gewinnt, sonst der von x
    if x == -math.inf and 18446744073709551616.0 < y < math.inf:
        # R_pow: (-Inf)^y mit ganzem y ruft myfmod(y, 2), das bei y > 2^64 warnt (seit 1.6.4, T4-R2)
        _warn("probable complete loss of accuracy in modulus")
    return _base.r_pow(x, y)


def _cls(v):
    return "Date" if isinstance(v, DAT) else "difftime" if isinstance(v, DIF) else None


def _ops_method(op, a, b):
    """Methodenwahl von R's DispatchGroup für Ops mit Date und difftime (seit 1.6.4, Entscheidung 105): "Date",
    "difftime" oder "internal" (unterschiedliche Methoden: Warnung „Incompatible methods“, dann die eingebaute
    Rechnung; +.Date und -.Date gehen vor Ops.difftime wie in R)."""
    ca, cb = _cls(a), _cls(b)
    if ca == cb or cb is None:
        return ca
    if ca is None:
        return cb
    meth = lambda c: (("+.Date" if op == "+" else "-.Date" if op == "-" else "Ops.Date") if c == "Date" else  # noqa: E731
                      ("*.difftime" if op == "*" else "/.difftime" if op == "/" else "Ops.difftime"))
    lm, rm = meth(ca), meth(cb)
    if rm == "Ops.difftime" and lm in ("+.Date", "-.Date"):
        return "Date"
    if lm == "Ops.difftime" and rm == "+.Date":
        return "Date"
    _warn('Incompatible methods ("%s", "%s") for "%s"' % (lm, rm, op))
    return "internal"


def _internal_cls(r, a, b):
    """Klasse der eingebauten Rechnung wie R_binary: die des ersten Operanden mit der Länge des Ergebnisses."""
    n = len(r)
    for v in (a, b):
        if len(v) == n and _cls(v) is not None:
            return DAT(r) if isinstance(v, DAT) else DIF(r)
        if len(v) == n:
            return r
    return r


def _round0(v):
    """as.vector(round(<difftime>)) von coerceTimeUnit in +.Date/-.Date (units = "days")."""
    return NUM([float(_fmt.r_round(x, 0.0)) for x in v])


def _difftime_ops(op, a, b):
    """Ops.difftime, *.difftime und /.difftime (R 4.3.3, units = "days")."""
    da, db = isinstance(a, DIF), isinstance(b, DIF)
    if op == "*":
        if da and db:
            _error('both arguments of * cannot be "difftime" objects')
        x, y = (a, b) if da else (b, a)
        return DIF(_arith("*", _undate(y), _undate(x)))
    if op == "/":
        if db:
            _error('second argument of / cannot be a "difftime" object')
        return DIF(_arith("/", _undate(a), _undate(b)))
    if op in ("+", "-"):
        return DIF(_arith(op, _undate(a), _undate(b)))
    _error("'%s' not defined for \"difftime\" objects" % op)


def _arith(op, a, b):
    r = _arith0(op, a, b)
    return _setnm(r, _binnames(a, b, len(r)))


def _arith0(op, a, b):
    if isinstance(a, (DAT, DIF)) or isinstance(b, (DAT, DIF)):
        m = _ops_method(op, a, b)
        if m == "Date":
            return _date_arith(op, a, b)
        if m == "difftime":
            return _difftime_ops(op, a, b)
        return _internal_cls(_arith(op, _undate(a), _undate(b)), a, b)
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
    """``+.Date``, ``-.Date`` und Ops.Date wie R 4.3.3 (seit 1.6.4, C-003/C-004, Entscheidung 97): das Ergebnis ist die
    Rechnung mit den Tagen als double ohne Abrunden; Text ist wie in R ein Fehler (bis 1.6.3 als Zahl gelesen).
    Datum - Datum ergibt die Differenz in Tagen als Zahl (R: difftime mit units = "days")."""
    da, db = isinstance(a, DAT), isinstance(b, DAT)
    if op == "+":
        if da and db:
            _error('binary + is not defined for "Date" objects')
        # difftime: as.vector(round(x)) (coerceTimeUnit, seit 1.6.4, Entscheidung 105)
        ua = _round0(a) if isinstance(a, DIF) else _undate(a)
        ub = _round0(b) if isinstance(b, DIF) else _undate(b)
        return DAT(_arith("+", ua, ub))
    if op == "-":
        if not da:
            _error('can only subtract from "Date" objects')
        if db:
            return DIF(_arith("-", _undate(a), _undate(b)))   # difftime(e1, e2, units = "days")
        return DAT(_arith("-", _undate(a), _round0(b) if isinstance(b, DIF) else b))
    _error('%s not defined for "Date" objects' % op)


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
    r = _compare0(op, a, b)
    return _setnm(r, _binnames(a, b, len(r)))


def _compare0(op, a, b):
    if isinstance(a, (DAT, DIF)) or isinstance(b, (DAT, DIF)):
        m = _ops_method(op, a, b)
        if m == "Date":   # Ops.Date: Text wird Datum
            a = _as_date(a) if isinstance(a, CHR) else a
            b = _as_date(b) if isinstance(b, CHR) else b
        elif m == "difftime" and isinstance(a, DIF) and isinstance(b, DIF):   # coerceTimeUnit: Sekunden
            a = _arith("*", NUM([86400.0]), _undate(a))
            b = _arith("*", NUM([86400.0]), _undate(b))
        return _compare(op, _undate(a), _undate(b))
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
    r = _logic0(op, a, b)
    return _setnm(r, _binnames(a, b, len(r)))


def _logic0(op, a, b):
    if isinstance(a, (DAT, DIF)) or isinstance(b, (DAT, DIF)):
        m = _ops_method(op, a, b)
        if m == "Date":
            _error('%s not defined for "Date" objects' % op)
        if m == "difftime":
            _error("'%s' not defined for \"difftime\" objects" % op)
        a, b = _undate(a), _undate(b)
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
    # seit 1.6.4 (C-089) wie R zuerst der Typ, dann die Länge (bis 1.6.3 bei c("x", "y") || FALSE die Längenmeldung)
    if v is _NULLV or isinstance(v, CHR):
        _error("invalid '%s' type in 'x %s y'" % (which, op))
    if len(v) > 1:
        _error("'length = %d' in coercion to 'logical(1)'" % len(v))
    if len(v) == 0:
        return None
    return _as_lgl(v)[0]


def _in(a, b):
    # seit 1.6.4 wie R match/mtfrm (C-004): ein Datum wird als Text verglichen (as.character), auch gegen Zahlen
    if isinstance(a, (CHR, DAT, DIF)) or isinstance(b, (CHR, DAT, DIF)):
        A = _as_chr(a)
        B = _as_chr(b)
        st = set(B)
        return LGL([x in st for x in A])
    A = _as_num(a)
    B = _as_num(b)
    # über eine Menge (seit 1.6.3; bis 1.6.2 _match_eq gegen jedes Element, seit 1.6.4 entfernt): wie match(x, table)
    # in R – NA trifft nur NA, NaN nur NaN, sonst == (-0 == 0)
    st = {y for y in B if y == y}
    has_na = any(y != y and isna_strict(y) for y in B)
    has_nan = any(y != y and not isna_strict(y) for y in B)
    return LGL([(has_na if isna_strict(x) else has_nan) if x != x else x in st for x in A])


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
    if math.floor(r + 1 + 1.1920928955078125e-07) > _MAX_LEN:   # seit 1.6.4 (C-006, Entscheidung 79)
        _len_error()

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
    r = _not0(v)
    return r if r is v else _setnm(r, _nm(v))


def _not0(v):
    if isinstance(v, CHR) and len(v) == 0 and v is not _NULLV:   # seit 1.6.4 wie R lunary (C-025): logical(0)
        return LGL()
    if isinstance(v, CHR) or v is _NULLV:
        _error("invalid argument type")
    if isinstance(v, DAT):
        _error('unary ! not defined for "Date" objects')
    if isinstance(v, DIF):
        _error("unary '!' not defined for \"difftime\" objects")
    if isinstance(v, LGL):
        return LGL([None if x is None else not x for x in v])
    if isinstance(v, INT):
        return LGL([None if x is None else x == 0 for x in v])
    return LGL([None if x != x else x == 0 for x in v])


def _unary(op, v):
    r = _unary0(op, v)
    return r if r is v else _setnm(r, _nm(v))


def _unary0(op, v):
    if isinstance(v, CHR) or v is _NULLV:
        _error("invalid argument to unary operator")
    if isinstance(v, DAT):
        if op == "+":
            return v
        _error('unary - is not defined for "Date" objects')
    if isinstance(v, DIF):   # Ops.difftime einstellig (seit 1.6.4, Entscheidung 105)
        return v if op == "+" else DIF([-t for t in v])
    if isinstance(v, (LGL, INT)):
        x = _as_int(v)
        return INT([None if t is None else -t for t in x]) if op == "-" else x
    return NUM([-t for t in v]) if op == "-" else v


# ═══════════════════════════════════════════════════════════════════════════
# Indizierung (subscript.c)
# ═══════════════════════════════════════════════════════════════════════════

def _subscript(s, nx, names=None):
    """Index-Vektor (1-basiert, ``None`` = NA) für x[s] mit length(x) == nx; Text über ``names`` (erster Treffer,
    "" und NA treffen nie; seit 1.6.4, C-001)."""
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
        if names is None:
            return [None for _ in s]
        pos = {}
        for i, nm in enumerate(names):
            if nm is not None and nm != "" and nm not in pos:
                pos[nm] = i + 1
        return [None if (t is None or t == "") else pos.get(t) for t in s]
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
    if x is _NULLV:   # seit 1.6.4 wie R (C-025): NULL[...] ist NULL (bis 1.6.3 NA je Index)
        return _NULLV
    nx = len(x)
    xn = _nm(x)
    idx = _subscript(s, nx, xn)
    na = _na_of(x)
    r = _like(x, [na if (i is None or i > nx) else x[i - 1] for i in idx])
    if xn is not None:
        r.names = [None if (i is None or i > nx) else xn[i - 1] for i in idx]
    return r


def _index2(x, s):
    if x is _NULLV:   # seit 1.6.4 wie R (C-025): NULL[[...]] ist NULL (bis 1.6.3 Fehler)
        return _NULLV
    ls = len(s)
    if ls > 1:
        _error("attempt to select more than one element in vectorIndex")
    if ls < 1:
        _error("attempt to select less than one element in get1index")
    nx = len(x)
    indx = -1
    if isinstance(s, CHR):   # seit 1.6.4 über die Namen (genauer Treffer, C-001)
        xn = _nm(x)
        if xn is not None and s[0] is not None:
            indx = next((i for i, nm in enumerate(xn) if nm == s[0]), -1)
    elif isinstance(s, (LGL, INT)):
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
    if isinstance(x, DIF):   # kein [[.difftime: die Klasse fällt weg wie in R (Entscheidung 105)
        return NUM([x[indx]])
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
        if isinstance(v, CHR):   # seit 1.6.4 wie R deparse (C-089; bis 1.6.3 mit \$ wie Julia, ohne Steuerzeichen)
            return "NA_character_" if x is None else _rformat.r_deparse_str(x)
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
    """``na.rm`` der Primitive (sum, min, max, any, all) wie R ``asLogical``: NA (auch Text ohne Wahrheitswert und
    Länge 0) gilt als TRUE (seit 1.6.4, C-008; bis 1.6.3 als FALSE)."""
    if v is None:
        return dflt
    x = _as_lgl(v)[0] if len(v) >= 1 else None
    return True if x is None else x


def _flag_pminmax(v):
    """``na.rm`` von pmin/pmax wie R ``do_pmin``: NA ist ein Fehler (seit 1.6.4, C-008)."""
    if v is None:
        return False
    x = _as_lgl(v)[0] if len(v) >= 1 else None
    if x is None:
        _error("invalid 'na.rm' value")
    return x


def _flag_istrue(v, dflt):
    """``na.rm`` von mean wie R ``isTRUE(na.rm)`` (seit 1.6.4, C-008; z. B. 1 oder "TRUE" gelten nicht)."""
    if v is None:
        return dflt
    return isinstance(v, LGL) and len(v) == 1 and v[0] is True


def _flag_if(v, dflt):
    """``na.rm`` von median, quantile, var, sd wie R ``if (na.rm)`` (seit 1.6.4, C-008: NA, Länge != 1 und Text
    ohne Wahrheitswert sind ein Fehler)."""
    if v is None:
        return dflt
    return bool(_cond1(v))


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


_DIF_MATH = ("abs", "sign", "floor", "ceiling", "trunc", "round", "signif")


def _dif_math(fname, r):
    """Math.difftime: abs, sign, floor, ceiling, trunc, round, signif behalten die Klasse, sonst Fehler wie R."""
    if fname not in _DIF_MATH:
        _error("'%s' not defined for \"difftime\" objects" % fname)
    return DIF(r)


def _date_math(fname):
    """Math.Date (R 4.3.3): Funktionen der Gruppe Math sind für Datumswerte nicht definiert (seit 1.6.4, C-004; bis 1.6.3
    "non-numeric argument to mathematical function")."""
    _error('%s not defined for "Date" objects' % fname)


def _math1(fname, f):
    def g(args, nms, ex):
        a = _prim1(fname, args, nms)
        if isinstance(a, DAT):
            _date_math(fname)
        if isinstance(a, DIF):
            if fname not in _DIF_MATH:
                _dif_math(fname, None)
            return DIF(g([NUM(a)], nms, ex))
        if isinstance(a, CHR) or a is _NULLV:   # NULL seit 1.6.4 wie R (T4-B3; bis dahin numeric(0))
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
    f = _libm._KERN[fname]   # Skalarkern ohne eigene Warnung (seit 1.6.4; RExpr warnt je Ausdruck, C-094)
    if fname in ("log2", "log10"):
        # seit 1.6.4 wie R (C-068, Entscheidung 101): log2/log10 laufen in R über math2/logbase, NA ergibt NA_real_,
        # jedes andere NaN und x < 0 R_NaN (0x7FF8…); bis 1.6.3 NaN unverändert und x < 0 0xFFF8…
        return lambda x: float(f(x))   # Kern _libm._log2/_log10 mit dieser Regel

    def g(x):
        if x != x:
            return x
        r = f(x)
        if r != r:
            return _DEFAULT_NAN
        return float(r)
    return g


def _logbase_nan(x, b):
    """NaN-Regel von R's math2 (arithmetic.c): NA in x oder base ergibt NA_real_, sonst ein NaN R_NaN."""
    return NA_REAL if (isna_strict(x) or isna_strict(b)) else _R_NAN


# seit 1.6.4 wie R (C-031, Entscheidung 100): das Vorzeichen der Null bleibt (C floor/ceil/trunc), z. B. ceiling(-0.5)
# ist -0; bis 1.6.3 über math.floor/ceil/trunc (int) immer +0
def _zsign(r, x):
    return math.copysign(0.0, x) if r == 0 else r


def _ffloor_(x):
    return x if (x != x or math.isinf(x)) else _zsign(float(math.floor(x)), x)


def _fceil_(x):
    return x if (x != x or math.isinf(x)) else _zsign(float(math.ceil(x)), x)


def _ftrunc_(x):
    return x if (x != x or math.isinf(x)) else _zsign(float(math.trunc(x)), x)


def _fsign_(x):
    if x != x:
        return x
    return 1.0 if x > 0 else (-1.0 if x < 0 else 0.0)


_TRUNC_UNITS = ["secs", "mins", "hours", "days", "months", "years"]


def _f_trunc(args, nms, ex):
    """trunc wie R: für Zahlen math1, für ein Datum trunc.Date (seit 1.6.4, C-004; bis 1.6.3 Fehler): Einheiten bis "days"
    über round(x - 0.4999999), "months" und "years" der erste Tag des Monats bzw. Jahres."""
    if args and isinstance(args[0], DAT) and (not nms or nms[0] in (None, "x")):
        w, _, _ = _bind("trunc", args, nms, ex, ["x", "units", "..."])
        x, u = w[0], w[1]
        unit = "secs"
        if u is not None:
            if not isinstance(u, CHR):
                _error("'arg' must be NULL or a character vector")
            if list(u) == _TRUNC_UNITS:
                unit = "secs"
            elif len(u) != 1:
                _error("'arg' must be of length 1")
            else:
                m = [c for c in _TRUNC_UNITS if u[0] is not None and c.startswith(u[0])]
                if u[0] in _TRUNC_UNITS:
                    m = [u[0]]
                if len(m) != 1 or u[0] == "":
                    _error("'arg' should be one of " + ", ".join("\u201c%s\u201d" % c for c in _TRUNC_UNITS))
                unit = m[0]
        if unit in ("months", "years"):
            out = []
            for t in x:
                if math.isfinite(t):
                    yy, mm, _ = _civil_from_days(int(math.floor(t)))
                    out.append(float(_days_from_civil(yy, mm if unit == "months" else 1, 1)))
                else:
                    out.append(NA_REAL)
            return DAT(out)
        return DAT(_f_round([_arith("-", _undate(x), NUM([0.4999999]))], [None], ex))
    if args and isinstance(args[0], DIF):   # Math.difftime: trunc(unclass(x), ...)
        return DIF(_math1("trunc", _ftrunc_)([NUM(args[0])], [None], ex[:1]))
    return _math1("trunc", _ftrunc_)(args, nms, ex)


def _f_abs(args, nms, ex):
    a = _prim1("abs", args, nms)
    if isinstance(a, DAT):
        _date_math("abs")
    if isinstance(a, DIF):
        return DIF(_f_abs([NUM(a)], nms, ex))
    if isinstance(a, CHR) or a is _NULLV:   # NULL seit 1.6.4 wie R (T4-B3; bis dahin integer(0))
        _error("non-numeric argument to mathematical function")
    if isinstance(a, (LGL, INT)):
        return INT([None if x is None else abs(x) for x in _as_int(a)])
    return NUM([abs(v) for v in a])


def _log1(x):
    if x != x:
        return x
    # ohne Warnung der libm (seit 1.6.4, C-094); x < 0 ergibt wie R_log R_NaN (seit 1.6.4, C-068; bis 1.6.3 0xFFF8…)
    return float(_libm._KERN["log"](float(x)))


def _f_log(args, nms, ex):
    v, _, _ = _bind("log", args, nms, ex, ["x", "base"])
    x, b = v
    if x is None:
        _missing_arg("x")
    if isinstance(x, DAT):
        _date_math("log")
    if isinstance(x, DIF):
        _dif_math("log", None)
    # NULL in x, Text oder NULL als base seit 1.6.4 wie R's math2 (T4-B3; bis dahin numeric(0) bzw. als Zahl gerechnet)
    if isinstance(x, CHR) or x is _NULLV or (b is not None and (isinstance(b, CHR) or b is _NULLV)):
        _error("non-numeric argument to mathematical function")
    xn = _as_num(x)
    if b is None:
        r = NUM([_log1(t) for t in xn])
    else:
        bb = list(_as_num(b))   # seit 1.6.4 wie R: base wird recycelt, Länge 0 ergibt numeric(0) (C-008)
        if not bb or not xn:
            return NUM()
        n = max(len(xn), len(bb))
        xn = [xn[i % len(xn)] for i in range(n)]
        bb = [bb[i % len(bb)] for i in range(n)]
        r = NUM([_logb(xn[i], bb[i]) for i in range(n)])
        # Warnung wie math2 je Paar nach dem Recycling: nur wenn weder x noch base NaN ist (seit 1.6.4, T4-B4)
        if any(r[i] != r[i] and xn[i] == xn[i] and bb[i] == bb[i] for i in range(n)):
            _warn("NaNs produced")
        return r
    return _nan_warn(xn, r)


def _logb(x, b):
    # seit 1.6.4 wie R math2/logbase (C-068): NaN in x oder base nach _logbase_nan, sonst der Kern (R_log(x)/R_log(base)
    # mit den NaN-Bits der Division; bis 1.6.3 NaN in x unverändert und jedes NaN-Ergebnis 0xFFF8…)
    if x != x or b != b:
        return _logbase_nan(x, b)
    return float(_libm._logb(float(x), b))   # ohne Warnung der libm (seit 1.6.4, C-094)


def _f_round(args, nms, ex, signif=False):
    v, _, _ = _bind("signif" if signif else "round", args, nms, ex, ["x", "digits"])
    x, d = v
    if x is None:
        _missing_arg("x")
    if isinstance(x, DIF):
        return DIF(_f_round([NUM(x)] + list(args[1:]), nms, ex, signif=signif))
    if isinstance(x, DAT):
        if signif:
            _date_math("signif")
        # round.Date (seit 1.6.4, C-004): .Date(round(unclass(x), digits))
        return DAT(_f_round([_undate(x), d], [None, "digits"], ex))
    # seit 1.6.4 wie R's do_Math2/math2 (T4-B3): erst die Länge von digits, dann NULL bzw. Text in x oder digits (bis
    # dahin numeric(0) bzw. digits als Zahl gerechnet)
    if d is not None and len(d) == 0:
        _error("invalid second argument of length 0")
    if isinstance(x, CHR) or x is _NULLV or isinstance(d, CHR):
        _error("non-numeric argument to mathematical function")
    xn = _as_num(x)
    dv = [6.0 if signif else 0.0] if d is None else list(_as_num(d))
    if not xn:
        return NUM()
    n = max(len(xn), len(dv))   # seit 1.6.4 wie R Math2: digits wird recycelt (C-008)
    f = _fmt.signif if signif else _fmt.r_round
    return NUM([float(f(xn[i % len(xn)], dv[i % len(dv)])) for i in range(n)])


def _f_isna(args, nms, ex):
    v = _prim1("is.na", args, nms)
    if isinstance(v, (NUM, DAT, DIF)):   # DAT, DIF wie double (seit 1.6.4, C-004)
        return LGL([x != x for x in v])
    return LGL([x is None for x in v])


def _f_isnan(args, nms, ex):
    v = _prim1("is.nan", args, nms)
    if isinstance(v, (NUM, DAT, DIF)):
        return LGL([x != x and not isna_strict(x) for x in v])
    return LGL([False for _ in v])


def _f_isfinite(args, nms, ex):
    v = _prim1("is.finite", args, nms)
    if isinstance(v, (NUM, DAT, DIF)):   # seit 1.6.4 wie R (C-004; bis 1.6.3 für ein Datum immer FALSE)
        return LGL([math.isfinite(x) for x in v])
    if isinstance(v, (LGL, INT)):
        return LGL([x is not None for x in v])
    return LGL([False for _ in v])


def _f_isinfinite(args, nms, ex):
    v = _prim1("is.infinite", args, nms)
    if isinstance(v, (NUM, DAT, DIF)):
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
    # seit 1.6.4 (C-025) wie R rep(yes, length.out = len): ein leerer Vektor ergibt NA seines Typs, NULL eine Warnung
    # und den Fehler von ans[ypos] <- NULL (bis 1.6.3 bei jedem leeren Wert der Fehler)
    if ypos:
        if yes is None:
            _missing_arg("yes")
        if yes is _NULLV:
            _warn("'x' is NULL so the result will be NULL")
            _error("replacement has length zero")
        kind = max(kind, _rtype(yes))
        for i in ypos:
            ans[i] = (yes, _rec(yes, i) if len(yes) else _na_of(yes))
    if npos:
        if no is None:
            _missing_arg("no")
        if no is _NULLV:
            _warn("'x' is NULL so the result will be NULL")
            _error("replacement has length zero")
        kind = max(kind, _rtype(no))
        for i in npos:
            ans[i] = (no, _rec(no, i) if len(no) else _na_of(no))

    def el(a):
        if a is None:
            return None
        return _coerce(_undate(_like(a[0], [a[1]])), kind)[0]   # Datum als Zahl wie R (seit 1.6.4, C-004)

    if kind == 4:
        return CHR([el(a) for a in ans])
    if kind == 3:
        return NUM([NA_REAL if a is None else el(a) for a in ans])
    if kind == 2:
        return INT([el(a) for a in ans])
    return LGL([el(a) for a in ans])


def _f_pminmax(args, nms, ex, greater):
    narm = False
    narm_raw = None
    xs = []
    for a, nm in zip(args, nms):
        if nm == "na.rm":
            narm_raw = a
        elif a is not None:
            xs.append(a)
    if narm_raw is not None and not any(isinstance(x, (DAT, DIF)) for x in xs):
        narm = _flag_pminmax(narm_raw)
    if not xs:
        _error("no arguments")
    if any(isinstance(x, (DAT, DIF)) for x in xs):
        return _pminmax_obj(xs, narm_raw, greater)
    if any(isinstance(x, CHR) for x in xs):
        # seit 1.6.4 wie R do_pmin für Text (C-008): Vergleich über die Kollation, NA-Regel wie bei Zahlen
        cs = [_as_chr(x) for x in xs]
        if any(len(c) == 0 for c in cs):
            return CHR()
        n = max(len(c) for c in cs)
        out = [cs[0][i % len(cs[0])] for i in range(n)]
        for c in cs[1:]:
            for i in range(n):
                a_, b_ = out[i], c[i % len(c)]
                better = b_ is not None and a_ is not None and (_scoll(b_, a_) > 0 if greater else _scoll(b_, a_) < 0)
                if (narm and a_ is None) or better or (not narm and b_ is None):
                    out[i] = b_
        return _setnm(CHR(out), _nm(xs[0]) if len(xs[0]) == n else None)
    if any(isinstance(x, CHR) for x in xs):
        _error("invalid input type")
    kind = max(_rtype(x) for x in xs)
    if any(len(x) == 0 for x in xs):
        return NUM() if kind == 3 else INT()
    arrs = [np.array(_as_num(x), dtype=np.float64) for x in xs]
    r = _base.pmax(*arrs, na_rm=narm) if greater else _base.pmin(*arrs, na_rm=narm)
    r = NUM(np.atleast_1d(np.asarray(r, dtype=np.float64)).tolist())   # tolist: dieselben float (seit 1.6.4, C-071)
    if kind != 3:
        r = INT([None if t != t else int(t) for t in r])
    # mostattributes(mmm) <- attributes(elts[[1L]]): Namen des ersten Arguments bei gleicher Länge (seit 1.6.4, C-001)
    return _setnm(r, _nm(xs[0]) if len(xs[0]) == len(r) else None)


def _rep_len(v, n):
    vn = _nm(v)
    if not len(v):
        return _setnm(_like(v, [_na_of(v)] * n), None if vn is None else [None] * n)
    return _setnm(_like(v, [v[i % len(v)] for i in range(n)]), None if vn is None else [vn[i % len(v)] for i in range(n)])


def _isna_vec(v):
    return [_isna_el(x) for x in v]


def _subassign(x, mask, value):
    """``x[mask] <- value[mask]`` (value gleich lang oder Länge 1) wie R: in ein Datum über ``[<-.Date`` (Wert mit
    as.Date), sonst über den höheren Typ."""
    if isinstance(x, DAT):
        if not any(mask):   # [<-.Date: if(!length(value)) return(x)
            return x
        vv = _as_date(value, "value")
        out = list(x)
        for i, m in enumerate(mask):
            if m:
                out[i] = vv[i % len(vv)]
        return _setnm(DAT(out), _nm(x))
    if isinstance(x, DIF):   # [<-.difftime: Werte als Zahl, Klasse bleibt
        vv = _undate(value)
        if isinstance(vv, CHR):
            return _subassign(NUM(x), mask, vv)
        vv = _as_num(vv)
        out = list(x)
        for i, m in enumerate(mask):
            if m:
                out[i] = vv[i % len(vv)]
        return _setnm(DIF(out), _nm(x))
    vv = _undate(value)
    t = max(_rtype(x), _rtype(vv))
    xx = _coerce(x, t)
    vv = _coerce(vv, t)
    out = list(xx)
    for i, m in enumerate(mask):
        if m:
            out[i] = vv[i % len(vv)]
    return _setnm(type(xx)(out), _nm(x))


def _pminmax_obj(xs, narm, greater):
    """pmin/pmax mit einem Datum wie R 4.3.3 (Zweig für Objekte in pmax.R, seit 1.6.4, C-004; bis 1.6.3 Fehler):
    Recycling mit Warnung „an argument will be fractionally recycled“, Vergleich über Ops.Date (Text wird Datum),
    Ergebnis mit der Klasse des ersten Arguments."""
    mmm = xs[0]
    has_na = False
    for each in xs[1:]:
        l1, l2 = len(each), len(mmm)
        if l2 and (l2 < l1 or not l1):
            if l1 % l2:
                _warn("an argument will be fractionally recycled")
            mmm = _rep_len(mmm, l1)
        elif l1 and (l1 < l2 or not l2):
            if l2 % l1:
                _warn("an argument will be fractionally recycled")
            each = _rep_len(each, l2)
        na_m = _isna_vec(mmm)
        na_e = _isna_vec(each)
        if has_na or any(na_m) or any(na_e):
            has_na = True
            if any(na_m):
                mmm = _subassign(mmm, na_m, each)
            if any(na_e):
                each = _subassign(each, na_e, mmm)
        ch = _compare("<" if greater else ">", mmm, each)
        mmm = _subassign(mmm, [c is True for c in ch], each)
        if has_na:   # if (has.na && !na.rm) mmm[na.m | na.e] <- NA
            keep_na = _scalar_lgl(_not(LGL([False]) if narm is None else narm), "&&", "y")
            if keep_na is None:
                _error("missing value where TRUE/FALSE needed")
            if keep_na:
                mmm = _subassign(mmm, [a or b for a, b in zip(na_m, na_e)], LGL([None]))
        # mostattributes(mmm) <- attributes(elts[[1L]]): Namen nur bei gleicher Länge
        mmm = _setnm(type(mmm)(mmm), _nm(xs[0]) if len(xs[0]) == len(mmm) else None)
    return mmm


def _dif_summary(vals):
    """Argumente von Summary.difftime: alle müssen difftime sein (sonst wie R der Fehler des Einheitenvergleichs)."""
    if not all(isinstance(v, DIF) for v in vals):
        _error("comparison of these types is not implemented")
    return [NUM(v) for v in vals]


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
    # Summary.Date nur, wenn das erste Argument ein Datum ist (R wählt die Methode nach dem ersten; seit 1.6.4, C-004)
    if vals and isinstance(vals[0], DAT):
        _error('%s not defined for "Date" objects' % ("any" if isany else "all"))
    if vals and isinstance(vals[0], DIF):
        _error("'%s' not defined for \"difftime\" objects" % ("any" if isany else "all"))
    for v in vals:
        if isinstance(v, (CHR, NUM, DAT)):
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
    if vals and isinstance(vals[0], DAT):   # Summary.Date nach dem ersten Argument (seit 1.6.4, C-004)
        _error('sum not defined for "Date" objects')
    if vals and isinstance(vals[0], DIF):   # Summary.difftime (Entscheidung 105)
        return DIF(_f_sum(_dif_summary(vals) + [LGL([narm])], [None] * len(vals) + ["na.rm"], ex))
    vals = [_undate(v) for v in vals]
    for v in vals:
        if isinstance(v, CHR):
            _error("invalid 'type' (character) of argument")
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
    if vals and isinstance(vals[0], DIF):   # Summary.difftime (Entscheidung 105)
        return DIF(_f_minmax(_dif_summary(vals) + [LGL([narm])], [None] * len(vals) + ["na.rm"], ex, ismax))
    if vals and isinstance(vals[0], DAT):
        # Summary.Date (seit 1.6.4, C-004): Methode nach dem ersten Argument, .Date(NextMethod()) über alle Argumente
        # (bis 1.6.3 nur, wenn alle Argumente Datumswerte waren); mit Text bleibt das Ergebnis Text (R: Datum mit Text)
        r = _f_minmax([_undate(v) for v in vals] + [LGL([narm])], [None] * len(vals) + ["na.rm"], ex, ismax)
        return DAT(_as_num(r)) if not isinstance(r, CHR) else r
    anstype = 2
    icum = -_IMAX - 1 if ismax else _IMAX
    icum_na = False
    zcum = -math.inf if ismax else math.inf
    scum = None
    empty = True
    for v in vals:
        if isinstance(v, (DAT, DIF)):
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
    if isinstance(x, DIF):   # mean.difftime (Entscheidung 105)
        return DIF(_f_mean([_as_num(x), v[1], v[2]], [None, "trim", "na.rm"], ex))
    if isinstance(x, DAT):   # mean.Date: .Date(mean(unclass(x), ...)) (seit 1.6.4 ohne Abrunden, C-003)
        return DAT(_f_mean([_as_num(x), v[1], v[2]], [None, "trim", "na.rm"], ex))
    if isinstance(x, CHR) or x is _NULLV:
        _warn("argument is not numeric or logical: returning NA")
        return NUM([NA_REAL])
    narm = _flag_istrue(v[2], False)
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
    narm = _flag_if(v[1], False)
    if x is _NULLV:   # seit 1.6.4 wie R (T4-B3): median(NULL) ist x[NA_integer_], also NULL (bis dahin NA)
        return _NULLV
    if isinstance(x, (DAT, DIF)):   # median.default mit Datum bzw. difftime (seit 1.6.4 ohne Abrunden, C-003)
        return type(x)(_f_median([_as_num(x), v[1]], [None, "na.rm"], ex))
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
    narm = _flag_if(v[2], False)
    if x is _NULLV:   # seit 1.6.4 wie R's C_cov (T4-B3; bis dahin NA), auch mit y (K43 RS)
        _error("'x' is NULL")
    # y = NULL ist R's Vorgabe, also wie ohne y (seit 1.6.4, K43 RS, Entscheidung 60; bis dahin „nicht unterstützt“)
    if v[1] is not None and v[1] is not _NULLV:
        _error("RExpr: var(x, y) wird nicht unterstützt")
    # ein Datum wie double (R 4.3.3 var(<Date>); seit 1.6.4, C-004, bis 1.6.3 Fehler "is.atomic(x) is not TRUE")
    return NUM([float(_stats.var(_num_arg(x), na_rm=narm))])


def _f_sd(args, nms, ex):
    v, _, _ = _bind("sd", args, nms, ex, ["x", "na.rm"])
    x = v[0]
    if x is None:
        _missing_arg("x")
    narm = _flag_if(v[1], False)
    return NUM([float(_stats.sd(_num_arg(x), na_rm=narm))])


def _f_quantile(args, nms, ex):
    v, _, _ = _bind("quantile", args, nms, ex, ["x", "probs", "na.rm", "names", "type", "digits", "..."])
    x = v[0]
    if x is None:
        _missing_arg("x")
    probs = [0.0, 0.25, 0.5, 0.75, 1.0] if v[1] is None else list(_as_num(v[1]))
    narm = _flag_if(v[2], False)
    # seit 1.6.4 type wie R (C-028): Text, Wahrheitswert, NA, gebrochene Zahl über _stats.quantile_type
    typ = 7 if v[4] is None else (list(v[4]) if isinstance(v[4], CHR) else [float(t) for t in _as_num(v[4])])
    if isinstance(x, CHR):
        xn = CHR([t for t in x if t is not None]) if narm else x
        if any(t is None for t in xn):
            _error("missing values and NaN's not allowed if 'na.rm' is FALSE")
        _error("non-numeric argument to binary operator")
    xv = np.array(_as_num(x), dtype=np.float64)
    r = _stats.quantile(xv, np.array(probs, dtype=np.float64), na_rm=narm, names=False, type=typ)
    r = NUM([float(t) for t in np.atleast_1d(np.asarray(r, dtype=np.float64))])
    if isinstance(x, DAT):
        _quantile_date_check(xv, probs, narm, typ)
        r = DAT(r)
    elif isinstance(x, DIF):   # *.difftime rechnet; Klasse bleibt (Entscheidung 105)
        r = DIF(r)
    # seit 1.6.4 wie R (C-001): names = TRUE gibt die Wahrscheinlichkeiten als Namen ("25%", format_perc)
    nmv = LGL([True]) if v[3] is None else v[3]
    use = _scalar_lgl(nmv, "&&")
    if use is None and len(nmv):
        _error("missing value where TRUE/FALSE needed")
    if use and probs:
        dg = NUM([7.0]) if v[5] is None else v[5]
        if not isinstance(dg, (NUM, INT, DAT, DIF)) or isinstance(dg, DAT):
            _error("is.numeric(digits) is not TRUE")
        if not all(t is not None and t == t and t >= 1 for t in _as_num(dg)):
            _error("digits >= 1 is not TRUE")
        r = _setnm(r, _format_perc(probs, _as_num(dg)[0]))
    return r


def _format_perc(probs, digits):
    """format_perc von R 4.3.3: formatC(100 * p, format = "fg", width = 1, digits) bei weniger als 100 Werten, sonst
    format(…, trim = TRUE, digits); NA ergibt ""."""
    x = np.array([100.0 * p for p in probs], dtype=np.float64)
    if len(probs) < 100:
        txt = _fmt.formatC(x, format="fg", width=1, digits=int(digits))
    else:
        txt = _fmt.format(x, trim=True, digits=int(digits))
    txt = [txt] if isinstance(txt, str) else list(txt)
    return ["" if p != p else t + "%" for p, t in zip(probs, txt)]


def _quantile_date_check(xv, probs, narm, typ):
    """quantile.default mit einem Datum (R 4.3.3, seit 1.6.4, C-004): Typ 7 rechnet immer (1 - h) * x, die übrigen
    Typen nur bei Zwischenwerten; dort meldet Ops.Date "* not defined for \"Date\" objects" (bis 1.6.3 gerechnet)."""
    t = typ[0] if isinstance(typ, list) and typ else typ
    try:
        t = int(float(t))
    except (TypeError, ValueError):
        return
    if t == 7:
        _error('* not defined for "Date" objects')
    x = sorted(v for v in xv.tolist() if not (narm and v != v))
    n = len(x)
    xp = ([x[0]] * 2 if n else [math.nan] * 2) + x + ([x[-1]] * 2 if n else [math.nan] * 2)
    fuzz = 4 * 2.220446049250313e-16
    for p in probs:
        pok = p == p
        if t <= 3:
            nppm = n * p - 0.5 if t == 3 else n * p
            if not pok:
                h = math.nan if t == 2 else 1.0
                j = None
            else:
                j = math.floor(nppm)
                h = ((nppm > j) + 1) / 2 if t == 2 else 0.0
        else:
            a, b = {4: (0.0, 1.0), 5: (0.5, 0.5), 6: (0.0, 0.0), 8: (1 / 3, 1 / 3), 9: (3 / 8, 3 / 8)}.get(t, (0.0, 0.0))
            nppm = a + p * (n + 1 - a - b)
            j = math.floor(nppm + fuzz) if pok else None
            h = nppm - j if pok else math.nan
            if pok and abs(h) < fuzz:
                h = 0.0
        if j is None:
            other = None if (h != h or 0 < h < 1) else False
        else:
            j = int(j)
            lo, hi = xp[j + 1] if 0 <= j + 1 < len(xp) else math.nan, xp[j + 2] if 0 <= j + 2 < len(xp) else math.nan
            ne = None if (lo != lo or hi != hi) else lo != hi
            other = False if not (0 < h < 1) else ne
        if other is None or other:
            _error('* not defined for "Date" objects')


def _c_names(args, nms):
    """Namen von c() wie R (bind.c NewExtractNames): Argumentname und innere Namen als "a.x", ohne inneren Namen "a1",
    "a2" (bei Länge 1 "a"); ohne Argumentname die inneren Namen bzw. "". None, wenn nichts benannt ist."""
    if not any(nm is not None for a, nm in zip(args, nms) if a is not None and len(a)) and \
            not any(_nm(a) is not None for a in args if a is not None):
        return None
    out = []
    for a, tag in zip(args, nms):
        if a is None or len(a) == 0:
            continue
        inner = _nm(a)
        m = len(a)
        for j in range(m):
            vn = None if inner is None else inner[j]
            if tag:
                if vn is not None and vn != "":
                    out.append(tag + "." + vn)
                elif inner is not None and vn is None:
                    out.append(tag + ".NA")
                else:
                    out.append(tag if m == 1 else "%s%d" % (tag, j + 1))
            else:
                out.append("" if inner is None else vn)
    return out


def _f_c(args, nms, ex):
    return _setnm(_f_c0(args, nms, ex), _c_names(args, nms))


def _f_c0(args, nms, ex):
    vals = [a for a in args if a is not None and not (isinstance(a, LGL) and len(a) == 0)]
    if not vals:
        return _NULLV
    if isinstance(args[0], DAT):   # c.Date: unclass(as.Date(e)) je Argument (seit 1.6.4 ohne Abrunden, C-003)
        out = DAT()
        for a in vals:
            out.extend(_as_date(a, "e"))
        return out
    if isinstance(args[0], DIF):   # c.difftime: as.difftime(e, units = "days") je Argument (Entscheidung 105)
        out = DIF()
        for a in vals:
            out.extend(_as_difftime(a))
        return out
    kind = max(_rtype(v) for v in vals)
    out = []
    for v in vals:
        out.extend(_coerce(_as_num(v) if isinstance(v, DAT) else v, kind))
    return {1: LGL, 2: INT, 3: NUM, 4: CHR}[kind](out)


def _as_difftime(v):
    """as.difftime(v, units = "days") für c.difftime: Zahlen bleiben, Text über strptime(v, "%X") gegen 0:0:0 (wie R,
    Zeit des Tages als Bruchteil eines Tages), sonst der Fehler von as.difftime."""
    if isinstance(v, DIF):
        return v
    if isinstance(v, (NUM, INT)):
        return DIF(_as_num(v))
    if isinstance(v, CHR):
        out = DIF()
        for x in v:
            t = _strptime_secs(x, "%X")
            out.append(_arith("-", NUM([t]), NUM([0.0]))[0] if t != t else t / 86400.0)
        return out
    _error("'tim' is not character or numeric")


def _f_length(args, nms, ex):
    v = _prim1("length", args, nms)
    return INT([len(v)])


def _textwidth(s):
    """``nchar(s, type = "width")``: Breite je Zeichen wie R (seit 1.6.3 dieselbe Tabelle wie ``fmt.nchar``)."""
    return sum(_fmt._wcwidth(ord(ch)) for ch in s)


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
    return NUM() if v[0] is None else _strip(_as_num(v[0]))


def _f_asint(args, nms, ex):
    v, _, _ = _bind("as.integer", args, nms, ex, ["x", "..."])
    return INT() if v[0] is None else _strip(_as_int(v[0]))


def _f_aslgl(args, nms, ex):
    v, _, _ = _bind("as.logical", args, nms, ex, ["x", "..."])
    return LGL() if v[0] is None else _strip(_as_lgl(v[0]))


def _f_aschr(args, nms, ex):
    v, _, _ = _bind("as.character", args, nms, ex, ["x", "..."])
    return CHR() if v[0] is None else _strip(_as_chr(v[0]))


def _f_asdate(args, nms, ex):
    """as.Date wie R 4.3.3 mit den Methoden für Text (format, tryFormats, optional), Zahlen (origin) und den Rest (seit
    1.6.4, C-002, Entscheidung 97; bis 1.6.3 fielen die weiteren Argumente still weg)."""
    v, _, _ = _bind("as.Date", args, nms, ex, ["x", "..."])
    x = v[0]
    if x is None:
        _missing_arg("x")
    if isinstance(x, DAT):
        return x
    if isinstance(x, CHR):
        w, _, _ = _bind("as.Date", args, nms, ex, ["x", "format", "tryFormats", "optional", "..."])
        r = _as_date_chr(x, _MISSING if w[1] is None else w[1], w[2], w[3])
        xn = _nm(x)   # strptime behält die Namen, bei längerem format wiederholt (seit 1.6.4, C-001)
        return _setnm(r, None if xn is None or not len(x) else [xn[i % len(x)] for i in range(len(r))])
    if isinstance(x, (NUM, INT)):
        # as.Date.numeric(x, origin, ...): ohne origin .Date(x), sonst as.Date(origin, ...) + x
        idx = [None if a is None else INT([i]) for i, a in enumerate(args)]
        w, rest, _ = _bind("as.Date", idx, nms, ex, ["x", "origin", "..."])
        if w[1] is None:
            return _setnm(DAT(_as_num(x)), _nm(x))
        ri = [t[0] for t in rest]
        o = _f_asdate([args[w[1][0]]] + [args[i] for i in ri], [None] + [nms[i] for i in ri],
                      [Node("sym", "origin")] + [ex[i] for i in ri])
        return _arith("+", o, x)
    # as.Date.default: logisch nur aus lauter NA, NULL ergibt ein leeres Datum
    if isinstance(x, LGL) and all(t is None for t in x):
        return DAT([NA_REAL] * len(x))
    i = next((k for k, nm in enumerate(nms) if nm == "x"), None)
    if i is None:
        i = next((k for k, nm in enumerate(nms) if nm is None), 0)
    _error("do not know how to convert '%s' to class \u201cDate\u201d" % _deparse(ex[i]))


def _f_cumsum(args, nms, ex):
    x = _prim1("cumsum", args, nms)
    if isinstance(x, DAT):
        _date_math("cumsum")
    if isinstance(x, DIF):
        _dif_math("cumsum", None)
    if x is _NULLV:   # seit 1.6.4 wie R (C-025): cumsum(NULL) ist numeric(0)
        return NUM()
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
    # seit 1.6.4 wie R (C-068, Entscheidung 101): die Bits kommen allein vom Kern (long double wie cum.c); bis 1.6.3
    # setzte ein Nachlauf ab dem ersten NaN 0xFFF8… bzw. NA_REAL
    return NUM([float(t) for t in _base.r_cumsum(xs)])


def _f_xor(args, nms, ex):
    v, _, _ = _bind("xor", args, nms, ex, ["x", "y"])
    if v[0] is None:
        _missing_arg("x")
    if v[1] is None:
        _missing_arg("y")
    a = _logic("|", v[0], v[1])
    b = _logic("&", v[0], v[1])
    return _setnm(LGL([None if (p is None or q is None) else (p and not q) for p, q in zip(a, b)]), _nm(a))


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


def _vec_size(v):
    """Länge für ``vector(mode, length)`` wie R's do_makevector mit asVecSize (seit 1.6.4, T4-B5; bis dahin jede
    Zahl außer NA/NaN, auch logisch, und Fehler „invalid 'length' argument“ für NA und negative Werte): Länge des
    Arguments ≠ 1 oder logisch: „invalid 'length' argument“; ganzzahliges NA: „vector size cannot be NA“; Zahl oder Text
    (Text mit der Warnung der Umwandlung): NaN „… NA/NaN“, ±Inf „… infinite“, über R_XLEN_T_MAX „… too large“, dann zur
    Null hin abgeschnitten; danach < 0 wieder „invalid 'length' argument“."""
    if len(v) != 1 or isinstance(v, LGL):
        _error("invalid 'length' argument")
    if isinstance(v, INT):
        if v[0] is None:
            _error("vector size cannot be NA")
        n = v[0]
    else:
        d = _as_num(v)[0]   # Text mit Warnung wie asReal
        if d != d:
            _error("vector size cannot be NA/NaN")
        if math.isinf(d):
            _error("vector size cannot be infinite")
        if d > 4503599627370496.0:   # R_XLEN_T_MAX
            _error("vector size specified is too large")
        n = int(math.trunc(d))
    if n < 0:
        _error("invalid 'length' argument")
    return n


def _f_vector(fname, mk):
    def g(args, nms, ex):
        v, _, _ = _bind(fname, args, nms, ex, ["length"])
        n = 0 if v[0] is None else _vec_size(v[0])
        if n > _MAX_LEN:   # seit 1.6.4 (C-006, Entscheidung 79)
            _len_error()
        return mk(n)
    return g


def _first(a):
    """Erstes Element von a als Vektor gleichen Typs (leer bleibt leer), wie R's asReal/asInteger nur das erste Element
    umwandeln (Warnung der Umwandlung nur dafür)."""
    return a if len(a) <= 1 else type(a)(a[:1])


def _f_rep(args, nms, ex):
    v, _, _ = _bind("rep", args, nms, ex, ["x", "times", "length.out", "each"])
    x = v[0]
    if x is None:
        return LGL()
    # seit 1.6.4 in der Reihenfolge von R do_rep (K43 RS, Entscheidungen 60 und 157): erst length.out, dann each, je mit
    # „first element used of '…' argument“, wenn die Länge nicht 1 ist (auch NULL); umgewandelt wird nur das erste
    # Element (bis dahin each vor length.out, ohne die Warnung, ganzer Vektor umgewandelt)
    lx = len(x)
    lo = None
    if v[2] is not None:
        lv = _as_num(_first(v[2]))
        # seit 1.6.4 wie R do_rep (C-008, C-025): NA und ±Inf gelten als fehlend, eine endliche Länge wird
        # abgeschnitten (-0.5 ergibt 0), unter 0 ist sie ein Fehler (bis 1.6.3 außerhalb von int als fehlend)
        if lv and math.isfinite(lv[0]):
            lo = int(math.trunc(lv[0]))
            if lo < 0:
                _error("invalid 'length.out' argument")
        if len(v[2]) != 1:
            _warn("first element used of 'length.out' argument")
    each = 1
    if v[3] is not None:
        e = _as_num(_first(v[3]))
        # seit 1.6.4 wie R (C-025): NA und ±Inf gelten als 1 (bis 1.6.3 OverflowError bei Inf)
        each = 1 if (not e or not math.isfinite(e[0])) else int(math.trunc(e[0]))
        if len(v[3]) != 1:
            _warn("first element used of 'each' argument")
    if each < 0:
        _error("invalid 'each' argument")
    # seit 1.6.4 wie R (K43 RS, Entscheidungen 60 und 157): bei leerem x prüft R times nicht; NULL bleibt NULL (mit
    # length.out > 0 die Warnung von R), sonst x, mit length.out > 0 auf diese Länge mit NA aufgefüllt (Namen "")
    # (bis dahin „invalid 'times' argument“ bzw. logical(0) für NULL)
    if lx == 0:
        if x is _NULLV:
            if lo is not None and lo > 0:
                _warn("'x' is NULL so the result will be NULL")
            return _NULLV
        if lo is not None and lo > 0:
            if lo > _MAX_LEN:
                _len_error()
            return _rep_inplace(_like(x, [_na_of(x)]), lo)
        return _like(x, [])
    # seit 1.6.4 (C-006, Entscheidung 79): Ergebnislänge vor dem Anlegen geprüft; x wird erst ausgedehnt, wenn das
    # Ergebnis höchstens _MAX_LEN Werte hat (mit length.out ohne Ausdehnen, wie R)
    if lo is not None:
        if lo > _MAX_LEN:
            _len_error()
        m = lx * each
        if m == 0:   # each = 0: wie R ein Fehler, wenn length.out > 0 (seit 1.6.4, K43 RS; bis dahin NA aufgefüllt)
            if lo > 0:
                _error("invalid 'each' argument")
            return _like(x, [])
        if lo == 0:
            return _like(x, [])
        if m <= lo:   # Ergebnis = ausgedehntes x im Kreis, im Vektor selbst verlängert
            r = _rep_each(x, lx, each)
            q, rest = divmod(lo, m)
            r *= q
            r.extend(_itertools.islice(r, rest))
            return r
        if each == 1:
            return _like_iter(x, _itertools.islice(x, lo))
        k = -(-lo // each)   # Werte x[0 … k-1], der letzte seltener
        r = _rep_each(x, k - 1, each)
        r.extend(_itertools.repeat(x[k - 1], lo - (k - 1) * each))
        return r
    tn = _as_num(INT([1]) if v[1] is None else v[1])
    # seit 1.6.4 wie R do_rep (C-025): times endlich mit -1 < times < 2^52 + 1, abgeschnitten (-0.5 ergibt 0);
    # bis 1.6.3 OverflowError bei Inf und Fehler bei -1 < times < 0
    ok_t = lambda t: -1.0 < t < 4503599627370497.0   # noqa: E731 (NaN ist nicht im Bereich)
    if len(tn) == 1:
        if not ok_t(tn[0]):
            _error("invalid 'times' argument")
        t = int(math.trunc(tn[0]))
        if lx * each * t > _MAX_LEN:
            _len_error()
        if t == 0:
            return _like(x, [])
        if each != 1:   # x ausgedehnt ist schon ein eigener Vektor ohne Namen
            return _rep_inplace(_rep_each(x, lx, each), t)
        return _rep_inplace(_like(x, x), t)
    if len(tn) != lx * each:
        _error("invalid 'times' argument")
    if each != 1:
        x = _rep_each(x, lx, each)
    if not all(ok_t(t) for t in tn):
        _error("invalid 'times' argument")
    if sum(int(math.trunc(t)) for t in tn) > _MAX_LEN:
        _len_error()
    return _rep_counts(x, [int(math.trunc(t)) for t in tn])


def _argpos(fname, args, nms, ex, formals):
    """Positionen der gebundenen Formalen (None, wenn nicht angegeben)."""
    idx = [None if a is None else INT([i]) for i, a in enumerate(args)]
    w, _, _ = _bind(fname, idx, nms, ex, formals)
    return [None if t is None else args[t[0]] for t in w]


def _kn_x(fname, formals=("x",)):
    """Namen des Arguments x behalten (Math-Gruppe, is.na & Co., cumsum, nchar; seit 1.6.4, C-001)."""
    def deco(f):
        def g(args, nms, ex):
            r = f(args, nms, ex)
            if r is _NULLV or _nm(r) is not None:
                return r
            x = args[0] if (len(formals) == 1 or not any(nms)) and args else \
                _argpos(fname, args, nms, ex, list(formals))[0]
            xn = _nm(x) if x is not None else None
            if xn is not None and r is not x and len(r) == len(x):
                r = _setnm(r, xn)
            return r
        return g
    return deco


def _kn_math2(fname, second):
    """Namen wie R's math2 (round, signif, log mit base): die von x bei gleicher Länge, sonst die des zweiten."""
    def deco(f):
        def g(args, nms, ex):
            r = f(args, nms, ex)
            if r is _NULLV or _nm(r) is not None:
                return r
            x, y = _argpos(fname, args, nms, ex, ["x", second])
            n = len(r)
            nm = None
            if x is not None and _nm(x) is not None and len(x) == n:
                nm = _nm(x)
            elif y is not None and _nm(y) is not None and len(y) == n:
                nm = _nm(y)
            return _setnm(r, nm)
        return g
    return deco


def _kn_ifelse(f):
    """ifelse: das Ergebnis trägt die Namen von test (R: ans <- test)."""
    def g(args, nms, ex):
        r = f(args, nms, ex)
        t = _argpos("ifelse", args, nms, ex, ["test", "yes", "no"])[0]
        return _setnm(r, _nm(t)) if (t is not None and _nm(t) is not None and len(t) == len(r)) else r
    return g


def _kn_rep(f):
    """rep: Namen werden mit den Werten wiederholt (rep.int nicht)."""
    def g(args, nms, ex):
        r = f(args, nms, ex)
        idx = [None if a is None else INT([i]) for i, a in enumerate(args)]
        w, _, _ = _bind("rep", idx, nms, ex, ["x", "times", "length.out", "each"])
        if w[0] is None:
            return r
        x = args[w[0][0]]
        xn = _nm(x)
        if xn is None:
            return r
        a2 = list(args)
        a2[w[0][0]] = INT(range(1, len(x) + 1))
        with warnings.catch_warnings():   # seit 1.6.4 (K43 RS): die Warnungen nur einmal (aus dem ersten Aufruf)
            warnings.simplefilter("ignore")
            ri = f(a2, nms, ex)
        # NA nur beim Auffüllen eines leeren x mit length.out: Name "" wie R (seit 1.6.4, K43 RS; bis dahin NA)
        return _setnm(r, ["" if i is None else xn[i - 1] for i in ri])
    return g


_FUNS = {
    "logical": _f_vector("logical", lambda n: _rep_inplace(LGL([False]), n)),
    "integer": _f_vector("integer", lambda n: _rep_inplace(INT([0]), n)),
    "numeric": _f_vector("numeric", lambda n: _rep_inplace(NUM([0.0]), n)),
    "double": _f_vector("double", lambda n: _rep_inplace(NUM([0.0]), n)),
    "character": _f_vector("character", lambda n: _rep_inplace(CHR([""]), n)),
    "rep": _kn_rep(_f_rep),
    "abs": _kn_x("abs")(_f_abs), "sqrt": _kn_x("sqrt")(_math1("sqrt", _sqrt)),
    "exp": _kn_x("exp")(_math1("exp", _lm1("exp"))), "expm1": _kn_x("expm1")(_math1("expm1", _lm1("expm1"))),
    "log1p": _kn_x("log1p")(_math1("log1p", _lm1("log1p"))), "log2": _kn_x("log2")(_math1("log2", _lm1("log2"))),
    "log10": _kn_x("log10")(_math1("log10", _lm1("log10"))),
    "sin": _kn_x("sin")(_math1("sin", _lm1("sin"))), "cos": _kn_x("cos")(_math1("cos", _lm1("cos"))),
    "tan": _kn_x("tan")(_math1("tan", _lm1("tan"))), "tanh": _kn_x("tanh")(_math1("tanh", _lm1("tanh"))),
    "atan": _kn_x("atan")(_math1("atan", _lm1("atan"))),
    "floor": _kn_x("floor")(_math1("floor", _ffloor_)), "ceiling": _kn_x("ceiling")(_math1("ceiling", _fceil_)), "trunc": _kn_x("trunc", ("x", "..."))(_f_trunc),
    "sign": _kn_x("sign")(_math1("sign", _fsign_)),
    "log": _kn_math2("log", "base")(_f_log), "round": _kn_math2("round", "digits")(_f_round),
    "signif": _kn_math2("signif", "digits")(lambda a, n, e: _f_round(a, n, e, signif=True)),
    "is.na": _kn_x("is.na")(_f_isna), "is.nan": _kn_x("is.nan")(_f_isnan),
    "is.finite": _kn_x("is.finite")(_f_isfinite), "is.infinite": _kn_x("is.infinite")(_f_isinfinite),
    "ifelse": _kn_ifelse(_f_ifelse),
    "pmin": lambda a, n, e: _f_pminmax(a, n, e, False), "pmax": lambda a, n, e: _f_pminmax(a, n, e, True),
    "min": lambda a, n, e: _f_minmax(a, n, e, False), "max": lambda a, n, e: _f_minmax(a, n, e, True),
    "sum": _f_sum, "mean": _f_mean, "median": _f_median, "var": _f_var, "sd": _f_sd,
    "quantile": _f_quantile,
    "any": lambda a, n, e: _f_anyall(a, n, e, True), "all": lambda a, n, e: _f_anyall(a, n, e, False),
    "length": _f_length, "c": _f_c, "nchar": _kn_x("nchar", ("x", "type", "allowNA", "keepNA"))(_f_nchar), "xor": _f_xor,
    "isTRUE": lambda a, n, e: _f_istf(a, n, e, True), "isFALSE": lambda a, n, e: _f_istf(a, n, e, False),
    "as.numeric": _f_asnum, "as.double": _f_asnum, "as.integer": _f_asint,
    "as.logical": _f_aslgl, "as.character": _f_aschr, "as.Date": _f_asdate,
    "cumsum": _kn_x("cumsum")(_f_cumsum), "identity": _f_identity,
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
        cond = _as_lgl(v)[0]
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
        if _ev(a[0], c) is _NULLV:   # seit 1.6.4 wie R (C-025): NULL$x ist NULL
            return _NULLV
        _error("$ operator is invalid for atomic vectors")
    if f == "@":
        x = _ev(a[0], c)
        _error('no applicable method for `@` applied to an object of class "%s"' % _rclass(x))
    if f in _UNSUPPORTED:
        _error("RExpr: '%s' wird in Ausdrücken nicht unterstützt" % f)
    if f == "ifelse":
        return _ev_ifelse(e, c)
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


def _ev_ifelse(e, c):
    """``ifelse`` als Sonderform (seit 1.6.4, T4-B6; bis dahin wurden yes und no immer ausgewertet): Argumente wie R
    gebunden, dann test ausgewertet; ein Datum bzw. eine Zeitdifferenz als test ist der Fehler von R's ``!test``
    (Ops.Date bzw. Ops.difftime); yes nur, wenn ein Wert von test TRUE ist, no nur, wenn einer FALSE ist (R wertet die
    Versprechen erst dann aus). Der Rest wie bisher in _f_ifelse."""
    a = e.args
    idx = [None if x.head == "empty" else INT([i]) for i, x in enumerate(a)]
    w, _, _ = _bind("ifelse", idx, e.names, a, ["test", "yes", "no"])
    pos = [None if t is None else t[0] for t in w]
    if pos[0] is None:
        _missing_arg("test")
    test = _ev(a[pos[0]], c)
    if isinstance(test, (DAT, DIF)):
        _not0(test)
    t = _as_lgl(test)
    yes = _ev(a[pos[1]], c) if (pos[1] is not None and any(x is True for x in t)) else None
    no = _ev(a[pos[2]], c) if (pos[2] is not None and any(x is False for x in t)) else None
    return _FUNS["ifelse"]([test, yes, no], [None, None, None], [None if p is None else a[p] for p in pos])


class _LazyCols:
    """Spalten von ``data`` als R-Vektoren, erst beim ersten Zugriff umgewandelt (seit 1.6.3; bis 1.6.2 alle
    Spalten vorab): dieselben Spaltenobjekte (zu Beginn gemerkt), dieselbe Umwandlung ``from_python``. Seit 1.6.4
    (C-007) wie R: bei gleichem Namen gilt die erste Spalte, und eine Spalte, die RExpr nicht darstellen kann
    (``from_python`` ergibt ``None``, z. B. gemischte, komplexe oder Zeitdauer-Werte), ist beim Zugriff ein Fehler (bis
    1.6.3 fiel sie weg, und der Name kam still aus ``env``)."""
    __slots__ = ("raw", "done")

    def __init__(self, raw):
        self.raw = raw
        self.done = {}

    def _get(self, name):
        if name in self.done:
            return self.done[name]
        vs = self.raw.get(name, ())
        r = from_python(vs[0]) if vs else None
        self.done[name] = r
        return r

    def __contains__(self, name):
        return name in self.raw

    def __getitem__(self, name):
        if name not in self.raw:
            raise KeyError(name)
        r = self._get(name)
        if r is None:
            from .._meldungen import EINGABE
            _error(EINGABE["sp.rexpr_spalte"] % name)
        return r


def _columns(data):
    d = {}
    if data is None:
        return d
    if isinstance(data, pd.DataFrame):
        # seit 1.6.4 je Spalte über die Stelle (C-007: bei doppelten Namen lieferte data[k] eine Tabelle)
        for j, k in enumerate(data.columns):
            d.setdefault(str(k), []).append(data.iloc[:, j])
        return _LazyCols(d)
    if isinstance(data, Mapping):
        for k, v in data.items():
            d.setdefault(str(k), []).append(v)
        return _LazyCols(d)
    if isinstance(data, (list, tuple)) and len(data) == 0:
        return d
    _error("data muss ein data.frame (DataFrame oder dict) sein.")


def _caller_env(depth=2):
    fr = inspect.currentframe()
    try:
        for _ in range(depth):
            fr = fr.f_back
        return _base.caller_env(fr)
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
