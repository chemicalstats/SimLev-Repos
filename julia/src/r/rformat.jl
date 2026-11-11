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
# ─────────────────────────────────────────────────────────────────────────────
# Textausgabe wie R (Engine): sprintf() mit NA/NaN/Inf-Regeln, format() und
# as.character() für Zahlen, deparse() für einfache Werte, round()/signif(). Seit 1.5.2
# eine dünne Hülle: Runden (fround, fprec) und formatReal/encodeReal rechnet RFmt
# (_fmt_core.jl, nach der Python-Fassung); r_sprintf ist seit 1.6.0 nur noch der skalare Zugang
# zum C-Kern sl_r_sprintf (core/slc_rbase_fmt.cpp) wie RFmt.sprintf.
# ─────────────────────────────────────────────────────────────────────────────

"""Datumstext wie R as.character/format für Tage seit 1970-01-01: `"%d-%02d-%02d"` mit dem Jahr ohne Auffüllen
(`"53-06-19"`, `"-1-01-01"`, `"12345-01-01"`). Seit 1.6.4 (C-005, Entscheidung 97); bis 1.6.3 `Dates.format` mit
vierstelligem, abgeschnittenem Jahr."""
function _r_date_text(z::Integer)
    z += 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = mp < 10 ? mp + 3 : mp - 9
    return string(yoe + era * 400 + (m <= 2)) * "-" * lpad(m, 2, '0') * "-" * lpad(d, 2, '0')
end

"Wert als Text wie R's `as.character()` in `%s` (Zahlen 15 Stellen, Datum wie R ohne aufgefülltes Jahr)."
function _as_str(@nospecialize(v))
    v === nothing && return "NULL"
    v === missing && return "NA"
    v isa AbstractString && return String(v)
    v isa AbstractChar && return string(v)
    v isa Bool && return v ? "TRUE" : "FALSE"
    v isa Date && return _r_date_text(Dates.value(v - Date(1970, 1, 1)))
    # seit 1.6.4 wie R as.character(<POSIXct>) (C-050): Mitternacht nur als Datum, sonst mit Uhrzeit
    v isa DateTime && return _r_date_text(Dates.value(Date(v) - Date(1970, 1, 1))) *
                             (Dates.Time(v) == Dates.Time(0) ? "" : " " * Dates.format(v, dateformat"HH:MM:SS"))
    v isa Real && return r_as_character(v)
    v isa Symbol && return String(v)
    return string(v)
end

"""
    r_sprintf(fmt, args...)

R's `sprintf()` für skalare Argumente (missing/nothing = NA): schneller Zugang zum C-Kern (sl_r_sprintf1, seit 1.6.0
dieselbe Rechnung wie `RFmt.sprintf`; bis 1.5.2 eine zweite Nachbildung über Printf).
"""
# Puffer je Thread für r_sprintf (Aufgaben wechseln den Thread nur an Haltepunkten; zwischen Füllen und ccall liegt
# keiner), damit ein Aufruf außer dem Ergebnis keinen Speicher anlegt
struct _SPBuf
    types::Vector{Cint}
    dv::Vector{Float64}
    iv::Vector{Int32}
    sv::Vector{Ptr{UInt8}}
    out::Vector{UInt8}
    nun::Base.RefValue{Cint}
end
_SPBuf() = _SPBuf(Vector{Cint}(undef, 16), Vector{Float64}(undef, 16), Vector{Int32}(undef, 16),
                  Vector{Ptr{UInt8}}(undef, 16), Vector{UInt8}(undef, 1024), Ref{Cint}(0))
# Seit 1.6.4 (K43 T2-B3): Bis dahin füllte der erste Aufruf die Puffer schon beim Vorkompilieren (ein Thread); nach
# dem Laden blieb es bei einem Platz, und r_sprintf warf auf Thread >= 2 einen BoundsError. Jetzt: beim Laden neu
# aufgesetzt (__init__), bei Bedarf unter der Sperre ergänzt. Ein veröffentlichter Vektor wird nie verändert:
# Ergänzen legt einen neuen an (alte Puffer bleiben) und setzt ihn atomar, so dass Leser ohne Sperre auskommen.
mutable struct _SPBufs
    @atomic v::Vector{_SPBuf}
end
const _SPBUFS = _SPBufs(_SPBuf[])
const _SPLOCK = ReentrantLock()
function _spbuf()
    while true
        tid = Threads.threadid()      # nach der Sperre neu lesen: die Aufgabe kann dort den Thread gewechselt haben
        v = @atomic :acquire _SPBUFS.v
        tid <= length(v) && return @inbounds v[tid]
        lock(_SPLOCK) do
            w = @atomic :acquire _SPBUFS.v
            k = max(tid, Threads.maxthreadid())
            length(w) < k && (@atomic :release _SPBUFS.v = vcat(w, [_SPBuf() for _ in length(w)+1:k]))
        end
    end
end
"Puffer für alle Threads beim Laden neu aufsetzen (kein Stand aus dem Vorkompilieren)."
_spbuf_init!() = (@atomic :release _SPBUFS.v = [_SPBuf() for _ in 1:Threads.maxthreadid()]; nothing)
# Modul SimLev (rformat.jl ist dort direkt eingebunden): einzige __init__-Funktion des Hauptmoduls
__init__() = _spbuf_init!()

function r_sprintf(fmt::AbstractString, @nospecialize(args...))
    n = length(args)
    n > 16 && return RFmt.sprintf(fmt, args...)
    b = _spbuf()
    types = b.types; dv = b.dv; iv = b.iv; sv = b.sv
    keep = nothing
    for k in 1:n
        v = args[k]
        dv[k] = 0.0; iv[k] = 0; sv[k] = C_NULL
        if v === nothing || v === missing
            types[k] = 0; iv[k] = typemin(Int32)
        elseif v isa Bool
            types[k] = 0; iv[k] = v
        elseif v isa Integer
            if abs(v) < 2^31
                types[k] = 1; iv[k] = v
            else
                types[k] = 2; dv[k] = v
            end
        elseif v isa Real
            types[k] = 2; dv[k] = v
        else
            keep === nothing && (keep = Vector{String}(undef, n))
            if v isa Date
                types[k] = 5; dv[k] = Dates.value(v - Date(1970, 1, 1)); keep[k] = _as_str(v)
            else
                types[k] = 3; keep[k] = v isa String ? v : v isa AbstractString ? String(v) : _as_str(v)
            end
        end
    end
    f = fmt isa String ? fmt : String(fmt)
    sp = RFmt._OPT[:scipen]; scipen = sp isa Int ? sp : Int(sp)::Int
    od = RFmt._OPT[:OutDec]; dec = od isa String ? od : String(od)::String
    out = b.out
    while true
        cap = length(out)
        len = GC.@preserve keep out begin
            if keep !== nothing
                for k in 1:n
                    isassigned(keep, k) && (sv[k] = pointer(keep[k]))
                end
            end
            ccall((:sl_r_sprintf1, LIBSLC), Int64,
                  (Cstring, Cint, Ptr{Cint}, Ptr{Float64}, Ptr{Int32}, Ptr{Ptr{UInt8}}, Cint, Cstring, Ptr{UInt8}, Int64,
                   Ptr{UInt8}, Int64, Ref{Cint}),
                  f, n, types, dv, iv, sv, scipen, dec, out, cap, out, cap, b.nun)
        end
        len == -2 && throw(OutOfMemoryError())
        len == -1 && error(GC.@preserve out unsafe_string(pointer(out)))
        if len <= cap
            res = GC.@preserve out unsafe_string(pointer(out), len)
            b.nun[] > 0 && RFmt._sprintf_warn(Int(b.nun[]), 1, f)
            return res
        end
        out = Vector{UInt8}(undef, len)
    end
end

# ── formatReal (R's format.c) ───────────────────────────────────────────────

const _libm_log10 = RFmt._log10   # glibc log10 (dashboard.jl); seit 1.6.4 eine ccall-Zeile (r/_fmt_core.jl)

# Seit 1.5.2 rechnen formatReal und encodeReal die Funktionen von RFmt (_fmt_core.jl; bis 1.5.1 eine zweite Nachbildung
# hier; Drop0 für as.character seit 1.6.4 im C-Kern sl_r_as_character_real); NA-Maske wie R (isna_strict).
_format_real(xs::AbstractVector{Float64}, digits::Int = 7, nsmall::Int = 0, scipen::Int = 0) =
    RFmt._format_real(xs, Bool[isna_strict(x) for x in xs], digits, nsmall, scipen)

_encode_real(x::Float64, w::Int, d::Int, e::Int) = RFmt._encode_real(x, w, d, e, ".", isna_strict(x))

function _insert_big_mark(s::String, mark::String)
    m = match(r"^(\s*[-+]?)(\d+)(.*)$", s)
    (m === nothing || length(m.captures[2]) < 4) && return s
    digs = m.captures[2]
    parts = String[]
    i = length(digs)
    while i >= 1
        j = max(1, i - 2)
        pushfirst!(parts, digs[j:i])
        i = j - 1
    end
    return m.captures[1] * join(parts, mark) * m.captures[3]
end

_isnumval(v) = v isa Real && !(v isa Bool)

# seit 1.6.4 (RP, C-049): Werte ohne Gegenstück in R (komplexe Zahlen) ergeben einen Fehler; gemischte Zahlen und
# Wahrheitswerte wie R's c(): Wahrheitswerte als 1/0 (bis 1.6.3 "TRUE" neben Zahlen)
function _rp_vals(vals::Vector{Any}, who::AbstractString)
    any(v -> v isa Complex, vals) && error(SimLev.chk_msg("rp.wert_typ", who))
    if any(v -> v isa Bool, vals) && any(_isnumval, vals) && all(v -> v === missing || v === nothing || v isa Real, vals)
        vals = Any[v isa Bool ? Int(v) : v for v in vals]
    end
    return vals
end

"""
    r_format(x; digits = 7, nsmall = 0, big_mark = "", scientific = nothing, width = nothing)

`format(x, ...)` wie R für Zahlen-, Wahrheits-, Text- und Datumsvektoren
(gemeinsame Breite). Rückgabe: Vektor der formatierten Elemente.
"""
function r_format(x; digits = nothing, nsmall::Int = 0, big_mark::AbstractString = "",
                  scientific = nothing, width = nothing)
    x === nothing && return String[]
    vals = x isa AbstractVector ? collect(Any, x) : x isa Tuple ? collect(Any, x) : Any[x]
    isempty(vals) && return String[]
    vals = _rp_vals(vals, "r_format")
    # seit 1.6.4 (C-012, Entscheidung 77) digits 1 bis 22 und nsmall 0 bis 20 wie R format()
    dg = digits === nothing ? 7 : RFmt._chk_digits(digits)
    nsmall = RFmt._chk_nsmall(nsmall)
    scipen = scientific === nothing ? 0 : scientific isa Bool ? (scientific ? -99 : 310) : Int(scientific)
    if all(v -> _isnumval(v) || v === missing || v === nothing, vals) && any(_isnumval, vals)
        fv = Float64[_isnumval(v) ? Float64(v) : NA for v in vals]
        # ganze Zahlen wie R-integer nur im int-Bereich (seit 1.6.4, Entscheidung 63, C-090), sonst wie double
        if all(v -> (v isa Integer && abs(v) < 2^31) || v === missing || v === nothing, vals)
            out = String[v isa Integer ? string(v) : "NA" for v in vals]
            ww = maximum(length, out)
            out = [lpad(s, ww) for s in out]
        else
            w, d, e = _format_real(fv, dg, nsmall, scipen)
            # in einem Aufruf (seit 1.6.3; bis 1.6.2 je Wert, gleicher Kern sl_r_encode_real, gleiche NA-Maske)
            out = SimLev._rb_encode_real(fv, UInt8[isna_strict(v) for v in fv], w, d, e, ".", "NA", false)
        end
        # seit 1.6.5 (CR2-D-13) wie R format.default: erst die Breite, dann die Tausenderzeichen (gemeinsame Breite)
        width !== nothing && (out = [lpad(s, Int(width)) for s in out])
        if !isempty(big_mark)
            out = [_insert_big_mark(s, String(big_mark)) for s in out]
            ww = maximum(length, out)
            out = [lpad(s, ww) for s in out]
        end
        return out
    end
    if all(v -> v isa Bool || v === missing || v === nothing, vals)
        out = String[v isa Bool ? (v ? "TRUE" : "FALSE") : "NA" for v in vals]
        ww = max(width === nothing ? 0 : Int(width), maximum(length, out))   # seit 1.6.5 mit width wie R (CR2-D-13)
        return [lpad(s, ww) for s in out]
    end
    out = String[v === missing || v === nothing ? "NA" : _as_str(v) for v in vals]
    # Datumswerte ohne gemeinsame Breite wie R format.Date (seit 1.6.4 mit Jahren ohne Auffüllen, C-005)
    all(v -> v === missing || v === nothing || v isa Date, vals) && return out
    ww = max(width === nothing ? 0 : Int(width), maximum(length, out))
    return [rpad(s, ww) for s in out]
end

"`format(x)` für einen einzelnen Wert."
function r_format1(x; kw...)
    r = r_format(x; kw...)
    return isempty(r) ? "character(0)" : r[1]
end

"`as.character(x)` für eine Zahl wie R (15 signifikante Stellen, ohne Endnullen)."
function r_as_character(x)
    x === missing && return "NA"
    x === nothing && return "NULL"
    x isa Bool && return x ? "TRUE" : "FALSE"
    x isa Integer && abs(x) < 2^31 && return string(x)
    xf = Float64(x)
    isnan(xf) && return isna_strict(xf) ? "NA" : "NaN"
    isinf(xf) && return xf > 0 ? "Inf" : "-Inf"
    # C-Kern sl_r_as_character_real mit scipen fest 0 und "." (seit 1.6.4; bis 1.6.3 formatReal + encodeReal + Drop0
    # hier nachgebaut, gleiche Texte)
    return _rb_as_character_real([xf], 0, ".")[1]
end

"""Text in Anführungszeichen wie R `deparse` (EncodeString in UTF-8; seit 1.6.4, C-089): `\\`, `\"` und
`\\a \\b \\f \\n \\r \\t \\v`, andere ASCII-Steuerzeichen oktal (`\\001`), nicht druckbare Zeichen als
`\\uxxxx`/`\\Uxxxxxxxx`, ungültige Bytes als `\\xNN`; `\$` bleibt."""
function r_deparse_str(s::AbstractString)
    io = IOBuffer()
    write(io, '"')
    for c in s
        if !isvalid(c)
            for b in codeunits(string(c))
                write(io, "\\x", string(b; base = 16, pad = 2))
            end
            continue
        end
        k = UInt32(c)
        e = c == '\a' ? "\\a" : c == '\b' ? "\\b" : c == '\f' ? "\\f" : c == '\n' ? "\\n" : c == '\r' ? "\\r" :
            c == '\t' ? "\\t" : c == '\v' ? "\\v" : c == '\\' ? "\\\\" : c == '"' ? "\\\"" : nothing
        if e !== nothing
            write(io, e)
        elseif k < 0x80
            0x20 <= k < 0x7F ? write(io, c) : write(io, "\\", string(k; base = 8, pad = 3))
        elseif _wct_print(c)
            write(io, c)
        else
            write(io, k > 0xFFFF ? "\\U" * string(k; base = 16, pad = 8) : "\\u" * string(k; base = 16, pad = 4))
        end
    end
    write(io, '"')
    return String(take!(io))
end

"`paste(deparse(x), collapse = \"\")` für einfache Werte."
function r_deparse(@nospecialize(x))
    one(v) = v === nothing || v === missing ? "NA" :
             v isa AbstractString ? r_deparse_str(v) :   # seit 1.6.4 wie R mit Steuerzeichen (C-089)
             v isa Bool ? (v ? "TRUE" : "FALSE") :
             v isa Date ? "\"" * _as_str(v) * "\"" :
             v isa Integer && abs(v) < 2^31 ? string(v) :   # wie R-integer (Entscheidung 63, C-090)
             v isa Real ? (isnan(v) ? (isna_strict(Float64(v)) ? "NA" : "NaN") : isinf(v) ? (v > 0 ? "Inf" : "-Inf") :
                           (r = _format_real([Float64(v)], 15, 0, 0); _encode_real(Float64(v), r...))) :
             v isa Symbol ? String(v) : repr(v)
    x === nothing && return "NULL"
    x isa Complex && error(SimLev.chk_msg("rp.wert_typ", "r_deparse"))
    # seit 1.6.4 wie R (RP, C-049): Datum als structure(<Tage>, class = "Date") (bis 1.6.3 Text in Anführungszeichen)
    x isa Date && return "structure(" * one(Float64(Dates.value(x - Date(1970, 1, 1)))) * ", class = \"Date\")"
    if x isa AbstractDict || x isa NamedTuple || x isa AbstractVector{<:Pair}
        ps = x isa NamedTuple ? collect(pairs(x)) : collect(x)
        isempty(ps) && return "list()"
        return "list(" * join((string(k) * " = " * r_deparse(v) for (k, v) in ps), ", ") * ")"
    end
    # seit 1.6.5 (CR2-C-11): benannter Vektor wie R "c(a = 1, b = 2)" (bis 1.6.4 ohne Namen)
    if x isa SimLev.RVector && x.names !== nothing && !isempty(x.values)
        nm(k) = occursin(r"^([A-Za-z]|[.](?![0-9]))[A-Za-z0-9._]*$", k) ? k : r_deparse_str(k)
        return "c(" * join((nm(k) * " = " * r_deparse(v) for (k, v) in zip(x.names, x.values)), ", ") * ")"
    end
    if x isa AbstractVector || x isa Tuple
        vals = collect(Any, x)
        # seit 1.6.5 (CR2-C-11): leerer Vektor nach Elementtyp wie R (bis 1.6.4 Text "NULL", Zahl "numeric(0)")
        if isempty(vals)
            x isa Tuple && return "NULL"
            T = nonmissingtype(eltype(x))
            return T <: Bool ? "logical(0)" : T <: Integer ? "integer(0)" : T <: Real ? "numeric(0)" :
                   T <: AbstractString ? "character(0)" : T <: Date ? "structure(numeric(0), class = \"Date\")" : "NULL"
        end
        if x isa AbstractVector && nonmissingtype(eltype(x)) <: Date && all(ismissing, vals)   # nur NA als Datum
            return "structure(" * (length(vals) == 1 ? "NA_real_" : "c(" * join(fill("NA_real_", length(vals)), ", ") * ")") *
                   ", class = \"Date\")"
        end
        any(v -> v isa Union{AbstractVector,Tuple,AbstractDict,NamedTuple}, vals) &&
            return "list(" * join((r_deparse(v) for v in vals), ", ") * ")"
        vals = _rp_vals(vals, "r_deparse")
        # seit 1.6.4 wie R (RP, C-049): Datumsvektor als structure(c(<Tage>), class = "Date"); mit Text wie c() alles als
        # Text (bis 1.6.3 Datum als Text in Anführungszeichen, Zahlen neben Text ohne Anführungszeichen)
        if all(v -> v === missing || v === nothing || v isa Date, vals) && any(v -> v isa Date, vals)
            d = Any[v isa Date ? Float64(Dates.value(v - Date(1970, 1, 1))) : NA for v in vals]
            inner = length(d) == 1 ? one(d[1]) : "c(" * join((one(t) for t in d), ", ") * ")"
            return "structure(" * inner * ", class = \"Date\")"
        end
        if any(v -> v isa AbstractString, vals) && !any(v -> v isa Union{Date,DateTime}, vals)
            vals = Any[v === missing || v === nothing || v isa AbstractString ? v : _as_str(v) for v in vals]
        end
        # R (deparse.c): sind alle Elemente eines double-Vektors NA (nicht NaN), heißt jedes NA_real_
        # (bzw. NA_character_ bei Zeichenvektoren), sonst NA
        if all(v -> v isa AbstractFloat && isna_strict(Float64(v)), vals)
            length(vals) == 1 && return "NA_real_"
            return "c(" * join(fill("NA_real_", length(vals)), ", ") * ")"
        elseif x isa AbstractVector && nonmissingtype(eltype(x)) <: AbstractString && all(ismissing, vals)
            length(vals) == 1 && return "NA_character_"
            return "c(" * join(fill("NA_character_", length(vals)), ", ") * ")"
        end
        length(vals) == 1 && return one(vals[1])
        return "c(" * join((one(v) for v in vals), ", ") * ")"
    end
    x isa AbstractFloat && isna_strict(Float64(x)) && return "NA_real_"
    return one(x)
end

# ── Runden ──────────────────────────────────────────────────────────────────

"R's `round(x, digits)` (Algorithmus seit R 4.0.0, nmath/fround.c; Rechnung `RFmt.fround`)."
r_round(x::Real, digits::Real = 0) = RFmt.fround(Float64(x), Float64(digits))

"R's `signif(x, digits)` (nmath/fprec.c; Rechnung `RFmt.fprec`, `digits` wie R mit C-`round()`)."
r_signif(x::Real, digits::Real = 6) = RFmt.fprec(Float64(x), Float64(digits))

