# SLib, Etappe 9.2 – Hüllen der C-Bibliothek slc über ccall: lineare Algebra, Matrixprodukt,
# kleinste Quadrate und Logit-IRLS, Stineman-Interpolation, Glättungsspline, Kerndichte.
#
# Wird innerhalb von `module SLib` (slib.jl) eingebunden und nutzt dessen Kontext (_ctx/_finish)
# und LIBSLC. Gegenstück zu r/R/slc_linalg.R (R) und python/simlev/_lib_linalg.py (Python). Die
# Rechnung steht in deps/core/slc_{linalg,matmul,lsq,stine,spline,kde}.c (Kopien von core/).
# Fehlertexte und Warnungen kommen aus dem Kern. Matrizen sind AbstractMatrix (spaltenweise wie
# in C), Vektoren AbstractVector bzw. Zahlen. Benannte Ergebnisse als Dict{String,Any}.
#
# Seit Etappe 9.6b rufen die Ports diese Hüllen an denselben Stellen wie R.

_la_ismat(x) = x isa AbstractMatrix
_la_vec(x) = x isa Number ? Float64[x] : Vector{Float64}(vec(collect(x)))
_la_mat(x) = x isa AbstractMatrix ? Matrix{Float64}(x) : reshape(_la_vec(x), :, 1)

# ── lineare Algebra ────────────────────────────────────────────────────────

"chol(x): obere Dreiecksmatrix R mit R'R = x (gelesen wird das obere Dreieck)."
function chol(x)
    a = _la_mat(x); n = size(a, 1)
    size(a, 2) == n || error("chol: Matrix nicht quadratisch")
    out = Matrix{Float64}(undef, n, n)
    cx = _ctx()
    s = ccall((:sl_chol, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Ptr{Float64}), cx, n, a, out)
    _finish(cx, s)
    out
end

"Band-Cholesky (Prüfung): ab = (kd + 1) x n, unteres Band spaltenweise."
function chol_band(ab, kd)
    out = _la_mat(ab)
    size(out, 1) == Int(kd) + 1 || error("interner Fehler: ab muss kd + 1 Zeilen haben")
    cx = _ctx()
    s = ccall((:sl_chol_band, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}), cx, size(out, 2), Int(kd), out)
    _finish(cx, s)
    out
end

"backsolve(r, x, upper.tri, transpose) mit k = ncol(r); Vektor bleibt Vektor."
function backsolve(r, x; upper_tri = true, transpose = false)
    ra = _la_mat(r); n = size(ra, 1)
    vecx = !_la_ismat(x)
    b = _la_mat(x)
    (size(ra, 2) == n && size(b, 1) == n) || error("backsolve: Dimensionen passen nicht")
    cx = _ctx()
    s = ccall((:sl_trisolve, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}, Cint, Cint, Ptr{Float64}),
              cx, n, size(b, 2), ra, Cint(Bool(upper_tri)), Cint(Bool(transpose)), b)
    _finish(cx, s)
    vecx ? vec(b) : b
end

forwardsolve(l, x; upper_tri = false, transpose = false) = backsolve(l, x; upper_tri = upper_tri, transpose = transpose)

"solve(a, b) für symmetrisch positiv definites a (oberes Dreieck gelesen); ohne b die Inverse."
function solve_spd(a, b = nothing)
    aa = _la_mat(a); n = size(aa, 1)
    size(aa, 2) == n || error("solve: Matrix nicht quadratisch")
    vecb = b !== nothing && !_la_ismat(b)
    bb = b === nothing ? Matrix{Float64}([i == j ? 1.0 : 0.0 for i in 1:n, j in 1:n]) : _la_mat(b)
    size(bb, 1) == n || error("solve: Dimensionen von a und b passen nicht")
    cx = _ctx()
    s = ccall((:sl_solve_spd, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}),
              cx, n, size(bb, 2), aa, bb, C_NULL)
    _finish(cx, s)
    vecb ? vec(bb) : bb
end

"log det a für symmetrisch positiv definites a (ersetzt determinant(a)\$modulus)."
function logdet_spd(a)
    aa = _la_mat(a); n = size(aa, 1)
    size(aa, 2) == n || error("determinant: Matrix nicht quadratisch")
    ld = Ref{Float64}(0.0)
    cx = _ctx()
    s = ccall((:sl_logdet_spd, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Ref{Float64}), cx, n, aa, ld)
    _finish(cx, s)
    ld[]
end

"eigen(x, symmetric = TRUE): absteigend, gelesen wird das untere Dreieck."
function eigen_sym(x; only_values = false)
    a = _la_mat(x); n = size(a, 1)
    size(a, 2) == n || error("eigen: Matrix nicht quadratisch")
    val = Vector{Float64}(undef, n)
    vecs = only_values ? nothing : Matrix{Float64}(undef, n, n)
    cx = _ctx()
    s = ccall((:sl_eigen_sym, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Ptr{Float64}, Ptr{Float64}),
              cx, n, a, Cint(!only_values), val, vecs === nothing ? Ptr{Float64}(C_NULL) : vecs)
    _finish(cx, s)
    Dict{String,Any}("values" => val, "vectors" => vecs)
end

# ── Matrixprodukt ──────────────────────────────────────────────────────────

_mm_err() = error("%m%: nicht passende Argumente")

"x %*% y mit den Vektorregeln von %*% (AbstractVector bzw. Zahl = Vektor)."
function matmul(x, y)
    xm, ym = _la_ismat(x), _la_ismat(y)
    if !xm && !ym
        xv, yv = _la_vec(x), _la_vec(y)
        nx, ny = length(xv), length(yv)
        X, Y = nx == ny ? (reshape(xv, 1, nx), reshape(yv, ny, 1)) :
               nx == 1 ? (reshape(xv, 1, 1), reshape(yv, 1, ny)) :
               ny == 1 ? (reshape(xv, nx, 1), reshape(yv, 1, 1)) : _mm_err()
    elseif !xm
        Y = _la_mat(y); xv = _la_vec(x)
        X = length(xv) == size(Y, 1) ? reshape(xv, 1, :) : size(Y, 1) == 1 ? reshape(xv, :, 1) : _mm_err()
    elseif !ym
        X = _la_mat(x); yv = _la_vec(y)
        Y = length(yv) == size(X, 2) ? reshape(yv, :, 1) : size(X, 2) == 1 ? reshape(yv, 1, :) : _mm_err()
    else
        X, Y = _la_mat(x), _la_mat(y)
    end
    m, k = size(X); k2, n = size(Y)
    k == k2 || _mm_err()
    C = Matrix{Float64}(undef, m, n)
    ccall((:sl_matmul, LIBSLC), Cvoid, (Cint, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}), m, k, n, X, Y, C)
    C
end

"crossprod(x, y) = t(x) %*% y; Vektoren als Spaltenmatrix."
function crossprod(x, y = nothing)
    X = _la_mat(x); Y = y === nothing ? X : _la_mat(y)
    size(X, 1) == size(Y, 1) || error("crossprod: nicht passende Argumente")
    m, k = size(X); n = size(Y, 2)
    C = Matrix{Float64}(undef, k, n)
    ccall((:sl_crossprod, LIBSLC), Cvoid, (Cint, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}), m, k, n, X, Y, C)
    C
end

"tcrossprod(x, y) = x %*% t(y)."
function tcrossprod(x, y = nothing)
    X = _la_mat(x); Y = y === nothing ? X : _la_mat(y)
    size(X, 2) == size(Y, 2) || error("tcrossprod: nicht passende Argumente")
    m, k = size(X); n = size(Y, 1)
    C = Matrix{Float64}(undef, m, n)
    ccall((:sl_tcrossprod, LIBSLC), Cvoid, (Cint, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}), m, k, n, X, Y, C)
    C
end

# ── kleinste Quadrate, Logit-IRLS ──────────────────────────────────────────

"""lm.fit/lm.wfit/qr.coef: Householder-QR mit begrenzter Spaltenpivotisierung; ausgefallene
Koeffizienten NA; pivot 1-basiert."""
function lsfit(x, y; w = nothing, tol = 1e-7, pivot = 1)
    X = _la_mat(x); m, n = size(X)
    yv = _la_vec(y)
    length(yv) == m || error("lm: Längen von x und y passen nicht")
    wv = w === nothing ? nothing : _la_vec(w)
    wv === nothing || length(wv) == m || error("lm: Längen von x und w passen nicht")
    coef = Vector{Float64}(undef, n); fit = Vector{Float64}(undef, m); perm = Vector{Int32}(undef, n)
    rank = Ref{Cint}(0)
    cx = _ctx()
    s = ccall((:sl_lsfit, LIBSLC), Cint,
              (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Float64, Cint, Ptr{Float64},
               Ptr{Float64}, Ref{Cint}, Ptr{Int32}),
              cx, m, n, X, yv, wv === nothing ? Ptr{Float64}(C_NULL) : wv, Float64(tol), Int(pivot),
              coef, fit, rank, perm)
    _finish(cx, s)
    Dict{String,Any}("coefficients" => coef, "fitted.values" => fit, "rank" => Int(rank[]), "pivot" => perm,
                     "residuals" => yv .- fit)
end

"glm(y ~ x, family = binomial()): Koeffizienten per IRLS (x mit Achsenabschnittsspalte)."
function logit_irls(x, y; maxit = 25, tol = 1e-8)
    X = _la_mat(x); m, n = size(X)
    yv = _la_vec(y)
    length(yv) == m || error("glm: Längen von x und y passen nicht")
    coef = Vector{Float64}(undef, n); conv = Ref{Cint}(0)
    cx = _ctx()
    s = ccall((:sl_logit_irls, LIBSLC), Cint,
              (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Cint, Float64, Ptr{Float64}, Ref{Cint}),
              cx, m, n, X, yv, Int(maxit), Float64(tol), coef, conv)
    _finish(cx, s)
    Dict{String,Any}("coefficients" => coef, "converged" => conv[] != 0)
end

# ── Stineman ───────────────────────────────────────────────────────────────

"stinterp(x, y, xout) (skaliert); NA außerhalb [x_1, x_n]."
function stineman(x, y, xout)
    xv, yv, xo = _la_vec(x), _la_vec(y), _la_vec(xout)
    length(xv) == length(yv) || error("stinterp: x und y ungleich lang")
    out = Vector{Float64}(undef, length(xo))
    cx = _ctx()
    s = ccall((:sl_stineman, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Ptr{Float64}, Cint, Ptr{Float64}, Ptr{Float64}),
              cx, length(xv), xv, yv, length(xo), xo, out)
    _finish(cx, s)
    out
end

function stineman_slopes(x, y; scale = true)
    xv, yv = _la_vec(x), _la_vec(y)
    length(xv) == length(yv) || error("stinterp: x und y ungleich lang")
    out = Vector{Float64}(undef, length(xv))
    cx = _ctx()
    s = ccall((:sl_stineman_slopes, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Ptr{Float64}, Cint, Ptr{Float64}),
              cx, length(xv), xv, yv, Cint(Bool(scale)), out)
    _finish(cx, s)
    out
end

function stineman_eval(x, y, yp, xout)
    xv, yv, pv, xo = _la_vec(x), _la_vec(y), _la_vec(yp), _la_vec(xout)
    (length(xv) == length(yv) && length(xv) == length(pv)) || error("stinterp: x, y und yp ungleich lang")
    out = Vector{Float64}(undef, length(xo))
    cx = _ctx()
    s = ccall((:sl_stineman_eval, LIBSLC), Cint,
              (Ptr{Cvoid}, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Cint, Ptr{Float64}, Ptr{Float64}),
              cx, length(xv), xv, yv, pv, length(xo), xo, out)
    _finish(cx, s)
    out
end

# ── Glättungsspline ────────────────────────────────────────────────────────

"smooth.spline(x, y, w, cv = FALSE): Knoten an allen verschiedenen x, lambda per GCV (nothing)."
function smspline_fit(x, y; w = nothing, lambda = nothing)
    xv, yv = _la_vec(x), _la_vec(y)
    n = length(xv)
    length(yv) == n || error("smooth.spline: x und y ungleich lang")
    wv = w === nothing ? nothing : _la_vec(w)
    wv === nothing || length(wv) == n || error("smooth.spline: x und w ungleich lang")
    kn = Vector{Float64}(undef, n); g = Vector{Float64}(undef, n); gam = Vector{Float64}(undef, n)
    nk = Ref{Cint}(0); lo = Ref{Float64}(0.0); df = Ref{Float64}(0.0); gcv = Ref{Float64}(0.0)
    cx = _ctx()
    s = ccall((:sl_smspline_fit, LIBSLC), Cint,
              (Ptr{Cvoid}, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Float64, Ref{Cint}, Ptr{Float64},
               Ptr{Float64}, Ptr{Float64}, Ref{Float64}, Ref{Float64}, Ref{Float64}),
              cx, n, xv, yv, wv === nothing ? Ptr{Float64}(C_NULL) : wv,
              lambda === nothing ? 0.0 : Float64(lambda), nk, kn, g, gam, lo, df, gcv)
    _finish(cx, s)
    k = Int(nk[])
    Dict{String,Any}("x" => kn[1:k], "y" => g[1:k], "gam" => gam[1:k], "lambda" => lo[], "df" => df[], "gcv" => gcv[])
end

"predict(fit, x)\$y; außerhalb der Knoten lineare Fortsetzung."
function smspline_predict(fit, x)
    kn, g, gam = _la_vec(fit["x"]), _la_vec(fit["y"]), _la_vec(fit["gam"])
    xo = _la_vec(x)
    out = Vector{Float64}(undef, length(xo))
    cx = _ctx()
    s = ccall((:sl_smspline_predict, LIBSLC), Cint,
              (Ptr{Cvoid}, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Cint, Ptr{Float64}, Ptr{Float64}),
              cx, length(kn), kn, g, gam, length(xo), xo, out)
    _finish(cx, s)
    out
end

# ── Kerndichte ─────────────────────────────────────────────────────────────

"Bandbreite nach Silvermans Faustregel (wie bw.nrd0)."
function bw_silverman(x)
    xv = _la_vec(x)
    bw = Ref{Float64}(0.0)
    cx = _ctx()
    s = ccall((:sl_kde_bw, LIBSLC), Cint, (Ptr{Cvoid}, Int64, Ptr{Float64}, Ref{Float64}), cx, length(xv), xv, bw)
    _finish(cx, s)
    bw[]
end

"density(x): Gauß-Kern, n Gitterpunkte von min(x) - cut bw bis max(x) + cut bw."
function kde(x; bw = nothing, n = 512, from = nothing, to = nothing, cut = 3, weights = nothing)
    xv = _la_vec(x)
    h = bw === nothing ? bw_silverman(xv) : Float64(bw)
    ok = !isempty(xv) && all(isfinite, xv)       # sonst meldet der Kern den Fehler
    f = from === nothing ? (ok ? minimum(xv) - cut * h : 0.0) : Float64(from)
    t = to === nothing ? (ok ? maximum(xv) + cut * h : 1.0) : Float64(to)
    ng = Int(n)
    ng >= 2 || error("density: mindestens 2 Gitterpunkte")
    wv = weights === nothing ? nothing : _la_vec(weights)
    gx = Vector{Float64}(undef, ng); gy = Vector{Float64}(undef, ng)
    cx = _ctx()
    s = ccall((:sl_kde, LIBSLC), Cint,
              (Ptr{Cvoid}, Int64, Ptr{Float64}, Ptr{Float64}, Float64, Cint, Float64, Float64, Ptr{Float64}, Ptr{Float64}),
              cx, length(xv), xv, wv === nothing ? Ptr{Float64}(C_NULL) : wv, h, ng, f, t, gx, gy)
    _finish(cx, s)
    Dict{String,Any}("x" => gx, "y" => gy, "bw" => h, "n" => length(xv))
end
