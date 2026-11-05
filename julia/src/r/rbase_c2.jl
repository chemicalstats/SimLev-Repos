# ─────────────────────────────────────────────────────────────────────────────
# Hüllen der Grundfunktionen mit R-Regeln, Teil 2 (seit 1.6.0), aus der C-Bibliothek slc (core/slc_rbase2.h:
# slc_rbase_clust.cpp, …). Python (simlev._ext, python/src/_ext_slc_rbase2.cpp) und Julia rechnen damit dieselbe
# Implementierung; bis 1.5.2 bildete jede Sprache die Funktionen selbst nach. Die R-Logik um die Kerne (Argumente,
# Namen, Meldungen) steht in den Modulen unter r/ (stats_cluster.jl, …).
# ─────────────────────────────────────────────────────────────────────────────

"dist: Zeilenabstände der nr × nc-Matrix X; method 1–6 wie `_DIST_METHODS` → (Werte, Warnung)."
function _rb_dist(X::Matrix{Float64}, method::Int, p::Float64)
    nr, nc = size(X)
    out = Vector{Float64}(undef, nr * (nr - 1) ÷ 2)
    warn = Ref{Cint}(0)
    ccall((:sl_r_dist, LIBSLC), Cvoid, (Int64, Int64, Ptr{Float64}, Cint, Float64, Ptr{Float64}, Ref{Cint}),
          nr, nc, X, method, p, out, warn)
    out, warn[] != 0
end

"hclust: n Objekte, Verfahren iopt 1–8, Gewichte und Abstände → (merge (n-1) × 2, height, order)."
function _rb_hclust(n::Int, iopt::Int, membr::Vector{Float64}, diss::Vector{Float64})
    merge = Matrix{Int64}(undef, n - 1, 2)
    height = Vector{Float64}(undef, n - 1)
    order = Vector{Int64}(undef, n)
    st = ccall((:sl_r_hclust, LIBSLC), Cint, (Int64, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Int64}, Ptr{Float64}, Ptr{Int64}),
               n, iopt, membr, diss, merge, height, order)
    st == 0 || throw(OutOfMemoryError())
    merge, height, order
end

"`.bincode`: Intervallnummern (1-basiert) der x in den aufsteigenden Grenzen b, 0 für NA."
function _rb_bincode(x::Vector{Float64}, b::Vector{Float64}, right::Bool, include_lowest::Bool)
    out = Vector{Float64}(undef, length(x))
    ccall((:sl_r_bincode, LIBSLC), Cvoid, (Int64, Ptr{Float64}, Int64, Ptr{Float64}, Cint, Cint, Ptr{Float64}),
          length(x), x, length(b), b, right, include_lowest, out)
    Int[isnan(t) ? 0 : Int(t) for t in out]
end

"`seq.int(from, to, length.out = n)` wie R."
function _rb_seq_len(from::Float64, to::Float64, n::Int)
    out = Vector{Float64}(undef, max(n, 0))
    ccall((:sl_r_seq_len, LIBSLC), Cvoid, (Float64, Float64, Int64, Ptr{Float64}), from, to, n, out)
    out
end

"`median(x, na.rm)` für Float64 (isint: ganzzahlige Eingabe) → Wert oder nothing (NA)."
function _rb_median(x::Vector{Float64}, narm::Bool, isint::Bool)
    r = Ref{Float64}(0.0)
    st = ccall((:sl_r_median, LIBSLC), Cint, (Int64, Ptr{Float64}, Cint, Cint, Ref{Float64}), length(x), x, narm, isint, r)
    st == 7 && throw(OutOfMemoryError())
    st == 0 ? r[] : nothing
end

"cor/cov mit `use` 1–5 und method 0 pearson, 1 kendall, 2 spearman (Ränge und NA-Regeln im Kern) → (ans, sd0)."
function _rb_cor(x::Vector{Float64}, n::Int, ncx::Int, xmat::Bool, y::Union{Nothing,Vector{Float64}}, ncy::Int,
                 ymat::Bool, use::Int, method::Int, cor::Bool)
    y === nothing && (ncy = ncx)
    ans = Vector{Float64}(undef, ncx * ncy)
    sd0 = Ref{Cint}(0)
    cx = SLib._ctx()
    st = ccall((:sl_r_cor, LIBSLC), Cint,
               (Ptr{Cvoid}, Int64, Int64, Ptr{Float64}, Cint, Int64, Ptr{Float64}, Cint, Cint, Cint, Cint, Ptr{Float64}, Ref{Cint}),
               cx, n, ncx, x, xmat, ncy, y === nothing ? Ptr{Float64}(C_NULL) : y, ymat, use, method, cor, ans, sd0)
    SLib._finish(cx, st)
    return reshape(ans, ncx, ncy), sd0[] != 0
end

"cov2cor einer p × p-Matrix → (Ergebnis, Warnung)."
function _rb_cov2cor(V::Matrix{Float64})
    p = size(V, 1)
    out = Matrix{Float64}(undef, p, p)
    warn = Ref{Cint}(0)
    ccall((:sl_r_cov2cor, LIBSLC), Cvoid, (Int64, Ptr{Float64}, Ptr{Float64}, Ref{Cint}), p, V, out, warn)
    out, warn[] != 0
end

"scale an Ort und Stelle: center/scale 0 nein, 1 berechnen (nach cen/sc), 2 vorgegeben."
function _rb_scale!(X::Matrix{Float64}, center::Int, cen::Vector{Float64}, scale::Int, sc::Vector{Float64})
    st = ccall((:sl_r_scale, LIBSLC), Cint, (Int64, Int64, Ptr{Float64}, Cint, Ptr{Float64}, Cint, Ptr{Float64}),
               size(X, 1), size(X, 2), X, center, cen, scale, sc)
    st == 0 || throw(OutOfMemoryError())
    X
end

"regularize.values: mode 0 sortieren und zusammenfassen, 1 nur zusammenfassen, 2 nichts; mean: Gruppenmittel im Kern
→ (xo, yo, grp, m, nout, collapsed, kept_na)."
function _rb_regularize(x::Vector{Float64}, y::Vector{Float64}, narm::Bool, mode::Int, mean::Bool)
    n = length(x)
    xo = Vector{Float64}(undef, n); yo = Vector{Float64}(undef, n); grp = Vector{Int64}(undef, n)
    m = Ref{Int64}(0); nout = Ref{Int64}(0); col = Ref{Cint}(0); kna = Ref{Cint}(0)
    st = ccall((:sl_r_regularize, LIBSLC), Cint,
               (Int64, Ptr{Float64}, Ptr{Float64}, Cint, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Int64}, Ref{Int64},
                Ref{Int64}, Ref{Cint}, Ref{Cint}), n, x, y, narm, mode, mean, xo, yo, grp, m, nout, col, kna)
    st == 0 || throw(OutOfMemoryError())
    xo, yo, grp, Int(m[]), Int(nout[]), col[] != 0, kna[] != 0
end

"filter einer Reihe: Faltung (sides, circular) oder rekursiv mit Startwerten init."
function _rb_filter(x::Vector{Float64}, f::Vector{Float64}, recursive::Bool, sides::Int, circular::Bool,
                    init::Vector{Float64})
    out = Vector{Float64}(undef, length(x))
    if recursive
        st = ccall((:sl_r_filter_rec, LIBSLC), Cint, (Int64, Ptr{Float64}, Int64, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}),
                   length(x), x, length(f), f, init, out)
        st == 0 || throw(OutOfMemoryError())
    else
        ccall((:sl_r_filter_conv, LIBSLC), Cvoid, (Int64, Ptr{Float64}, Int64, Ptr{Float64}, Cint, Cint, Ptr{Float64}),
              length(x), x, length(f), f, sides, circular, out)
    end
    out
end

"p.adjust für lp Werte ohne NA, n >= lp > 1, Verfahren 0 holm … 6 none (core/slc_rbase2.h SL_PADJ_*)."
function _rb_p_adjust(p::Vector{Float64}, n::Float64, method::Int)
    out = Vector{Float64}(undef, length(p))
    st = ccall((:sl_r_p_adjust, LIBSLC), Cint, (Int64, Ptr{Float64}, Float64, Cint, Ptr{Float64}),
               length(p), p, n, method, out)
    st == 0 || throw(OutOfMemoryError())
    out
end

"ecdf: (Sprungstellen, Höhen, Zahl der Werte ohne NA); Fehler ohne Wert."
function _rb_ecdf(x::Vector{Float64})
    vals = Vector{Float64}(undef, length(x)); y = Vector{Float64}(undef, length(x)); nv = Ref{Int64}(0)
    st = ccall((:sl_r_ecdf, LIBSLC), Cint, (Int64, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ref{Int64}),
               length(x), x, vals, y, nv)
    st == 1 && error("'x' must have 1 or more non-missing values")
    st == 0 || throw(OutOfMemoryError())
    resize!(vals, nv[]), resize!(y, nv[]), count(!isnan, x)
end

# ── Zahlformat und sprintf (core/slc_rbase_fmt.cpp, seit 1.6.0) ──────────────

_rb_fround(x::Float64, d::Float64) = ccall((:sl_r_fround, LIBSLC), Float64, (Float64, Float64), x, d)
_rb_fprec(x::Float64, d::Float64) = ccall((:sl_r_fprec, LIBSLC), Float64, (Float64, Float64), x, d)

"round (kind 0) bzw. signif (kind 1) mit Recycling: Länge max(nx, nd)."
function _rb_round_vec(kind::Int, x::Vector{Float64}, d::Vector{Float64})
    n = (isempty(x) || isempty(d)) ? 0 : max(length(x), length(d))
    out = Vector{Float64}(undef, n)
    ccall((:sl_r_round_vec, LIBSLC), Cvoid, (Cint, Int64, Ptr{Float64}, Int64, Ptr{Float64}, Ptr{Float64}),
          kind, length(x), x, length(d), d, out)
    out
end

"Texte des Kerns (Puffer und n + 1 Grenzen) als Vector{String}; gibt beide frei."
function _rb_strings(buf::Ptr{UInt8}, off::Ptr{Int64}, n::Int)
    out = Vector{String}(undef, n)
    try
        for i in 1:n
            a = unsafe_load(off, i); b = unsafe_load(off, i + 1)
            out[i] = unsafe_string(buf + a, b - a)
        end
    finally
        ccall((:sl_r_free, LIBSLC), Cvoid, (Ptr{Cvoid},), buf)
        ccall((:sl_r_free, LIBSLC), Cvoid, (Ptr{Cvoid},), off)
    end
    out
end

"formatReal: (w, d, e); na: Maske der NA (UInt8)."
function _rb_format_real(x::Vector{Float64}, na::Vector{UInt8}, digits::Int, nsmall::Int, scipen::Int)
    w = Ref{Cint}(0); d = Ref{Cint}(0); e = Ref{Cint}(0)
    ccall((:sl_r_format_real, LIBSLC), Cvoid,
          (Int64, Ptr{Float64}, Ptr{UInt8}, Cint, Cint, Cint, Ref{Cint}, Ref{Cint}, Ref{Cint}),
          length(x), x, na, digits, nsmall, scipen, w, d, e)
    Int(w[]), Int(d[]), Int(e[])
end

"encodeReal0 je Wert (NA nach Maske als nastr), drop0: Endnullen entfernen."
function _rb_encode_real(x::Vector{Float64}, na::Vector{UInt8}, w::Int, d::Int, e::Int, dec::AbstractString,
                         nastr::AbstractString, drop0::Bool)
    buf = Ref{Ptr{UInt8}}(C_NULL); off = Ref{Ptr{Int64}}(C_NULL)
    st = ccall((:sl_r_encode_real, LIBSLC), Cint,
               (Int64, Ptr{Float64}, Ptr{UInt8}, Cint, Cint, Cint, Cstring, Cstring, Cint, Ref{Ptr{UInt8}}, Ref{Ptr{Int64}}),
               length(x), x, na, w, d, e, String(dec), String(nastr), drop0, buf, off)
    st == 0 || throw(OutOfMemoryError())
    _rb_strings(buf[], off[], length(x))
end

"as.character für Doubles (15 Stellen; NA als \"NA\")."
function _rb_as_character_real(x::Vector{Float64}, scipen::Int, dec::AbstractString)
    buf = Ref{Ptr{UInt8}}(C_NULL); off = Ref{Ptr{Int64}}(C_NULL)
    st = ccall((:sl_r_as_character_real, LIBSLC), Cint, (Int64, Ptr{Float64}, Cint, Cstring, Ref{Ptr{UInt8}}, Ref{Ptr{Int64}}),
               length(x), x, scipen, String(dec), buf, off)
    st == 0 || throw(OutOfMemoryError())
    _rb_strings(buf[], off[], length(x))
end

"formatC (str_signif): istrlen je Wert."
function _rb_str_signif(x::Vector{Float64}, isint::Bool, width::Int, digits::Int, format::AbstractString,
                        flag::AbstractString, istrlen::Vector{Int64})
    buf = Ref{Ptr{UInt8}}(C_NULL); off = Ref{Ptr{Int64}}(C_NULL)
    cx = SLib._ctx()
    st = ccall((:sl_r_str_signif, LIBSLC), Cint,
               (Ptr{Cvoid}, Int64, Ptr{Float64}, Cint, Cint, Cint, Cstring, Cstring, Ptr{Int64}, Ref{Ptr{UInt8}}, Ref{Ptr{Int64}}),
               cx, length(x), x, isint, width, digits, String(format), String(flag), istrlen, buf, off)
    SLib._finish(cx, st)
    _rb_strings(buf[], off[], length(x))
end

"Argument von sprintf für den Kern: Typ SL_RS_*, Daten (Double bzw. Int32 mit NA = typemin(Int32); das jeweils andere
Feld leer) und Texte (character: Pflicht; factor, Date: je Element; sonst nothing)."
struct _SpArg
    t::Cint
    d::Vector{Float64}
    i::Vector{Int32}
    s::Union{Nothing,Vector{Union{Nothing,String}}}
end
_SpArg(t::Integer, d::Vector{Float64}, s = nothing) = _SpArg(Cint(t), d, Int32[], s)
_SpArg(t::Integer, i::Vector{Int32}, s = nothing) = _SpArg(Cint(t), Float64[], i, s)
_SpArg(t::Integer, ::Nothing, s) = _SpArg(Cint(t), Float64[], Int32[], s)

"""sprintf über den Kern: Formate (nothing = NA) und Argumente → (Ergebnisse, Zahl nicht benutzter Argumente)."""
function _rb_sprintf(fmts::Vector{Union{Nothing,String}}, args::Vector{_SpArg}, scipen::Int, dec::String)
    na = length(args)
    types = Vector{Cint}(undef, na); lens = Vector{Int64}(undef, na)
    datas = Vector{Ptr{Cvoid}}(undef, na); strs = Vector{Ptr{Ptr{UInt8}}}(undef, na)
    sptr = Vector{Vector{Ptr{UInt8}}}(undef, na)
    fs = Ptr{UInt8}[f === nothing ? C_NULL : pointer(f) for f in fmts]
    buf = Ref{Ptr{UInt8}}(C_NULL); off = Ref{Ptr{Int64}}(C_NULL); nout = Ref{Int64}(0); nun = Ref{Cint}(0)
    GC.@preserve fmts args sptr begin
        for k in 1:na
            a = args[k]
            types[k] = a.t
            isd = a.t == 2 || a.t == 5
            dat = isd ? length(a.d) : length(a.i)
            datas[k] = a.t == 3 ? C_NULL : isd ? Ptr{Cvoid}(pointer(a.d)) : Ptr{Cvoid}(pointer(a.i))
            if a.s === nothing
                sptr[k] = Ptr{UInt8}[]
                strs[k] = C_NULL
                lens[k] = dat
            else
                sv = a.s
                sptr[k] = Ptr{UInt8}[x === nothing ? C_NULL : pointer(x) for x in sv]
                strs[k] = pointer(sptr[k])
                lens[k] = a.t == 3 ? length(sv) : dat
            end
        end
        cx = SLib._ctx()
        st = ccall((:sl_r_sprintf, LIBSLC), Cint,
                   (Ptr{Cvoid}, Int64, Ptr{Ptr{UInt8}}, Cint, Ptr{Cint}, Ptr{Int64}, Ptr{Ptr{Cvoid}}, Ptr{Ptr{Ptr{UInt8}}},
                    Cint, Cstring, Ref{Ptr{UInt8}}, Ref{Ptr{Int64}}, Ref{Int64}, Ref{Cint}),
                   cx, length(fmts), fs, na, types, lens, datas, strs, scipen, dec, buf, off, nout, nun)
    end
    SLib._finish(cx, st)
    _rb_strings(buf[], off[], Int(nout[])), Int(nun[])
end
