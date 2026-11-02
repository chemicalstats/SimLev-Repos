# ─────────────────────────────────────────────────────────────────────────────
# N8: Hüllen der Grundfunktionen mit R-Regeln aus der C-Bibliothek slc (core/slc_rbase*.c)
#
# Python (simlev._ext, python/src/_ext_slc_rbase.c) und Julia rechnen damit dieselbe Implementierung:
# Summen, Mittel, Varianz und Kumulationen in long double wie R, R's Potenz, stabile Ordnung und Rang,
# partielle Sortierung und Quantile wie R, tabulate, findInterval und cov/cor. Die Hüllen hier nehmen
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
