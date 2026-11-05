# ─────────────────────────────────────────────────────────────────────────────
# Hüllen der Grundfunktionen mit R-Regeln aus der C-Bibliothek slc (core/slc_rbase*.cpp)
#
# Python (simlev._ext, python/src/_ext_slc_rbase.cpp) und Julia rechnen damit dieselbe Implementierung:
# Summen, Mittel, Varianz und Kumulationen in long double wie R, R's Potenz, stabile Ordnung und Rang,
# partielle Sortierung und Quantile wie R, tabulate, findInterval, approx und cov/cor. Die Hüllen hier nehmen
# Float64-Vektoren (spaltenweise Matrizen) und geben Float64 zurück; die R-Logik um die Kerne
# (Argumente, Namen, NA-Prüfungen) steht in rnum.jl, base.jl, stats_sort.jl und stats_cor.jl.
# ─────────────────────────────────────────────────────────────────────────────

@inline _rbv(x::Vector{Float64}) = x
@inline _rbv(x) = collect(Float64, x)

_rb_sum(x::Vector{Float64}, narm::Bool) = ccall((:sl_r_sum, LIBSLC), Float64, (Int64, Ptr{Float64}, Cint), length(x), x, narm)
_rb_prod(x::Vector{Float64}, narm::Bool) = ccall((:sl_r_prod, LIBSLC), Float64, (Int64, Ptr{Float64}, Cint), length(x), x, narm)
_rb_mean(x::Vector{Float64}) = ccall((:sl_r_mean, LIBSLC), Float64, (Int64, Ptr{Float64}), length(x), x)
_rb_mean_int(x::Vector{Int64}) = ccall((:sl_r_mean_int, LIBSLC), Float64, (Int64, Ptr{Int64}), length(x), x)
_rb_var(x::Vector{Float64}) = ccall((:sl_r_var, LIBSLC), Float64, (Int64, Ptr{Float64}), length(x), x)

for (f, c) in ((:_rb_cumsum, :sl_r_cumsum), (:_rb_cumprod, :sl_r_cumprod), (:_rb_cummax, :sl_r_cummax),
               (:_rb_cummin, :sl_r_cummin))
    @eval function $f(x::Vector{Float64})
        out = Vector{Float64}(undef, length(x))
        ccall(($(QuoteNode(c)), LIBSLC), Cvoid, (Int64, Ptr{Float64}, Ptr{Float64}), length(x), x, out)
        out
    end
end

"colSums/colMeans (rows = false) bzw. rowSums/rowMeans (rows = true) einer spaltenweisen nr × nc-Matrix."
function _rb_margsums(x::Vector{Float64}, nr::Int, nc::Int, narm::Bool, mean::Bool, rows::Bool)
    length(x) == nr * nc || error("interner Fehler: Matrix hat die falsche Länge")
    out = Vector{Float64}(undef, rows ? nr : nc)
    if rows
        st = ccall((:sl_r_rowsums, LIBSLC), Cint, (Int64, Int64, Ptr{Float64}, Cint, Cint, Ptr{Float64}),
                   nr, nc, x, narm, mean, out)
        st == 0 || throw(OutOfMemoryError())
    else
        ccall((:sl_r_colsums, LIBSLC), Cvoid, (Int64, Int64, Ptr{Float64}, Cint, Cint, Ptr{Float64}),
              nr, nc, x, narm, mean, out)
    end
    out
end

_rb_pow1(x::Float64, y::Float64) = ccall((:sl_r_pow1, LIBSLC), Float64, (Float64, Float64), x, y)
function _rb_pow(x::Vector{Float64}, y::Float64)
    out = Vector{Float64}(undef, length(x))
    ccall((:sl_r_pow, LIBSLC), Cvoid, (Int64, Ptr{Float64}, Float64, Ptr{Float64}), length(x), x, y, out)
    out
end

"order über Zahlenschlüssel (je ein Vektor gleicher Länge); nalast 1 hinten, 0 vorn, -1 entfernen → 1-basierte Indizes."
function _rb_order(keys::Vector{Vector{Float64}}, dec::Vector{Bool}, nalast::Int)
    n = isempty(keys) ? 0 : length(keys[1])
    all(k -> length(k) == n, keys) || error("argument lengths differ")
    kk = reduce(vcat, keys; init = Float64[])
    d = Cint[c for c in dec]
    out = Vector{Int64}(undef, n)
    nout = Ref{Int64}(0)
    st = ccall((:sl_r_order, LIBSLC), Cint, (Int64, Cint, Ptr{Float64}, Ptr{Cint}, Cint, Ptr{Int64}, Ref{Int64}),
               n, length(keys), kk, d, nalast, out, nout)
    st == 0 || throw(OutOfMemoryError())
    resize!(out, nout[])
end

const _RB_TIES = Dict("average" => 0, "first" => 1, "last" => 2, "min" => 3, "max" => 4)
"rank(x, ties.method) für Zahlen ohne NA (Float64-Ergebnis)."
function _rb_rank(x::Vector{Float64}, ties::AbstractString)
    out = Vector{Float64}(undef, length(x))
    st = ccall((:sl_r_rank, LIBSLC), Cint, (Int64, Ptr{Float64}, Cint, Ptr{Float64}), length(x), x, _RB_TIES[ties], out)
    st == 0 || throw(OutOfMemoryError())
    out
end

"sort(x, partial = k) wie R (x ohne NA, Kopie)."
function _rb_psort(x::Vector{Float64}, k::Vector{Int64})
    v = copy(x)
    st = ccall((:sl_r_psort, LIBSLC), Cint, (Int64, Ptr{Float64}, Int64, Ptr{Int64}), length(v), v, length(k), k)
    st == 0 || throw(OutOfMemoryError())
    v
end

"quantile(x, p, type) für x ohne NA und begrenzte p (NaN erlaubt)."
function _rb_quantile(x::Vector{Float64}, p::Vector{Float64}, type::Int)
    out = Vector{Float64}(undef, length(p))
    st = ccall((:sl_r_quantile, LIBSLC), Cint, (Int64, Ptr{Float64}, Int64, Ptr{Float64}, Cint, Ptr{Float64}),
               length(x), x, length(p), p, type, out)
    st == 7 && throw(OutOfMemoryError())
    st == 0 || error("'type' must be 1:9")
    out
end

function _rb_tabulate(bin::Vector{Float64}, nbins::Int)
    out = zeros(Int64, max(nbins, 0))
    ccall((:sl_r_tabulate, LIBSLC), Cvoid, (Int64, Ptr{Float64}, Int64, Ptr{Int64}), length(bin), bin, length(out), out)
    out
end

function _rb_findinterval(vec::Vector{Float64}, x::Vector{Float64}, rc::Bool, ai::Bool, lo::Bool)
    out = Vector{Float64}(undef, length(x))
    ccall((:sl_r_findinterval, LIBSLC), Cvoid, (Int64, Ptr{Float64}, Int64, Ptr{Float64}, Cint, Cint, Cint, Ptr{Float64}),
          length(vec), vec, length(x), x, rc, ai, lo, out)
    out
end

"approx-Kern (R_approxfun): x aufsteigend ohne NA, y gleich lang; Interpolation je Punkt von v (seit 1.5.0)."
function _rb_approx(x::Vector{Float64}, y::Vector{Float64}, v::Vector{Float64}, method::Int, yleft::Float64,
                    yright::Float64, f::Float64)
    length(y) == length(x) || error("_rb_approx: x und y verschieden lang")
    out = Vector{Float64}(undef, length(v))
    ccall((:sl_r_approx, LIBSLC), Cvoid, (Int64, Ptr{Float64}, Ptr{Float64}, Int64, Ptr{Float64}, Cint, Float64, Float64,
                                          Float64, Ptr{Float64}), length(x), x, y, length(v), v, method, yleft, yright, f, out)
    out
end

"cov/cor-Kern: x n × ncx, y n × ncy oder nothing (spaltenweise); → (ncx × ncy-Matrix, sd0)."
function _rb_cov(x::Vector{Float64}, n::Int, ncx::Int, y::Union{Nothing,Vector{Float64}}, ncy::Int,
                 use::Int, kendall::Bool, cor::Bool)
    y === nothing && (ncy = ncx)
    ans = Vector{Float64}(undef, ncx * ncy)
    sd0 = Ref{Cint}(0)
    cx = SLib._ctx()
    st = ccall((:sl_r_cov, LIBSLC), Cint,
               (Ptr{Cvoid}, Int64, Int64, Ptr{Float64}, Int64, Ptr{Float64}, Cint, Cint, Cint, Ptr{Float64}, Ref{Cint}),
               cx, n, ncx, x, ncy, y === nothing ? Ptr{Float64}(C_NULL) : y, use, kendall, cor, ans, sd0)
    SLib._finish(cx, st)
    return reshape(ans, ncx, ncy), sd0[] != 0
end

# ── Datum (core/slc_rbase_date.cpp) ───────────────────────────────────────
# format.Date/strftime in der C-Locale für einen Tag (Tage seit 1970-01-01) und as.Date(s, format =
# "%Y<sep>%m<sep>%d"); dieselbe Implementierung wie Python (_ext.slc_r_format_date/slc_r_strptime_ymd).

"""
strftime(fmt) für den Tag `z`; `digits_secs` = getOption("digits.secs") für %OS ohne Ziffer.
`nothing` bei |z| >= 1e14 (wie die Python-Hülle); Ergebnis über 2048 Bytes ist wie in R ein Fehler. `buf`
(mindestens 2048 Bytes) kann über mehrere Aufrufe wiederverwendet werden.
"""
function _rb_strftime(z::Int64, fmt::String, digits_secs::Integer = 0, buf::Vector{UInt8} = Vector{UInt8}(undef, 2048))
    length(buf) < 2048 && resize!(buf, 2048)
    n = GC.@preserve buf ccall((:sl_r_strftime, LIBSLC), Int64, (Int64, Ptr{UInt8}, Int64, Cint, Ptr{UInt8}, Int64),
                               z, fmt, sizeof(fmt), Cint(clamp(digits_secs, -1, 7)), buf, length(buf))
    n == -2 && error("output string exceeded 2048 bytes")
    n == -3 && throw(OutOfMemoryError())
    n < 0 && return nothing
    return GC.@preserve buf unsafe_string(pointer(buf), n)   # Puffer bleibt für weitere Aufrufe nutzbar
end

"as.Date(s, format = \"%Y<sep>%m<sep>%d\") → Tage oder `nothing` (NA)."
function _rb_strptime_ymd(s::AbstractString, sep::Char)
    str = String(s)
    z = Ref{Int64}(0)
    ok = ccall((:sl_r_strptime_ymd, LIBSLC), Cint, (Ptr{UInt8}, Int64, Cint, Ref{Int64}),
               str, sizeof(str), Cint(sep), z)
    return ok == 0 ? nothing : z[]
end

# ── Summen und Mittel im Fachcode, weitere long-double-Wege (core/slc_rbase.cpp, slc_rbase_num.cpp) ──
# Ersetzen die Nachbildung von long double (früher r/ld80.jl) an allen Stellen außerhalb von src/r/.

_mat64(M) = M isa Matrix{Float64} ? M : Float64[Float64(v) for v in M]
"colSums (mean = false) bzw. colMeans (mean = true) einer Matrix wie R (long double)."
_ld_colsums(M; mean::Bool = false, na_rm::Bool = false) =
    (A = _mat64(M); _rb_margsums(vec(A), size(A, 1), size(A, 2), na_rm, mean, false))
"rowSums bzw. rowMeans einer Matrix wie R (long double, spaltenweise akkumuliert)."
_ld_rowsums(M; mean::Bool = false, na_rm::Bool = false) =
    (A = _mat64(M); _rb_margsums(vec(A), size(A, 1), size(A, 2), na_rm, mean, true))

"Zahlteil von R_strtod ab Byte `i` von `s` → (Wert ≥ 0, gelesene Bytes oder -1 ohne Ziffer, Betrag > DBL_MAX)."
function _rb_strtod_num(s::String, i::Int)
    used = Ref{Int64}(0)
    gt = Ref{Cint}(0)
    v = GC.@preserve s ccall((:sl_r_strtod_num, LIBSLC), Float64, (Ptr{UInt8}, Int64, Ref{Int64}, Ref{Cint}),
                             pointer(s) + (i - 1), sizeof(s) - i + 1, used, gt)
    return v, Int(used[]), gt[] != 0
end
"Long-double-Teil von R's `x1 %% x2` (myfmod) für endliche Operanden."
_rb_fmod_ld(x1::Float64, x2::Float64) = ccall((:sl_r_fmod_ld, LIBSLC), Float64, (Float64, Float64), x1, x2)
"Long-double-Teil von R's `x1 %/% x2` (myfloor)."
_rb_idiv_ld(x1::Float64, x2::Float64) = ccall((:sl_r_idiv_ld, LIBSLC), Float64, (Float64, Float64), x1, x2)
"`scientific()` von formatReal für r > 0 (endlich), 1 ≤ digits ≤ 15 → (kpower, nsig, roundingwidens)."
function _rb_scientific(r::Float64, digits::Int)
    kp = Ref{Cint}(0)
    ns = Ref{Cint}(0)
    rw = ccall((:sl_r_scientific, LIBSLC), Cint, (Float64, Cint, Ref{Cint}, Ref{Cint}), r, digits, kp, ns)
    return Int(kp[]), Int(ns[]), rw != 0
end
