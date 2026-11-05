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

"Wert als Text wie R's `as.character()` in `%s` (Zahlen 15 Stellen, Datum JJJJ-MM-TT)."
function _as_str(@nospecialize(v))
    v === nothing && return "NULL"
    v === missing && return "NA"
    v isa AbstractString && return String(v)
    v isa AbstractChar && return string(v)
    v isa Bool && return v ? "TRUE" : "FALSE"
    v isa Date && return Dates.format(v, dateformat"yyyy-mm-dd")
    v isa DateTime && return Dates.format(v, dateformat"yyyy-mm-dd HH:MM:SS")
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
const _SPBUFS = _SPBuf[]
const _SPLOCK = ReentrantLock()
function _spbuf()
    if isempty(_SPBUFS)
        lock(_SPLOCK) do
            isempty(_SPBUFS) && append!(_SPBUFS, [_SPBuf() for _ in 1:Threads.maxthreadid()])
        end
    end
    return _SPBUFS[Threads.threadid()]
end

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

_libm_log10(x::Float64) = ccall((:log10, _LIBM), Float64, (Float64,), x)   # dashboard.jl

# Seit 1.5.2 rechnen formatReal, encodeReal und Drop0 die Funktionen von RFmt (_fmt_core.jl; bis 1.5.1 eine
# zweite Nachbildung hier); NA-Maske wie R (isna_strict).
_format_real(xs::AbstractVector{Float64}, digits::Int = 7, nsmall::Int = 0, scipen::Int = 0) =
    RFmt._format_real(xs, Bool[isna_strict(x) for x in xs], digits, nsmall, scipen)

function _encode_real(x::Float64, w::Int, d::Int, e::Int; drop0::Bool = false)
    s = RFmt._encode_real(x, w, d, e, ".", isna_strict(x))
    return drop0 && isfinite(x) ? RFmt._drop0(s) : s
end

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
    dg = digits === nothing ? 7 : Int(digits)
    scipen = scientific === nothing ? 0 : scientific isa Bool ? (scientific ? -99 : 310) : Int(scientific)
    if all(v -> _isnumval(v) || v === missing || v === nothing, vals) && any(_isnumval, vals)
        fv = Float64[_isnumval(v) ? Float64(v) : NA for v in vals]
        if all(v -> v isa Integer || v === missing || v === nothing, vals)
            out = String[v isa Integer ? string(v) : "NA" for v in vals]
            ww = maximum(length, out)
            out = [lpad(s, ww) for s in out]
        else
            w, d, e = _format_real(fv, dg, nsmall, scipen)
            # in einem Aufruf (seit 1.6.3; bis 1.6.2 je Wert, gleicher Kern sl_r_encode_real, gleiche NA-Maske)
            out = SimLev._rb_encode_real(fv, UInt8[isna_strict(v) for v in fv], w, d, e, ".", "NA", false)
        end
        if !isempty(big_mark)
            out = [_insert_big_mark(s, String(big_mark)) for s in out]
            ww = maximum(length, out)
            out = [lpad(s, ww) for s in out]
        end
        width !== nothing && (out = [lpad(s, Int(width)) for s in out])
        return out
    end
    if all(v -> v isa Bool || v === missing || v === nothing, vals)
        out = String[v isa Bool ? (v ? "TRUE" : "FALSE") : "NA" for v in vals]
        ww = maximum(length, out)
        return [lpad(s, ww) for s in out]
    end
    out = String[v === missing || v === nothing ? "NA" : _as_str(v) for v in vals]
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
    w, d, e = _format_real([xf], 15, 0, 0)
    return _encode_real(xf, 0, d, e; drop0 = true)
end

"`paste(deparse(x), collapse = \"\")` für einfache Werte."
function r_deparse(@nospecialize(x))
    one(v) = v === nothing || v === missing ? "NA" :
             v isa AbstractString ? "\"" * replace(String(v), "\\" => "\\\\", "\"" => "\\\"") * "\"" :
             v isa Bool ? (v ? "TRUE" : "FALSE") :
             v isa Date ? "\"" * _as_str(v) * "\"" :
             v isa Integer ? string(v) :
             v isa Real ? (isnan(v) ? (isna_strict(Float64(v)) ? "NA" : "NaN") : isinf(v) ? (v > 0 ? "Inf" : "-Inf") :
                           (r = _format_real([Float64(v)], 15, 0, 0); _encode_real(Float64(v), r...))) :
             v isa Symbol ? String(v) : repr(v)
    x === nothing && return "NULL"
    if x isa AbstractDict || x isa NamedTuple || x isa AbstractVector{<:Pair}
        ps = x isa NamedTuple ? collect(pairs(x)) : collect(x)
        isempty(ps) && return "list()"
        return "list(" * join((string(k) * " = " * r_deparse(v) for (k, v) in ps), ", ") * ")"
    end
    if x isa AbstractVector || x isa Tuple
        vals = collect(Any, x)
        isempty(vals) && return x isa AbstractVector{<:Real} ? "numeric(0)" : "NULL"
        any(v -> v isa Union{AbstractVector,Tuple,AbstractDict,NamedTuple}, vals) &&
            return "list(" * join((r_deparse(v) for v in vals), ", ") * ")"
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

