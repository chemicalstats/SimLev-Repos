# Herkunft:           nachgebildet nach R 4.3.3, src/main/gram.y (Grammatik und Vorrang) und der
#                     Semantik der Grundoperatoren
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); gram.y: zusätzlich Romain Francois (2009-2011)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
# RExpr – Ausdrücke in R-Syntax als Text auswerten (wie `eval(parse(text = s), data, env)`)
#
# Ein gemeinsamer Auswerter für Bedingungen als Text in
# `Bootstrap.bootstrap_probability`, `Dependence.regime_subset`,
# `Scenarios.view_prob`/`scenario_entropy_pooling` und `Tactical.tactical_rules`.
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
# `Vector{Union{Missing,String}}`, Datum `Vector{Union{Missing,Float64}}` (seit 1.6.4: Tage als double wie R mit
# Bruchteilen, NA = `SimLev.NA`; der Typ dient nur als Kennzeichen, `missing` kommt nicht vor); NULL
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
# Datum: Tage seit 1970-01-01 als double wie R (seit 1.6.4, C-003, Entscheidung 97; bis 1.6.3
# Vector{Union{Missing,Date}} mit ganzen Tagen). Kennzeichen ist der Elementtyp; die Werte sind immer Float64 (NA =
# SimLev.NA, NaN, ±Inf, Bruchteile), nie `missing`. Nach außen (eval_r ohne raw, to_julia) wieder Datumswerte.
const DAT = Vector{Union{Missing,Float64}}
# Zeitdifferenz in Tagen (schlanke Nachbildung von R's difftime mit units = "days", seit 1.6.4, Entscheidung 105):
# Ergebnis von Datum - Datum; Kennzeichen wie bei DAT der Elementtyp, die Werte immer Float64 (nie `nothing`).
const DIF = Vector{Union{Nothing,Float64}}
const _NA = SimLev.NA
const _IMAX = 2147483647
const _EPOCH = Date(1970, 1, 1)

_warn(msg::AbstractString) = (@warn msg; nothing)

# ── Namen (seit 1.6.4, C-001, Entscheidung 97) ───────────────────────────────────────────────────────────────────────
# Julia-Vektoren tragen keine Attribute; die Namen stehen daher je Auswertung in einer IdDict (Schlüssel: der Vektor)
# im task_local_storage, angelegt von eval_r (`_with_names`). Regeln wie Python (Attribut `names`): Namen entstehen in
# c(), as.Date und quantile und laufen wie in R durch [, Operatoren, Math-Funktionen, is.na & Co., ifelse, rep, cumsum,
# nchar, pmin/pmax; as.numeric & Co., [[, Zusammenfassungen und %in% lassen sie fallen; nach außen fallen sie weg.
# Bis 1.6.3 verwarf c() die Namen, x["b"] ergab NA und x[["b"]] einen Fehler.
const _NKEY = :simlev_rexpr_names
const _NTab = IdDict{Any,Vector{Union{Missing,String}}}
_ntab() = get(task_local_storage(), _NKEY, nothing)
function _getnames(v)
    t = _ntab()
    t === nothing && return nothing
    return get(t, v, nothing)
end
_nm(v) = _getnames(v)
function _setnm(v, nm)
    (nm === nothing || v === _NULLV) && return v
    t = _ntab()
    t === nothing && return v
    t[v] = Vector{Union{Missing,String}}(nm)
    return v
end
"Kopie ohne Namen (as.vector-Regel), wenn v Namen trägt."
_strip(v) = _nm(v) === nothing ? v : copy(v)
"`T(r)` mit den Namen von r."
_cp(T, r) = _setnm(T(r), _nm(r))
"Namen eines zweistelligen Operators wie R: die des ersten Operanden mit der Länge des Ergebnisses, sonst des zweiten."
function _binnames(a, b, n)
    na = _nm(a); nb = _nm(b)
    (na !== nothing && length(a) == n) && return na
    (nb !== nothing && length(b) == n) && return nb
    return nothing
end
"f() mit einer Namenstabelle (eine neue, wenn noch keine besteht)."
function _with_names(f)
    _ntab() === nothing || return f()
    return task_local_storage(f, _NKEY, _NTab())
end
# seit 1.6.4 (C-006, Entscheidung 79): höchstens 1e8 Werte je Vektor (wie Entscheidung 16)
const _MAX_LEN = 100000000
_len_error() = error(SimLev.chk_msg("sp.rexpr_laenge", _MAX_LEN))

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
        return (NaN, p + 3)                  # R gibt NaN ohne Vorzeichen (0x7FF8000000000000)
    elseif low(p, 8) == "infinity"
        return (sign * Inf, p + 8)
    elseif low(p, 3) == "inf"
        return (sign * Inf, p + 3)
    end
    # Zahlteil (dezimal mit Exponent, hexadezimal mit Punkt und p-Exponent) in long double über den
    # C-Kern core/slc_rbase_num.cpp; gelesen werden nur ASCII-Zeichen, Bytes = Zeichen
    q = p
    while q <= n && isascii(cs[q]) && (isxdigit(cs[q]) || cs[q] in ".xXpPeE+-")
        q += 1
    end
    # ein Zeichen mehr übergeben – "0x" gilt wie in R (und Python) nur, wenn danach noch etwas folgt
    v, used, gt = SimLev._rb_strtod_num(String(cs[p:min(q, n)]), 1)
    used < 0 && return (_NA, i0)
    gt && (v = Inf)                          # Betrag über DBL_MAX (long double) → ±Inf wie R
    return (sign * v, p + used)
end

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

# Kontext langer Syntaxfehler (seit 1.6.5, CR2-X10-1; gleiche Regel in R `.e5_parse_ctx` und Python): ist der ganze
# Text länger als 256 Bytes (seit PR2-3; vorher der Text bis zur Fehlerstelle), nur die Fehlerzeile bis zur Fehlerstelle (Spalte wie der Zerleger),
# gekürzt auf die letzten 80 Zeichen, Tabulator als ein Leerzeichen; sonst nothing (Kontext wie R)
function _ctx_long(L::Lexer, line::Int, col::Int)
    lines = split(String(L.cs), '\n')
    (line < 1 || line > length(lines)) && return nothing
    cur = collect(lines[line])
    c = 0; k = 0
    while c < col && k < length(cur)
        c += 1
        cur[k+1] == '\t' && (c = (c + 7) & ~7)
        k += 1
    end
    pre = cur[1:k]
    sum((ncodeunits(ch) for ch in L.cs); init = 0) <= 256 && return nothing
    sh = [ch == '\t' ? ' ' : ch for ch in pre]
    length(sh) > 80 && (sh = sh[end-79:end])
    return String(sh)
end

function _parse_errmsg(L::Lexer, line::Int, col::Int, msg::String)
    head = "<text>:$line:$col: $msg"
    sh = _ctx_long(L, line, col)
    if sh !== nothing
        hd = "$line: "
        return head * "\n" * hd * sh * "\n" * lpad("^", length(hd) + length(sh) + 1)
    end
    lines, cl = _ctx_lines(L)
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
# Namen wie R (glibc iswalpha/iswalnum in C.UTF-8, julia/src/r/wctype.jl; seit 1.6.4, C-026: auch Buchstabenziffern Nl
# wie Ⅳ und Ziffern anderer Schriften wie ٣ am Anfang, bis 1.6.3 nur isletter)
_isalpha_u(c::Char) = SimLev._wct_alpha(c)
_isalnum_u(c::Char) = SimLev._wct_alnum(c)

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
                # seit 1.6.4 wie R (C-089, P11-B3)
                0xD800 <= val <= 0xDFFF && push!(L.warns, "unpaired surrogate Unicode point $(string(val; base = 16))")
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
    # seit 1.6.4 wie R install("") beim Zerlegen (C-025)
    forsym && isempty(s) && error("attempt to use zero-length variable name")
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
# Kontextstapel wie R's gram.y (CONTEXTSTACK_SIZE 50): seit 1.6.4 (C-006) mit R's Grenze und Meldung
# „contextstack overflow (<input>:Zeile:Spalte)“; bis 1.6.3 ohne Grenze (Stapelüberlauf möglich)
const _CONTEXTSTACK_SIZE = 50
function _cpush!(L::Lexer, c::Char, k::Int = 1)
    length(L.cstack) - 1 >= _CONTEXTSTACK_SIZE - (k - 1) && _lexerr(L, "contextstack overflow")
    for _ in 1:k
        push!(L.cstack, c)
    end
    nothing
end
_ifpush!(L::Lexer) = (_ctop(L) in ('{', '[', '(', 'i') && _cpush!(L, 'i'); nothing)

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
            _cpush!(L, '[', 2)
        elseif k === :LBRACKET
            _cpush!(L, '[')
        elseif k === :LBRACE
            _cpush!(L, '{'); L.eat = true
        elseif k === :LPAREN
            _cpush!(L, '(')
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
    depth::Int   # Schachtelung von _expr! (seit 1.6.4, C-006)
    cplx::Bool   # komplexe Konstante gesehen (seit 1.6.5, PR2-4: Ablehnung erst nach dem Zerlegen)
end
Parser(L::Lexer, la) = Parser(L, la, 0, false)
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

# höchste Schachtelungstiefe eines Ausdrucks (seit 1.6.4, Entscheidung 75): Tiefe des Syntaxbaums wie R's Aufrufbaum
# (jeder Aufruf, auch Operator, Klammer, Index, eine Ebene; Namen und Konstanten 0)
const _MAX_DEPTH = 200
_depth_error() = error(SimLev.chk_msg("sp.rexpr_tiefe", _MAX_DEPTH))

"Tiefe des Syntaxbaums ohne Rekursion (Aufruf 1 + Tiefe des tiefsten Kinds, auch der Funktion bei callx)."
function _tree_depth(e::Node)
    best = 0
    stack = Tuple{Node,Int}[(e, 0)]
    while !isempty(stack)
        x, d = pop!(stack)
        if x.head === :call || x.head === :callx
            d += 1
            d > best && (best = d)
            d > _MAX_DEPTH && return d
            for a in x.args
                push!(stack, (a, d))
            end
            x.head === :callx && push!(stack, (x.val::Node, d))
        end
    end
    best
end

function _expr!(P::Parser, minbp::Int, ctx::Symbol, first::Union{Nothing,Tok} = nothing)
    # seit 1.6.4 (C-006): mehr als _MAX_DEPTH + 1 geschachtelte Teilausdrücke ergeben einen Baum tiefer als _MAX_DEPTH
    P.depth += 1
    P.depth > _MAX_DEPTH + 1 && _depth_error()
    try
        return _expr0!(P, minbp, ctx, first)
    finally
        P.depth -= 1
    end
end

function _expr0!(P::Parser, minbp::Int, ctx::Symbol, first::Union{Nothing,Tok} = nothing)
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
        k === :EQ_ASSIGN && (rbp = 4)   # seit 1.6.4 (C-024) wie R's Grammatik: rechts darf '<-' stehen (a = b <- 3)
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
        # 1i, NA_complex_: seit 1.6.4 in allen drei Sprachen abgelehnt (Entscheidung 64); seit 1.6.5 (PR2-4,
        # Entscheidung 199) erst nach dem Zerlegen wie R
        t.val === :complex && (P.cplx = true)
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
                # seit 1.6.4 wie R's CheckFormalArgs (C-024)
                String(s.val) in formals && error("repeated formal argument '$(s.val)' (<input>:$(s.line):$(s.col))")
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
        _tree_depth(e) > _MAX_DEPTH && _depth_error()   # seit 1.6.4 (C-006, Entscheidung 75)
        if _has_placeholder(e)
            error("invalid use of pipe placeholder (<input>:$(t.kind === :NL ? L.line - 1 : L.line):$(L.col))")
        end
        push!(exprs, e)
    end
    # seit 1.6.5 (PR2-4, Entscheidung 199): komplexe Zahlen erst nach dem Zerlegen des ganzen Textes abgelehnt wie R
    # (.e5_rexpr_parse: Syntaxfehler, dann Tiefe, dann komplexe Zahlen; bis dahin Ablehnung schon beim Zerlegen)
    P.cplx && error(SimLev.chk_msg("b2b.m_e5_rexpr_parse"))
    return exprs, L.warns
end

const _CACHE = Dict{String,Any}()
const _CACHE_LOCK = ReentrantLock()
# seit 1.6.4 (C-069): höchstens so viele Regeltexte, danach fällt der älteste weg (bis 1.6.3 ohne Grenze)
const _CACHE_MAX = 1000
const _CACHE_ORDER = String[]

"""
    parse_r(s) -> Vector{Node}

Text in R-Syntax zerlegen wie `parse(text = s)` (mehrere Elemente von `s`
werden zeilenweise verbunden). Syntaxfehler → `error` mit R's Meldung;
Warnungen des Lexers (z. B. zu `1.5L`) bei jedem Aufruf. Ergebnisse werden
zwischengespeichert (seit 1.6.4 höchstens `_CACHE_MAX` Texte, C-069).
"""
function parse_r(s::AbstractString)
    k = String(s)
    exprs, warns = lock(_CACHE_LOCK) do
        hit = get(_CACHE, k, nothing)
        if hit === nothing
            hit = _parse_all(k)
            while length(_CACHE_ORDER) >= _CACHE_MAX
                delete!(_CACHE, popfirst!(_CACHE_ORDER))
            end
            _CACHE[k] = hit
            push!(_CACHE_ORDER, k)
        end
        hit
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
    v isa Date && return DAT([_dayf(v)])
    v isa Dates.DateTime && return DAT([_dayf(Date(v))])
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
    T <: Union{Missing,Date} && return DAT(Float64[_dayf(x) for x in v])
    T <: Union{Missing,Dates.DateTime} && return DAT(Float64[x === missing ? _NA : _dayf(Date(x)) for x in v])
    # seit 1.6.5 (CR2-C-11): nothing wie missing (wie als Einzelwert), Wahrheitswerte neben Zahlen werden wie in R c()
    # zu Zahlen (bis 1.6.4 „keine Daten“), Symbole wie Text
    any(x -> x === nothing, v) && (v = Any[x === nothing ? missing : x for x in v])
    all(x -> x === missing || x isa Bool, v) && return LGL(v)
    all(x -> x === missing || (x isa Integer && _int_ok(x)), v) &&
        return INT(Union{Missing,Int}[x === missing ? missing : Int(x) for x in v])
    all(x -> x === missing || x isa Real, v) && return NUM(Float64[x === missing ? _NA : Float64(x) for x in v])
    all(x -> x === missing || x isa Union{AbstractString,Symbol}, v) &&
        return CHR(Union{Missing,String}[x === missing ? missing : String(x) for x in v])
    all(x -> x === missing || x isa Date, v) && return DAT(Float64[_dayf(x) for x in v])
    return nothing
end
_dayf(d::Date) = Float64(Dates.value(d - _EPOCH))
_dayf(::Missing) = _NA

"Datum nach außen (seit 1.6.4, C-003): Bruchteile abgerundet; NA, NaN, ±Inf und Beträge über 1e15 Tage als `missing`."
_date_out(v::DAT) = Union{Missing,Date}[(isfinite(x) && abs(x) <= 1e15) ? _EPOCH + Day(Int(floor(x))) : missing for x in v]
_public(v::DAT) = _date_out(v)
_public(v::DIF) = NUM(v)
_public(v) = v

"R-Vektor → natürlicher Julia-Vektor (für Aufrufe von Julia-Funktionen aus `env`)."
to_julia(v::LGL) = any(ismissing, v) ? v : Vector{Bool}(v)
to_julia(v::INT) = any(ismissing, v) ? v : Vector{Int}(v)
to_julia(v::CHR) = any(ismissing, v) ? v : Vector{String}(v)
to_julia(v::DAT) = (d = _date_out(v); any(ismissing, d) ? d : Vector{Date}(d))
to_julia(v) = v

_days(d::Date) = Dates.value(d - _EPOCH)
_i2d(x::Union{Missing,Int}) = x === missing ? _NA : Float64(x)

_as_lgl(v::LGL) = v
_as_lgl(v::INT) = LGL([x === missing ? missing : x != 0 for x in v])
_as_lgl(v::NUM) = LGL([isnan(x) ? missing : x != 0 for x in v])
_lgl_str(x) = x === missing ? missing : x in ("TRUE", "true", "T", "True") ? true :
              x in ("FALSE", "false", "F", "False") ? false : missing
_as_lgl(v::CHR) = LGL([_lgl_str(x) for x in v])
_as_lgl(v::Union{DAT,DIF}) = LGL([isnan(x) ? missing : x != 0 for x in v])   # wie double (seit 1.6.4, C-003)

_as_num(v::NUM) = v
_as_num(v::LGL) = NUM([x === missing ? _NA : Float64(x) for x in v])
_as_num(v::INT) = NUM([_i2d(x) for x in v])
_as_num(v::Union{DAT,DIF}) = NUM(v)   # Tage als double, Bits unverändert (seit 1.6.4, C-003)
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
_as_chr(v::DAT) = CHR(Union{Missing,String}[_date_chr(x) for x in v])
_as_chr(v::DIF) = _as_chr(NUM(v))
_as_int(v::DIF) = _as_int(NUM(v))

"""`as.character(<Date>)` wie R 4.3.3 (as.character.POSIXt über Date2POSIXlt): `"%d-%02d-%02d"` mit dem Jahr ohne
Auffüllen (`"53-06-19"`, `"-1-01-01"`, `"12345-01-01"`), Bruchteile abgerundet; NA bleibt NA, NaN, ±Inf und Jahre
außerhalb von int als Zahltext (`"NaN"`, `"Inf"`, `"1e+15"`). Seit 1.6.4 (C-003, C-005, Entscheidung 97); bis 1.6.3
`Dates.format` mit vierstelligem, abgeschnittenem Jahr."""
function _date_chr(x::Float64)
    (isnan(x) && SimLev.isna_strict(x)) && return missing
    if isfinite(x)
        y, m, d = _civil_from_days(Int(floor(x)))
        if -2147483648 <= y - 1900 <= 2147483647
            y > 2147483647 && error("invalid format '%d'; use format %f, %e, %g or %a for numeric objects")
            return string(y) * "-" * lpad(m, 2, '0') * "-" * lpad(d, 2, '0')
        end
    end
    return _as_chr(NUM([x]))[1]
end

"Tage seit 1970-01-01 im proleptischen gregorianischen Kalender (auch Jahr 0)."
function _days_from_civil(y::Int, m::Int, d::Int)
    y -= m <= 2
    era = fld(y, 400)
    yoe = y - era * 400
    doy = div(153 * (m + (m > 2 ? -3 : 9)) + 2, 5) + d - 1
    return era * 146097 + yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy - 719468
end

"""R's strptime(x, "%Y<sep>%m<sep>%d") als Tageszahl oder `nothing` (R_strptime: vor jeder Zahl nur ASCII-Leerzeichen
überspringen, %Y bis 4, %m/%d bis 2 ASCII-Ziffern, Rest des Textes egal; ungültiger Tag ergibt NA)."""
function _strptime_ymd(x::AbstractString, sep::Char)
    cs = collect(x); n = length(cs)
    function num(i, lo, hi, nd)
        while i <= n && cs[i] == ' '; i += 1; end
        (i > n || !('0' <= cs[i] <= '9')) && return nothing, i
        v = 0; k = 0
        while k < nd && i <= n && '0' <= cs[i] <= '9'
            v = v * 10 + (cs[i] - '0'); i += 1; k += 1
        end
        return (lo <= v <= hi ? v : nothing), i
    end
    y, i = num(1, 0, 9999, 4)
    (y === nothing || i > n || cs[i] != sep) && return nothing
    m, i = num(i + 1, 1, 12, 2)
    (m === nothing || i > n || cs[i] != sep) && return nothing
    d, i = num(i + 1, 1, 31, 2)
    d === nothing && return nothing
    leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
    d > (m == 2 ? (leap ? 29 : 28) : m in (4, 6, 9, 11) ? 30 : 31) && return nothing
    return _days_from_civil(y, m, d)
end

# ── strptime wie R 4.3.3 (seit 1.6.4, C-002, Entscheidung 97) ────────────────────────────────────────────────────────
# Übertragung von w_strptime_internal (src/main/Rstrptime.h, Fassung für Mehrbyte-Locales wie C.UTF-8) und der
# Nachbearbeitung in do_strptime/glibc_fix/validate_tm/POSIXlt2Date (src/main/datetime.c), soweit sie das Datum
# bestimmt; 1:1 wie Python `_strptime_w` usw. Namen von Monat und Wochentag englisch (C-Locale), Groß-/Kleinschreibung
# nur ASCII, Leerraum im Format wie glibc iswspace; fehlen Jahr, Monat oder Tag, gelten die des heutigen Tags (lokale
# Zeit) wie R; %z verschiebt in UTC.

const _WDAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const _MON_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                    "November", "December"]
const _MON_YDAY = ((0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365),
                   (0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366))
const _MONTH_DAYS = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
const _IWSPACE = Set(collect("\t\n\v\f\r               　"))
const _NA_INT = -2147483648

_isleap(y::Integer) = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
_dim(mon::Int, yr::Int) = (mon == 1 && _isleap(1900 + yr)) ? 29 : _MONTH_DAYS[mon+1]
_yv(y) = y === nothing ? _NA_INT : y

mutable struct _TM
    sec::Int; min::Int; hour::Int
    mday::Union{Nothing,Int}; mon::Union{Nothing,Int}; year::Union{Nothing,Int}
    wday::Union{Nothing,Int}; yday::Union{Nothing,Int}
end
_TM() = _TM(0, 0, 0, nothing, nothing, nothing, nothing, nothing)
Base.copy(t::_TM) = _TM(t.sec, t.min, t.hour, t.mday, t.mon, t.year, t.wday, t.yday)

function _wmatch(name::String, s::Vector{Char}, i::Int)
    n = length(name)
    i + n - 1 > length(s) && return -1
    for k in 1:n
        c = s[i+k-1]
        (isascii(c) && lowercase(c) == lowercase(name[k])) || return -1
    end
    return i + n
end

function _day_of_the_week!(tm::_TM)
    (tm.year === nothing || tm.mon === nothing || tm.mday === nothing) && return
    cy = 1900 + tm.year - (tm.mon < 2)
    q4 = div(cy, 4)
    wday = (-473 + 365 * (tm.year - 70) + q4 - div(q4, 25) + (rem(q4, 25) < 0 ? 1 : 0) + div(div(q4, 25), 4) +
            _MON_YDAY[1][tm.mon+1] + tm.mday - 1)
    tm.wday = rem(rem(wday, 7) + 7, 7)
end

function _day_of_the_year!(tm::_TM)
    (tm.year === nothing || tm.mon === nothing || tm.mday === nothing) && return
    tm.yday = _MON_YDAY[_isleap(1900 + tm.year) ? 2 : 1][tm.mon+1] + tm.mday - 1
end

const _RE_STRTOD = r"^[+-]?(?:0[xX](?:[0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)(?:[pP][+-]?[0-9]+)?|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|[iI][nN][fF](?:[iI][nN][iI][tT][yY])?|[nN][aA][nN](?:\([0-9A-Za-z_]*\))?)"

"wcstod für %OS: (Wert, Ende); ohne Zahl (0.0, i)."
function _wcstod(s::Vector{Char}, i::Int)
    j = i
    while j <= length(s) && s[j] in _IWSPACE; j += 1; end
    str = String(s[j:end])
    m = match(_RE_STRTOD, str)
    m === nothing && return (0.0, i)
    t = m.match
    v = if occursin('x', t) || occursin('X', t)
        tt = (occursin('p', t) || occursin('P', t)) ? t : t * "p0"
        tt = replace(tt, r"^([+-]?0[xX])\." => s"\g<1>0.")
        something(tryparse(Float64, tt), Inf)
    elseif lowercase(lstrip(t, ['+', '-']))[1] == 'n'
        NaN
    else
        something(tryparse(Float64, t), Inf)
    end
    return (v, j + length(t))
end

"w_strptime_internal: Index hinter dem gelesenen Teil von s oder -1 (NULL)."
function _strptime_w(s::Vector{Char}, i::Int, fmt::Vector{Char}, tm::_TM, st::Vector{Any})
    n = length(s); nf = length(fmt)
    at(k) = k <= n ? s[k] : '\0'
    have_I = is_pm = false
    century = -1
    want_century = false
    have_wday = want_xday = have_yday = have_mon = have_mday = false
    have_uweek = have_wweek = false
    week_no = 0
    f = 1
    function num(lo, hi, nd)
        while at(i) == ' '; i += 1; end
        '0' <= at(i) <= '9' || return nothing
        v = 0
        while true
            v = v * 10 + (at(i) - '0'); i += 1; nd -= 1
            (nd > 0 && '0' <= at(i) <= '9') || break
        end
        return lo <= v <= hi ? v : nothing
    end
    while f <= nf
        c = fmt[f]
        if c in _IWSPACE
            while i <= n && at(i) in _IWSPACE; i += 1; end
            f += 1
            continue
        end
        if c != '%'
            at(i) == c || return -1
            i += 1; f += 1
            continue
        end
        f += 1
        c = f <= nf ? fmt[f] : '\0'
        f += 1
        if c == 'E'
            c2 = f <= nf ? fmt[f] : '\0'
            c2 in "cCyYxX" || return -1
            c = c2; f += 1
        end
        if c == '%'
            at(i) == '%' || return -1
            i += 1
        elseif c in "aA"
            k = -1; cnt = 0
            for (q, nm) in enumerate(_WDAY_NAMES)
                k = _wmatch(nm, s, i); cnt = q - 1; k >= 0 && break
            end
            if k < 0
                for (q, nm) in enumerate(_WDAY_NAMES)
                    k = _wmatch(nm[1:3], s, i); cnt = q - 1; k >= 0 && break
                end
            end
            k < 0 && return -1
            i = k; tm.wday = cnt; have_wday = true
        elseif c in "bBh"
            k = -1; cnt = 0
            for (q, nm) in enumerate(_MON_NAMES)
                k = _wmatch(nm, s, i); cnt = q - 1; k >= 0 && break
            end
            if k < 0
                for (q, nm) in enumerate(_MON_NAMES)
                    k = _wmatch(nm[1:3], s, i); cnt = q - 1; k >= 0 && break
                end
            end
            k < 0 && return -1
            i = k; tm.mon = cnt; want_xday = true
        elseif c in "cDxFrRTX"
            sub = c == 'c' ? "%a %b %e %H:%M:%S %Y" : c in "Dx" ? "%y/%m/%d" : c == 'F' ? "%Y-%m-%d" :
                  c == 'r' ? "%I:%M:%S %p" : c == 'R' ? "%H:%M" : "%H:%M:%S"
            i = _strptime_w(s, i, collect(sub), tm, st)
            i < 0 && return -1
            c in "DxF" && (want_xday = true)
        elseif c == 'C'
            v = num(0, 99, 2); v === nothing && return -1
            century = v; want_xday = true
        elseif c in "de"
            v = num(1, 31, 2); v === nothing && return -1
            tm.mday = v; have_mday = want_xday = true
        elseif c in "kH"
            v = num(0, 24, 2); v === nothing && return -1
            tm.hour = v; have_I = false
        elseif c in "lI"
            v = num(1, 12, 2); v === nothing && return -1
            tm.hour = v % 12; have_I = true
        elseif c == 'j'
            v = num(1, 366, 3); v === nothing && return -1
            tm.yday = v - 1; have_yday = true
        elseif c == 'm'
            v = num(1, 12, 2); v === nothing && return -1
            tm.mon = v - 1; have_mon = want_xday = true
        elseif c == 'M'
            v = num(0, 59, 2); v === nothing && return -1
            tm.min = v
        elseif c in "nt"
            while i <= n && at(i) in _IWSPACE; i += 1; end
        elseif c == 'p'
            k = _wmatch("AM", s, i)
            if k < 0
                k = _wmatch("PM", s, i)
                k < 0 && return -1
                is_pm = true
            end
            i = k
        elseif c == 's'
            '0' <= at(i) <= '9' || return -1
            secs = big(0)
            while '0' <= at(i) <= '9'
                secs = secs * 10 + (at(i) - '0'); i += 1
            end
            typemin(Int64) <= secs <= typemax(Int64) || return -1
            lt = try
                Libc.TmStruct(Float64(secs))
            catch
                return -1
            end
            tm.sec = lt.sec; tm.min = lt.min; tm.hour = lt.hour; tm.mday = lt.mday
            tm.mon = lt.month; tm.year = lt.year; tm.wday = lt.wday; tm.yday = lt.yday
        elseif c == 'S'
            v = num(0, 61, 2); v === nothing && return -1
            tm.sec = v
        elseif c == 'u'
            v = num(1, 7, 1); v === nothing && return -1
            tm.wday = v % 7; have_wday = true
        elseif c == 'g'
            num(0, 99, 2) === nothing && return -1
        elseif c == 'G'
            '0' <= at(i) <= '9' || return -1
            while '0' <= at(i) <= '9'; i += 1; end
        elseif c in "UW"
            v = num(0, 53, 2); v === nothing && return -1
            week_no = v
            c == 'U' ? (have_uweek = true) : (have_wweek = true)
        elseif c == 'V'
            num(0, 53, 2) === nothing && return -1
        elseif c == 'w'
            v = num(0, 6, 1); v === nothing && return -1
            tm.wday = v; have_wday = true
        elseif c == 'y'
            v = num(0, 99, 2); v === nothing && return -1
            tm.year = v >= 69 ? v : v + 100
            want_century = want_xday = true
        elseif c == 'Y'
            v = num(0, 9999, 4); v === nothing && return -1
            tm.year = v - 1900
            want_century = false; want_xday = true
        elseif c == 'z'
            while at(i) == ' '; i += 1; end
            at(i) in "+-" || return -1
            neg = at(i) == '-'
            i += 1
            k = 0; v = 0
            while k < 4 && '0' <= at(i) <= '9'
                v = v * 10 + (at(i) - '0'); i += 1; k += 1
            end
            (k != 4 || v % 100 >= 60) && return -1
            v = div(v, 100) * 100 + div((v % 100) * 50, 30)
            if v > 1400
                _warn("values for %z outside +/-1400 are an error")
                return -1
            end
            off = div(v * 3600, 100)
            st[2] = neg ? -off : off
        elseif c == 'Z'
            error("use of %Z for input is not supported")
        elseif c == 'O'
            c2 = f <= nf ? fmt[f] : '\0'
            f += 1
            if c2 in "de"
                v = num(1, 31, 2); v === nothing && return -1
                tm.mday = v; have_mday = want_xday = true
            elseif c2 == 'H'
                v = num(0, 23, 2); v === nothing && return -1
                tm.hour = v; have_I = false
            elseif c2 == 'I'
                v = num(1, 12, 2); v === nothing && return -1
                tm.hour = v % 12; have_I = true
            elseif c2 == 'm'
                v = num(1, 12, 2); v === nothing && return -1
                tm.mon = v - 1; have_mon = want_xday = true
            elseif c2 == 'M'
                v = num(0, 59, 2); v === nothing && return -1
                tm.min = v
            elseif c2 == 'S'
                sv, e = _wcstod(s, i)
                if 0.0 <= sv <= 61.0
                    tm.sec = Int(trunc(sv)); st[1] = sv
                end
                i = e
            elseif c2 in "UW"
                v = num(0, 53, 2); v === nothing && return -1
                week_no = v
                c2 == 'U' ? (have_uweek = true) : (have_wweek = true)
            elseif c2 == 'V'
                num(0, 53, 2) === nothing && return -1
            elseif c2 == 'w'
                v = num(0, 6, 1); v === nothing && return -1
                tm.wday = v; have_wday = true
            elseif c2 == 'y'
                v = num(0, 99, 2); v === nothing && return -1
                tm.year = v >= 69 ? v : v + 100
                want_xday = true
            else
                return -1
            end
        else
            return -1
        end
    end
    (have_I && is_pm) && (tm.hour += 12)
    if century != -1
        tm.year = want_century ? rem(tm.year, 100) + (century - 19) * 100 : (century - 19) * 100
    end
    function from_yday!()
        yr = 1900 + _yv(tm.year)
        lp = _isleap(yr) ? 2 : 1
        t_mon = 0
        if tm.yday > (lp == 2 ? 365 : 364)
            return yr, lp, 12, true
        end
        while _MON_YDAY[lp][t_mon+1] <= tm.yday; t_mon += 1; end
        return yr, lp, t_mon, false
    end
    if want_xday && !have_wday
        if !(have_mon && have_mday) && have_yday
            yr, lp, t_mon, bad = from_yday!()
            bad && _warn("day-of-year $(tm.yday + 1) in year $yr is invalid\n")
            have_mon || (tm.mon = t_mon - 1)
            have_mday || (tm.mday = tm.yday - _MON_YDAY[lp][t_mon] + 1)
        end
        _day_of_the_week!(tm)
    end
    (want_xday && !have_yday) && _day_of_the_year!(tm)
    if (have_uweek || have_wweek) && have_wday
        save_wday = tm.wday; save_mday = tm.mday; save_mon = tm.mon
        w_offset = have_uweek ? 0 : 1
        tm.mday = 1; tm.mon = 0
        _day_of_the_week!(tm)
        have_mday && (tm.mday = save_mday)
        have_mon && (tm.mon = save_mon)
        if !have_yday
            tm.yday = rem(7 - (tm.wday - w_offset), 7) + (week_no - 1) * 7 + save_wday - w_offset
            tm.yday < 0 && (tm.yday += 7)
        end
        if !have_mday || !have_mon
            yr, lp, t_mon, bad = from_yday!()
            bad && _warn("(0-based) yday $(tm.yday) in year $yr is invalid\n")
            have_mon || (tm.mon = t_mon - 1)
            have_mday || (tm.mday = tm.yday - _MON_YDAY[lp][t_mon] + 1)
        end
        tm.wday = save_wday
    end
    return i
end

"validate_tm von datetime.c: 0 gültig, -1 ungültig, > 0 Zahl der Korrekturen (tm wird angepasst)."
function _validate_tm!(tm::_TM)
    res = 0
    if tm.sec < 0 || tm.sec > 60
        res += 1; tmp = div(tm.sec, 60)
        tm.sec -= 60 * tmp; tm.min += tmp
        tm.sec < 0 && (tm.sec += 60; tm.min -= 1)
    end
    if tm.min < 0 || tm.min > 59
        res += 1; tmp = div(tm.min, 60)
        tm.min -= 60 * tmp; tm.hour += tmp
        tm.min < 0 && (tm.min += 60; tm.hour -= 1)
    end
    if tm.hour == 24 && tm.min == 0 && tm.sec == 0
        tm.hour = 0; tm.mday += 1
        if 0 <= tm.mon <= 11 && tm.mday > _dim(tm.mon, tm.year)
            tm.mon += 1; tm.mday = 1
            tm.mon == 12 && (tm.year += 1; tm.mon = 0)
        end
    elseif tm.hour < 0 || tm.hour > 23
        res += 1; tmp = div(tm.hour, 24)
        tm.hour -= 24 * tmp; tm.mday += tmp
        tm.hour < 0 && (tm.hour += 24; tm.mday -= 1)
    end
    if tm.mon < 0 || tm.mon > 11
        res += 1; tmp = div(tm.mon, 12)
        tm.mon -= 12 * tmp; tm.year += tmp
        tm.mon < 0 && (tm.mon += 12; tm.year -= 1)
    end
    (tm.mday < -1000000 || tm.mday > 1000000) && return -1
    if abs(tm.mday) > 366
        res += 1
        while tm.mon > 0
            tm.mon -= 1; tm.mday += _dim(tm.mon, tm.year)
        end
        while tm.mday < 1
            tm.year -= 1; tm.mday += _isleap(1900 + tm.year) ? 366 : 365
        end
        while true
            tmp = _isleap(1900 + tm.year) ? 366 : 365
            tm.mday <= tmp && break
            tm.mday -= tmp; tm.year += 1
        end
    end
    while tm.mday < 1
        res += 1
        tm.mon -= 1
        tm.mon < 0 && (tm.mon += 12; tm.year -= 1)
        tm.mday += _dim(tm.mon, tm.year)
    end
    while true
        tmp = _dim(tm.mon, tm.year)
        tm.mday <= tmp && break
        res += 1
        tm.mon += 1
        tm.mon > 11 && (tm.mon -= 12; tm.year += 1)
        tm.mday -= tmp
    end
    return res
end

"glibc_fix von datetime.c: fehlendes Jahr, fehlender Monat oder Tag aus dem heutigen Datum (lokale Zeit); false, wenn nur der Tag fehlt."
function _glibc_fix!(tm::_TM)
    lt = Libc.TmStruct(time())
    tm.year === nothing && (tm.year = lt.year)
    (tm.mon !== nothing && tm.mday !== nothing) && return true
    if tm.yday !== nothing
        yday = tm.yday; mon = 0
        while true
            mon > 11 && return false   # in R über das Monatsende hinaus (undefiniert); hier ungültig
            tmp = _dim(mon, tm.year)
            yday < tmp && break
            yday -= tmp; mon += 1
        end
        tm.mon = mon; tm.mday = yday + 1
        return true
    end
    if tm.mday === nothing
        tm.mon !== nothing && return false
        tm.mday = lt.mday
    end
    tm.mon === nothing && (tm.mon = lt.month)
    return true
end

"Ein Element von as.Date(strptime(x, fmt, tz = \"GMT\")): Tage seit 1970-01-01 oder NA."
function _strptime1(x, fmt::String, utc::Bool = true)
    x === missing && return _NA
    xs = collect(x); fs = collect(fmt)
    length(xs) > 1000 && error("input string is too long")
    length(fs) > 1000 && error("format string is too long")
    tm = _TM()
    st = Any[0.0, nothing]
    _strptime_w(xs, 1, fs, tm, st) < 0 && return _NA
    tm.mday == 0 && (tm.mday = nothing)
    if tm.mon === nothing || tm.mday === nothing || tm.year === nothing
        _glibc_fix!(tm) || return _NA
    end
    py = tm.year; pm = tm.mon; pd = tm.mday
    if st[2] !== nothing
        tm2 = copy(tm)
        _validate_tm!(tm2) < 0 && return _NA
        t0 = tm2.sec + tm2.min * 60 + tm2.hour * 3600 + _days_from_civil(1900 + tm2.year, tm2.mon + 1, tm2.mday) * 86400
        t0 == -1 && return _NA
        t0 -= st[2]
        if utc
            y, m, d = _civil_from_days(fld(t0, 86400))
            py = y - 1900; pm = m - 1; pd = d
        else   # localtime0(&t0, 1): Systemzeitzone (TZ wie in R; Entscheidung 108)
            typemin(Int64) <= t0 <= typemax(Int64) || return _NA
            lt = try
                Libc.TmStruct(Float64(t0))
            catch
                return _NA
            end
            py = Int(lt.year); pm = Int(lt.month); pd = Int(lt.mday)
        end
    end
    _validate_tm!(tm) != 0 && return _NA
    if st[2] === nothing
        py = tm.year; pm = tm.mon; pd = tm.mday
    end
    return Float64(_days_from_civil(1900 + py, pm + 1, pd))
end

"as.Date(strptime(x, format)) mit Recycling wie do_strptime (Länge max(n, m), 0 bei n = 0)."
function _strptime_vec(xs, fmts::Vector{String}, utc::Bool = true)
    n = length(xs); m = length(fmts)
    m == 0 && error("invalid 'format' argument")
    N = n == 0 ? 0 : max(n, m)
    return Float64[_strptime1(xs[(i-1)%n+1], fmts[(i-1)%m+1], utc) for i in 1:N]
end

"""Sekunden von strptime(x, fmt) (lokal, fehlendes Datum heute) seit Mitternacht des heutigen Tags, für as.difftime(x,
format) gegen strptime("0:0:0", format); NA, wenn x nicht passt."""
function _strptime_secs(x, fmt::String)
    x === missing && return _NA
    tm = _TM()
    _strptime_w(collect(x), 1, collect(fmt), tm, Any[0.0, nothing]) < 0 && return _NA
    if tm.mon === nothing || tm.mday === nothing || tm.year === nothing
        _glibc_fix!(tm) || return _NA
    end
    _validate_tm!(tm) != 0 && return _NA
    t0 = _TM(); _glibc_fix!(t0)
    return Float64((_days_from_civil(1900 + tm.year, tm.mon + 1, tm.mday) -
                    _days_from_civil(1900 + t0.year, t0.mon + 1, t0.mday)) * 86400 + tm.hour * 3600 + tm.min * 60 + tm.sec)
end

"Tage seit 1970-01-01 (ganze Zahl) → (Jahr, Monat, Tag), proleptisch gregorianisch."
function _civil_from_days(z::Integer)
    z += 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = mp < 10 ? mp + 3 : mp - 9
    return (y + (m <= 2), m, d)
end

const _MISSING = :missing_format

"`_strptime_ymd` als Tag oder NA, mit R's Längengrenze für den Text."
function _ymd_fast(x::String, sep::Char)
    length(x) > 1000 && error("input string is too long")
    t = _strptime_ymd(x, sep)
    return t === nothing ? _NA : Float64(t)
end

"Formatangabe für strptime: nur Text (NA wird wie in R als \"NA\" gelesen), sonst Fehler wie do_strptime."
function _fmt_list(f)
    (f isa CHR && !isempty(f)) || error("invalid 'format' argument")
    return String[t === missing ? "NA" : t for t in f]
end

"""as.Date.character wie R 4.3.3 (seit 1.6.4 mit format, tryFormats und optional, C-002, Entscheidung 97; bis 1.6.3 nur
die beiden Standardformate): mit `format` strptime je Element, sonst charToDate ("" ist NA, das erste Element ungleich
NA bestimmt das Format aus `tryFormats`, sonst Fehler bzw. NA mit `optional = TRUE`). Wie Python `_as_date_chr`."""
function _as_date_chr(v::CHR, fmt = _MISSING, try_formats = nothing, optional = nothing)
    fmt === _MISSING || return DAT(_strptime_vec(v, _fmt_list(fmt)))
    xs = Union{Missing,String}[x === missing || isempty(x) ? missing : String(x) for x in v]
    i1 = findfirst(x -> x !== missing, xs)
    i1 === nothing && return DAT(Float64[_NA for _ in xs])
    first = xs[i1]
    tf = try_formats === nothing ? CHR(["%Y-%m-%d", "%Y/%m/%d"]) : try_formats
    for k in eachindex(tf)
        f1 = _fmt_list(tf[k:k])[1]
        if f1 == "%Y-%m-%d" || f1 == "%Y/%m/%d"   # schneller Weg, gleich strptime für diese Formate (C-021)
            sep = f1[3]
            isnan(_ymd_fast(first, sep)) && continue
            return DAT(Float64[x === missing ? _NA : _ymd_fast(x, sep) for x in xs])
        elseif !isnan(_strptime1(first, f1))
            return DAT(_strptime_vec(xs, [f1], false))   # strptime(x, ff) ohne tz: Systemzeitzone
        end
    end
    (optional !== nothing && _cond1(optional)) && return DAT(Float64[_NA for _ in xs])
    error("character string is not in a standard unambiguous format")
end

"""as.Date(v) wie R (Methode nach der Klasse): Datum bleibt, Text über as.Date.character, Zahlen unverändert als Tage
(seit 1.6.4 ohne Abrunden, C-003), logisch nur aus lauter NA (sonst der Fehler von as.Date.default mit `what`)."""
_as_date(v::DAT, what = "x") = v
_as_date(v::CHR, what = "x") = _as_date_chr(v)
_as_date(v::Union{NUM,INT}, what = "x") = DAT(_as_num(v))
_as_date(v::DIF, what = "x") = error("do not know how to convert '$what' to class \u201cDate\u201d")
function _as_date(v::LGL, what = "x")
    any(x -> x !== missing, v) && error("do not know how to convert '$what' to class \u201cDate\u201d")
    return DAT(Float64[_NA for _ in v])
end
_undate(v) = v isa Union{DAT,DIF} ? _cp(NUM, v) : v   # mit den Namen

_na_of(::LGL) = missing
_na_of(::INT) = missing
_na_of(::NUM) = _NA
_na_of(::CHR) = missing
_na_of(::DAT) = _NA
_na_of(::DIF) = _NA
_isna_el(x) = x === missing || (x isa Float64 && isnan(x))

_rtype(::LGL) = 1
_rtype(::INT) = 2
_rtype(::NUM) = 3
_rtype(::CHR) = 4
_rtype(::DAT) = 3
_rtype(::DIF) = 3
_coerce(v, t::Int) = t == 1 ? _as_lgl(v) : t == 2 ? _as_int(v) : t == 3 ? _as_num(v) : _as_chr(v)

_rclass(::LGL) = "logical"
_rclass(::INT) = "integer"
_rclass(::NUM) = "numeric"
_rclass(::CHR) = "character"
_rclass(::DAT) = "Date"
_rclass(::DIF) = "difftime"
_rtypeof(::LGL) = "logical"
_rtypeof(::INT) = "integer"
_rtypeof(::NUM) = "double"
_rtypeof(::CHR) = "character"
_rtypeof(::DAT) = "double"
_rtypeof(::DIF) = "double"

_rec(v, i) = v[(i-1)%length(v)+1]
function _len2(a, b)
    na, nb = length(a), length(b)
    (na == 0 || nb == 0) && return 0
    n = max(na, nb)
    n % min(na, nb) == 0 || _warn("longer object length is not a multiple of shorter object length")
    return n
end

_scoll(a::String, b::String) = SimLev.RStats.str_collate(a, b)

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
    x2 == 0.0 && return reinterpret(Float64, 0x7ff8000000000000)   # R_NaN (positiv), auch bei NA in x1
    if abs(x2) * _LDBL_EPS > 1 && isfinite(x1) && abs(x1) <= abs(x2)
        return abs(x1) == abs(x2) ? 0.0 : ((x1 < 0 && x2 > 0) || (x2 < 0 && x1 > 0)) ? x1 + x2 : x1
    end
    q = x1 / x2
    (isfinite(q) && abs(q) * _LDBL_EPS > 1) && _warn("probable complete loss of accuracy in modulus")
    # C-Kern (long double wie R); NaN-Operanden nach der Regel in core/slc_rbase_num.cpp
    return SimLev._rb_fmod_ld(x1, x2)
end

"R's `myfloor(x1, x2)` (`x1 %/% x2`)."
function r_idiv(x1::Float64, x2::Float64)
    q = x1 / x2
    (x2 == 0.0 || abs(q) * _LDBL_EPS > 1 || !isfinite(q)) && return q
    abs(q) < 1 && return q < 0 ? -1.0 : (((x1 < 0 && x2 > 0) || (x1 > 0 && x2 < 0)) ? -1.0 : 0.0)
    return SimLev._rb_idiv_ld(x1, x2)   # C-Kern (long double wie R)
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

_cls(v) = v isa DAT ? "Date" : v isa DIF ? "difftime" : nothing

# Methodenwahl von R's DispatchGroup für Ops mit Date und difftime (seit 1.6.4, Entscheidung 105): "Date", "difftime"
# oder "internal" (unterschiedliche Methoden: Warnung „Incompatible methods“, dann die eingebaute Rechnung; +.Date und
# -.Date gehen vor Ops.difftime wie in R). Wie Python `_ops_method`.
function _ops_method(op, a, b)
    ca = _cls(a); cb = _cls(b)
    (ca == cb || cb === nothing) && return ca
    ca === nothing && return cb
    meth(c) = c == "Date" ? (op == "+" ? "+.Date" : op == "-" ? "-.Date" : "Ops.Date") :
              (op == "*" ? "*.difftime" : op == "/" ? "/.difftime" : "Ops.difftime")
    lm = meth(ca); rm = meth(cb)
    (rm == "Ops.difftime" && lm in ("+.Date", "-.Date")) && return "Date"
    (lm == "Ops.difftime" && rm == "+.Date") && return "Date"
    _warn("Incompatible methods (\"$lm\", \"$rm\") for \"$op\"")
    return "internal"
end

"Klasse der eingebauten Rechnung wie R_binary: die des ersten Operanden mit der Länge des Ergebnisses."
function _internal_cls(r, a, b)
    n = length(r)
    for v in (a, b)
        if length(v) == n
            v isa DAT && return DAT(r)
            v isa DIF && return DIF(r)
            return r
        end
    end
    return r
end

"as.vector(round(<difftime>)) von coerceTimeUnit in +.Date/-.Date (units = \"days\")."
_round0(v) = NUM(Float64[Float64(SimLev.RFmt.r_round(x, 0.0)) for x in v])

"Ops.difftime, *.difftime und /.difftime (R 4.3.3, units = \"days\")."
function _difftime_ops(op, a, b)
    da = a isa DIF; db = b isa DIF
    if op == "*"
        (da && db) && error("both arguments of * cannot be \"difftime\" objects")
        x, y = da ? (a, b) : (b, a)
        return DIF(_arith("*", _undate(y), _undate(x)))
    elseif op == "/"
        db && error("second argument of / cannot be a \"difftime\" object")
        return DIF(_arith("/", _undate(a), _undate(b)))
    elseif op == "+" || op == "-"
        return DIF(_arith(op, _undate(a), _undate(b)))
    end
    error("'$op' not defined for \"difftime\" objects")
end

function _arith(op::String, a, b)
    r = _arith0(op, a, b)
    return _setnm(r, _binnames(a, b, length(r)))
end

function _arith0(op::String, a, b)
    if a isa Union{DAT,DIF} || b isa Union{DAT,DIF}
        m = _ops_method(op, a, b)
        m == "Date" && return _date_arith(op, a, b)
        m == "difftime" && return _difftime_ops(op, a, b)
        return _internal_cls(_arith(op, _undate(a), _undate(b)), a, b)
    end
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
    # seit 1.6.5 (CR2-X38-1): + und * mit zwei double-Operanden, der erste von Länge 1, der zweite länger: der NaN des
    # Vektors setzt sich durch wie in R (x86-64); sonst der des ersten Operanden
    swap = (op == "+" || op == "*") && a isa NUM && b isa NUM && length(A) == 1 && length(B) > 1
    @inbounds for i in 1:n
        x = _rec(A, i); y = _rec(B, i)
        out[i] = if op == "%%"
            r_fmod(x, y)
        elseif op == "%/%"
            r_idiv(x, y)
        elseif op == "^"
            # seit 1.6.4 wie R_pow: bei zwei NaN-Operanden gewinnt der von y (T4-B2); (-Inf)^y mit y > 2^64 warnt wie
            # myfmod(y, 2) (T4-R2)
            (x == -Inf && 1.8446744073709552e19 < y < Inf) && _warn("probable complete loss of accuracy in modulus")
            (isnan(x) || isnan(y)) ? (y == 2.0 ? _nanop(x, x) : (x == 1.0 || y == 0.0) ? 1.0 : _nanop(y, x)) : SimLev.r_pow(x, y)
        elseif isnan(x) || isnan(y)
            swap ? _nanop(y, x) : _nanop(x, y)
        else
            op == "+" ? x + y : op == "-" ? x - y : op == "*" ? x * y : x / y
        end
    end
    return out
end

# `+.Date`, `-.Date` und Ops.Date wie R 4.3.3 (seit 1.6.4, C-003/C-004, Entscheidung 97): Rechnung mit den Tagen als
# double ohne Abrunden, Text ist wie in R ein Fehler (bis 1.6.3 als Zahl gelesen); Datum - Datum ergibt die Differenz
# in Tagen als Zahl (R: difftime mit units = "days"). Wie Python `_date_arith`.
function _date_arith(op, a, b)
    da = a isa DAT; db = b isa DAT
    if op == "+"
        (da && db) && error("binary + is not defined for \"Date\" objects")
        # difftime: as.vector(round(x)) (coerceTimeUnit, seit 1.6.4, Entscheidung 105)
        return DAT(_arith("+", a isa DIF ? _round0(a) : _undate(a), b isa DIF ? _round0(b) : _undate(b)))
    elseif op == "-"
        da || error("can only subtract from \"Date\" objects")
        db && return DIF(_arith("-", _undate(a), _undate(b)))   # difftime(e1, e2, units = "days")
        return DAT(_arith("-", _undate(a), b isa DIF ? _round0(b) : b))
    end
    error("$op not defined for \"Date\" objects")
end

_cmpres(op::String, c::Int) = op == "<" ? c < 0 : op == ">" ? c > 0 : op == "<=" ? c <= 0 :
                               op == ">=" ? c >= 0 : op == "==" ? c == 0 : c != 0

function _compare(op::String, a, b)
    r = _compare0(op, a, b)
    return _setnm(r, _binnames(a, b, length(r)))
end

function _compare0(op::String, a, b)
    if a isa Union{DAT,DIF} || b isa Union{DAT,DIF}
        m = _ops_method(op, a, b)
        if m == "Date"   # Ops.Date: Text wird Datum
            a = a isa CHR ? _as_date(a) : a
            b = b isa CHR ? _as_date(b) : b
        elseif m == "difftime" && a isa DIF && b isa DIF   # coerceTimeUnit: Sekunden
            a = _arith("*", NUM([86400.0]), _undate(a))
            b = _arith("*", NUM([86400.0]), _undate(b))
        end
        return _compare(op, _undate(a), _undate(b))
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
    r = _logic0(op, a, b)
    return _setnm(r, _binnames(a, b, length(r)))
end

function _logic0(op::String, a, b)
    if a isa Union{DAT,DIF} || b isa Union{DAT,DIF}
        m = _ops_method(op, a, b)
        m == "Date" && error("$op not defined for \"Date\" objects")
        m == "difftime" && error("'$op' not defined for \"difftime\" objects")
        a = _undate(a); b = _undate(b)
    end
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
    # seit 1.6.4 (C-089) wie R zuerst der Typ, dann die Länge
    (v === _NULLV || v isa CHR) && error("invalid '$which' type in 'x $op y'")
    length(v) > 1 && error("'length = $(length(v))' in coercion to 'logical(1)'")
    length(v) == 0 && return missing
    return _as_lgl(v)[1]
end

# match(x, table) wie R: NA trifft nur NA, NaN nur NaN, -0 == 0
function _in(a, b)
    # seit 1.6.4 wie R match/mtfrm (C-004): ein Datum wird als Text verglichen (as.character), auch gegen Zahlen.
    # Über eine Menge wie Python (seit 1.6.4, T4-R4; bis dahin jedes x gegen alle y): NA trifft nur NA, NaN nur NaN,
    # sonst == (-0 == 0; die Menge hält -0 als 0, weil isequal(-0.0, 0.0) falsch ist)
    if a isa Union{CHR,DAT,DIF} || b isa Union{CHR,DAT,DIF}
        A = _as_chr(a); B = _as_chr(b)
        st = Set{String}()
        has_miss = false
        for y in B
            y === missing ? (has_miss = true) : push!(st, y)
        end
        return LGL([x === missing ? has_miss : (x in st) for x in A])
    end
    A = _as_num(a); B = _as_num(b)
    sn = Set{Float64}()
    has_na = false; has_nan = false
    for y in B
        if isnan(y)
            SimLev.isna_strict(y) ? (has_na = true) : (has_nan = true)
        else
            push!(sn, y == 0.0 ? 0.0 : y)
        end
    end
    return LGL([isnan(x) ? (SimLev.isna_strict(x) ? has_na : has_nan) : ((x == 0.0 ? 0.0 : x) in sn) for x in A])
end

function _asreal1(v)
    v isa CHR && return _as_num(CHR([v[1]]))[1]
    return _as_num(v)[1]   # DAT → NUM in einem Schritt (bis 1.6.3 doppelt gewandelt, gleicher Wert)
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
    isnan(r) && error("negative length vectors are not allowed")   # Inf:Inf (seit 1.6.5, CR2-L-3)
    floor(r + 1 + 1.1920928955078125e-07) > _MAX_LEN && _len_error()   # seit 1.6.4 (C-006, Entscheidung 79)
    inr(v) = -2147483648.0 < v <= 2147483647.0
    if n1 == trunc(n1) && n2 == trunc(n2)
        lo, hi = n1, n2
        if inr(lo) && inr(hi)
            rg = Int(lo) <= Int(hi) ? (Int(lo):Int(hi)) : (Int(lo):-1:Int(hi))
            return collect(Union{Missing,Int}, rg)::INT   # seit 1.6.4 ohne zweite Kopie (Entscheidung 111)
        end
        n = Int(r) + 1
        return Float64[n1 <= n2 ? n1 + (i - 1) : n1 - (i - 1) for i in 1:n]
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
        return Union{Missing,Int}[n1 <= n2 ? s + (i - 1) : s - (i - 1) for i in 1:n]
    end
    return Float64[n1 <= n2 ? n1 + (i - 1) : n1 - (i - 1) for i in 1:n]
end

function _not(v)
    r = _not0(v)
    return r === v ? r : _setnm(r, _nm(v))
end

function _not0(v)
    v isa CHR && isempty(v) && v !== _NULLV && return LGL()   # seit 1.6.4 wie R lunary (C-025): logical(0)
    (v isa CHR || v === _NULLV) && error("invalid argument type")
    v isa DAT && error("unary ! not defined for \"Date\" objects")
    v isa DIF && error("unary '!' not defined for \"difftime\" objects")
    v isa LGL && return LGL([x === missing ? missing : !x for x in v])
    v isa INT && return LGL([x === missing ? missing : x == 0 for x in v])
    return LGL([isnan(x) ? missing : x == 0 for x in v])
end

function _unary(op::String, v)
    r = _unary0(op, v)
    return r === v ? r : _setnm(r, _nm(v))
end

function _unary0(op::String, v)
    (v isa CHR || v === _NULLV) && error("invalid argument to unary operator")
    if v isa DAT
        op == "+" && return v
        error("unary - is not defined for \"Date\" objects")
    end
    v isa DIF && return op == "+" ? v : DIF(Float64[-t for t in v])   # Ops.difftime einstellig (Entscheidung 105)
    if v isa Union{LGL,INT}
        x = _as_int(v)
        return op == "-" ? INT([t === missing ? missing : -t for t in x]) : x
    end
    return op == "-" ? NUM([-t for t in v]) : v
end

# ═══════════════════════════════════════════════════════════════════════════
# Indizierung (subscript.c)
# ═══════════════════════════════════════════════════════════════════════════

# Index-Vektor (1-basiert, `missing` = NA) für x[s] mit length(x) == nx; Text über `names` (erster Treffer, "" und NA
# treffen nie; seit 1.6.4, C-001)
function _subscript(s, nx::Int, names = nothing)
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
        names === nothing && return Union{Missing,Int}[missing for _ in s]
        pos = Dict{String,Int}()
        for (i, nm) in enumerate(names)
            (nm !== missing && nm != "" && !haskey(pos, nm)) && (pos[nm] = i)
        end
        return Union{Missing,Int}[(t === missing || t == "") ? missing : get(pos, t, missing) for t in s]
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
    x === _NULLV && return _NULLV   # seit 1.6.4 wie R (C-025): NULL[...] ist NULL
    nx = length(x)
    xn = _nm(x)
    idx = _subscript(s, nx, xn)
    out = similar(x, length(idx))
    na = _na_of(x)
    for (k, i) in enumerate(idx)
        out[k] = (i === missing || i > nx) ? na : x[i]
    end
    xn === nothing || _setnm(out, Union{Missing,String}[(i === missing || i > nx) ? missing : xn[i] for i in idx])
    return out
end

function _index2(x, s)
    x === _NULLV && return _NULLV   # seit 1.6.4 wie R (C-025): NULL[[...]] ist NULL
    ls = length(s)
    ls > 1 && error("attempt to select more than one element in vectorIndex")
    ls < 1 && error("attempt to select less than one element in get1index")
    nx = length(x)
    indx = -1
    if s isa CHR   # seit 1.6.4 über die Namen (genauer Treffer, C-001)
        xn = _nm(x)
        if xn !== nothing && s[1] !== missing
            k = findfirst(nm -> nm !== missing && nm == s[1], xn)
            k === nothing || (indx = k - 1)
        end
    elseif s isa Union{LGL,INT}
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
    x isa DIF && return NUM([x[indx+1]])   # kein [[.difftime: die Klasse fällt weg wie in R (Entscheidung 105)
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
        v isa CHR && return x === missing ? "NA_character_" : SimLev.r_deparse_str(x)   # seit 1.6.4 wie R (C-089)
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
# na.rm der Primitive (sum, min, max, any, all) wie R asLogical: NA (auch Text ohne Wahrheitswert und Länge 0) gilt
# als TRUE (seit 1.6.4, C-008; bis 1.6.3 als FALSE)
function _flag(v, dflt::Bool)
    v === nothing && return dflt
    x = isempty(v) ? missing : _as_lgl(v)[1]
    return x === missing ? true : x
end
# na.rm von pmin/pmax wie R do_pmin: NA ist ein Fehler (seit 1.6.4, C-008)
function _flag_pminmax(v)
    v === nothing && return false
    x = isempty(v) ? missing : _as_lgl(v)[1]
    x === missing && error("invalid 'na.rm' value")
    return x
end
# na.rm von mean wie R isTRUE(na.rm) (seit 1.6.4, C-008; z. B. 1 oder "TRUE" gelten nicht)
_flag_istrue(v, dflt::Bool) = v === nothing ? dflt : (v isa LGL && length(v) == 1 && v[1] === true)
# na.rm von median, quantile, var, sd wie R if (na.rm) (seit 1.6.4, C-008)
_flag_if(v, dflt::Bool) = v === nothing ? dflt : Bool(_cond1(v))

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

# Math.Date (R 4.3.3): Funktionen der Gruppe Math sind für Datumswerte nicht definiert (seit 1.6.4, C-004; bis 1.6.3
# "non-numeric argument to mathematical function")
_date_math(fname) = error("$fname not defined for \"Date\" objects")
# Math.difftime: abs, sign, floor, ceiling, trunc, round, signif behalten die Klasse, sonst Fehler wie R
const _DIF_MATH = ("abs", "sign", "floor", "ceiling", "trunc", "round", "signif")
_dif_math(fname) = fname in _DIF_MATH || error("'$fname' not defined for \"difftime\" objects")

function _math1(fname::String, f)
    (args, nms, ex) -> begin
        a = _prim1(fname, args, nms)
        a isa DAT && _date_math(fname)
        if a isa DIF
            _dif_math(fname)
            x = NUM(a)
            return DIF(_nan_warn(x, NUM([f(v) for v in x])))
        end
        # NULL seit 1.6.4 wie R (T4-B3; bis dahin numeric(0))
        (a isa CHR || a === _NULLV) && error("non-numeric argument to mathematical function")
        x = _as_num(a)
        _nan_warn(x, NUM([f(v) for v in x]))
    end
end
# seit 1.6.4 wie R (C-068, Entscheidung 101): sqrt(x < 0) ist das NaN der Hardware 0xFFF8… (R über libm sqrt); bis
# 1.6.3 über SimLev.r_sqrt das positive NaN 0x7FF8…
const _DEFAULT_NAN = reinterpret(Float64, 0xfff8000000000000)
_sqrt(x::Float64) = x < 0 ? _DEFAULT_NAN : sqrt(x)
# seit 1.6.4 wie R (C-031, Entscheidung 100): sign(-0) ist +0 wie R (x > 0 ? 1 : x == 0 ? 0 : -1); bis 1.6.3 Julia
# sign mit -0
_rsign(x::Float64) = isnan(x) ? x : x > 0 ? 1.0 : x < 0 ? -1.0 : 0.0
# NaN-Regel von R's math1 (arithmetic.c, seit 1.6.4, C-068): ein NaN in x bleibt Bit für Bit x (auch NA 0x7FF0…07A2;
# bis 1.6.3 machten floor, sqrt, exp u. a. es still), ein neues NaN ist das der Hardware 0xFFF8… (libm, wie Python
# _lm1; R_log und R's logbase setzen R_NaN selbst: log, log2, log10 laufen nicht hierüber)
_rm1(f) = x -> (y = Float64(x); isnan(y) ? y : (r = Float64(f(y)); isnan(r) ? _DEFAULT_NAN : r))

const _TRUNC_UNITS = ["secs", "mins", "hours", "days", "months", "years"]

# trunc wie R: für Zahlen math1, für ein Datum trunc.Date (seit 1.6.4, C-004; bis 1.6.3 Fehler): Einheiten bis "days"
# über round(x - 0.4999999), "months" und "years" der erste Tag des Monats bzw. Jahres. Wie Python `_f_trunc`.
function _f_trunc(args, nms, ex)
    if !isempty(args) && args[1] isa DAT && (isempty(nms) || nms[1] === nothing || nms[1] == "x")
        w, _, _ = _bind("trunc", args, nms, ex, ["x", "units", "..."])
        x = w[1]; u = w[2]
        unit = "secs"
        if u !== nothing
            u isa CHR || error("'arg' must be NULL or a character vector")
            if collect(u) == _TRUNC_UNITS
                unit = "secs"
            elseif length(u) != 1
                error("'arg' must be of length 1")
            else
                m = (u[1] !== missing && u[1] in _TRUNC_UNITS) ? [u[1]] :
                    String[c for c in _TRUNC_UNITS if u[1] !== missing && startswith(c, u[1])]
                (length(m) != 1 || u[1] == "") &&
                    error("'arg' should be one of " * join(["\u201c$c\u201d" for c in _TRUNC_UNITS], ", "))
                unit = m[1]
            end
        end
        if unit in ("months", "years")
            return DAT(Float64[isfinite(t) ? (c = _civil_from_days(Int(floor(t)));
                                               Float64(_days_from_civil(c[1], unit == "months" ? c[2] : 1, 1))) : _NA
                               for t in x])
        end
        return DAT(_f_round(Any[_arith("-", _undate(x), NUM([0.4999999]))], Union{Nothing,String}[nothing], ex))
    end
    (!isempty(args) && args[1] isa DIF) &&   # Math.difftime: trunc(unclass(x), ...)
        return DIF(_math1("trunc", _rm1(trunc))(Any[NUM(args[1])], Union{Nothing,String}[nothing], ex[1:1]))
    return _math1("trunc", _rm1(trunc))(args, nms, ex)
end

function _f_abs(args, nms, ex)
    a = _prim1("abs", args, nms)
    a isa DAT && _date_math("abs")
    a isa DIF && return DIF(_f_abs(Any[NUM(a)], nms, ex))
    (a isa CHR || a === _NULLV) && error("non-numeric argument to mathematical function")   # NULL seit 1.6.4 (T4-B3)
    a isa Union{LGL,INT} && return INT([x === missing ? missing : abs(x) for x in _as_int(a)])
    return NUM([abs(v) for v in a])
end

function _f_log(args, nms, ex)
    v, _, _ = _bind("log", args, nms, ex, ["x", "base"])
    x = v[1]; b = v[2]
    x === nothing && _missing_arg("x")
    x isa DAT && _date_math("log")
    x isa DIF && _dif_math("log")
    # NULL in x, Text oder NULL als base seit 1.6.4 wie R's math2 (T4-B3; bis dahin numeric(0) bzw. als Zahl gerechnet)
    (x isa CHR || x === _NULLV || (b !== nothing && (b isa CHR || b === _NULLV))) &&
        error("non-numeric argument to mathematical function")
    xn = _as_num(x)
    b === nothing && return _nan_warn(xn, NUM([SimLev.RLibm._log(Float64(t)) for t in xn]))   # ohne libm-Warnung
    bb = _as_num(b)   # seit 1.6.4 wie R: base wird recycelt, Länge 0 ergibt numeric(0) (C-008)
    (isempty(bb) || isempty(xn)) && return NUM()
    n = max(length(xn), length(bb))
    xr = NUM([xn[(i - 1) % length(xn) + 1] for i in 1:n])
    br = NUM([Float64(bb[(i - 1) % length(bb) + 1]) for i in 1:n])
    r = NUM([SimLev.RLibm._logb(Float64(xr[i]), br[i]) for i in 1:n])
    # Warnung wie math2 je Paar nach dem Recycling: nur wenn weder x noch base NaN ist (seit 1.6.4, T4-B4)
    any(i -> isnan(r[i]) && !isnan(xr[i]) && !isnan(br[i]), 1:n) && _warn("NaNs produced")
    r
end

function _f_round(args, nms, ex; signif = false)
    v, _, _ = _bind(signif ? "signif" : "round", args, nms, ex, ["x", "digits"])
    x = v[1]; d = v[2]
    x === nothing && _missing_arg("x")
    x isa DIF && return DIF(_f_round(vcat(Any[NUM(x)], Any[a for a in args[2:end]]), nms, ex; signif = signif))
    if x isa DAT
        signif && _date_math("signif")
        # round.Date (seit 1.6.4, C-004): .Date(round(unclass(x), digits))
        return DAT(_f_round(Any[_undate(x), d], Union{Nothing,String}[nothing, "digits"], ex))
    end
    # seit 1.6.4 wie R's do_Math2/math2 (T4-B3): erst die Länge von digits, dann NULL bzw. Text in x oder digits (bis
    # dahin numeric(0) bzw. digits als Zahl gerechnet)
    (d !== nothing && isempty(d)) && error("invalid second argument of length 0")
    (x isa CHR || x === _NULLV || d isa CHR) && error("non-numeric argument to mathematical function")
    xn = _as_num(x)
    dv = d === nothing ? [signif ? 6.0 : 0.0] : collect(_as_num(d))
    isempty(xn) && return NUM()
    n = max(length(xn), length(dv))   # seit 1.6.4 wie R Math2: digits wird recycelt (C-008)
    f = signif ? SimLev.RFmt.signif : SimLev.RFmt.r_round
    return NUM([Float64(f(xn[(i - 1) % length(xn) + 1], dv[(i - 1) % length(dv) + 1])) for i in 1:n])
end

function _f_isna(args, nms, ex)
    v = _prim1("is.na", args, nms)
    LGL(v isa Union{NUM,DAT,DIF} ? [isnan(x) for x in v] : [x === missing for x in v])
end
function _f_isnan(args, nms, ex)
    v = _prim1("is.nan", args, nms)
    LGL(v isa Union{NUM,DAT,DIF} ? [isnan(x) && !SimLev.isna_strict(x) for x in v] : [false for _ in v])
end
function _f_isfinite(args, nms, ex)
    v = _prim1("is.finite", args, nms)   # Datum wie double (seit 1.6.4, C-004; bis 1.6.3 immer FALSE)
    LGL(v isa Union{NUM,DAT,DIF} ? [isfinite(x) for x in v] : v isa Union{LGL,INT} ? [x !== missing for x in v] : [false for _ in v])
end
function _f_isinfinite(args, nms, ex)
    v = _prim1("is.infinite", args, nms)
    LGL(v isa Union{NUM,DAT,DIF} ? [isinf(x) for x in v] : [false for _ in v])
end

function _f_ifelse(args, nms, ex)
    v, _, _ = _bind("ifelse", args, nms, ex, ["test", "yes", "no"])
    test, yes, no = v
    test === nothing && _missing_arg("test")
    t = _as_lgl(test)   # LGL bleibt dasselbe Objekt
    ans = Any[x for x in t]
    kind = 1
    ypos = [i for i in eachindex(t) if t[i] === true]
    npos = [i for i in eachindex(t) if t[i] === false]
    # seit 1.6.4 (C-025) wie R rep(yes, length.out = len): ein leerer Vektor ergibt NA seines Typs, NULL eine Warnung
    # und den Fehler von ans[ypos] <- NULL (bis 1.6.3 bei jedem leeren Wert der Fehler)
    if !isempty(ypos)
        yes === nothing && _missing_arg("yes")
        yes === _NULLV && (_warn("'x' is NULL so the result will be NULL"); error("replacement has length zero"))
        kind = max(kind, _rtype(yes))
        for i in ypos; ans[i] = (yes, isempty(yes) ? _na_of(yes) : _rec(yes, i)); end
    end
    if !isempty(npos)
        no === nothing && _missing_arg("no")
        no === _NULLV && (_warn("'x' is NULL so the result will be NULL"); error("replacement has length zero"))
        kind = max(kind, _rtype(no))
        for i in npos; ans[i] = (no, isempty(no) ? _na_of(no) : _rec(no, i)); end
    end
    # seit 1.6.5 (CR2-A-8): Zahlen auf beiden benutzten Seiten typstabil ohne das Any-Zwischenfeld (gleiche Werte)
    if kind == 3 && (isempty(ypos) || (yes isa NUM && !isempty(yes))) && (isempty(npos) || (no isa NUM && !isempty(no)))
        out = Vector{Float64}(undef, length(t))
        @inbounds for i in eachindex(t)
            ti = t[i]
            out[i] = ti === true ? (yes::NUM)[mod1(i, length(yes))] : ti === false ? (no::NUM)[mod1(i, length(no))] : _NA
        end
        return out
    end
    el(a) = a === missing ? missing : _coerce(_undate(similar_one(a[1], a[2])), kind)[1]   # Datum als Zahl (seit 1.6.4)
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
    narm_raw = nothing
    for (a, nm) in zip(args, nms)
        if nm == "na.rm"
            narm_raw = a
        else
            a === nothing || push!(xs, a)
        end
    end
    (narm_raw !== nothing && !any(x -> x isa Union{DAT,DIF}, xs)) && (narm = _flag_pminmax(narm_raw))
    isempty(xs) && error("no arguments")
    any(x -> x isa Union{DAT,DIF}, xs) && return _pminmax_obj(xs, narm_raw, greater)
    if any(x -> x isa CHR, xs)
        # seit 1.6.4 wie R do_pmin für Text (C-008): Vergleich über die Kollation, NA-Regel wie bei Zahlen
        cs = [_as_chr(x) for x in xs]
        any(isempty, cs) && return CHR()
        n = maximum(length, cs)
        out = Union{Missing,String}[cs[1][(i - 1) % length(cs[1]) + 1] for i in 1:n]
        for c in cs[2:end], i in 1:n
            a_ = out[i]; b_ = c[(i - 1) % length(c) + 1]
            better = b_ !== missing && a_ !== missing && (greater ? _scoll(b_, a_) > 0 : _scoll(b_, a_) < 0)
            ((narm && a_ === missing) || better || (!narm && b_ === missing)) && (out[i] = b_)
        end
        return _setnm(CHR(out), length(xs[1]) == n ? _nm(xs[1]) : nothing)
    end
    any(x -> x isa CHR, xs) && error("invalid input type")
    kind = maximum(_rtype(x) for x in xs)
    any(isempty, xs) && return kind == 3 ? NUM() : INT()
    r = greater ? SimLev.RBase.pmax([_as_num(x) for x in xs]...; na_rm = narm) :
                  SimLev.RBase.pmin([_as_num(x) for x in xs]...; na_rm = narm)
    r = NUM(r isa SimLev.RVector ? r.values : r isa AbstractVector ? collect(r) : [r])
    kind == 3 || (r = INT([isnan(x) ? missing : Int(x) for x in r]))
    # mostattributes(mmm) <- attributes(elts[[1L]]): Namen des ersten Arguments bei gleicher Länge (seit 1.6.4, C-001)
    return _setnm(r, length(xs[1]) == length(r) ? _nm(xs[1]) : nothing)
end

function _rep_len(v, n::Int)
    vn = _nm(v)
    if isempty(v)
        o = similar(v, n); o .= _na_of(v)
        return _setnm(o, vn === nothing ? nothing : Union{Missing,String}[missing for _ in 1:n])
    end
    ii = [(i - 1) % length(v) + 1 for i in 1:n]
    return _setnm(v[ii], vn === nothing ? nothing : vn[ii])
end
_isna_vec(v) = Bool[_isna_el(x) for x in v]

"`x[mask] <- value[mask]` wie R (in ein Datum über `[<-.Date` mit as.Date des Werts, sonst über den höheren Typ)."
function _subassign(x, mask::AbstractVector{Bool}, value)
    if x isa DAT
        any(mask) || return x   # [<-.Date: if(!length(value)) return(x)
        vv = _as_date(value, "value")
        out = copy(x)
        for i in eachindex(mask)
            mask[i] && (out[i] = vv[(i - 1) % length(vv) + 1])
        end
        return _setnm(out, _nm(x))
    end
    vv = _undate(value)
    if x isa DIF && !(vv isa CHR)   # [<-.difftime: Werte als Zahl, Klasse bleibt
        vv = _as_num(vv); out = copy(x)
        for i in eachindex(mask)
            mask[i] && (out[i] = vv[(i - 1) % length(vv) + 1])
        end
        return _setnm(out, _nm(x))
    end
    xn = _nm(x)
    x = _undate(x)
    t = max(_rtype(x), _rtype(vv))
    out = copy(_coerce(x, t)); vv = _coerce(vv, t)
    for i in eachindex(mask)
        mask[i] && (out[i] = vv[(i - 1) % length(vv) + 1])
    end
    return _setnm(out, xn)
end

"""pmin/pmax mit einem Datum wie R 4.3.3 (Zweig für Objekte in pmax.R, seit 1.6.4, C-004; bis 1.6.3 Fehler): Recycling
mit Warnung „an argument will be fractionally recycled“, Vergleich über Ops.Date, Klasse des ersten Arguments."""
function _pminmax_obj(xs, narm, greater::Bool)
    mmm = xs[1]
    has_na = false
    for each in xs[2:end]
        l1 = length(each); l2 = length(mmm)
        if l2 > 0 && (l2 < l1 || l1 == 0)
            l1 % l2 == 0 || _warn("an argument will be fractionally recycled")
            mmm = _rep_len(mmm, l1)
        elseif l1 > 0 && (l1 < l2 || l2 == 0)
            l2 % l1 == 0 || _warn("an argument will be fractionally recycled")
            each = _rep_len(each, l2)
        end
        na_m = _isna_vec(mmm); na_e = _isna_vec(each)
        if has_na || any(na_m) || any(na_e)
            has_na = true
            any(na_m) && (mmm = _subassign(mmm, na_m, each))
            any(na_e) && (each = _subassign(each, na_e, mmm))
        end
        ch = _compare(greater ? "<" : ">", mmm, each)
        mmm = _subassign(mmm, Bool[c === true for c in ch], each)
        if has_na   # if (has.na && !na.rm) mmm[na.m | na.e] <- NA
            keep_na = _scalar_lgl(_not(narm === nothing ? LGL([false]) : narm), "&&", "y")
            keep_na === missing && error("missing value where TRUE/FALSE needed")
            keep_na && (mmm = _subassign(mmm, na_m .| na_e, LGL([missing])))
        end
        # mostattributes(mmm) <- attributes(elts[[1L]]): Namen nur bei gleicher Länge
        mmm = _setnm(copy(mmm), length(xs[1]) == length(mmm) ? _nm(xs[1]) : nothing)
    end
    return mmm
end

"Argumente von Summary.difftime: alle müssen difftime sein (sonst wie R der Fehler des Einheitenvergleichs)."
function _dif_summary(vals)
    all(v -> v isa DIF, vals) || error("comparison of these types is not implemented")
    return Any[NUM(v) for v in vals]
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
    # Summary.Date nur, wenn das erste Argument ein Datum ist (R wählt die Methode nach dem ersten; seit 1.6.4, C-004)
    (!isempty(vals) && vals[1] isa DAT) && error("$(isany ? "any" : "all") not defined for \"Date\" objects")
    (!isempty(vals) && vals[1] isa DIF) && error("'$(isany ? "any" : "all")' not defined for \"difftime\" objects")
    for v in vals
        if v isa CHR || v isa NUM || v isa DAT
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
    (!isempty(vals) && vals[1] isa DAT) && error("sum not defined for \"Date\" objects")   # seit 1.6.4 (C-004)
    (!isempty(vals) && vals[1] isa DIF) &&   # Summary.difftime (Entscheidung 105)
        return DIF(_f_sum(vcat(_dif_summary(vals), Any[LGL([narm])]),
                          vcat(Union{Nothing,String}[nothing for _ in vals], Union{Nothing,String}["na.rm"]), ex))
    vals = Any[_undate(v) for v in vals]
    for v in vals
        v isa CHR && error("invalid 'type' (character) of argument")
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
    (!isempty(vals) && vals[1] isa DIF) &&   # Summary.difftime (Entscheidung 105)
        return DIF(_f_minmax(vcat(_dif_summary(vals), Any[LGL([narm])]),
                             vcat(Union{Nothing,String}[nothing for _ in vals], Union{Nothing,String}["na.rm"]), ex, ismax))
    if !isempty(vals) && vals[1] isa DAT
        # Summary.Date (seit 1.6.4, C-004): Methode nach dem ersten Argument, .Date(NextMethod()) über alle Argumente
        # (bis 1.6.3 nur, wenn alle Argumente Datumswerte waren); mit Text bleibt das Ergebnis Text
        r = _f_minmax(vcat(Any[_undate(v) for v in vals], Any[LGL([narm])]),
                      vcat(Union{Nothing,String}[nothing for _ in vals], Union{Nothing,String}["na.rm"]), ex, ismax)
        return r isa CHR ? r : DAT(_as_num(r))
    end
    anstype = 2
    icum = ismax ? -_IMAX - 1 : _IMAX
    icum_na = false
    zcum = ismax ? -Inf : Inf
    scum = missing
    empty = true
    for v in vals
        v isa Union{DAT,DIF} && (v = _as_num(v))
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
    x isa DIF && return DIF(_f_mean(Any[_as_num(x), v[2], v[3]], Union{Nothing,String}[nothing, "trim", "na.rm"], ex))
    # mean.Date: .Date(mean(unclass(x), ...)) (seit 1.6.4 ohne Abrunden, C-003)
    x isa DAT && return DAT(_f_mean(Any[_as_num(x), v[2], v[3]], Union{Nothing,String}[nothing, "trim", "na.rm"], ex))
    if x isa CHR || x === _NULLV
        _warn("argument is not numeric or logical: returning NA")
        return NUM([_NA])
    end
    narm = _flag_istrue(v[3], false)
    # seit 1.6.5 (CR2-Q-2) wie mean.default: trim nur als Zahl (double oder integer, kein Wahrheitswert und kein
    # Datum) der Länge 1; NA mit Werten in x ist der Fehler von if (trim > 0 && n)
    trim = v[2] === nothing ? 0.0 : (length(v[2]) == 1 && v[2] isa Union{NUM,INT} ? _as_num(v[2])[1] :
                                     error("'trim' must be numeric of length one"))
    if narm
        x = x[[!_isna_el(t) for t in x]]
    end
    n = length(x)
    isnan(trim) && n > 0 && error("missing value where TRUE/FALSE needed")
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
    narm = _flag_if(v[2], false)
    x === _NULLV && return _NULLV   # seit 1.6.4 wie R (T4-B3): median(NULL) ist x[NA_integer_], also NULL (bis dahin NA)
    # median.default mit Datum (seit 1.6.4 ohne Abrunden, C-003)
    x isa Union{DAT,DIF} && return typeof(x)(_f_median(Any[_as_num(x), v[2]], Union{Nothing,String}[nothing, "na.rm"], ex))
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

_num_arg(x) = _as_num(x)

function _f_var(args, nms, ex)
    v, _, _ = _bind("var", args, nms, ex, ["x", "y", "na.rm", "use"])
    x = v[1]
    x === nothing && _missing_arg("x")
    narm = _flag_if(v[3], false)
    x === _NULLV && error("'x' is NULL")   # seit 1.6.4 wie R's C_cov (T4-B3; bis dahin NA), auch mit y (K43 RS)
    # y = NULL ist R's Vorgabe, also wie ohne y (seit 1.6.4, K43 RS, Entscheidung 60; bis dahin „nicht unterstützt“)
    (v[2] === nothing || v[2] === _NULLV) || error("RExpr: var(x, y) wird nicht unterstützt")
    # ein Datum wie double (R 4.3.3 var(<Date>); seit 1.6.4, C-004, bis 1.6.3 Fehler "is.atomic(x) is not TRUE")
    return NUM([Float64(SimLev.RStats.var(_num_arg(x); na_rm = narm))])
end

function _f_sd(args, nms, ex)
    v, _, _ = _bind("sd", args, nms, ex, ["x", "na.rm"])
    x = v[1]
    x === nothing && _missing_arg("x")
    narm = _flag_if(v[2], false)
    return NUM([Float64(SimLev.RStats.sd(_num_arg(x); na_rm = narm))])
end

function _f_quantile(args, nms, ex)
    v, _, _ = _bind("quantile", args, nms, ex, ["x", "probs", "na.rm", "names", "type", "digits", "..."])
    x = v[1]
    x === nothing && _missing_arg("x")
    probs = v[2] === nothing ? [0.0, 0.25, 0.5, 0.75, 1.0] : _as_num(v[2])
    narm = _flag_if(v[3], false)
    # seit 1.6.4 type wie R (C-028): Text, Wahrheitswert, NA, gebrochene Zahl über RStats.quantile_type
    type = v[5] === nothing ? 7 : v[5] isa CHR ? collect(v[5]) : Any[ismissing(t) ? NaN : Float64(t) for t in _as_num(v[5])]
    xn = x isa CHR && narm ? x[.!ismissing.(x)] : x
    if x isa CHR
        any(ismissing, xn) && error("missing values and NaN's not allowed if 'na.rm' is FALSE")
        error("non-numeric argument to binary operator")
    end
    xv = _as_num(xn)
    r = SimLev.RStats.quantile(xv, probs; na_rm = narm, names = false, type = type)
    r = r isa AbstractVector ? NUM(collect(Float64, r)) : NUM([Float64(r)])
    if x isa DAT
        _quantile_date_check(xv, probs, narm, type)
        r = DAT(r)
    elseif x isa DIF   # *.difftime rechnet; Klasse bleibt (Entscheidung 105)
        r = DIF(r)
    end
    # seit 1.6.4 wie R (C-001): names = TRUE gibt die Wahrscheinlichkeiten als Namen ("25%", format_perc)
    nmv = v[4] === nothing ? LGL([true]) : v[4]
    use = _scalar_lgl(nmv, "&&")
    (use === missing && !isempty(nmv)) && error("missing value where TRUE/FALSE needed")
    if use === true && !isempty(probs)
        dg = v[6] === nothing ? NUM([7.0]) : v[6]
        (dg isa Union{NUM,INT,DIF}) || error("is.numeric(digits) is not TRUE")
        all(t -> !isnan(t) && t >= 1, _as_num(dg)) || error("digits >= 1 is not TRUE")
        r = _setnm(r, _format_perc(probs, _as_num(dg)[1]))
    end
    return r
end

"""format_perc von R 4.3.3: formatC(100 * p, format = "fg", width = 1, digits) bei weniger als 100 Werten, sonst
format(…, trim = TRUE, digits); NA ergibt ""."""
function _format_perc(probs, digits)
    x = Float64[100.0 * p for p in probs]
    txt = length(probs) < 100 ? SimLev.RFmt.formatC(x; format = "fg", width = 1, digits = Int(trunc(digits))) :
                                SimLev.RFmt.format(x; trim = true, digits = Int(trunc(digits)))
    txt isa AbstractVector || (txt = [txt])
    return Union{Missing,String}[isnan(p) ? "" : string(t) * "%" for (p, t) in zip(probs, txt)]
end

"""quantile.default mit einem Datum (R 4.3.3, seit 1.6.4, C-004): Typ 7 rechnet immer (1 - h) * x, die übrigen Typen nur
bei Zwischenwerten; dort meldet Ops.Date "* not defined for \"Date\" objects" (bis 1.6.3 gerechnet). Wie Python."""
function _quantile_date_check(xv, probs, narm, typ)
    t0 = typ isa AbstractVector ? (isempty(typ) ? nothing : typ[1]) : typ
    t = t0 isa Real ? t0 : t0 isa AbstractString ? tryparse(Float64, t0) : nothing
    (t === nothing || !isfinite(t)) && return
    t = Int(trunc(Float64(t)))
    t == 7 && error("* not defined for \"Date\" objects")
    x = sort(Float64[v for v in xv if !(narm && isnan(v))])
    n = length(x)
    xp = vcat(n > 0 ? [x[1], x[1]] : [NaN, NaN], x, n > 0 ? [x[end], x[end]] : [NaN, NaN])
    fuzz = 4 * 2.220446049250313e-16
    for p in probs
        pok = !isnan(p)
        j = nothing; h = 0.0
        if t <= 3
            nppm = t == 3 ? n * p - 0.5 : n * p
            if !pok
                h = t == 2 ? NaN : 1.0
            else
                j = floor(nppm)
                h = t == 2 ? ((nppm > j) + 1) / 2 : 0.0
            end
        else
            a, b = t == 4 ? (0.0, 1.0) : t == 5 ? (0.5, 0.5) : t == 6 ? (0.0, 0.0) : t == 8 ? (1 / 3, 1 / 3) :
                   t == 9 ? (3 / 8, 3 / 8) : (0.0, 0.0)
            nppm = a + p * (n + 1 - a - b)
            if pok
                j = floor(nppm + fuzz); h = nppm - j
                abs(h) < fuzz && (h = 0.0)
            else
                h = NaN
            end
        end
        other = if j === nothing
            (isnan(h) || 0 < h < 1) ? missing : false
        else
            jj = Int(j)
            lo = 1 <= jj + 2 <= length(xp) ? xp[jj+2] : NaN
            hi = 1 <= jj + 3 <= length(xp) ? xp[jj+3] : NaN
            ne = (isnan(lo) || isnan(hi)) ? missing : lo != hi
            !(0 < h < 1) ? false : ne
        end
        (other === missing || other) && error("* not defined for \"Date\" objects")
    end
end

"""Namen von c() wie R (bind.c NewExtractNames): Argumentname und innere Namen als "a.x", ohne inneren Namen "a1",
"a2" (bei Länge 1 "a"); ohne Argumentname die inneren Namen bzw. "". `nothing`, wenn nichts benannt ist."""
function _c_names(args, nms)
    any(i -> args[i] !== nothing && !isempty(args[i]) && nms[i] !== nothing, eachindex(args)) ||
        any(a -> a !== nothing && _nm(a) !== nothing, args) || return nothing
    out = Union{Missing,String}[]
    for (a, tag) in zip(args, nms)
        (a === nothing || isempty(a)) && continue
        inner = _nm(a); m = length(a)
        for j in 1:m
            vn = inner === nothing ? nothing : inner[j]
            if tag !== nothing && tag != ""
                if vn !== nothing && vn !== missing && vn != ""
                    push!(out, tag * "." * vn)
                elseif vn === missing
                    push!(out, tag * ".NA")
                else
                    push!(out, m == 1 ? tag : tag * string(j))
                end
            else
                push!(out, inner === nothing ? "" : vn)
            end
        end
    end
    return out
end

function _f_c(args, nms, ex)
    r = _f_c0(args, nms, ex)
    any(a -> a === r, args) && (r = copy(r))   # reduce(vcat, [v]) gibt v selbst zurück
    return _setnm(r, _c_names(args, nms))
end

function _f_c0(args, nms, ex)
    vals = Any[a for a in args if a !== nothing && !(a isa LGL && isempty(a))]
    isempty(vals) && return _NULLV
    # c.Date: unclass(as.Date(e)) je Argument (seit 1.6.4 ohne Abrunden, C-003)
    args[1] isa DAT && return DAT(reduce(vcat, [NUM(_as_date(a, "e")) for a in vals]; init = Float64[]))
    # c.difftime: as.difftime(e, units = "days") je Argument (Entscheidung 105)
    args[1] isa DIF && return DIF(reduce(vcat, [NUM(_as_difftime(a)) for a in vals]; init = Float64[]))
    kind = maximum(_rtype(v) for v in vals)
    return reduce(vcat, [_coerce(v isa DAT ? _as_num(v) : v, kind) for v in vals])
end

"""as.difftime(v, units = "days") für c.difftime: Zahlen bleiben, Text über strptime(v, "%X") gegen 0:0:0 (Zeit des
Tages als Bruchteil eines Tages), sonst der Fehler von as.difftime. Wie Python `_as_difftime`."""
function _as_difftime(v)
    v isa DIF && return v
    v isa Union{NUM,INT} && return DIF(_as_num(v))
    if v isa CHR
        return DIF(Float64[(t = _strptime_secs(x, "%X"); isnan(t) ? _arith("-", NUM([t]), NUM([0.0]))[1] : t / 86400.0)
                           for x in v])
    end
    error("'tim' is not character or numeric")
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
                t == "bytes" ? ncodeunits(z) : t == "chars" ? length(z) :
                sum((SimLev.RFmt._wcwidth(c) for c in z); init = 0) for z in s])   # Breite wie R (seit 1.6.3)
end

function _f_asnum(args, nms, ex)
    v, _, _ = _bind("as.numeric", args, nms, ex, ["x", "..."])
    return v[1] === nothing ? NUM() : _strip(_as_num(v[1]))
end
function _f_asint(args, nms, ex)
    v, _, _ = _bind("as.integer", args, nms, ex, ["x", "..."])
    return v[1] === nothing ? INT() : _strip(_as_int(v[1]))
end
function _f_aslgl(args, nms, ex)
    v, _, _ = _bind("as.logical", args, nms, ex, ["x", "..."])
    return v[1] === nothing ? LGL() : _strip(_as_lgl(v[1]))
end
function _f_aschr(args, nms, ex)
    v, _, _ = _bind("as.character", args, nms, ex, ["x", "..."])
    return v[1] === nothing ? CHR() : _strip(_as_chr(v[1]))
end
# as.Date wie R 4.3.3 mit den Methoden für Text (format, tryFormats, optional), Zahlen (origin) und den Rest (seit
# 1.6.4, C-002, Entscheidung 97; bis 1.6.3 fielen die weiteren Argumente still weg). Wie Python `_f_asdate`.
function _f_asdate(args, nms, ex)
    v, _, _ = _bind("as.Date", args, nms, ex, ["x", "..."])
    x = v[1]
    x === nothing && _missing_arg("x")
    x isa DAT && return x
    if x isa CHR
        w, _, _ = _bind("as.Date", args, nms, ex, ["x", "format", "tryFormats", "optional", "..."])
        r = _as_date_chr(x, w[2] === nothing ? _MISSING : w[2], w[3], w[4])
        xn = _nm(x)   # strptime behält die Namen, bei längerem format wiederholt (seit 1.6.4, C-001)
        return _setnm(r, (xn === nothing || isempty(x)) ? nothing : xn[[(i - 1) % length(x) + 1 for i in 1:length(r)]])
    end
    if x isa Union{NUM,INT}
        idx = Any[a === nothing ? nothing : INT([i]) for (i, a) in enumerate(args)]
        w, rest, _ = _bind("as.Date", idx, nms, ex, ["x", "origin", "..."])
        w[2] === nothing && return _setnm(DAT(_as_num(x)), _nm(x))
        ri = Int[t[1] for t in rest]
        o = _f_asdate(vcat(Any[args[w[2][1]]], Any[args[i] for i in ri]),
                      vcat(Union{Nothing,String}[nothing], Union{Nothing,String}[nms[i] for i in ri]),
                      vcat(Node[Node(:sym, :origin)], Node[ex[i] for i in ri]))
        return _arith("+", o, x)
    end
    # as.Date.default: logisch nur aus lauter NA, NULL ergibt ein leeres Datum
    (x isa LGL && all(ismissing, x)) && return DAT(Float64[_NA for _ in x])
    i = findfirst(==("x"), nms)
    i === nothing && (i = something(findfirst(isnothing, nms), 1))
    error("do not know how to convert '$(_deparse(ex[i]))' to class \u201cDate\u201d")
end

function _f_cumsum(args, nms, ex)
    x = _prim1("cumsum", args, nms)
    x isa DAT && _date_math("cumsum")
    x isa DIF && _dif_math("cumsum")
    x === _NULLV && return NUM()   # seit 1.6.4 wie R (C-025): cumsum(NULL) ist numeric(0)
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

# ── Reihenfunktionen (seit 1.6.5, E-T4-1): rev, which, seq_len, cumprod, cummax, cummin, diff, head, tail ─────────────
# Wie R 4.3.3 und die Python-Fassung (rexpr.py): diff und head/tail aus den Grundoperationen zusammengesetzt wie der
# R-Text dieser Funktionen.

function _f_rev(args, nms, ex)
    v, _, _ = _bind("rev", args, nms, ex, ["x"])
    x = v[1]
    x === nothing && _missing_arg("x")
    return length(x) > 0 ? _index(x, INT(collect(length(x):-1:1))) : x
end

function _f_which(args, nms, ex)
    v, _, _ = _bind("which", args, nms, ex, ["x", "arr.ind", "useNames"])
    x = v[1]
    x === nothing && _missing_arg("x")
    (x isa LGL && x !== _NULLV) || error("argument to 'which' is not logical")
    idx = Int[i for i in eachindex(x) if x[i] === true]
    r = INT(idx)
    xn = _nm(x)
    return xn === nothing ? r : _setnm(r, xn[idx])   # arr.ind/useNames nur mit dim (isTRUE)
end

function _seq_len_n(v)
    length(v) != 1 && _warn("first element used of 'length.out' argument")
    d = length(v) > 0 ? _asreal1(v) : _NA
    (isfinite(d) && d >= 0) || error("argument must be coercible to non-negative integer")
    d >= 4.503599627370496e15 && error("result would be too long a vector")
    trunc(d) > _MAX_LEN && _len_error()
    return Int(trunc(d))
end

function _f_seq_len(args, nms, ex)
    length(args) == 1 || error("$(length(args)) arguments passed to 'seq_len' which requires 1")
    nm = nms[1]
    (nm === nothing || startswith("length.out", nm)) ||
        error("supplied argument name '$nm' does not match 'length.out'")
    args[1] === nothing && _missing_arg("length.out")
    return INT(collect(1:_seq_len_n(args[1])))
end

# cumprod (kind 1), cummax (2), cummin (3) wie do_cum
function _f_cumx(fname::String, kind::Int)
    return function (args, nms, ex)
        x = _prim1(fname, args, nms)
        x isa DAT && _date_math(fname)
        x isa DIF && _dif_math(fname)
        x === _NULLV && return NUM()
        if x isa Union{LGL,INT} && kind != 1
            out = INT([missing for _ in x])
            m = 0
            for i in eachindex(x)
                x[i] === missing && break
                xi = Int(x[i])
                m = i == 1 ? xi : (kind == 2 ? max(m, xi) : min(m, xi))
                out[i] = m
            end
            return out
        end
        xs = Vector{Float64}(_as_num(x))
        isempty(xs) && return NUM()
        return NUM(kind == 1 ? SimLev._rb_cumprod(xs) : kind == 2 ? SimLev._rb_cummax(xs) : SimLev._rb_cummin(xs))
    end
end

# if (x || y()) für zwei logische Einzelwerte
function _oror_cond(x, yfn)
    xv = _scalar_lgl(x, "||")
    xv === true && return true
    yv = _scalar_lgl(yfn(), "||", "y")
    yv === true && return true
    (xv === missing || yv === missing) && error("missing value where TRUE/FALSE needed")
    return false
end

function _f_diff(args, nms, ex)
    v, _, _ = _bind("diff", args, nms, ex, ["x", "lag", "differences", "..."])
    x = v[1]
    x === nothing && _missing_arg("x")
    lag = v[2] === nothing ? INT([1]) : v[2]
    dif = v[3] === nothing ? INT([1]) : v[3]
    isdate = x isa DAT
    one = INT([1])
    if length(lag) != 1 || (isdate ? length(dif) > 1 : length(dif) != 1) ||
            _oror_cond(_compare("<", lag, one), () -> _compare("<", dif, one))
        error("'lag' and 'differences' must be integers >= 1")
    end
    _cond1(_compare(">=", _arith("*", lag, dif), INT([length(x)]))) && return isdate ? DIF() : _index(x, INT([0]))
    r = isdate ? x : _undate(x)
    i1 = _unary("-", INT(collect(1:_seq_len_n(lag))))
    for _ in 1:_seq_len_n(dif)
        nr = INT([length(r)])
        hi = _unary("-", _arith("+", _arith("-", nr, lag), one))
        r = _arith("-", _index(r, i1), _index(r, _colon(_unary("-", nr), hi)))
    end
    x isa DIF && return _cp(DIF, r)   # diff.difftime
    return r
end

const _HT_MSG = ("invalid 'n' - must contain at least one non-missing element, got none.",
                 "invalid 'n' - must be numeric, possibly NA.",
                 "invalid 'n' - must have length one when dim(x) is NULL, got ")

function _ht_n(x, n, ex)
    ln = length(n)
    (ln == 0 || all(_isna_el, n)) && error(_HT_MSG[1])
    n isa Union{NUM,INT,LGL} || error(_HT_MSG[2])
    ln > 1 && error(_HT_MSG[3] * string(ln))
    lx = INT([length(x)])
    nms2 = Union{Nothing,String}[nothing, nothing]
    _cond1(_compare("<", n, INT([0]))) && return _f_minmax(Any[_arith("+", lx, n), INT([0])], nms2, ex, true)
    return _f_minmax(Any[n, lx], nms2, ex, false)
end

function _f_head(args, nms, ex)
    v, _, _ = _bind("head", args, nms, ex, ["x", "n", "..."])
    x = v[1]
    x === nothing && _missing_arg("x")
    n = _ht_n(x, v[2] === nothing ? INT([6]) : v[2], ex)
    return _index(x, INT(collect(1:_seq_len_n(n))))
end

function _f_tail(args, nms, ex)
    v, _, _ = _bind("tail", args, nms, ex, ["x", "n", "keepnums", "addrownums", "..."])
    x = v[1]
    x === nothing && _missing_arg("x")
    n = _ht_n(x, v[2] === nothing ? INT([6]) : v[2], ex)
    lout = Int(ceil(_asreal1(n)))   # seq.int(to = xlen, length.out = n)
    xlen = length(x)
    return _index(x, INT(collect((xlen - lout + 1):xlen)))
end

function _f_xor(args, nms, ex)
    v, _, _ = _bind("xor", args, nms, ex, ["x", "y"])
    (v[1] === nothing) && _missing_arg("x")
    (v[2] === nothing) && _missing_arg("y")
    a = _logic("|", v[1], v[2]); b = _logic("&", v[1], v[2])
    _setnm(LGL([(p === missing || q === missing) ? missing : (p && !q) for (p, q) in zip(a, b)]), _nm(a))
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

# Länge für vector(mode, length) wie R's do_makevector mit asVecSize (seit 1.6.4, T4-B5; bis dahin jede Zahl außer
# NA/NaN, auch logisch, und „invalid 'length' argument“ für NA und negative Werte): Länge des Arguments ≠ 1 oder logisch:
# „invalid 'length' argument“; ganzzahliges NA: „vector size cannot be NA“; Zahl oder Text (Text mit der Warnung der
# Umwandlung): NaN „… NA/NaN“, ±Inf „… infinite“, über R_XLEN_T_MAX „… too large“, dann zur Null hin abgeschnitten;
# danach < 0 wieder „invalid 'length' argument“. Wie Python `_vec_size`.
function _vec_size(v)
    (length(v) != 1 || v isa LGL) && error("invalid 'length' argument")
    if v isa INT
        v[1] === missing && error("vector size cannot be NA")
        n = Int(v[1])
    else
        d = Float64(_as_num(v)[1])   # Text mit Warnung wie asReal
        isnan(d) && error("vector size cannot be NA/NaN")
        isinf(d) && error("vector size cannot be infinite")
        d > 4503599627370496.0 && error("vector size specified is too large")   # R_XLEN_T_MAX
        n = Int(trunc(d))
    end
    n < 0 && error("invalid 'length' argument")
    return n
end

function _f_vector(fname::String, mk)
    (args, nms, ex) -> begin
        v, _, _ = _bind(fname, args, nms, ex, ["length"])
        n = v[1] === nothing ? 0 : _vec_size(v[1])
        n > _MAX_LEN && _len_error()                   # seit 1.6.4 (C-006, Entscheidung 79)
        return mk(n)
    end
end

# erstes Element von a als Vektor gleichen Typs (leer bleibt leer), wie R's asReal/asInteger nur das erste Element
# umwandeln (Warnung der Umwandlung nur dafür)
_first(a) = length(a) <= 1 ? a : a[1:1]

function _f_rep(args, nms, ex)
    v, _, _ = _bind("rep", args, nms, ex, ["x", "times", "length.out", "each"])
    x = v[1]
    x === nothing && return LGL()
    # seit 1.6.4 in der Reihenfolge von R do_rep (K43 RS, Entscheidungen 60 und 157): erst length.out, dann each, je mit
    # „first element used of '…' argument“, wenn die Länge nicht 1 ist (auch NULL); umgewandelt wird nur das erste
    # Element (bis dahin each vor length.out, ohne die Warnung, ganzer Vektor umgewandelt)
    lx = length(x)
    # seit 1.6.4 wie R do_rep (C-008, C-025): NA und ±Inf gelten als fehlend, eine endliche Länge wird abgeschnitten
    # (-0.5 ergibt 0), unter 0 ist sie ein Fehler (bis 1.6.3 außerhalb von int als fehlend)
    lo = nothing
    if v[3] !== nothing
        l = _as_num(_first(v[3]))
        if !isempty(l) && isfinite(l[1])
            trunc(l[1]) < 0 && error("invalid 'length.out' argument")
            lo = Int(trunc(min(l[1], _MAX_LEN + 1.0)))   # über 1e8 + 1 begrenzt (ohne InexactError; wird abgelehnt)
        end
        length(v[3]) != 1 && _warn("first element used of 'length.out' argument")
    end
    # seit 1.6.4 wie R (C-025): NA und ±Inf gelten als 1 (bis 1.6.3 InexactError bei Inf); über 1e8 + 1 begrenzt
    # (gleiches Ergebnis, weil ein längeres Ergebnis ohnehin abgelehnt wird; ohne InexactError)
    each = 1
    if v[4] !== nothing
        e = _as_num(_first(v[4]))
        each = isempty(e) || !isfinite(e[1]) ? 1 : Int(trunc(min(e[1], _MAX_LEN + 1.0)))
        length(v[4]) != 1 && _warn("first element used of 'each' argument")
    end
    each < 0 && error("invalid 'each' argument")
    # seit 1.6.4 wie R (K43 RS, Entscheidungen 60 und 157): bei leerem x prüft R times nicht; NULL bleibt NULL (mit
    # length.out > 0 die Warnung von R), sonst x, mit length.out > 0 auf diese Länge mit NA aufgefüllt (Namen "")
    # (bis dahin „invalid 'times' argument“ bzw. logical(0) für NULL)
    if lx == 0
        if x === _NULLV
            (lo !== nothing && lo > 0) && _warn("'x' is NULL so the result will be NULL")
            return _NULLV
        end
        if lo !== nothing && lo > 0
            lo > _MAX_LEN && _len_error()
            return similar(x, lo) .= _na_of(x)
        end
        return x[Int[]]
    end
    # seit 1.6.4 (C-006, Entscheidung 79): Ergebnislänge vor dem Anlegen geprüft; x wird erst ausgedehnt, wenn das
    # Ergebnis höchstens _MAX_LEN Werte hat (mit length.out ohne Ausdehnen, wie R)
    if lo !== nothing
        lo > _MAX_LEN && _len_error()
        m = lx * each
        if m == 0   # each = 0: wie R ein Fehler, wenn length.out > 0 (seit 1.6.4, K43 RS; bis dahin NA aufgefüllt)
            lo > 0 && error("invalid 'each' argument")
            return x[Int[]]
        end
        return _rep_lo(x, lo, m, each)
    end
    tm = v[2] === nothing ? INT([1]) : v[2]
    tn = _as_num(tm)
    # seit 1.6.4 wie R do_rep (C-025): times endlich mit -1 < times < 2^52 + 1, abgeschnitten (-0.5 ergibt 0);
    # bis 1.6.3 InexactError bei Inf und Fehler bei -1 < times < 0
    ok_t(t) = -1.0 < t < 4503599627370497.0   # NaN ist nicht im Bereich
    if length(tn) == 1
        ok_t(tn[1]) || error("invalid 'times' argument")
        t = Int(trunc(tn[1]))
        Float64(lx) * each * t > _MAX_LEN && _len_error()
        t == 0 && return x[Int[]]
        each != 1 && return (xe = _rep_each(x, each); t == 1 ? xe : _rep_times(xe, t))   # xe ist schon neu
        return _rep_times(x, t)
    end
    length(tn) == lx * each || error("invalid 'times' argument")
    each != 1 && (x = _rep_each(x, each))
    all(ok_t, tn) || error("invalid 'times' argument")
    sum(t -> trunc(t), tn; init = 0.0) > _MAX_LEN && _len_error()   # init: leeres times (seit 1.6.4, K43 RS)
    return _rep_counts(x, tn)
end

# seit 1.6.4 (Entscheidung 111): rep füllt den Ergebnisvektor direkt (bis dahin Indexvektor über Generatoren mit
# push!-Wachstum und danach x[idx]); dieselben Werte, Typ von x, immer ein neuer Vektor
function _rep_lo(x::AbstractVector, lo::Int, m::Int, each::Int)
    r = similar(x, lo)
    @inbounds for i in 1:lo
        r[i] = x[((i - 1) % m) ÷ each + 1]
    end
    return r
end
function _rep_each(x::AbstractVector, each::Int)
    r = similar(x, length(x) * each)
    k = 0
    @inbounds for i in eachindex(x)
        v = x[i]
        for _ in 1:each
            r[k += 1] = v
        end
    end
    return r
end
function _rep_times(x::AbstractVector, t::Int)
    n = length(x)
    r = similar(x, n * t)
    n == 0 && return r
    @inbounds for j in 0:t-1
        copyto!(r, j * n + 1, x, 1, n)
    end
    return r
end
function _rep_counts(x::AbstractVector, tf::AbstractVector)
    tn = Int[Int(trunc(t)) for t in tf]   # hinter der Funktionsgrenze typisiert
    r = similar(x, sum(tn; init = 0))
    k = 0
    @inbounds for i in eachindex(x)
        v = x[i]
        for _ in 1:tn[i]
            r[k += 1] = v
        end
    end
    return r
end

"Positionen der gebundenen Formalen (`nothing`, wenn nicht angegeben)."
function _argpos(fname, args, nms, ex, formals)
    idx = Any[a === nothing ? nothing : INT([i]) for (i, a) in enumerate(args)]
    w, _, _ = _bind(fname, idx, nms, ex, collect(String, formals))
    return Any[t === nothing ? nothing : args[t[1]] for t in w]
end

"Namen des Arguments x behalten (Math-Gruppe, is.na & Co., cumsum, nchar; seit 1.6.4, C-001)."
function _kn_x(fname, formals = ("x",))
    f -> (args, nms, ex) -> begin
        r = f(args, nms, ex)
        (r === _NULLV || _nm(r) !== nothing) && return r
        x = ((length(formals) == 1 || all(isnothing, nms)) && !isempty(args)) ? args[1] :
            _argpos(fname, args, nms, ex, formals)[1]
        xn = x === nothing ? nothing : _nm(x)
        (xn !== nothing && r !== x && length(r) == length(x)) ? _setnm(r, xn) : r
    end
end

"Namen wie R's math2 (round, signif, log mit base): die von x bei gleicher Länge, sonst die des zweiten."
function _kn_math2(fname, second)
    f -> (args, nms, ex) -> begin
        r = f(args, nms, ex)
        (r === _NULLV || _nm(r) !== nothing) && return r
        x, y = _argpos(fname, args, nms, ex, ("x", second))
        n = length(r)
        nm = (x !== nothing && _nm(x) !== nothing && length(x) == n) ? _nm(x) :
             (y !== nothing && _nm(y) !== nothing && length(y) == n) ? _nm(y) : nothing
        _setnm(r, nm)
    end
end

"ifelse: das Ergebnis trägt die Namen von test (R: ans <- test)."
_kn_ifelse(f) = (args, nms, ex) -> begin
    r = f(args, nms, ex)
    t = _argpos("ifelse", args, nms, ex, ("test", "yes", "no"))[1]
    (t !== nothing && _nm(t) !== nothing && length(t) == length(r)) ? _setnm(r, _nm(t)) : r
end

"rep: Namen werden mit den Werten wiederholt."
_kn_rep(f) = (args, nms, ex) -> begin
    r = f(args, nms, ex)
    idx = Any[a === nothing ? nothing : INT([i]) for (i, a) in enumerate(args)]
    w, _, _ = _bind("rep", idx, nms, ex, ["x", "times", "length.out", "each"])
    w[1] === nothing && return r
    x = args[w[1][1]]
    xn = _nm(x)
    xn === nothing && return r
    a2 = copy(args); a2[w[1][1]] = INT(collect(1:length(x)))
    # seit 1.6.4 (K43 RS): die Warnungen nur einmal (aus dem ersten Aufruf)
    ri = Base.CoreLogging.with_logger(() -> f(a2, nms, ex), Base.CoreLogging.NullLogger())
    # NA nur beim Auffüllen eines leeren x mit length.out: Name "" wie R (seit 1.6.4, K43 RS; bis dahin NA)
    _setnm(r, Union{Missing,String}[i === missing ? "" : xn[i] for i in ri])
end

const _FUNS = Dict{String,Function}(
    # seit 1.6.4 (Entscheidung 111) gleich im Zieltyp angelegt (bis dahin fill/zeros und danach eine Kopie)
    "logical" => _f_vector("logical", n -> fill!(LGL(undef, n), false)),
    "integer" => _f_vector("integer", n -> fill!(INT(undef, n), 0)),
    "numeric" => _f_vector("numeric", n -> zeros(n)),
    "double" => _f_vector("double", n -> zeros(n)),
    "character" => _f_vector("character", n -> fill!(CHR(undef, n), "")),
    "rep" => _kn_rep(_f_rep),
    "abs" => _kn_x("abs")(_f_abs), "sqrt" => _kn_x("sqrt")(_math1("sqrt", _rm1(_sqrt))),
    # Skalarkerne der RLibm ohne eigene Warnung (seit 1.6.4; RExpr warnt je Ausdruck, C-094); seit 1.6.4 (C-068) mit
    # der NaN-Regel von R's math1 (_rm1) wie Python _lm1
    "exp" => _kn_x("exp")(_math1("exp", _rm1(SimLev.RLibm._exp))),
    "expm1" => _kn_x("expm1")(_math1("expm1", _rm1(SimLev.RLibm._expm1))),
    "log1p" => _kn_x("log1p")(_math1("log1p", _rm1(SimLev.RLibm._log1p))),
    "log2" => _kn_x("log2")(_math1("log2", v -> SimLev.RLibm._log2(Float64(v)))),     # math2/logbase (RLibm._nan_lb)
    "log10" => _kn_x("log10")(_math1("log10", v -> SimLev.RLibm._log10(Float64(v)))),
    "sin" => _kn_x("sin")(_math1("sin", _rm1(SimLev.RLibm._sin))), "cos" => _kn_x("cos")(_math1("cos", _rm1(SimLev.RLibm._cos))),
    "tan" => _kn_x("tan")(_math1("tan", _rm1(SimLev.RLibm._tan))),
    "tanh" => _kn_x("tanh")(_math1("tanh", _rm1(SimLev.RLibm._tanh))),
    "atan" => _kn_x("atan")(_math1("atan", _rm1(SimLev.RLibm._atan))),
    "floor" => _kn_x("floor")(_math1("floor", _rm1(floor))), "ceiling" => _kn_x("ceiling")(_math1("ceiling", _rm1(ceil))),
    "trunc" => _kn_x("trunc", ("x", "..."))(_f_trunc),
    "sign" => _kn_x("sign")(_math1("sign", _rsign)),
    "log" => _kn_math2("log", "base")(_f_log), "round" => _kn_math2("round", "digits")(_f_round),
    "signif" => _kn_math2("signif", "digits")((a, n, e) -> _f_round(a, n, e; signif = true)),
    "is.na" => _kn_x("is.na")(_f_isna), "is.nan" => _kn_x("is.nan")(_f_isnan),
    "is.finite" => _kn_x("is.finite")(_f_isfinite), "is.infinite" => _kn_x("is.infinite")(_f_isinfinite),
    "ifelse" => _kn_ifelse(_f_ifelse),
    "pmin" => (a, n, e) -> _f_pminmax(a, n, e, false), "pmax" => (a, n, e) -> _f_pminmax(a, n, e, true),
    "min" => (a, n, e) -> _f_minmax(a, n, e, false), "max" => (a, n, e) -> _f_minmax(a, n, e, true),
    "sum" => _f_sum, "mean" => _f_mean, "median" => _f_median, "var" => _f_var, "sd" => _f_sd,
    "quantile" => _f_quantile,
    "any" => (a, n, e) -> _f_anyall(a, n, e, true), "all" => (a, n, e) -> _f_anyall(a, n, e, false),
    "length" => _f_length, "c" => _f_c, "nchar" => _kn_x("nchar", ("x", "type", "allowNA", "keepNA"))(_f_nchar), "xor" => _f_xor,
    "isTRUE" => (a, n, e) -> _f_istf(a, n, e, true), "isFALSE" => (a, n, e) -> _f_istf(a, n, e, false),
    "as.numeric" => _f_asnum, "as.double" => _f_asnum, "as.integer" => _f_asint,
    "as.logical" => _f_aslgl, "as.character" => _f_aschr, "as.Date" => _f_asdate,
    "cumsum" => _kn_x("cumsum")(_f_cumsum), "identity" => _f_identity,
    # seit 1.6.5 (E-T4-1)
    "rev" => _f_rev, "which" => _f_which, "seq_len" => _f_seq_len,
    "cumprod" => _kn_x("cumprod")(_f_cumx("cumprod", 1)), "cummax" => _kn_x("cummax")(_f_cumx("cummax", 2)),
    "cummin" => _kn_x("cummin")(_f_cumx("cummin", 3)), "diff" => _f_diff, "head" => _f_head, "tail" => _f_tail,
)

# ═══════════════════════════════════════════════════════════════════════════
# Auswertung
# ═══════════════════════════════════════════════════════════════════════════

# Spalte, die RExpr nicht darstellen kann (seit 1.6.4, C-007): Zugriff ist ein Fehler (bis 1.6.3 fiel sie weg, und der
# Name kam still aus env)
struct _BadCol end

# Spalten von data als R-Vektoren, erst beim ersten Zugriff umgewandelt (seit 1.6.4, T4-B7, wie Python _LazyCols; bis
# dahin bei jeder Auswertung alle Spalten vorab): dieselben Spaltenobjekte (zu Beginn gemerkt, bei gleichem Namen die
# erste), dieselbe Umwandlung from_julia; eine Spalte, die RExpr nicht darstellen kann, ist erst beim Zugriff ein Fehler
# (wie bisher _BadCol).
struct _LazyCols
    raw::Dict{String,Any}
    done::Dict{String,Any}
end
Base.haskey(L::_LazyCols, k::String) = haskey(L.raw, k)
function Base.getindex(L::_LazyCols, k::String)
    haskey(L.done, k) && return L.done[k]
    r = from_julia(L.raw[k])
    v = r === nothing ? _BadCol() : r
    L.done[k] = v
    return v
end

struct Ctx
    cols::Union{Dict{String,Any},_LazyCols}
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
    if haskey(c.cols, name)
        x = c.cols[name]
        x isa _BadCol && error(SimLev.chk_msg("sp.rexpr_spalte", name))
        return x
    end
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
                    "as.logical", "as.character", "cumsum", "rep", "cumprod", "cummax", "cummin", "seq_len"])

# Aufruf eines Ausdrucks als Funktion (seit 1.6.5, CR2-D-12): 'function'/'\\(' bzw. '::'/':::' im Funktionsteil (ohne
# Klammern) mit derselben Meldung wie ohne Aufruf, sonst „attempt to apply non-function“
function _callx_error(f::Node)
    while f.head === :call && String(f.val) == "(" && !isempty(f.args)
        f = f.args[1]
    end
    if f.head === :call && String(f.val) in ("function", "::", ":::")
        error("RExpr: '$(String(f.val))' wird in Ausdrücken nicht unterstützt")
    end
    error("attempt to apply non-function")
end

function _ev(e::Node, c::Ctx)
    h = e.head
    h === :const && return e.val
    h === :sym && return _lookup(String(e.val), c)
    h === :empty && error("argument is missing, with no default")
    h === :callx && _callx_error(e.val::Node)
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
        _ev(a[1], c) === _NULLV && return _NULLV   # seit 1.6.4 wie R (C-025): NULL$x ist NULL
        error("\$ operator is invalid for atomic vectors")
    elseif f == "@"
        x = _ev(a[1], c)
        error("no applicable method for `@` applied to an object of class \"$(_rclass(x))\"")
    elseif f in _UNSUPPORTED
        error("RExpr: '$f' wird in Ausdrücken nicht unterstützt")
    end
    f == "ifelse" && return _ev_ifelse(e, c)
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

# ifelse als Sonderform (seit 1.6.4, T4-B6; bis dahin wurden yes und no immer ausgewertet): Argumente wie R gebunden,
# dann test ausgewertet; ein Datum bzw. eine Zeitdifferenz als test ist der Fehler von R's !test (Ops.Date bzw.
# Ops.difftime); yes nur, wenn ein Wert von test TRUE ist, no nur, wenn einer FALSE ist (R wertet die Versprechen erst
# dann aus). Der Rest wie bisher in _f_ifelse. Wie Python `_ev_ifelse`.
function _ev_ifelse(e::Node, c::Ctx)
    a = e.args
    idx = Any[x.head === :empty ? nothing : INT([i]) for (i, x) in enumerate(a)]
    w, _, _ = _bind("ifelse", idx, e.names, a, ["test", "yes", "no"])
    pos = [t === nothing ? nothing : t[1] for t in w]
    pos[1] === nothing && _missing_arg("test")
    test = _ev(a[pos[1]], c)
    test isa Union{DAT,DIF} && _not0(test)
    t = _as_lgl(test)
    yes = (pos[2] !== nothing && any(x -> x === true, t)) ? _ev(a[pos[2]], c) : nothing
    no = (pos[3] !== nothing && any(x -> x === false, t)) ? _ev(a[pos[3]], c) : nothing
    return _FUNS["ifelse"](Any[test, yes, no], Union{Nothing,String}[nothing, nothing, nothing],
                           [p === nothing ? nothing : a[p] for p in pos])
end

_columns(::Nothing) = Dict{String,Any}()
function _columns(data)
    d = Dict{String,Any}()
    if data isa SimLev.RFrame
        # seit 1.6.4 (C-007) wie R: bei gleichem Namen gilt die erste Spalte
        for (k, col) in zip(names(data), getfield(data, :cols))
            haskey(d, k) && continue
            d[k] = col
        end
    elseif data isa NamedTuple || data isa AbstractDict || data isa SimLev.RList
        for (k, v) in pairs(data)
            haskey(d, String(k)) && continue
            d[String(k)] = v
        end
    elseif !(data isa AbstractVector && isempty(data))
        error("data muss ein data.frame (RFrame, NamedTuple oder Dict) sein.")
    end
    return _LazyCols(d, Dict{String,Any}())
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
function eval_r(expr, data = nothing; env = nothing, raw::Bool = false)
    exprs = expr isa Node ? Node[expr] : expr isa AbstractVector{Node} ? expr : parse_r(expr)
    return _with_names() do
        c = Ctx(_columns(data), env, Dict{String,Any}())
        r = _NULLV
        for e in exprs
            r = _ev(e, c)
        end
        raw ? r : _public(r)
    end
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
