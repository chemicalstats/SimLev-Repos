# RExpr – Ausdrücke in R-Syntax als Text auswerten (wie `eval(parse(text = s), data, env)`)
#
# Ein gemeinsamer Auswerter für Bedingungen als Text in
# `Bootstrap.bootstrap_probability`, `Dependence.regime_subset`,
# `Scenarios.view_prob`/`entropy_pooling` und `Tactical.tactical_rules`.
# Gegenstück in Python: `python/simlev/_r/rexpr.py` (1:1-Übersetzung).
#
# Zerlegen wie R 4.3 (src/main/gram.y): derselbe Lexer (Zahlen, Zeichenketten
# mit Escapes, `%op%`, Rohzeichenketten, Kommentare, kontextabhängige
# Zeilenenden einschließlich `if … \n else` in Klammern) und dieselbe
# Grammatik mit R's Vorrang (niedrig → hoch):
#   `?`  <  `=` (rechts)  <  `<-` (rechts)  <  `->`  <  `~`  <  `|` `||`  <  `&` `&&`
#   <  einstelliges `!`  <  Vergleiche (nicht assoziativ)  <  `+` `-`  <  `*` `/`
#   <  `%%` `%/%` `%in%` `|>`  <  `:`  <  einstelliges `-` `+`  <  `^` (rechts)
#   <  `$` `@`  <  `::`  <  Aufruf `f(…)`, Indizierung `x[…]`, `x[[…]]`
# `if`, `function`, `for`, `while`, `repeat` wie in R. Syntaxfehler mit R's
# Meldung (`<text>:Zeile:Spalte: unexpected …` samt Kontextzeilen und `^`),
# Fehler des Lexers wie `'\q' is an unrecognized escape … (<input>:1:4)`.
#
# Werte sind Vektoren wie in R: logisch `Vector{Union{Missing,Bool}}`,
# ganzzahlig `Vector{Union{Missing,Int}}` (Wertebereich von R's integer),
# numerisch `Vector{Float64}` (NA = `SimLev.NA`), Zeichen
# `Vector{Union{Missing,String}}`, Datum `Vector{Union{Missing,Date}}`; NULL
# ist der leere logische Vektor. Alle Operationen elementweise mit Recycling
# (Warnung bei unpassender Länge) und dreiwertiger NA-Logik; Ganzzahl-
# arithmetik mit Überlauf → NA und Warnung; Zahlen wie R (`^` über `R_POW`,
# `%%`/`%/%` wie `myfmod`/`myfloor`, Literale und `as.numeric` über
# R_strtod mit long double, Summen/Mittel über `RBase`, `median`, `var`,
# `sd`, `quantile` über `RStats`), Zeichenkettenvergleiche `<`, `>` über
# `RStats.str_collate` (ICU wie R).
#
# Ausgewertet werden Konstanten, Variablen, Operatoren, `(`, `{`, `;`,
# Zuweisungen an lokale Namen (`<-`, `=`, `->`), `if`/`else`, `x[i]`
# (positiv, negativ, logisch, Zeichen), `x[[i]]`, `|>` und die Funktionen in
# `_FUNS`. `function`, Schleifen, `$`, `@`, `::`, `~`, `?` werden zerlegt, aber
# nicht ausgewertet (Fehler).
#
# Variablen: zuerst lokale Zuweisungen, dann Spalten von `data`, dann `env`
# (ein Modul, `AbstractDict`, `NamedTuple` oder `RList`), zuletzt `T`, `F`,
# `pi`, `letters`, `LETTERS`, `month.name`, `month.abb`. Funktionen: die
# R-Funktionen in `_FUNS`, sonst eine gleichnamige Julia-Funktion aus `env`
# (Aufruf mit den Werten als Julia-Vektoren, benannte Argumente als
# Schlüsselwörter mit `.` → `_`).
module RExpr

import ..SimLev
using Dates: Dates, Date, Day

export parse_r, eval_r

const LGL = Vector{Union{Missing,Bool}}
const INT = Vector{Union{Missing,Int}}
const NUM = Vector{Float64}
const CHR = Vector{Union{Missing,String}}
const DAT = Vector{Union{Missing,Date}}
const _NA = SimLev.NA
const _IMAX = 2147483647
const _EPOCH = Date(1970, 1, 1)

_warn(msg::AbstractString) = (@warn msg; nothing)

# ═══════════════════════════════════════════════════════════════════════════
# R_strtod (arithmetic.c/util.c, R_strtod5 mit NA = FALSE, long double)
# ═══════════════════════════════════════════════════════════════════════════

_isdig(c::Char) = '0' <= c <= '9'
_isspace_c(c::Char) = c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'

"""
    r_strtod(s, i = 1) -> (Wert, Endindex)

R's `R_strtod` auf den Zeichen von `s` ab Index `i`: Rückgabe des Werts und
des Index hinter dem gelesenen Teil (wie `endptr`; bei ungültiger Eingabe der
Anfangsindex und NA).
"""
function r_strtod(cs::Vector{Char}, i0::Int = 1)
    L = SimLev.F80
    n = length(cs)
    at(k) = k <= n ? cs[k] : '\0'
    p = i0
    while _isspace_c(at(p)); p += 1; end
    sign = 1.0
    if at(p) == '-'
        sign = -1.0; p += 1
    elseif at(p) == '+'
        p += 1
    end
    low(k, m) = lowercase(String(cs[k:min(n, k + m - 1)]))
    if low(p, 3) == "nan"
        return (sign * NaN, p + 3)
    elseif low(p, 8) == "infinity"
        return (sign * Inf, p + 8)
    elseif low(p, 3) == "inf"
        return (sign * Inf, p + 3)
    end
    ans = L(0.0)
    expn = 0
    if n - p + 1 > 2 && at(p) == '0' && (at(p + 1) == 'x' || at(p + 1) == 'X')
        exph = -1
        p += 2
        while true
            c = at(p)
            if _isdig(c)
                ans = L(16.0) * ans + L(Float64(c - '0'))
            elseif 'a' <= c <= 'f'
                ans = L(16.0) * ans + L(Float64(c - 'a' + 10))
            elseif 'A' <= c <= 'F'
                ans = L(16.0) * ans + L(Float64(c - 'A' + 10))
            elseif c == '.'
                exph = 0; p += 1; continue
            else
                break
            end
            exph >= 0 && (exph += 4)
            p += 1
        end
        if at(p) == 'p' || at(p) == 'P'
            expsign = 1
            p += 1
            if at(p) == '-'
                expsign = -1; p += 1
            elseif at(p) == '+'
                p += 1
            end
            m = 0
            while _isdig(at(p))
                m = m < 9999 ? m * 10 + (at(p) - '0') : m; p += 1
            end
            if ans != L(0.0)
                expn += expsign * m
                p2 = L(2.0)
                if exph > 0
                    if expn - exph < -122
                        fac = L(1.0); k = exph
                        while k != 0
                            (k & 1) == 1 && (fac *= p2)
                            k >>= 1; p2 *= p2
                        end
                        ans /= fac
                        p2 = L(2.0)
                    else
                        expn -= exph
                    end
                end
                fac = L(1.0)
                k = abs(expn)
                while k != 0
                    (k & 1) == 1 && (fac *= p2)
                    k >>= 1; p2 *= p2
                end
                ans = expn < 0 ? ans / fac : ans * fac
            end
        end
        return (sign * Float64(ans), p)
    end
    nd = 0
    while _isdig(at(p))
        ans = L(10.0) * ans + L(Float64(at(p) - '0')); p += 1; nd += 1
    end
    if at(p) == '.'
        p += 1
        while _isdig(at(p))
            ans = L(10.0) * ans + L(Float64(at(p) - '0')); p += 1; nd += 1; expn -= 1
        end
    end
    nd == 0 && return (_NA, i0)
    if at(p) == 'e' || at(p) == 'E'
        expsign = 1
        p += 1
        if at(p) == '-'
            expsign = -1; p += 1
        elseif at(p) == '+'
            p += 1
        end
        m = 0
        while _isdig(at(p))
            m = m < 9999 ? m * 10 + (at(p) - '0') : m; p += 1
        end
        expn += expsign * m
    end
    if expn + nd < -300
        for _ in 1:nd
            ans /= L(10.0)
        end
        expn += nd
    end
    p10 = L(10.0); fac = L(1.0)
    if expn < -307
        k = -expn
        while k != 0
            (k & 1) == 1 && (fac /= p10)
            k >>= 1; p10 *= p10
        end
        ans *= fac
    elseif expn < 0
        k = -expn
        while k != 0
            (k & 1) == 1 && (fac *= p10)
            k >>= 1; p10 *= p10
        end
        ans /= fac
    elseif ans != L(0.0)
        k = expn
        while k != 0
            (k & 1) == 1 && (fac *= p10)
            k >>= 1; p10 *= p10
        end
        ans *= fac
    end
    Float64(ans) > floatmax(Float64) && return (sign > 0 ? Inf : -Inf, p)
    isinf(Float64(ans)) && return (sign * Float64(ans), p)
    return (sign * Float64(ans), p)
end
r_strtod(s::AbstractString, i0::Int = 1) = r_strtod(collect(String(s)), i0)

_isblank_str(cs::Vector{Char}, i::Int) = all(_isspace_c, @view cs[i:end])

"`String_to_real`: (Wert, ungültig?) – leere Zeichenkette und NA ohne Warnung."
function _str2num(s::Union{Missing,String})
    s === missing && return (_NA, false)
    cs = collect(s)
    _isblank_str(cs, 1) && return (_NA, false)
    v, e = r_strtod(cs, 1)
    _isblank_str(cs, e) && return (v, false)
    return (_NA, true)
end

# ═══════════════════════════════════════════════════════════════════════════
# Lexer (gram.y: xxgetc, token, yylex)
# ═══════════════════════════════════════════════════════════════════════════

struct Tok
    kind::Symbol
    val::Any
    line::Int
    col::Int
end

mutable struct Lexer
    cs::Vector{Char}
    pos::Int
    line::Int
    col::Int
    hist::Vector{NTuple{3,Int}}
    ctxline::Int
    cstack::Vector{Char}
    eat::Bool
    saved::Union{Nothing,Tok}
    warns::Vector{String}
end
Lexer(s::String) = Lexer(collect(s), 1, 1, 0, NTuple{3,Int}[], 1, [' '], false, nothing, String[])

const _EOF = '\0'

function _getc!(L::Lexer)
    if L.pos > length(L.cs)
        push!(L.hist, (L.line, L.col, 0))
        return _EOF
    end
    c = L.cs[L.pos]
    L.pos += 1
    push!(L.hist, (L.line, L.col, 1))
    if c == '\n'
        L.line += 1; L.col = 0
    else
        L.col += 1
    end
    c == '\t' && (L.col = (L.col + 7) & ~7)
    L.ctxline = L.line
    return c
end

function _ungetc!(L::Lexer)
    l, c, k = pop!(L.hist)
    L.line = l; L.col = c; L.ctxline = l
    L.pos -= k
    nothing
end

function _nextchar!(L::Lexer, e::Char)
    c = _getc!(L)
    c == e && return true
    _ungetc!(L)
    return false
end

# Kontextzeilen der Fehlermeldung (source.c: getParseContext, tabExpand, parseError)
function _ctx_lines(L::Lexer)
    s = String(L.cs[1:L.pos-1])
    if ncodeunits(s) > 256
        k = ncodeunits(s) - 255
        while k <= ncodeunits(s) && !isvalid(s, k); k += 1; end
        s = s[k:end]
    end
    lines = String.(split(s, '\n'))
    isempty(s) && (lines = String[])
    cl = L.ctxline
    if !isempty(lines) && isempty(lines[end])
        pop!(lines); cl -= 1
    end
    out = String[]
    for ln in lines
        b = IOBuffer(); w = 0
        for ch in ln
            w >= 192 && break
            if ch == '\t'
                while true
                    write(b, ' '); w += 1
                    (w & 7) == 0 && break
                end
            else
                write(b, ch); w += ncodeunits(ch)
            end
        end
        push!(out, String(take!(b)))
    end
    return out, cl
end

function _parse_errmsg(L::Lexer, line::Int, col::Int, msg::String)
    lines, cl = _ctx_lines(L)
    head = "<text>:$line:$col: $msg"
    if isempty(lines)
        return head
    elseif length(lines) == 1
        w = length("$cl: ")
        return head * "\n$cl: " * lines[1] * "\n" * lpad("^", w + col + 1)
    else
        w = length("$cl:")
        return head * "\n$(cl - 1): " * lines[end-1] * "\n$cl: " * lines[end] * "\n" * lpad("^", w + col + 1)
    end
end

_lexerr(L::Lexer, msg::String) = error("$msg (<input>:$(L.line):$(L.col))")

const _TOKNAME = Dict{Symbol,String}(
    :END => "end of input", :ERROR => "input", :STR => "string constant", :NUM => "numeric constant",
    :SYMBOL => "symbol", :LEFT_ASSIGN => "assignment", :NL => "end of line", :NULL => "'NULL'",
    :FUNCTION => "'function'", :EQ_ASSIGN => "'='", :RIGHT_ASSIGN => "'->'", :LBB => "'[['",
    :FOR => "'for'", :IN => "'in'", :IF => "'if'", :ELSE => "'else'", :WHILE => "'while'",
    :NEXT => "'next'", :BREAK => "'break'", :REPEAT => "'repeat'", :GT => "'>'", :GE => "'>='",
    :LT => "'<'", :LE => "'<='", :EQ => "'=='", :NE => "'!='", :AND => "'&'", :OR => "'|'",
    :AND2 => "'&&'", :OR2 => "'||'", :NS_GET => "'::'", :NS_GET_INT => "':::'", :PIPE => "'|>'",
    :PIPEBIND => "'=>'", :PLACEHOLDER => "input", :INCOMPLETE_STRING => "INCOMPLETE_STRING",
    :SPECIAL => "SPECIAL", :SEMI => "';'", :COMMA => "','", :LPAREN => "'('", :RPAREN => "')'",
    :LBRACKET => "'['", :RBRACKET => "']'", :LBRACE => "'{'", :RBRACE => "'}'", :PLUS => "'+'",
    :MINUS => "'-'", :STAR => "'*'", :SLASH => "'/'", :CARET => "'^'", :TILDE => "'~'",
    :QUESTION => "'?'", :BANG => "'!'", :COLON => "':'", :DOLLAR => "'\$'", :AT => "'@'",
    :BACKSLASH => "'\\\\'", :UNDEF => "input")

const _KEYWORDS = Dict{String,Symbol}("NULL" => :NULL, "NA" => :NUM, "TRUE" => :NUM, "FALSE" => :NUM,
    "Inf" => :NUM, "NaN" => :NUM, "NA_integer_" => :NUM, "NA_real_" => :NUM, "NA_character_" => :NUM,
    "NA_complex_" => :NUM, "function" => :FUNCTION, "while" => :WHILE, "repeat" => :REPEAT, "for" => :FOR,
    "if" => :IF, "in" => :IN, "else" => :ELSE, "next" => :NEXT, "break" => :BREAK)

# Wert eines Schlüsselworts mit NUM_CONST
function _kwvalue(s::String)
    s == "NA" && return LGL([missing])
    s == "TRUE" && return LGL([true])
    s == "FALSE" && return LGL([false])
    s == "Inf" && return NUM([Inf])
    s == "NaN" && return NUM([NaN])
    s == "NA_integer_" && return INT([missing])
    s == "NA_real_" && return NUM([_NA])
    s == "NA_character_" && return CHR([missing])
    return :complex
end

_isblank_u(c::Char) = c == ' ' || c == ' ' || c == '　' ||
                      (' ' <= c <= ' ') || (' ' <= c <= ' ')
_isalpha_u(c::Char) = isletter(c)
_isalnum_u(c::Char) = isletter(c) || isdigit(c) || (c >= '\x80' && Base.Unicode.category_code(c) == Base.Unicode.UTF8PROC_CATEGORY_ND)

function _skipspace!(L::Lexer)
    while true
        c = _getc!(L)
        (c == ' ' || c == '\t' || c == '\f') && continue
        (c == '\n' || c == _EOF) && return c
        c < '\x80' && return c
        _isblank_u(c) || return c
    end
end

function _skipcomment!(L::Lexer)
    c = '#'
    while c != '\n' && c != _EOF
        c = _getc!(L)
    end
    return c
end

function _numeric!(L::Lexer, c::Char, fl::Int, fc::Int)
    buf = Char[c]
    seendot = c == '.' ? 1 : 0
    seenexp = false
    last = c
    nd = 0
    asnum = false
    count = 1
    err() = Tok(:ERROR, nothing, fl, fc)
    while true
        c = _getc!(L)
        (_isdig(c) || c == '.' || c == 'e' || c == 'E' || c == 'x' || c == 'X' || c == 'L') || break
        count += 1
        if c == 'L'
            push!(buf, c); break
        end
        if c == 'x' || c == 'X'
            (count > 2 || last != '0') && break
            push!(buf, c)
            while true
                c = _getc!(L)
                (_isdig(c) || ('a' <= c <= 'f') || ('A' <= c <= 'F') || c == '.') || break
                if c == '.'
                    seendot != 0 && return err()
                    seendot = 1
                end
                push!(buf, c); nd += 1
            end
            nd == 0 && return err()
            if c == 'p' || c == 'P'
                seenexp = true
                push!(buf, c)
                c = _getc!(L)
                (!_isdig(c) && c != '+' && c != '-') && return err()
                if c == '+' || c == '-'
                    push!(buf, c); c = _getc!(L)
                end
                nd = 0
                while _isdig(c)
                    push!(buf, c); c = _getc!(L); nd += 1
                end
                nd == 0 && return err()
            end
            (seendot != 0 && !seenexp) && return err()
            c == 'L' && push!(buf, c)
            break
        end
        if c == 'E' || c == 'e'
            seenexp && break
            seenexp = true
            seendot = seendot == 1 ? seendot : 2
            push!(buf, c)
            c = _getc!(L)
            (!_isdig(c) && c != '+' && c != '-') && return err()
            if c == '+' || c == '-'
                push!(buf, c)
                c = _getc!(L)
                _isdig(c) || return err()
            end
        end
        if c == '.'
            seendot != 0 && break
            seendot = 1
        end
        push!(buf, c)
        last = c
    end
    c == 'i' && push!(buf, c)
    txt = String(buf)
    if c == 'L'
        a = r_strtod(buf, 1)[1]
        b = (isfinite(a) && -2.147483649e9 < a < 2.147483648e9) ? trunc(a) : -2.147483648e9
        if a != b
            if seendot == 1 && !seenexp
                push!(L.warns, "integer literal $txt contains decimal; using numeric value")
            else
                push!(L.warns, "non-integer value $txt qualified with L; using numeric value")
            end
            asnum = true
            seenexp = true
        end
    end
    if c == 'i'
        return Tok(:NUM, :complex, fl, fc)
    elseif c == 'L' && !asnum
        seendot == 1 && !seenexp && push!(L.warns, "integer literal $txt contains unnecessary decimal point")
        a = r_strtod(buf, 1)[1]
        return Tok(:NUM, INT([Int(trunc(a))]), fl, fc)
    else
        c != 'L' && _ungetc!(L)
        return Tok(:NUM, NUM([r_strtod(buf, 1)[1]]), fl, fc)
    end
end

function _hexval(c::Char)
    _isdig(c) && return Int(c - '0')
    'A' <= c <= 'F' && return Int(c - 'A' + 10)
    'a' <= c <= 'f' && return Int(c - 'a' + 10)
    return -1
end

function _string!(L::Lexer, quote_::Char, forsym::Bool, fl::Int, fc::Int)
    buf = UInt8[]
    oct_or_hex = false
    use_wcs = false
    c = quote_
    while true
        c = _getc!(L)
        (c == _EOF || c == quote_) && break
        if c == '\n'
            _ungetc!(L)
            c = '\\'
        end
        if c == '\\'
            c = _getc!(L)
            if '0' <= c <= '7'
                octal = Int(c - '0')
                c = _getc!(L)
                if '0' <= c <= '7'
                    octal = 8 * octal + Int(c - '0')
                    c = _getc!(L)
                    if '0' <= c <= '7'
                        octal = 8 * octal + Int(c - '0')
                    else
                        _ungetc!(L)
                    end
                else
                    _ungetc!(L)
                end
                octal == 0 && _lexerr(L, "nul character not allowed")
                octal > 0xff && _lexerr(L, "\\$(string(octal; base = 8)) exceeds maximum allowed octal value \\377")
                push!(buf, UInt8(octal)); oct_or_hex = true
                continue
            elseif c == 'x'
                val = 0
                for i in 1:2
                    c = _getc!(L)
                    ext = _hexval(c)
                    if ext < 0
                        _ungetc!(L)
                        i == 1 && _lexerr(L, "'\\x' used without hex digits in character string")
                        break
                    end
                    val = 16 * val + ext
                end
                val == 0 && _lexerr(L, "nul character not allowed")
                push!(buf, UInt8(val)); oct_or_hex = true
                continue
            elseif c == 'u' || c == 'U'
                big = c == 'U'
                forsym && _lexerr(L, big ? "\\Uxxxxxxxx sequences not supported inside backticks" :
                                           "\\uxxxx sequences not supported inside backticks")
                delim = false
                c = _getc!(L)
                if c == '{'
                    delim = true
                else
                    _ungetc!(L)
                end
                val = 0
                for i in 1:(big ? 8 : 4)
                    c = _getc!(L)
                    ext = _hexval(c)
                    if ext < 0
                        _ungetc!(L)
                        i == 1 && _lexerr(L, big ? "'\\U' used without hex digits in character string" :
                                                   "'\\u' used without hex digits in character string")
                        break
                    end
                    val = 16 * val + ext
                end
                if delim
                    c = _getc!(L)
                    c == '}' || (big ? _lexerr(L, "invalid \\U{xxxxxxxx} sequence") :
                                 error("invalid \\u{xxxx} sequence (line $(L.line))"))
                end
                val == 0 && _lexerr(L, "nul character not allowed")
                if big && val > 0x10FFFF
                    _lexerr(L, delim ? "invalid \\U{xxxxxxxx} value $(lpad(string(val; base = 16), 6))" :
                                       "invalid \\Uxxxxxxxx value $(lpad(string(val; base = 16), 6))")
                end
                append!(buf, codeunits(string(Char(val)))); use_wcs = true
                continue
            else
                e = c == 'a' ? '\a' : c == 'b' ? '\b' : c == 'f' ? '\f' : c == 'n' ? '\n' : c == 'r' ? '\r' :
                    c == 't' ? '\t' : c == 'v' ? '\v' : c == '\\' ? '\\' :
                    c in ('"', '\'', '`', ' ', '\n') ? c : nothing
                e === nothing && _lexerr(L, "'\\$(c)' is an unrecognized escape in character string")
                append!(buf, codeunits(string(e)))
                continue
            end
        end
        append!(buf, codeunits(string(c)))
    end
    c == _EOF && return Tok(:INCOMPLETE_STRING, nothing, fl, fc)
    s = String(buf)
    forsym && return Tok(:SYMBOL, s, fl, fc)
    (use_wcs && oct_or_hex) && _lexerr(L, "mixing Unicode and octal/hex escapes in a string is not allowed")
    return Tok(:STR, s, fl, fc)
end

function _rawstring!(L::Lexer, quote_::Char, fl::Int, fc::Int)
    ndash = 0
    c = _getc!(L)
    while c == '-'
        ndash += 1; c = _getc!(L)
    end
    close = c == '(' ? ')' : c == '[' ? ']' : c == '{' ? '}' : '\0'
    close == '\0' && _lexerr(L, "malformed raw string literal")
    buf = Char[]
    while true
        c = _getc!(L)
        c == _EOF && return Tok(:INCOMPLETE_STRING, nothing, fl, fc)
        if c == close
            k = 0
            hist = Char[c]
            while k < ndash
                d = _getc!(L)
                d == _EOF && return Tok(:INCOMPLETE_STRING, nothing, fl, fc)
                push!(hist, d)
                d == '-' || break
                k += 1
            end
            if k == ndash
                d = _getc!(L)
                if d == quote_
                    return Tok(:STR, String(buf), fl, fc)
                end
                d == _EOF && return Tok(:INCOMPLETE_STRING, nothing, fl, fc)
                push!(hist, d)
            end
            # kein Ende: gelesene Zeichen (bis auf das letzte) gehören zum Inhalt
            append!(buf, hist[1:end-1])
            _ungetc!(L)
            continue
        end
        push!(buf, c)
    end
end

function _special!(L::Lexer, fl::Int, fc::Int)
    buf = Char['%']
    c = '%'
    while true
        c = _getc!(L)
        (c == _EOF || c == '%') && break
        if c == '\n'
            _ungetc!(L)
            return Tok(:ERROR, nothing, fl, fc)
        end
        push!(buf, c)
    end
    c == '%' && push!(buf, c)
    return Tok(:SPECIAL, String(buf), fl, fc)
end

function _symbol!(L::Lexer, c::Char, fl::Int, fc::Int)
    buf = Char[c]
    while true
        c = _getc!(L)
        c == _EOF && break
        (c == '.' || c == '_' || _isalnum_u(c)) || break
        push!(buf, c)
    end
    _ungetc!(L)
    s = String(buf)
    kw = get(_KEYWORDS, s, nothing)
    kw === :NUM && return Tok(:NUM, _kwvalue(s), fl, fc)
    kw === nothing || return Tok(kw, s, fl, fc)
    return Tok(:SYMBOL, s, fl, fc)
end

function _token!(L::Lexer)
    if L.saved !== nothing
        t = L.saved; L.saved = nothing
        return t
    end
    c = _skipspace!(L)
    c == '#' && (c = _skipcomment!(L))
    fl, fc = L.line, L.col
    c == _EOF && return Tok(:END, nothing, fl, fc)
    T(k, v = nothing) = Tok(k, v, fl, fc)
    if c == '.'
        d = _getc!(L); _ungetc!(L)
        _isdig(d) || return _symbol!(L, c, fl, fc)
        return _numeric!(L, c, fl, fc)
    end
    _isdig(c) && return _numeric!(L, c, fl, fc)
    if c == 'r' || c == 'R'
        _nextchar!(L, '"') && return _rawstring!(L, '"', fl, fc)
        _nextchar!(L, '\'') && return _rawstring!(L, '\'', fl, fc)
    end
    (c == '"' || c == '\'') && return _string!(L, c, false, fl, fc)
    c == '%' && return _special!(L, fl, fc)
    c == '`' && return _string!(L, c, true, fl, fc)
    c == '_' && return T(:PLACEHOLDER)
    _isalpha_u(c) && return _symbol!(L, c, fl, fc)
    if c == '<'
        _nextchar!(L, '=') && return T(:LE)
        _nextchar!(L, '-') && return T(:LEFT_ASSIGN, "<-")
        if _nextchar!(L, '<')
            _nextchar!(L, '-') && return T(:LEFT_ASSIGN, "<<-")
            return T(:ERROR)
        end
        return T(:LT)
    elseif c == '-'
        if _nextchar!(L, '>')
            _nextchar!(L, '>') && return T(:RIGHT_ASSIGN, "<<-")
            return T(:RIGHT_ASSIGN, "<-")
        end
        return T(:MINUS)
    elseif c == '>'
        _nextchar!(L, '=') && return T(:GE)
        return T(:GT)
    elseif c == '!'
        _nextchar!(L, '=') && return T(:NE)
        return T(:BANG)
    elseif c == '='
        _nextchar!(L, '=') && return T(:EQ)
        _nextchar!(L, '>') && return T(:PIPEBIND)
        return T(:EQ_ASSIGN)
    elseif c == ':'
        if _nextchar!(L, ':')
            _nextchar!(L, ':') && return T(:NS_GET_INT)
            return T(:NS_GET)
        end
        _nextchar!(L, '=') && return T(:LEFT_ASSIGN, ":=")
        return T(:COLON)
    elseif c == '&'
        _nextchar!(L, '&') && return T(:AND2)
        return T(:AND)
    elseif c == '|'
        _nextchar!(L, '|') && return T(:OR2)
        _nextchar!(L, '>') && return T(:PIPE)
        return T(:OR)
    elseif c == '{'
        return T(:LBRACE)
    elseif c == '}'
        return T(:RBRACE)
    elseif c == '('
        return T(:LPAREN)
    elseif c == ')'
        return T(:RPAREN)
    elseif c == '['
        _nextchar!(L, '[') && return T(:LBB)
        return T(:LBRACKET)
    elseif c == ']'
        return T(:RBRACKET)
    elseif c == '?'
        return T(:QUESTION)
    elseif c == '*'
        _nextchar!(L, '*') && return T(:CARET)
        return T(:STAR)
    elseif c == '+'
        return T(:PLUS)
    elseif c == '/'
        return T(:SLASH)
    elseif c == '^'
        return T(:CARET)
    elseif c == '~'
        return T(:TILDE)
    elseif c == '$'
        return T(:DOLLAR)
    elseif c == '@'
        return T(:AT)
    elseif c == '\\'
        return T(:BACKSLASH)
    elseif c == '\n'
        return T(:NL)
    elseif c == ';'
        return T(:SEMI)
    elseif c == ','
        return T(:COMMA)
    end
    return T(:UNDEF)
end

_ctop(L::Lexer) = isempty(L.cstack) ? ' ' : L.cstack[end]
_cpop!(L::Lexer) = (isempty(L.cstack) || pop!(L.cstack); nothing)
_ifpop!(L::Lexer) = (_ctop(L) == 'i' && pop!(L.cstack); nothing)
_ifpush!(L::Lexer) = (_ctop(L) in ('{', '[', '(', 'i') && push!(L.cstack, 'i'); nothing)

const _EATS = Set([:PLUS, :MINUS, :STAR, :SLASH, :CARET, :LT, :LE, :GE, :GT, :EQ, :NE, :OR, :AND, :OR2,
                   :AND2, :PIPE, :PIPEBIND, :SPECIAL, :FUNCTION, :WHILE, :REPEAT, :FOR, :IN, :QUESTION,
                   :BANG, :EQ_ASSIGN, :COLON, :TILDE, :DOLLAR, :AT, :LEFT_ASSIGN, :RIGHT_ASSIGN])
const _NOEAT = Set([:SYMBOL, :PLACEHOLDER, :STR, :NUM, :NULL, :NEXT, :BREAK])

function _yylex!(L::Lexer)
    while true
        tok = _token!(L)
        if tok.kind === :NL
            (L.eat || _ctop(L) == '[' || _ctop(L) == '(') && continue
            if _ctop(L) == 'i'
                while tok.kind === :NL
                    tok = _token!(L)
                end
                if tok.kind === :RBRACE || tok.kind === :RPAREN || tok.kind === :RBRACKET
                    while _ctop(L) == 'i'; _ifpop!(L); end
                    _cpop!(L)
                    return tok
                end
                if tok.kind === :COMMA
                    _ifpop!(L)
                    return tok
                end
                if tok.kind === :ELSE
                    L.eat = true
                    _ifpop!(L)
                    return tok
                end
                _ifpop!(L)
                L.saved = tok
                return Tok(:NL, nothing, tok.line, tok.col)
            end
            return tok
        end
        k = tok.kind
        if k in _EATS
            L.eat = true
        elseif k === :IF
            _ifpush!(L); L.eat = true
        elseif k === :ELSE
            _ifpop!(L); L.eat = true
        elseif k === :SEMI || k === :COMMA
            _ifpop!(L)
        elseif k in _NOEAT
            L.eat = false
        elseif k === :LBB
            push!(L.cstack, '['); push!(L.cstack, '[')
        elseif k === :LBRACKET
            push!(L.cstack, '[')
        elseif k === :LBRACE
            push!(L.cstack, '{'); L.eat = true
        elseif k === :LPAREN
            push!(L.cstack, '(')
        elseif k === :RBRACKET || k === :RPAREN
            while _ctop(L) == 'i'; _ifpop!(L); end
            _cpop!(L); L.eat = false
        elseif k === :RBRACE
            while _ctop(L) == 'i'; _ifpop!(L); end
            _cpop!(L)
        end
        return tok
    end
end

# ═══════════════════════════════════════════════════════════════════════════
# Parser (Vorrangklettern mit R's Grammatik)
# ═══════════════════════════════════════════════════════════════════════════

"Knoten des Syntaxbaums: `:const` (val = R-Wert), `:sym` (Name), `:call` (val = Funktionsname),
`:callx` (val = Ausdruck der Funktion), `:empty`, `:placeholder`."
struct Node
    head::Symbol
    val::Any
    args::Vector{Node}
    names::Vector{Union{Nothing,String}}
    line::Int
    col::Int
end
Node(head::Symbol, val, line::Int = 0, col::Int = 0) = Node(head, val, Node[], Union{Nothing,String}[], line, col)
_mkcall(f, args::Vector{Node}, line = 0, col = 0) = Node(:call, f, args, Union{Nothing,String}[nothing for _ in args], line, col)
const _EMPTY = Node(:empty, nothing)
"NULL (eindeutiges Objekt; leerer logischer Vektor)"
const _NULLV = LGL()

mutable struct Parser
    L::Lexer
    la::Union{Nothing,Tok}
end
_peek!(P::Parser) = P.la === nothing ? (P.la = _yylex!(P.L)) : P.la
_next!(P::Parser) = (t = _peek!(P); P.la = nothing; t)
_synerr(P::Parser, t::Tok) = error(_parse_errmsg(P.L, t.line, t.col, "unexpected " * _TOKNAME[t.kind]))

# Binäroperatoren: Bindungsstärke, Assoziativität, Name im Syntaxbaum
const _BINOP = Dict{Symbol,Tuple{Int,Symbol}}(
    :QUESTION => (1, :left), :LEFT_ASSIGN => (5, :right), :EQ_ASSIGN => (6, :right),
    :RIGHT_ASSIGN => (7, :left), :TILDE => (8, :left), :OR => (9, :left), :OR2 => (9, :left),
    :AND => (10, :left), :AND2 => (10, :left), :GT => (12, :non), :GE => (12, :non), :LT => (12, :non),
    :LE => (12, :non), :EQ => (12, :non), :NE => (12, :non), :PLUS => (13, :left), :MINUS => (13, :left),
    :STAR => (14, :left), :SLASH => (14, :left), :SPECIAL => (15, :left), :PIPE => (15, :left),
    :PIPEBIND => (16, :left), :COLON => (17, :left), :CARET => (19, :right), :DOLLAR => (20, :left),
    :AT => (20, :left))
const _OPNAME = Dict{Symbol,String}(:QUESTION => "?", :EQ_ASSIGN => "=", :TILDE => "~", :OR => "|",
    :OR2 => "||", :AND => "&", :AND2 => "&&", :GT => ">", :GE => ">=", :LT => "<", :LE => "<=",
    :EQ => "==", :NE => "!=", :PLUS => "+", :MINUS => "-", :STAR => "*", :SLASH => "/", :COLON => ":",
    :CARET => "^", :DOLLAR => "\$", :AT => "@")
const _CMPK = Set([:GT, :GE, :LT, :LE, :EQ, :NE])
const _CMP = ("<", ">", "<=", ">=", "==", "!=")

# Symbole mit R's IS_SPECIAL_SYMBOL (names.c) – nicht als rechte Seite von |>
const _SPECIAL_SYMS = Set(["if", "while", "repeat", "for", "break", "next", "return", "function", "(", "{",
    "+", "-", "*", "/", "^", "%%", "%/%", "%*%", ":", "==", "!=", "<", ">", "<=", ">=", "&", "|", "&&",
    "||", "!", "<-", "<<-", "=", "\$", "[", "[[", "\$<-", "[<-", "[[<-"])

function _expr!(P::Parser, minbp::Int, ctx::Symbol, first::Union{Nothing,Tok} = nothing)
    t0 = first === nothing ? _next!(P) : first
    lhs = _primary!(P, t0)
    while true
        t = _peek!(P)
        k = t.kind
        if k === :LPAREN || k === :LBRACKET || k === :LBB
            _next!(P)
            lhs = _postfix!(P, lhs, t)
            continue
        end
        info = get(_BINOP, k, nothing)
        info === nothing && break
        bp, assoc = info
        bp > minbp || break
        k === :EQ_ASSIGN && ctx !== :assign && break
        k === :QUESTION && ctx === :expr && break
        _next!(P)
        if k === :DOLLAR || k === :AT
            r = _next!(P)
            (r.kind === :SYMBOL || r.kind === :STR) || _synerr(P, r)
            lhs = _mkcall(_OPNAME[k], Node[lhs, Node(r.kind === :SYMBOL ? :sym : :const,
                                                     r.kind === :SYMBOL ? r.val : CHR([r.val]))], t.line, t.col)
            continue
        end
        k === :PIPEBIND && error("'=>' is disabled; set '_R_USE_PIPEBIND_' envvar to a true value to enable it (<input>:$(t.line):$(t.col))")
        rctx = k === :EQ_ASSIGN ? :assign : k === :QUESTION ? ctx : :expr
        rbp = assoc === :right ? bp - 1 : bp
        r1 = _peek!(P)
        rhs = _expr!(P, rbp, rctx)
        if k === :LEFT_ASSIGN
            lhs = _mkcall(String(t.val), Node[lhs, rhs], t.line, t.col)
        elseif k === :RIGHT_ASSIGN
            lhs = _mkcall(String(t.val), Node[rhs, lhs], t.line, t.col)
        elseif k === :SPECIAL
            lhs = _mkcall(String(t.val), Node[lhs, rhs], t.line, t.col)
        elseif k === :PIPE
            lhs = _pipe(lhs, rhs, r1)
        else
            lhs = _mkcall(_OPNAME[k], Node[lhs, rhs], t.line, t.col)
        end
        if k in _CMPK
            t2 = _peek!(P)
            t2.kind in _CMPK && _synerr(P, t2)
        end
    end
    return lhs
end

function _pipe(lhs::Node, rhs::Node, r1::Tok)
    loc = "(<input>:$(r1.line):$(r1.col))"
    (rhs.head === :call || rhs.head === :callx) ||
        error("The pipe operator requires a function call as RHS $loc")
    ph = [i for i in eachindex(rhs.args) if rhs.args[i].head === :placeholder]
    if !isempty(ph)
        length(ph) > 1 && error("pipe placeholder may only appear once $loc")
        i = ph[1]
        rhs.names[i] === nothing && error("pipe placeholder can only be used as a named argument $loc")
        args = copy(rhs.args); args[i] = lhs
        return Node(rhs.head, rhs.val, args, copy(rhs.names), rhs.line, rhs.col)
    end
    if rhs.head === :call && rhs.val in _SPECIAL_SYMS
        error("function '$(rhs.val)' not supported in RHS call of a pipe $loc")
    end
    if rhs.head === :callx && rhs.val.head === :call && rhs.val.val == "function"
        error("function 'function' not supported in RHS call of a pipe $loc")
    end
    return Node(rhs.head, rhs.val, vcat(Node[lhs], rhs.args), vcat(Union{Nothing,String}[nothing], rhs.names),
                rhs.line, rhs.col)
end

function _expect!(P::Parser, k::Symbol)
    t = _next!(P)
    t.kind === k || _synerr(P, t)
    t
end

function _primary!(P::Parser, t::Tok)
    k = t.kind
    if k === :NUM
        return Node(:const, t.val, t.line, t.col)
    elseif k === :STR || k === :SYMBOL
        n = _peek!(P)
        if n.kind === :NS_GET || n.kind === :NS_GET_INT
            _next!(P)
            r = _next!(P)
            (r.kind === :SYMBOL || r.kind === :STR) || _synerr(P, r)
            return _mkcall(n.kind === :NS_GET ? "::" : ":::", Node[Node(:sym, String(t.val)), Node(:sym, String(r.val))], t.line, t.col)
        end
        return k === :STR ? Node(:const, CHR([t.val]), t.line, t.col) : Node(:sym, t.val, t.line, t.col)
    elseif k === :NULL
        return Node(:const, _NULLV, t.line, t.col)
    elseif k === :PLACEHOLDER
        return Node(:placeholder, nothing, t.line, t.col)
    elseif k === :LBRACE
        items = Node[]
        while true
            n = _peek!(P)
            if n.kind === :RBRACE
                _next!(P); break
            elseif n.kind === :SEMI || n.kind === :NL
                _next!(P); continue
            end
            push!(items, _expr!(P, 0, :assign))
            n = _peek!(P)
            (n.kind === :SEMI || n.kind === :NL || n.kind === :RBRACE) || _synerr(P, n)
        end
        P.L.eat = false
        return _mkcall("{", items, t.line, t.col)
    elseif k === :LPAREN
        e = _expr!(P, 0, :assign)
        _expect!(P, :RPAREN)
        return _mkcall("(", Node[e], t.line, t.col)
    elseif k === :MINUS || k === :PLUS
        return _mkcall(k === :MINUS ? "-" : "+", Node[_expr!(P, 18, :expr)], t.line, t.col)
    elseif k === :BANG
        return _mkcall("!", Node[_expr!(P, 11, :expr)], t.line, t.col)
    elseif k === :TILDE
        return _mkcall("~", Node[_expr!(P, 8, :expr)], t.line, t.col)
    elseif k === :QUESTION
        return _mkcall("?", Node[_expr!(P, 1, :assign)], t.line, t.col)
    elseif k === :FUNCTION || k === :BACKSLASH
        _expect!(P, :LPAREN)
        formals = Union{Nothing,String}[]
        defs = Node[]
        if _peek!(P).kind !== :RPAREN
            while true
                s = _next!(P)
                s.kind === :SYMBOL || _synerr(P, s)
                push!(formals, String(s.val))
                if _peek!(P).kind === :EQ_ASSIGN
                    _next!(P)
                    push!(defs, _expr!(P, 0, :help))
                else
                    push!(defs, _EMPTY)
                end
                n = _peek!(P)
                n.kind === :COMMA && (_next!(P); continue)
                n.kind === :RPAREN && break
                _synerr(P, n)
            end
        end
        _expect!(P, :RPAREN)
        P.L.eat = true
        body = _expr!(P, 2, :assign)
        return Node(:call, "function", vcat(Node[body], defs), vcat(Union{Nothing,String}[nothing], formals), t.line, t.col)
    elseif k === :IF
        _expect!(P, :LPAREN)
        cond = _expr!(P, 0, :help)
        _expect!(P, :RPAREN)
        P.L.eat = true
        yes = _expr!(P, 2, :assign)
        if _peek!(P).kind === :ELSE
            _next!(P)
            no = _expr!(P, 4, :assign)
            return _mkcall("if", Node[cond, yes, no], t.line, t.col)
        end
        return _mkcall("if", Node[cond, yes], t.line, t.col)
    elseif k === :FOR
        _expect!(P, :LPAREN)
        s = _expect!(P, :SYMBOL)
        _expect!(P, :IN)
        seq = _expr!(P, 0, :help)
        _expect!(P, :RPAREN)
        P.L.eat = true
        body = _expr!(P, 2, :assign)
        return _mkcall("for", Node[Node(:sym, s.val), seq, body], t.line, t.col)
    elseif k === :WHILE
        _expect!(P, :LPAREN)
        cond = _expr!(P, 0, :help)
        _expect!(P, :RPAREN)
        P.L.eat = true
        body = _expr!(P, 2, :assign)
        return _mkcall("while", Node[cond, body], t.line, t.col)
    elseif k === :REPEAT
        return _mkcall("repeat", Node[_expr!(P, 2, :assign)], t.line, t.col)
    elseif k === :NEXT || k === :BREAK
        return _mkcall(String(t.val), Node[], t.line, t.col)
    end
    _synerr(P, t)
end

function _sublist!(P::Parser, closer::Symbol)
    args = Node[]; nms = Union{Nothing,String}[]
    while true
        t = _peek!(P)
        if t.kind === :COMMA || t.kind === closer
            push!(args, _EMPTY); push!(nms, nothing)
        elseif t.kind === :SYMBOL || t.kind === :STR || t.kind === :NULL
            _next!(P)
            if _peek!(P).kind === :EQ_ASSIGN
                _next!(P)
                nm = t.kind === :NULL ? "NULL" : String(t.val)
                t3 = _peek!(P)
                if t3.kind === :COMMA || t3.kind === closer
                    push!(args, _EMPTY)
                else
                    push!(args, _expr!(P, 0, :help))
                end
                push!(nms, nm)
            else
                push!(args, _expr!(P, 0, :help, t)); push!(nms, nothing)
            end
        else
            push!(args, _expr!(P, 0, :help)); push!(nms, nothing)
        end
        t = _next!(P)
        t.kind === :COMMA && continue
        t.kind === closer && break
        _synerr(P, t)
    end
    return args, nms
end

function _postfix!(P::Parser, lhs::Node, t::Tok)
    if t.kind === :LPAREN
        args, nms = _sublist!(P, :RPAREN)
        if length(args) == 1 && args[1].head === :empty && nms[1] === nothing
            args = Node[]; nms = Union{Nothing,String}[]
        end
        if lhs.head === :sym
            return Node(:call, lhs.val, args, nms, lhs.line, lhs.col)
        elseif lhs.head === :const && lhs.val isa CHR && length(lhs.val) == 1 && lhs.val[1] !== missing
            return Node(:call, lhs.val[1], args, nms, lhs.line, lhs.col)
        end
        return Node(:callx, lhs, args, nms, lhs.line, lhs.col)
    end
    args, nms = _sublist!(P, :RBRACKET)
    t.kind === :LBB && _expect!(P, :RBRACKET)
    return Node(:call, t.kind === :LBB ? "[[" : "[", vcat(Node[lhs], args), vcat(Union{Nothing,String}[nothing], nms),
                t.line, t.col)
end

_has_placeholder(e::Node) = e.head === :placeholder || any(_has_placeholder, e.args) ||
                            (e.head === :callx && _has_placeholder(e.val))

function _parse_all(s::String)
    L = Lexer(s * "\n")
    P = Parser(L, nothing)
    exprs = Node[]
    while true
        L.cstack = [' ']; L.saved = nothing; L.eat = false; P.la = nothing
        t = _peek!(P)
        t.kind === :END && break
        if t.kind === :NL
            _next!(P); continue
        end
        e = _expr!(P, 0, :assign)
        t = _next!(P)
        (t.kind === :NL || t.kind === :SEMI) || _synerr(P, t)
        if _has_placeholder(e)
            error("invalid use of pipe placeholder (<input>:$(t.kind === :NL ? L.line - 1 : L.line):$(L.col))")
        end
        push!(exprs, e)
    end
    return exprs, L.warns
end

const _CACHE = Dict{String,Any}()
const _CACHE_LOCK = ReentrantLock()

"""
    parse_r(s) -> Vector{Node}

Text in R-Syntax zerlegen wie `parse(text = s)` (mehrere Elemente von `s`
werden zeilenweise verbunden). Syntaxfehler → `error` mit R's Meldung;
Warnungen des Lexers (z. B. zu `1.5L`) bei jedem Aufruf. Ergebnisse werden
zwischengespeichert.
"""
function parse_r(s::AbstractString)
    k = String(s)
    exprs, warns = lock(_CACHE_LOCK) do
        get!(_CACHE, k) do
            _parse_all(k)
        end
    end
    for w in warns
        _warn(w)
    end
    return exprs
end
parse_r(s::AbstractVector{<:AbstractString}) = parse_r(join(s, "\n"))

# ═══════════════════════════════════════════════════════════════════════════
# Werte und Umwandlungen
# ═══════════════════════════════════════════════════════════════════════════

_int_ok(x::Integer) = -_IMAX <= x <= _IMAX
_int_ok(x) = false

"Julia-Wert → R-Vektor (`nothing`, wenn der Wert keine Daten sind)."
function from_julia(v)
    v === nothing && return _NULLV
    v === missing && return LGL([missing])
    v isa Bool && return LGL([v])
    v isa Integer && return _int_ok(v) ? INT([Int(v)]) : NUM([Float64(v)])
    v isa Real && return NUM([Float64(v)])
    v isa AbstractString && return CHR([String(v)])
    v isa Symbol && return CHR([String(v)])
    v isa Date && return DAT([v])
    v isa Dates.DateTime && return DAT([Date(v)])
    v isa SimLev.RVector && return from_julia(v.values)
    v isa SimLev.RFmt.RFactor && return CHR(collect(v))
    v isa SimLev.NamedMat && return from_julia(vec(v.data))
    v isa Tuple && return from_julia(collect(v))
    v isa AbstractArray || return nothing
    v = vec(collect(v))
    T = eltype(v)
    T <: Union{Missing,Bool} && return LGL(v)
    if T <: Union{Missing,Integer}
        all(x -> x === missing || _int_ok(x), v) && return INT(Union{Missing,Int}[x === missing ? missing : Int(x) for x in v])
        return NUM(Float64[x === missing ? _NA : Float64(x) for x in v])
    end
    T <: Union{Missing,Real} && return NUM(Float64[x === missing ? _NA : Float64(x) for x in v])
    T <: Union{Missing,AbstractString} && return CHR(Union{Missing,String}[x === missing ? missing : String(x) for x in v])
    T <: Union{Missing,Date} && return DAT(v)
    T <: Union{Missing,Dates.DateTime} && return DAT(Union{Missing,Date}[x === missing ? missing : Date(x) for x in v])
    all(x -> x === missing || x isa Bool, v) && return LGL(v)
    all(x -> x === missing || (x isa Integer && !(x isa Bool) && _int_ok(x)), v) &&
        return INT(Union{Missing,Int}[x === missing ? missing : Int(x) for x in v])
    all(x -> x === missing || (x isa Real && !(x isa Bool)), v) && return NUM(Float64[x === missing ? _NA : Float64(x) for x in v])
    all(x -> x === missing || x isa AbstractString, v) && return CHR(Union{Missing,String}[x === missing ? missing : String(x) for x in v])
    all(x -> x === missing || x isa Date, v) && return DAT(v)
    return nothing
end

"R-Vektor → natürlicher Julia-Vektor (für Aufrufe von Julia-Funktionen aus `env`)."
to_julia(v::LGL) = any(ismissing, v) ? v : Vector{Bool}(v)
to_julia(v::INT) = any(ismissing, v) ? v : Vector{Int}(v)
to_julia(v::CHR) = any(ismissing, v) ? v : Vector{String}(v)
to_julia(v::DAT) = any(ismissing, v) ? v : Vector{Date}(v)
to_julia(v) = v

_isna_num(x::Float64) = isnan(x)
_days(d::Date) = Dates.value(d - _EPOCH)
_i2d(x::Union{Missing,Int}) = x === missing ? _NA : Float64(x)

_as_lgl(v::LGL) = v
_as_lgl(v::INT) = LGL([x === missing ? missing : x != 0 for x in v])
_as_lgl(v::NUM) = LGL([isnan(x) ? missing : x != 0 for x in v])
_lgl_str(x) = x === missing ? missing : x in ("TRUE", "true", "T", "True") ? true :
              x in ("FALSE", "false", "F", "False") ? false : missing
_as_lgl(v::CHR) = LGL([_lgl_str(x) for x in v])
_as_lgl(v::DAT) = LGL([x === missing ? missing : _days(x) != 0 for x in v])

_as_num(v::NUM) = v
_as_num(v::LGL) = NUM([x === missing ? _NA : Float64(x) for x in v])
_as_num(v::INT) = NUM([_i2d(x) for x in v])
_as_num(v::DAT) = NUM([x === missing ? _NA : Float64(_days(x)) for x in v])
function _as_num(v::CHR)
    bad = false
    out = NUM(undef, length(v))
    for i in eachindex(v)
        out[i], b = _str2num(v[i])
        bad |= b
    end
    bad && _warn("NAs introduced by coercion")
    out
end

_as_int(v::INT) = v
_as_int(v::LGL) = INT([x === missing ? missing : Int(x) for x in v])
function _dbl2int(x::Float64, flag::Ref{Bool})
    isnan(x) && return missing
    if x >= 2147483648.0 || x <= -2147483648.0
        flag[] = true
        return missing
    end
    return Int(trunc(x))
end
function _as_int(v::NUM)
    f = Ref(false)
    out = INT([_dbl2int(x, f) for x in v])
    f[] && _warn("NAs introduced by coercion to integer range")
    out
end
function _as_int(v::CHR)
    fna = false; f = Ref(false)
    out = INT(undef, length(v))
    for i in eachindex(v)
        x, b = _str2num(v[i])
        fna |= b
        out[i] = _dbl2int(x, f)
    end
    fna && _warn("NAs introduced by coercion")
    f[] && _warn("NAs introduced by coercion to integer range")
    out
end
_as_int(v::DAT) = _as_int(_as_num(v))

function _as_chr(v::NUM)
    isempty(v) && return CHR()
    r = SimLev.RFmt.as_character(v)
    r isa AbstractVector || (r = [r])
    CHR(Union{Missing,String}[x === missing || x === nothing ? missing : String(x) for x in r])
end
_as_chr(v::CHR) = v
_as_chr(v::INT) = CHR([x === missing ? missing : string(x) for x in v])
_as_chr(v::LGL) = CHR([x === missing ? missing : x ? "TRUE" : "FALSE" for x in v])
_as_chr(v::DAT) = CHR([x === missing ? missing : Dates.format(x, "yyyy-mm-dd") for x in v])

function _as_date(v::CHR)
    DAT([x === missing ? missing : (d = tryparse(Date, strip(x)); d === nothing ?
                                    (d2 = tryparse(Date, replace(strip(x), "/" => "-")); d2 === nothing ?
                                     error("character string is not in a standard unambiguous format") : d2) : d) for x in v])
end
_as_date(v::DAT) = v
_as_date(v::NUM) = DAT([isnan(x) ? missing : _EPOCH + Day(Int(floor(x))) for x in v])
_as_date(v::Union{LGL,INT}) = _as_date(_as_num(v))

_na_of(::LGL) = missing
_na_of(::INT) = missing
_na_of(::NUM) = _NA
_na_of(::CHR) = missing
_na_of(::DAT) = missing
_empty_like(v::Vector) = similar(v, 0)
_isna_el(x) = x === missing || (x isa Float64 && isnan(x))

_rtype(::LGL) = 1
_rtype(::INT) = 2
_rtype(::NUM) = 3
_rtype(::CHR) = 4
_rtype(::DAT) = 3
_coerce(v, t::Int) = t == 1 ? _as_lgl(v) : t == 2 ? _as_int(v) : t == 3 ? _as_num(v) : _as_chr(v)

_rclass(::LGL) = "logical"
_rclass(::INT) = "integer"
_rclass(::NUM) = "numeric"
_rclass(::CHR) = "character"
_rclass(::DAT) = "Date"
_rtypeof(::LGL) = "logical"
_rtypeof(::INT) = "integer"
_rtypeof(::NUM) = "double"
_rtypeof(::CHR) = "character"
_rtypeof(::DAT) = "double"

_rec(v, i) = v[(i-1)%length(v)+1]
function _len2(a, b)
    na, nb = length(a), length(b)
    (na == 0 || nb == 0) && return 0
    n = max(na, nb)
    n % min(na, nb) == 0 || _warn("longer object length is not a multiple of shorter object length")
    return n
end

_scoll(a::String, b::String) = isdefined(SimLev.RStats, :str_collate) ? SimLev.RStats.str_collate(a, b) :
                               (c = cmp(a, b); c < 0 ? -1 : c > 0 ? 1 : 0)

# ═══════════════════════════════════════════════════════════════════════════
# Operatoren
# ═══════════════════════════════════════════════════════════════════════════

const _LDBL_EPS = 1.0842021724855044e-19   # LDBL_EPSILON (c_eps in arithmetic.c)

# NaN-Operanden wie SSE2 auf x86-64 (R): der erste NaN-Operand setzt sich durch (beruhigt)
_qnan(x::Float64) = reinterpret(Float64, reinterpret(UInt64, x) | 0x0008000000000000)
@inline function _nanop(x::Float64, y::Float64)
    isnan(x) && return _qnan(x)
    return _qnan(y)
end

"R's `myfmod(x1, x2)` (`x1 %% x2`)."
function r_fmod(x1::Float64, x2::Float64)
    x2 == 0.0 && return NaN
    if abs(x2) * _LDBL_EPS > 1 && isfinite(x1) && abs(x1) <= abs(x2)
        return abs(x1) == abs(x2) ? 0.0 : ((x1 < 0 && x2 > 0) || (x2 < 0 && x1 > 0)) ? x1 + x2 : x1
    end
    q = x1 / x2
    (isfinite(q) && abs(q) * _LDBL_EPS > 1) && _warn("probable complete loss of accuracy in modulus")
    # NaN-Operanden: x87 liefert die NaN mit der größeren Mantisse, NA schlägt also NaN
    (isnan(x1) || isnan(x2)) && return (SimLev.isna_strict(x1) || SimLev.isna_strict(x2)) ? _NA : NaN
    L = SimLev.F80
    tmp = L(x1) - L(floor(q)) * L(x2)
    return Float64(tmp - floor(tmp / L(x2)) * L(x2))
end

"R's `myfloor(x1, x2)` (`x1 %/% x2`)."
function r_idiv(x1::Float64, x2::Float64)
    q = x1 / x2
    (x2 == 0.0 || abs(q) * _LDBL_EPS > 1 || !isfinite(q)) && return q
    abs(q) < 1 && return q < 0 ? -1.0 : (((x1 < 0 && x2 > 0) || (x1 > 0 && x2 < 0)) ? -1.0 : 0.0)
    L = SimLev.F80
    tmp = L(x1) - L(floor(q)) * L(x2)
    return Float64(L(floor(q)) + floor(tmp / L(x2)))
end

function _iop(op::String, x::Union{Missing,Int}, y::Union{Missing,Int}, of::Ref{Bool})
    if op == "%%"
        (x === missing || y === missing || y == 0) && return missing
        return (x >= 0 && y > 0) ? x % y : Int(r_fmod(Float64(x), Float64(y)))
    elseif op == "%/%"
        (x === missing || y === missing || y == 0) && return missing
        return Int(floor(Float64(x) / Float64(y)))
    end
    (x === missing || y === missing) && return missing
    z = op == "+" ? x + y : op == "-" ? x - y : x * y
    if !_int_ok(z)
        of[] = true
        return missing
    end
    return z
end

function _arith(op::String, a, b)
    (a isa DAT || b isa DAT) && return _date_arith(op, a, b)
    (a isa CHR || b isa CHR) && error("non-numeric argument to binary operator")
    isint = a isa Union{LGL,INT} && b isa Union{LGL,INT}
    if isint && op in ("+", "-", "*", "%%", "%/%")
        A = _as_int(a); B = _as_int(b)
        n = _len2(A, B)
        out = INT(undef, n)
        of = Ref(false)
        for i in 1:n
            out[i] = _iop(op, _rec(A, i), _rec(B, i), of)
        end
        of[] && _warn("NAs produced by integer overflow")
        return out
    end
    if isint && op == "^"
        A = _as_int(a); B = _as_int(b)
        n = _len2(A, B)
        out = NUM(undef, n)
        for i in 1:n
            x = _rec(A, i); y = _rec(B, i)
            out[i] = (x === 1 || y === 0) ? 1.0 : (x === missing || y === missing) ? _NA : SimLev.r_pow(Float64(x), Float64(y))
        end
        return out
    end
    A = _as_num(a); B = _as_num(b)
    n = _len2(A, B)
    out = NUM(undef, n)
    @inbounds for i in 1:n
        x = _rec(A, i); y = _rec(B, i)
        out[i] = if op == "%%"
            r_fmod(x, y)
        elseif op == "%/%"
            r_idiv(x, y)
        elseif op == "^"
            (isnan(x) || isnan(y)) ? (y == 2.0 ? _nanop(x, x) : (x == 1.0 || y == 0.0) ? 1.0 : _nanop(x, y)) : SimLev.r_pow(x, y)
        elseif isnan(x) || isnan(y)
            _nanop(x, y)
        else
            op == "+" ? x + y : op == "-" ? x - y : op == "*" ? x * y : x / y
        end
    end
    return out
end

function _date_arith(op, a, b)
    if op == "-" && a isa DAT && b isa DAT
        return _arith("-", _as_num(a), _as_num(b))
    end
    (op in ("+", "-")) || error("$op not defined for \"Date\" objects")
    (a isa DAT && b isa DAT) && error("binary + is not defined for \"Date\" objects")
    (b isa DAT && op == "-") && error("can only subtract from \"Date\" objects")
    r = _arith(op, _as_num(a), _as_num(b))
    return DAT([isnan(x) ? missing : _EPOCH + Day(Int(floor(x))) for x in r])
end

_cmpres(op::String, c::Int) = op == "<" ? c < 0 : op == ">" ? c > 0 : op == "<=" ? c <= 0 :
                               op == ">=" ? c >= 0 : op == "==" ? c == 0 : c != 0

function _compare(op::String, a, b)
    if a isa DAT || b isa DAT
        a = a isa CHR ? _as_date(a) : a
        b = b isa CHR ? _as_date(b) : b
        return _compare(op, _as_num(a), _as_num(b))
    end
    n = _len2(a, b)
    r = LGL(undef, n)
    if a isa CHR || b isa CHR
        A = _as_chr(a); B = _as_chr(b)
        for i in 1:n
            x = _rec(A, i); y = _rec(B, i)
            r[i] = if x === missing || y === missing
                missing
            elseif op == "==" || op == "!="
                (x == y) == (op == "==")
            elseif x == y
                op == "<=" || op == ">="
            else
                _cmpres(op, _scoll(x, y))
            end
        end
        return r
    end
    A = _as_num(a); B = _as_num(b)
    @inbounds for i in 1:n
        x = _rec(A, i); y = _rec(B, i)
        r[i] = (isnan(x) || isnan(y)) ? missing :
               (op == "<" ? x < y : op == ">" ? x > y : op == "<=" ? x <= y : op == ">=" ? x >= y : op == "==" ? x == y : x != y)
    end
    return r
end

function _check_logic(v, op)
    v isa CHR && error("operations are possible only for numeric, logical or complex types")
    v isa DAT && error("$op not defined for \"Date\" objects")
    _as_lgl(v)
end

function _logic(op::String, a, b)
    (a isa DAT || b isa DAT) && error("$op not defined for \"Date\" objects")
    A = _check_logic(a, op); B = _check_logic(b, op)
    n = _len2(A, B); r = LGL(undef, n)
    for i in 1:n
        x = _rec(A, i); y = _rec(B, i)
        r[i] = op == "&" ? ((x === false || y === false) ? false : (x === missing || y === missing) ? missing : true) :
                           ((x === true || y === true) ? true : (x === missing || y === missing) ? missing : false)
    end
    return r
end

function _scalar_lgl(v, op, which = "x")
    length(v) > 1 && error("'length = $(length(v))' in coercion to 'logical(1)'")
    (v === _NULLV || v isa CHR) && error("invalid '$which' type in 'x $op y'")
    length(v) == 0 && return missing
    return _as_lgl(v)[1]
end

# match(x, table) wie R: NA trifft nur NA, NaN nur NaN, -0 == 0
function _match_eq(x::Float64, y::Float64)
    (isnan(x) || isnan(y)) && return isnan(x) && isnan(y) && SimLev.isna_strict(x) == SimLev.isna_strict(y)
    x == y
end
function _in(a, b)
    if a isa CHR || b isa CHR
        A = _as_chr(a); B = _as_chr(b)
        return LGL([any(y -> (x === missing ? y === missing : (y !== missing && x == y)), B) for x in A])
    end
    A = _as_num(a); B = _as_num(b)
    return LGL([any(y -> _match_eq(x, y), B) for x in A])
end

function _asreal1(v)
    v isa CHR && return _as_num(CHR([v[1]]))[1]
    return _as_num(v isa DAT ? _as_num(v) : v)[1]
end
function _colon(a, b)
    na, nb = length(a), length(b)
    if na != 1 || nb != 1
        (na == 0 || nb == 0) && error("argument of length 0")
        _warn("numerical expression has $(na > 1 ? na : nb) elements: only the first used")
    end
    n1 = _asreal1(a); n2 = _asreal1(b)
    (isnan(n1) || isnan(n2)) && error("NA/NaN argument")
    r = abs(n2 - n1)
    r >= 4.503599627370496e15 && error("result would be too long a vector")
    inr(v) = -2147483648.0 < v <= 2147483647.0
    if n1 == trunc(n1) && n2 == trunc(n2)
        lo, hi = n1, n2
        if inr(lo) && inr(hi)
            rg = Int(lo) <= Int(hi) ? (Int(lo):Int(hi)) : (Int(lo):-1:Int(hi))
            return INT(collect(Union{Missing,Int}, rg))
        end
        n = Int(r) + 1
        return NUM([n1 <= n2 ? n1 + (i - 1) : n1 - (i - 1) for i in 1:n])
    end
    n = Int(floor(r + 1 + Float64(eps(Float32))))
    useint = n1 <= 2147483647.0 && n1 == trunc(n1)
    if useint
        if n1 <= -2147483648.0 || n1 > 2147483647.0
            useint = false
        else
            rr = n1 + (n1 <= n2 ? n - 1 : -(n - 1))
            (rr <= -2147483648.0 || rr > 2147483647.0) && (useint = false)
        end
    end
    if useint
        s = Int(n1)
        return INT(Union{Missing,Int}[n1 <= n2 ? s + (i - 1) : s - (i - 1) for i in 1:n])
    end
    return NUM([n1 <= n2 ? n1 + (i - 1) : n1 - (i - 1) for i in 1:n])
end

function _not(v)
    (v isa CHR || v === _NULLV) && error("invalid argument type")
    v isa DAT && error("unary ! not defined for \"Date\" objects")
    v isa LGL && return LGL([x === missing ? missing : !x for x in v])
    v isa INT && return LGL([x === missing ? missing : x == 0 for x in v])
    return LGL([isnan(x) ? missing : x == 0 for x in v])
end

function _unary(op::String, v)
    (v isa CHR || v === _NULLV) && error("invalid argument to unary operator")
    if v isa DAT
        op == "+" && return v
        error("unary - is not defined for \"Date\" objects")
    end
    if v isa Union{LGL,INT}
        x = _as_int(v)
        return op == "-" ? INT([t === missing ? missing : -t for t in x]) : x
    end
    return op == "-" ? NUM([-t for t in v]) : v
end

# ═══════════════════════════════════════════════════════════════════════════
# Indizierung (subscript.c)
# ═══════════════════════════════════════════════════════════════════════════

# Index-Vektor (1-basiert, `missing` = NA) für x[s] mit length(x) == nx
function _subscript(s, nx::Int)
    if s isa LGL
        ns = length(s)
        ns == 0 && return Union{Missing,Int}[]
        nmax = max(ns, nx)
        out = Union{Missing,Int}[]
        for i in 1:nmax
            v = s[(i-1)%ns+1]
            v === missing ? push!(out, missing) : v && push!(out, i)
        end
        return out
    elseif s isa CHR
        return Union{Missing,Int}[missing for _ in s]
    elseif s isa INT
        neg = false; isna = false; mx = 0
        for v in s
            if v === missing
                isna = true
            elseif v < 0
                neg = true
            elseif v > mx
                mx = v
            end
        end
        if neg
            (mx == 0 && !isna) || error("only 0's may be mixed with negative subscripts")
            keep = trues(nx)
            for v in s
                v !== missing && v < 0 && -v <= nx && (keep[-v] = false)
            end
            return Union{Missing,Int}[i for i in 1:nx if keep[i]]
        end
        return Union{Missing,Int}[v for v in s if v === missing || v != 0]
    end
    d = _as_num(s)
    mn = 0.0; mx = 0.0; isna = false
    for v in d
        if isfinite(v)
            v < mn && (mn = v); v > mx && (mx = v)
        else
            isna = true
        end
    end
    if mn <= -1
        (mx < 1 && !isna) || error("only 0's may be mixed with negative subscripts")
        keep = trues(nx)
        for v in d
            (isfinite(v) && v <= -1 && -v < nx + 1.0) && (keep[Int(trunc(-v))] = false)
        end
        return Union{Missing,Int}[i for i in 1:nx if keep[i]]
    end
    out = Union{Missing,Int}[]
    for v in d
        if !isfinite(v)
            push!(out, missing)
        elseif trunc(v) != 0
            push!(out, v > 4.0e18 ? typemax(Int) : Int(trunc(v)))
        end
    end
    return out
end

function _index(x, s)
    nx = length(x)
    idx = _subscript(s, nx)
    out = similar(x, length(idx))
    na = _na_of(x)
    for (k, i) in enumerate(idx)
        out[k] = (i === missing || i > nx) ? na : x[i]
    end
    return out
end

function _index2(x, s)
    ls = length(s)
    ls > 1 && error("attempt to select more than one element in vectorIndex")
    ls < 1 && error("attempt to select less than one element in get1index")
    nx = length(x)
    indx = -1
    if s isa Union{LGL,INT}
        i = s[1] === missing ? missing : Int(s[1])
        if i !== missing
            if i > 0
                indx = i - 1
            elseif i == 0 || nx < 2
                error("attempt to select less than one element in integerOneIndex")
            elseif nx == 2 && i > -3
                indx = 2 + i
            else
                error("attempt to select more than one element in integerOneIndex")
            end
        end
    elseif s isa Union{NUM,DAT}
        d = _as_num(s)[1]
        if !isnan(d)
            if d >= 1
                isfinite(d) && (indx = d - 1 > 4.0e18 ? typemax(Int) - 1 : Int(trunc(d - 1)))
            elseif d > -1 || nx < 2
                error(d <= -1 ? "invalid negative subscript in get1index <real>" :
                      "attempt to select less than one element in get1index <real>")
            elseif nx == 2 && d > -3
                indx = 2 + Int(trunc(d))
            else
                error(d <= -1 ? "invalid negative subscript in get1index <real>" :
                      "attempt to select more than one element in get1index <real>")
            end
        end
    end
    (indx < 0 || indx >= nx) && error("subscript out of bounds")
    return x[indx+1:indx+1]
end

# ═══════════════════════════════════════════════════════════════════════════
# Funktionen
# ═══════════════════════════════════════════════════════════════════════════

# Ausdruck → Text wie deparse (für Fehlermeldungen)
function _deparse(e::Node)
    e.head === :empty && return ""
    e.head === :placeholder && return "_"
    e.head === :sym && return String(e.val)
    if e.head === :const
        v = e.val
        isempty(v) && return "NULL"
        x = v[1]
        v isa LGL && return x === missing ? "NA" : x ? "TRUE" : "FALSE"
        v isa INT && return x === missing ? "NA_integer_" : "$(x)L"
        v isa CHR && return x === missing ? "NA_character_" : repr(x)
        v isa NUM && return isnan(x) ? (SimLev.isna_strict(x) ? "NA_real_" : "NaN") : _as_chr(NUM([x]))[1]
        return "?"
    end
    args = [(nm === nothing ? "" : nm * " = ") * _deparse(a) for (a, nm) in zip(e.args, e.names)]
    if e.head === :call
        f = String(e.val)
        if length(e.args) == 2 && (f in _CMP || f in ("+", "-", "*", "/", "&", "|", "&&", "||", "<-", "=", "~") || startswith(f, "%"))
            return _deparse(e.args[1]) * " $f " * _deparse(e.args[2])
        elseif length(e.args) == 2 && f in ("^", ":", "\$", "@")
            return _deparse(e.args[1]) * f * _deparse(e.args[2])
        elseif length(e.args) == 1 && f in ("-", "+", "!", "~")
            return f * _deparse(e.args[1])
        elseif f == "("
            return "(" * _deparse(e.args[1]) * ")"
        elseif f == "[" || f == "[["
            cl = f == "[" ? "]" : "]]"
            return _deparse(e.args[1]) * f * join(args[2:end], ", ") * cl
        end
        return f * "(" * join(args, ", ") * ")"
    end
    return _deparse(e.val) * "(" * join(args, ", ") * ")"
end

# Argumente an Formale binden (match.arg-Regeln von R: exakt, partiell, Position)
function _bind(fname::String, args, nms, exprs, formals::Vector{String})
    nf = length(formals)
    dots = findfirst(==("..."), formals)
    val = Any[nothing for _ in 1:nf]
    used = falses(length(args))
    rest = Any[]; restn = Union{Nothing,String}[]
    for (i, nm) in enumerate(nms)
        nm === nothing && continue
        j = findfirst(==(nm), formals)
        if j !== nothing && formals[j] != "..."
            val[j] === nothing || error("formal argument \"$nm\" matched by multiple actual arguments")
            val[j] = args[i]; used[i] = true
        end
    end
    for (i, nm) in enumerate(nms)
        (nm === nothing || used[i]) && continue
        lim = dots === nothing ? nf : dots - 1
        cand = [j for j in 1:lim if val[j] === nothing && startswith(formals[j], nm)]
        if length(cand) == 1
            val[cand[1]] = args[i]; used[i] = true
        end
    end
    lim = dots === nothing ? nf : dots - 1
    j = 1
    for i in eachindex(args)
        used[i] && continue
        if nms[i] === nothing
            while j <= lim && val[j] !== nothing; j += 1; end
            if j <= lim
                val[j] = args[i]; used[i] = true; j += 1
                continue
            end
        end
        if dots !== nothing
            push!(rest, args[i]); push!(restn, nms[i]); used[i] = true
        end
    end
    if !all(used)
        un = [(nms[i] === nothing ? "" : nms[i] * " = ") * _deparse(exprs[i]) for i in eachindex(args) if !used[i]]
        error((length(un) == 1 ? "unused argument (" : "unused arguments (") * join(un, ", ") * ")")
    end
    return val, rest, restn
end

_missing_arg(nm) = error("argument \"$nm\" is missing, with no default")
_flag(v, dflt::Bool) = v === nothing ? dflt : (length(v) >= 1 && _as_lgl(v)[1] === true)

function _nan_warn(x::NUM, r::NUM)
    any(i -> isnan(r[i]) && !isnan(x[i]), eachindex(r)) && _warn("NaNs produced")
    r
end

function _prim1(fname, args, nms)
    length(args) == 1 || error("$(length(args)) arguments passed to '$fname' which requires 1")
    a = args[1]
    a === nothing && _missing_arg("x")
    return a
end

function _math1(fname::String, f)
    (args, nms, ex) -> begin
        a = _prim1(fname, args, nms)
        (a isa CHR || a isa DAT) && error("non-numeric argument to mathematical function")
        x = _as_num(a)
        _nan_warn(x, NUM([f(v) for v in x]))
    end
end
_sqrt(x::Float64) = x < 0 ? NaN : sqrt(x)

function _f_abs(args, nms, ex)
    a = _prim1("abs", args, nms)
    (a isa CHR || a isa DAT) && error("non-numeric argument to mathematical function")
    a isa Union{LGL,INT} && return INT([x === missing ? missing : abs(x) for x in _as_int(a)])
    return NUM([abs(v) for v in a])
end

function _f_log(args, nms, ex)
    v, _, _ = _bind("log", args, nms, ex, ["x", "base"])
    x = v[1]; b = v[2]
    x === nothing && _missing_arg("x")
    (x isa CHR || x isa DAT) && error("non-numeric argument to mathematical function")
    xn = _as_num(x)
    r = b === nothing ? NUM([SimLev.RLibm.log(t) for t in xn]) :
        (bb = _as_num(b)[1]; NUM([SimLev.RLibm.log(t, bb) for t in xn]))
    _nan_warn(xn, r)
end

function _f_round(args, nms, ex; signif = false)
    v, _, _ = _bind(signif ? "signif" : "round", args, nms, ex, ["x", "digits"])
    x = v[1]; d = v[2]
    x === nothing && _missing_arg("x")
    (x isa CHR || x isa DAT) && error("non-numeric argument to mathematical function")
    xn = _as_num(x)
    dv = d === nothing ? (signif ? 6.0 : 0.0) : _as_num(d)[1]
    signif && return NUM([Float64(SimLev.RFmt.signif(t, dv)) for t in xn])
    return NUM([Float64(SimLev.RFmt.r_round(t, dv)) for t in xn])
end

function _f_isna(args, nms, ex)
    v = _prim1("is.na", args, nms)
    LGL(v isa NUM ? [isnan(x) for x in v] : [x === missing for x in v])
end
function _f_isnan(args, nms, ex)
    v = _prim1("is.nan", args, nms)
    LGL(v isa NUM ? [isnan(x) && !SimLev.isna_strict(x) for x in v] : [false for _ in v])
end
function _f_isfinite(args, nms, ex)
    v = _prim1("is.finite", args, nms)
    LGL(v isa NUM ? [isfinite(x) for x in v] : v isa Union{LGL,INT} ? [x !== missing for x in v] : [false for _ in v])
end
function _f_isinfinite(args, nms, ex)
    v = _prim1("is.infinite", args, nms)
    LGL(v isa NUM ? [isinf(x) for x in v] : [false for _ in v])
end

function _f_ifelse(args, nms, ex)
    v, _, _ = _bind("ifelse", args, nms, ex, ["test", "yes", "no"])
    test, yes, no = v
    test === nothing && _missing_arg("test")
    t = test isa CHR ? _as_lgl(test) : test isa LGL ? test : _as_lgl(test)
    ans = Any[x for x in t]
    kind = 1
    ypos = [i for i in eachindex(t) if t[i] === true]
    npos = [i for i in eachindex(t) if t[i] === false]
    if !isempty(ypos)
        yes === nothing && _missing_arg("yes")
        isempty(yes) && error("replacement has length zero")
        kind = max(kind, _rtype(yes))
        for i in ypos; ans[i] = (yes, _rec(yes, i)); end
    end
    if !isempty(npos)
        no === nothing && _missing_arg("no")
        isempty(no) && error("replacement has length zero")
        kind = max(kind, _rtype(no))
        for i in npos; ans[i] = (no, _rec(no, i)); end
    end
    el(a) = a === missing ? missing : _coerce(similar_one(a[1], a[2]), kind)[1]
    similar_one(src, x) = (o = similar(src, 1); o[1] = x; o)
    if kind == 4
        return CHR(Union{Missing,String}[el(a) for a in ans])
    elseif kind == 3
        return NUM(Float64[a === missing ? _NA : el(a) for a in ans])
    elseif kind == 2
        return INT(Union{Missing,Int}[el(a) for a in ans])
    end
    return LGL(Union{Missing,Bool}[el(a) for a in ans])
end

function _f_pminmax(args, nms, ex, greater::Bool)
    narm = false; xs = Any[]
    for (a, nm) in zip(args, nms)
        if nm == "na.rm"
            narm = _flag(a, false)
        else
            a === nothing || push!(xs, a)
        end
    end
    isempty(xs) && error("no arguments")
    any(x -> x isa CHR || x isa DAT, xs) && error("invalid input type")
    kind = maximum(_rtype(x) for x in xs)
    any(isempty, xs) && return kind == 3 ? NUM() : INT()
    r = greater ? SimLev.RBase.pmax([_as_num(x) for x in xs]...; na_rm = narm) :
                  SimLev.RBase.pmin([_as_num(x) for x in xs]...; na_rm = narm)
    r = NUM(r isa SimLev.RVector ? r.values : r isa AbstractVector ? collect(r) : [r])
    kind == 3 && return r
    return INT([isnan(x) ? missing : Int(x) for x in r])
end

function _summary_args(args, nms)
    narm = false; vals = Any[]
    for (a, nm) in zip(args, nms)
        if nm == "na.rm"
            narm = _flag(a, false)
        else
            a === nothing && error("argument is missing, with no default")
            push!(vals, a)
        end
    end
    return vals, narm
end

function _f_anyall(args, nms, ex, isany::Bool)
    vals, narm = _summary_args(args, nms)
    res = isany ? false : true
    sawna = false
    for v in vals
        if v isa CHR || v isa NUM || v isa DAT
            v isa DAT && error("$(isany ? "any" : "all") not defined for \"Date\" objects")
            isempty(v) || _warn("coercing argument of type '$(_rtypeof(v))' to logical")
        end
        for x in _as_lgl(v)
            if x === missing
                narm || (sawna = true)
            elseif x == isany
                return LGL([isany])
            end
        end
    end
    return LGL([sawna ? missing : res])
end

# sum/min/max wie do_summary (summary.c)
function _f_sum(args, nms, ex)
    vals, narm = _summary_args(args, nms)
    for v in vals
        v isa CHR && error("invalid 'type' (character) of argument")
        v isa DAT && error("sum not defined for \"Date\" objects")
    end
    real = any(v -> v isa NUM, vals)
    anstype = real ? 3 : 2
    icum = 0; zcum = 0.0
    for v in vals
        isempty(v) && continue
        if v isa Union{LGL,INT}
            s = 0; hasna = false
            for x in v
                if x === missing
                    narm || (hasna = true; break)
                else
                    s += Int(x)
                end
            end
            if hasna
                return anstype == 2 ? INT([missing]) : NUM([_NA])
            end
            if anstype == 2
                t = Float64(icum) + Float64(s)
                if t > _IMAX || t < -_IMAX
                    anstype = 3; zcum = t
                else
                    icum += s
                end
            else
                zcum += Float64(s)
            end
        else
            if anstype == 2
                anstype = 3; zcum = Float64(icum)
            end
            zcum += SimLev.r_sum(v; na_rm = narm)
        end
    end
    anstype == 2 && return INT([icum])
    return NUM([zcum])
end

function _f_minmax(args, nms, ex, ismax::Bool)
    vals, narm = _summary_args(args, nms)
    if !isempty(vals) && all(v -> v isa DAT, vals)
        r = _f_minmax(vcat(Any[_as_num(v) for v in vals], Any[LGL([narm])]),
                      vcat(Union{Nothing,String}[nothing for _ in vals], Union{Nothing,String}["na.rm"]), ex, ismax)
        return r isa NUM ? _as_date(r) : r
    end
    anstype = 2
    icum = ismax ? -_IMAX - 1 : _IMAX
    icum_na = false
    zcum = ismax ? -Inf : Inf
    scum = missing
    empty = true
    for v in vals
        v isa DAT && (v = _as_num(v))
        if isempty(v)
            if v isa CHR
                if !empty && anstype == 2
                    scum = icum_na ? missing : string(icum)
                elseif !empty && anstype == 3
                    scum = _as_chr(NUM([zcum]))[1]
                end
                anstype = 4
            elseif _rtype(v) > anstype && anstype != 4
                (!empty && anstype == 2) && (zcum = icum_na ? _NA : Float64(icum))
                anstype = _rtype(v)
            end
            continue
        end
        updated = false
        if v isa Union{LGL,INT}
            # imin/imax
            s = 0; isna = false
            for x in v
                if x === missing
                    narm || (isna = true; updated = true; break)
                elseif !updated || (ismax ? x > s : x < s)
                    s = Int(x); updated = true
                end
            end
            if updated
                if anstype == 2
                    if icum_na
                    elseif isna || (ismax ? s > icum : s < icum)
                        isna ? (icum_na = true) : (icum = s)
                    end
                elseif anstype == 3
                    tmp = isna ? _NA : Float64(s)
                    zcum = _real_upd(zcum, tmp, ismax)
                else
                    stmp = isna ? missing : string(s)
                    scum = _str_upd(scum, stmp, empty, ismax)
                end
            end
        elseif v isa NUM
            if anstype == 2
                anstype = 3
                empty || (zcum = icum_na ? _NA : Float64(icum))
            end
            s = 0.0
            for x in v
                if isnan(x)
                    if !narm
                        SimLev.isna_strict(s) || (s = x)
                        updated = true
                    end
                elseif !updated || (ismax ? x > s : x < s)
                    s = x; updated = true
                end
            end
            if updated
                if anstype == 3
                    zcum = _real_upd(zcum, s, ismax)
                else
                    scum = _str_upd(scum, _as_chr(NUM([s]))[1], empty, ismax)
                end
            end
        else
            if !empty && anstype == 2
                scum = icum_na ? missing : string(icum)
            elseif !empty && anstype == 3
                scum = _as_chr(NUM([zcum]))[1]
            end
            anstype = 4
            ss = missing
            for x in v
                if x !== missing
                    if !updated || (ss !== x && (ismax ? _scoll(ss, x) < 0 : _scoll(ss, x) > 0))
                        ss = x; updated = true
                    end
                elseif !narm
                    ss = missing; updated = true; break
                end
            end
            updated && (scum = _str_upd(scum, ss, empty, ismax))
        end
        (empty && updated) && (empty = false)
    end
    if empty
        if anstype == 4
            _warn("no non-missing arguments, returning NA")
        else
            _warn(ismax ? "no non-missing arguments to max; returning -Inf" : "no non-missing arguments to min; returning Inf")
            anstype = 3
        end
    end
    anstype == 2 && return INT([icum_na ? missing : icum])
    anstype == 3 && return NUM([zcum])
    return CHR([scum])
end
function _real_upd(zcum::Float64, tmp::Float64, ismax::Bool)
    SimLev.isna_strict(zcum) && return zcum
    if isnan(tmp)
        return SimLev.isna_strict(tmp) ? tmp : zcum + tmp
    end
    (ismax ? tmp > zcum : tmp < zcum) && return tmp
    return zcum
end
function _str_upd(scum, stmp, empty::Bool, ismax::Bool)
    empty && return stmp
    scum === missing && return scum
    stmp === missing && return stmp
    (stmp != scum && (ismax ? _scoll(stmp, scum) > 0 : _scoll(stmp, scum) < 0)) && return stmp
    return scum
end

function _f_mean(args, nms, ex)
    v, rest, _ = _bind("mean", args, nms, ex, ["x", "trim", "na.rm", "..."])
    x = v[1]
    x === nothing && _missing_arg("x")
    if x isa DAT
        r = _f_mean(Any[_as_num(x), v[2], v[3]], Union{Nothing,String}[nothing, "trim", "na.rm"], ex)
        return _as_date(r)
    end
    if x isa CHR || x === _NULLV
        _warn("argument is not numeric or logical: returning NA")
        return NUM([_NA])
    end
    narm = _flag(v[3], false)
    trim = v[2] === nothing ? 0.0 : (length(v[2]) == 1 && !(v[2] isa CHR) ? _as_num(v[2])[1] :
                                     error("'trim' must be numeric of length one"))
    if narm
        x = x[[!_isna_el(t) for t in x]]
    end
    n = length(x)
    if trim > 0 && n > 0
        any(_isna_el, x) && return NUM([_NA])
        trim >= 0.5 && return _f_median(Any[x], Union{Nothing,String}[nothing], ex)
        lo = Int(floor(n * trim)) + 1
        hi = n + 1 - lo
        xs = SimLev.RStats.sort_partial(_as_num(x), unique([lo, hi]))
        if x isa Union{LGL,INT}
            return NUM([SimLev.r_mean_int(Int.(xs[lo:hi]))])
        end
        return NUM([SimLev.r_mean(xs[lo:hi])])
    end
    if x isa Union{LGL,INT}
        any(ismissing, x) && return NUM([_NA])
        return NUM([SimLev.r_mean_int(Int[t for t in x])])
    end
    return NUM([SimLev.r_mean(x)])
end

function _f_median(args, nms, ex)
    v, _, _ = _bind("median", args, nms, ex, ["x", "na.rm", "..."])
    x = v[1]
    x === nothing && _missing_arg("x")
    narm = _flag(v[2], false)
    if x isa DAT
        r = _f_median(Any[_as_num(x), v[2]], Union{Nothing,String}[nothing, "na.rm"], ex)
        return _as_date(r)
    end
    if narm
        x = x[[!_isna_el(t) for t in x]]
    elseif any(_isna_el, x)
        return x isa NUM ? NUM([_NA]) : (o = similar(x, 1); o[1] = missing; o)
    end
    n = length(x)
    n == 0 && return x isa NUM ? NUM([_NA]) : (o = similar(x, 1); o[1] = missing; o)
    half = (n + 1) ÷ 2
    if x isa CHR
        if isodd(n)
            xs = sort(collect(String, x); lt = (a, b) -> _scoll(a, b) < 0)
            return CHR([xs[half]])
        end
        _warn("argument is not numeric or logical: returning NA")
        return NUM([_NA])
    end
    if x isa Union{LGL,INT}
        r = SimLev.RStats.median(Int[t for t in x])
        r isa Integer || return NUM([Float64(r)])
        return x isa LGL ? LGL([r != 0]) : INT([Int(r)])
    end
    return NUM([Float64(SimLev.RStats.median(x))])
end

function _num_arg(x)
    x isa CHR && return _as_num(x)
    return _as_num(x)
end

function _f_var(args, nms, ex)
    v, _, _ = _bind("var", args, nms, ex, ["x", "y", "na.rm", "use"])
    x = v[1]
    x === nothing && _missing_arg("x")
    v[2] === nothing || error("RExpr: var(x, y) wird nicht unterstützt")
    narm = _flag(v[3], false)
    x isa DAT && error("is.atomic(x) is not TRUE")
    return NUM([Float64(SimLev.RStats.var(_num_arg(x); na_rm = narm))])
end

function _f_sd(args, nms, ex)
    v, _, _ = _bind("sd", args, nms, ex, ["x", "na.rm"])
    x = v[1]
    x === nothing && _missing_arg("x")
    narm = _flag(v[2], false)
    return NUM([Float64(SimLev.RStats.sd(_num_arg(x); na_rm = narm))])
end

function _f_quantile(args, nms, ex)
    v, _, _ = _bind("quantile", args, nms, ex, ["x", "probs", "na.rm", "names", "type", "digits", "..."])
    x = v[1]
    x === nothing && _missing_arg("x")
    probs = v[2] === nothing ? [0.0, 0.25, 0.5, 0.75, 1.0] : _as_num(v[2])
    narm = _flag(v[3], false)
    type = v[5] === nothing ? 7 : Int(_as_num(v[5])[1])
    xn = x isa CHR ? (any(ismissing, x) || !narm ? (narm ? x[.!ismissing.(x)] : x) : x) : x
    if x isa CHR
        any(ismissing, xn) && error("missing values and NaN's not allowed if 'na.rm' is FALSE")
        error("non-numeric argument to binary operator")
    end
    xv = _as_num(xn)
    r = SimLev.RStats.quantile(xv, probs; na_rm = narm, names = false, type = type)
    r = r isa AbstractVector ? NUM(collect(Float64, r)) : NUM([Float64(r)])
    return x isa DAT ? _as_date(r) : r
end

function _f_c(args, nms, ex)
    vals = Any[a for a in args if a !== nothing && !(a isa LGL && isempty(a))]
    isempty(vals) && return _NULLV
    if args[1] isa DAT
        return DAT(reduce(vcat, [a isa CHR ? _as_date(a) : _as_date(a) for a in vals]))
    end
    kind = maximum(_rtype(v) for v in vals)
    return reduce(vcat, [_coerce(v isa DAT ? _as_num(v) : v, kind) for v in vals])
end

function _f_length(args, nms, ex)
    v = _prim1("length", args, nms)
    return INT([length(v)])
end

function _f_nchar(args, nms, ex)
    v, _, _ = _bind("nchar", args, nms, ex, ["x", "type", "allowNA", "keepNA"])
    x = v[1]
    x === nothing && _missing_arg("x")
    tp = v[2] === nothing ? "chars" : _as_chr(v[2])[1]
    types = ["bytes", "chars", "width"]
    m = (tp === missing || isempty(tp)) ? Int[] : [i for i in 1:3 if startswith(types[i], tp)]
    isempty(m) && error("invalid 'type' argument")
    t = types[m[1]]
    kv = v[4] === nothing ? missing : _as_lgl(v[4])[1]
    keep = kv === missing ? t != "width" : kv
    s = x isa CHR ? x : _as_chr(x isa DAT ? _as_num(x) : x)
    return INT([z === missing ? (keep ? missing : 2) :
                t == "bytes" ? ncodeunits(z) : t == "chars" ? length(z) : textwidth(z) for z in s])
end

function _f_asnum(args, nms, ex)
    v, _, _ = _bind("as.numeric", args, nms, ex, ["x", "..."])
    return v[1] === nothing ? NUM() : _as_num(v[1])
end
function _f_asint(args, nms, ex)
    v, _, _ = _bind("as.integer", args, nms, ex, ["x", "..."])
    return v[1] === nothing ? INT() : _as_int(v[1])
end
function _f_aslgl(args, nms, ex)
    v, _, _ = _bind("as.logical", args, nms, ex, ["x", "..."])
    return v[1] === nothing ? LGL() : _as_lgl(v[1])
end
function _f_aschr(args, nms, ex)
    v, _, _ = _bind("as.character", args, nms, ex, ["x", "..."])
    return v[1] === nothing ? CHR() : _as_chr(v[1])
end
function _f_asdate(args, nms, ex)
    v, _, _ = _bind("as.Date", args, nms, ex, ["x", "..."])
    x = v[1]
    x === nothing && _missing_arg("x")
    x isa CHR && return _as_date(x)
    x isa DAT && return x
    x isa LGL && all(ismissing, x) && return DAT([missing for _ in x])
    return _as_date(_as_num(x))
end

function _f_cumsum(args, nms, ex)
    x = _prim1("cumsum", args, nms)
    if x isa Union{LGL,INT}
        out = INT([missing for _ in x])
        s = 0.0
        for i in eachindex(x)
            x[i] === missing && break
            s += Float64(x[i])
            if s > _IMAX || s < -_IMAX
                _warn("integer overflow in 'cumsum'; use 'cumsum(as.numeric(.))'")
                break
            end
            out[i] = Int(s)
        end
        return out
    end
    return NUM(SimLev.r_cumsum(_as_num(x)))
end

function _f_xor(args, nms, ex)
    v, _, _ = _bind("xor", args, nms, ex, ["x", "y"])
    (v[1] === nothing) && _missing_arg("x")
    (v[2] === nothing) && _missing_arg("y")
    a = _logic("|", v[1], v[2]); b = _logic("&", v[1], v[2])
    LGL([(p === missing || q === missing) ? missing : (p && !q) for (p, q) in zip(a, b)])
end

function _f_istf(args, nms, ex, val::Bool)
    v, _, _ = _bind(val ? "isTRUE" : "isFALSE", args, nms, ex, ["x"])
    x = v[1]
    x === nothing && _missing_arg("x")
    LGL([x isa LGL && length(x) == 1 && x[1] === val])
end

function _f_identity(args, nms, ex)
    v, _, _ = _bind("identity", args, nms, ex, ["x"])
    return v[1] === nothing ? _missing_arg("x") : v[1]
end

function _f_vector(fname::String, mk)
    (args, nms, ex) -> begin
        v, _, _ = _bind(fname, args, nms, ex, ["length"])
        n = v[1] === nothing ? 0 : _as_num(v[1])
        (length(n) != 1 || isnan(n[1]) || n[1] < 0) && error("invalid 'length' argument")
        return mk(Int(trunc(n[1])))
    end
end

function _f_rep(args, nms, ex)
    v, _, _ = _bind("rep", args, nms, ex, ["x", "times", "length.out", "each"])
    x = v[1]
    x === nothing && return LGL()
    each = v[4] === nothing ? 1 : (e = _as_num(v[4]); isempty(e) || isnan(e[1]) ? 1 : Int(trunc(e[1])))
    each < 0 && error("invalid 'each' argument")
    if each != 1
        x = x[[i for i in eachindex(x) for _ in 1:each]]
    end
    lo = v[3] === nothing ? nothing : (l = _as_num(v[3]); isempty(l) || isnan(l[1]) ? nothing : Int(trunc(l[1])))
    if lo !== nothing
        isempty(x) && return similar(x, lo) .= _na_of(x)
        return x[[(i - 1) % length(x) + 1 for i in 1:lo]]
    end
    tm = v[2] === nothing ? INT([1]) : v[2]
    tn = _as_num(tm)
    if length(tn) == 1
        (isnan(tn[1]) || tn[1] < 0) && error("invalid 'times' argument")
        t = Int(trunc(tn[1]))
        return x[[i for _ in 1:t for i in eachindex(x)]]
    end
    length(tn) == length(x) || error("invalid 'times' argument")
    any(t -> isnan(t) || t < 0, tn) && error("invalid 'times' argument")
    return x[[i for i in eachindex(x) for _ in 1:Int(trunc(tn[i]))]]
end

const _FUNS = Dict{String,Function}(
    "logical" => _f_vector("logical", n -> LGL(fill(false, n))),
    "integer" => _f_vector("integer", n -> INT(fill(0, n))),
    "numeric" => _f_vector("numeric", n -> NUM(zeros(n))),
    "double" => _f_vector("double", n -> NUM(zeros(n))),
    "character" => _f_vector("character", n -> CHR(fill("", n))),
    "rep" => _f_rep,
    "abs" => _f_abs, "sqrt" => _math1("sqrt", _sqrt),
    "exp" => _math1("exp", SimLev.RLibm.exp), "expm1" => _math1("expm1", SimLev.RLibm.expm1),
    "log1p" => _math1("log1p", SimLev.RLibm.log1p), "log2" => _math1("log2", SimLev.RLibm.log2),
    "log10" => _math1("log10", SimLev.RLibm.log10),
    "sin" => _math1("sin", SimLev.RLibm.sin), "cos" => _math1("cos", SimLev.RLibm.cos),
    "tan" => _math1("tan", SimLev.RLibm.tan), "tanh" => _math1("tanh", SimLev.RLibm.tanh),
    "atan" => _math1("atan", SimLev.RLibm.atan),
    "floor" => _math1("floor", floor), "ceiling" => _math1("ceiling", ceil), "trunc" => _math1("trunc", trunc),
    "sign" => _math1("sign", sign),
    "log" => _f_log, "round" => _f_round, "signif" => (a, n, e) -> _f_round(a, n, e; signif = true),
    "is.na" => _f_isna, "is.nan" => _f_isnan, "is.finite" => _f_isfinite, "is.infinite" => _f_isinfinite,
    "ifelse" => _f_ifelse,
    "pmin" => (a, n, e) -> _f_pminmax(a, n, e, false), "pmax" => (a, n, e) -> _f_pminmax(a, n, e, true),
    "min" => (a, n, e) -> _f_minmax(a, n, e, false), "max" => (a, n, e) -> _f_minmax(a, n, e, true),
    "sum" => _f_sum, "mean" => _f_mean, "median" => _f_median, "var" => _f_var, "sd" => _f_sd,
    "quantile" => _f_quantile,
    "any" => (a, n, e) -> _f_anyall(a, n, e, true), "all" => (a, n, e) -> _f_anyall(a, n, e, false),
    "length" => _f_length, "c" => _f_c, "nchar" => _f_nchar, "xor" => _f_xor,
    "isTRUE" => (a, n, e) -> _f_istf(a, n, e, true), "isFALSE" => (a, n, e) -> _f_istf(a, n, e, false),
    "as.numeric" => _f_asnum, "as.double" => _f_asnum, "as.integer" => _f_asint,
    "as.logical" => _f_aslgl, "as.character" => _f_aschr, "as.Date" => _f_asdate,
    "cumsum" => _f_cumsum, "identity" => _f_identity,
)

# ═══════════════════════════════════════════════════════════════════════════
# Auswertung
# ═══════════════════════════════════════════════════════════════════════════

struct Ctx
    cols::Dict{String,Any}
    env::Any
    locals::Dict{String,Any}
end

function _env_get(env, name::String)
    env === nothing && return nothing
    if env isa Module
        s = Symbol(name)
        isdefined(env, s) || return nothing
        return getglobal(env, s)
    elseif env isa NamedTuple
        s = Symbol(name)
        return haskey(env, s) ? getfield(env, s) : nothing
    elseif env isa SimLev.RList
        return haskey(env, name) ? env[name] : nothing
    elseif env isa AbstractDict
        haskey(env, name) && return env[name]
        haskey(env, Symbol(name)) && return env[Symbol(name)]
        return nothing
    end
    return nothing
end

const _MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                 "October", "November", "December"]

function _lookup(name::String, c::Ctx)
    haskey(c.locals, name) && return c.locals[name]
    haskey(c.cols, name) && return c.cols[name]
    v = _env_get(c.env, name)
    if v !== nothing && !(v isa Function) && !(v isa Module) && !(v isa Type)
        r = from_julia(v)
        r === nothing || return r
    end
    name == "T" && return LGL([true])
    name == "F" && return LGL([false])
    name == "pi" && return NUM([Float64(pi)])
    name == "letters" && return CHR([string(Char('a' + i)) for i in 0:25])
    name == "LETTERS" && return CHR([string(Char('A' + i)) for i in 0:25])
    name == "month.name" && return CHR(_MONTHS)
    name == "month.abb" && return CHR([m[1:3] for m in _MONTHS])
    error("object '$name' not found")
end

function _cond1(v)
    if v isa LGL && length(v) == 1 && v[1] !== missing
        return v[1]
    elseif v isa INT && length(v) == 1 && v[1] !== missing
        return v[1] != 0
    end
    len = length(v)
    len > 1 && error("the condition has length > 1")
    cond = missing
    if len > 0
        cond = v isa CHR ? _lgl_str(v[1]) : _as_lgl(v)[1]
    end
    if cond === missing
        error(len == 0 ? "argument is of length zero" :
              v isa LGL ? "missing value where TRUE/FALSE needed" : "argument is not interpretable as logical")
    end
    return cond
end

const _UNSUPPORTED = Set(["function", "for", "while", "repeat", "next", "break", "~", "?", "::", ":::", "<<-"])

# Primitive (ohne Argumentabgleich): leeres Argument ist ein Fehler
const _PRIMS = Set(["c", "sum", "min", "max", "any", "all", "length", "abs", "sqrt", "exp", "expm1", "log1p",
                    "log2", "log10", "sin", "cos", "tan", "tanh", "atan", "floor", "ceiling", "trunc", "sign",
                    "is.na", "is.nan", "is.finite", "is.infinite", "as.numeric", "as.double", "as.integer",
                    "as.logical", "as.character", "cumsum", "rep"])

function _ev(e::Node, c::Ctx)
    h = e.head
    h === :const && return e.val
    h === :sym && return _lookup(String(e.val), c)
    h === :empty && error("argument is missing, with no default")
    h === :callx && error("attempt to apply non-function")
    f = String(e.val); a = e.args
    if f == "("
        return _ev(a[1], c)
    elseif f == "{"
        r = _NULLV
        for x in a
            r = _ev(x, c)
        end
        return r
    elseif f == "if"
        if _cond1(_ev(a[1], c))
            return _ev(a[2], c)
        end
        return length(a) == 3 ? _ev(a[3], c) : _NULLV
    elseif f == "<-" || f == "="
        lhs = a[1]
        nm = lhs.head === :sym ? String(lhs.val) :
             (lhs.head === :const && lhs.val isa CHR && length(lhs.val) == 1 && lhs.val[1] !== missing) ? lhs.val[1] :
             (lhs.head === :call ? error("RExpr: Zuweisung an '$(_deparse(lhs))' wird nicht unterstützt") :
              error("invalid (do_set) left-hand side to assignment"))
        v = _ev(a[2], c)
        c.locals[nm] = v
        return v
    elseif f == "!" && length(a) == 1
        return _not(_ev(a[1], c))
    elseif (f == "-" || f == "+") && length(a) == 1
        return _unary(f, _ev(a[1], c))
    elseif f == "&&" || f == "||"
        x = _scalar_lgl(_ev(a[1], c), f)
        f == "&&" && x === false && return LGL([false])
        f == "||" && x === true && return LGL([true])
        y = _scalar_lgl(_ev(a[2], c), f, "y")
        return _logic(f == "&&" ? "&" : "|", LGL([x]), LGL([y]))
    elseif (f == "&" || f == "|") && length(a) == 2
        return _logic(f, _ev(a[1], c), _ev(a[2], c))
    elseif f in _CMP && length(a) == 2
        return _compare(f, _ev(a[1], c), _ev(a[2], c))
    elseif f in ("+", "-", "*", "/", "^", "%%", "%/%") && length(a) == 2
        return _arith(f, _ev(a[1], c), _ev(a[2], c))
    elseif f == "%in%" && length(a) == 2
        return _in(_ev(a[1], c), _ev(a[2], c))
    elseif f == ":" && length(a) == 2
        return _colon(_ev(a[1], c), _ev(a[2], c))
    elseif f == "["
        x = _ev(a[1], c)
        subs = a[2:end]
        length(subs) == 1 && subs[1].head === :empty && return x
        length(subs) == 1 || error("incorrect number of dimensions")
        return _index(x, _ev(subs[1], c))
    elseif f == "[["
        x = _ev(a[1], c)
        subs = a[2:end]
        length(subs) == 1 || error("incorrect number of subscripts")
        subs[1].head === :empty && error("missing subscript")
        s = _ev(subs[1], c)
        return _index2(x, s)
    elseif f == "\$"
        _ev(a[1], c)
        error("\$ operator is invalid for atomic vectors")
    elseif f == "@"
        x = _ev(a[1], c)
        error("no applicable method for `@` applied to an object of class \"$(_rclass(x))\"")
    elseif f in _UNSUPPORTED
        error("RExpr: '$f' wird in Ausdrücken nicht unterstützt")
    end
    fn = get(_FUNS, f, nothing)
    if fn !== nothing
        if f in _PRIMS
            for (k, x) in enumerate(a)
                x.head === :empty && error("argument $k is empty")
            end
        end
        args = Any[x.head === :empty ? nothing : _ev(x, c) for x in a]
        return fn(args, e.names, a)
    end
    g = _env_get(c.env, f)
    if g isa Function
        args = Any[_ev(x, c) for x in a]
        jargs = Any[to_julia(x) for (x, nm) in zip(args, e.names) if nm === nothing]
        kw = [Symbol(replace(nm, "." => "_")) => to_julia(x) for (x, nm) in zip(args, e.names) if nm !== nothing]
        r = from_julia(g(jargs...; kw...))
        r === nothing && error("Funktion '$f' lieferte keinen Vektor.")
        return r
    end
    error("could not find function \"$f\"")
end

_columns(::Nothing) = Dict{String,Any}()
function _columns(data)
    d = Dict{String,Any}()
    if data isa SimLev.RFrame
        for k in names(data)
            r = from_julia(data[k])
            r === nothing || (d[k] = r)
        end
    elseif data isa NamedTuple || data isa AbstractDict || data isa SimLev.RList
        for (k, v) in pairs(data)
            r = from_julia(v)
            r === nothing || (d[String(k)] = r)
        end
    elseif !(data isa AbstractVector && isempty(data))
        error("data muss ein data.frame (RFrame, NamedTuple oder Dict) sein.")
    end
    return d
end

"""
    eval_r(expr, data = nothing; env = nothing)

Ausdruck `expr` (Text in R-Syntax, Vektor von Zeilen oder Ergebnis von
[`parse_r`](@ref)) wie `eval(parse(text = expr), data, env)` auswerten
(mehrere Ausdrücke nacheinander, Ergebnis des letzten; leerer Text → NULL).
`data`: `RFrame`, `NamedTuple` oder `Dict` (Spalten als Variablen); `env`:
Modul, Dict, NamedTuple oder RList für weitere Variablen und Funktionen.
Ergebnis: logischer (`Vector{Union{Missing,Bool}}`), ganzzahliger
(`Vector{Union{Missing,Int}}`), numerischer (`Vector{Float64}`), Zeichen-
oder Datumsvektor; NULL als leerer logischer Vektor.
"""
function eval_r(expr, data = nothing; env = nothing)
    exprs = expr isa Node ? Node[expr] : expr isa AbstractVector{Node} ? expr : parse_r(expr)
    c = Ctx(_columns(data), env, Dict{String,Any}())
    r = _NULLV
    for e in exprs
        r = _ev(e, c)
    end
    return r
end

"`as.numeric(v)` wie R für ein Ergebnis von [`eval_r`](@ref) oder einen Julia-Vektor (Zeichen mit Warnung)."
function as_numeric(v)
    r = from_julia(v)
    r === nothing && error("Bedingung lieferte keinen Vektor.")
    return _as_num(r)
end

"`as.logical(v)` wie R für ein Ergebnis von [`eval_r`](@ref) oder einen Julia-Vektor."
function as_logical(v)
    r = from_julia(v)
    r === nothing && error("Bedingung lieferte keinen Vektor.")
    return LGL(_as_lgl(r))
end

end # module
