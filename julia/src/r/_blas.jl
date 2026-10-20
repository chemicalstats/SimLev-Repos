# ─────────────────────────────────────────────────────────────────────────────
# Referenz-BLAS (netlib 3.12, wie libblas.so.3 des Systems), bitgleich.
#
# Die Routinen arbeiten auf (Sichten von) Float64-Matrizen in place und halten
# die Schleifen- und Rechenreihenfolge der Fortran-Quellen exakt ein (1-basiert,
# wie Fortran). Wie die System-Bibliothek enthalten dsyrk, dtrsm, dtrmm, dtrmv,
# dtrsv, dger, dsyr2 und dsyr2k die Null-Abfragen von netlib; dgemm und dgemv
# haben sie seit LAPACK 3.10 nicht mehr. Vorlage: python/simlev/_r/_blas.py.
# Eingebunden in RLinalg.
# ─────────────────────────────────────────────────────────────────────────────

const _AM = AbstractMatrix{Float64}
const _AV = AbstractVector{Float64}

# ── Level 1 ───────────────────────────────────────────────────────────────

"DDOT (Schrittweite 1, sequenziell ab 0.0)."
function ddot(x::_AV, y::_AV)
    n = length(x)
    n <= 0 && return 0.0
    t = 0.0
    @inbounds for i in 1:n
        t = t + x[i] * y[i]
    end
    return t
end

"DAXPY: `y += da * x` in place (Rückkehr bei `da == 0`)."
function daxpy(da::Float64, x::_AV, y::_AV)
    (length(x) <= 0 || da == 0.0) && return nothing
    @inbounds for i in eachindex(x)
        y[i] = y[i] + da * x[i]
    end
    nothing
end

"DSCAL: `x = da * x` in place."
function dscal(da::Float64, x::_AV)
    @inbounds for i in eachindex(x)
        x[i] = da * x[i]
    end
    nothing
end

function dswap(x::_AV, y::_AV)
    @inbounds for i in eachindex(x)
        t = x[i]; x[i] = y[i]; y[i] = t
    end
    nothing
end

"DASUM (sequenziell)."
function dasum(x::_AV)
    t = 0.0
    @inbounds for v in x
        t = t + abs(v)
    end
    return t
end

"IDAMAX: erster Index (1-basiert) mit maximalem |x|; 0 für leere Vektoren."
function idamax(x::_AV)
    n = length(x)
    n < 1 && return 0
    n == 1 && return 1
    k = 1
    dmax = abs(x[1])
    @inbounds for i in 2:n
        a = abs(x[i])
        if a > dmax
            k = i
            dmax = a
        end
    end
    return k
end

const _TSML = 2.0^-511
const _TBIG = 2.0^486
const _SSML = 2.0^537
const _SBIG = 2.0^-538
const _MAXN = floatmax(Float64)

"DNRM2 aus LAPACK 3.10+ (Blue/Anderson, drei Akkumulatoren)."
function dnrm2(x::_AV)
    n = length(x)
    n <= 0 && return 0.0
    notbig = true
    asml = 0.0; amed = 0.0; abig = 0.0
    @inbounds for i in 1:n
        ax = abs(x[i])
        if ax > _TBIG
            t = ax * _SBIG
            abig = abig + t * t
            notbig = false
        elseif ax < _TSML
            if notbig
                t = ax * _SSML
                asml = asml + t * t
            end
        else
            amed = amed + ax * ax
        end
    end
    if abig > 0.0
        if amed > 0.0 || amed > _MAXN || amed != amed
            abig = abig + (amed * _SBIG) * _SBIG
        end
        scl = 1.0 / _SBIG
        sumsq = abig
    elseif asml > 0.0
        if amed > 0.0 || amed > _MAXN || amed != amed
            amed = sqrt(amed)
            asml = sqrt(asml) / _SSML
            if asml > amed
                ymin = amed; ymax = asml
            else
                ymin = asml; ymax = amed
            end
            scl = 1.0
            r = ymin / ymax
            sumsq = (ymax * ymax) * (1.0 + r * r)
        else
            scl = 1.0 / _SSML
            sumsq = asml
        end
    else
        scl = 1.0
        sumsq = amed
    end
    return scl * sqrt(sumsq)
end

# ── Level 2 ───────────────────────────────────────────────────────────────

_up(c::Char) = uppercase(c)

"DGEMV: `y := alpha*op(A)*x + beta*y` in place (ohne Null-Abfragen)."
function dgemv(trans::Char, alpha::Float64, A::_AM, x::_AV, beta::Float64, y::_AV)
    m, n = size(A)
    (m == 0 || n == 0 || (alpha == 0.0 && beta == 1.0)) && return nothing
    if beta != 1.0
        if beta == 0.0
            fill!(y, 0.0)
        else
            @inbounds for i in eachindex(y)
                y[i] = beta * y[i]
            end
        end
    end
    alpha == 0.0 && return nothing
    @inbounds if _up(trans) == 'N'
        for j in 1:n
            temp = alpha * x[j]
            for i in 1:m
                y[i] = y[i] + temp * A[i, j]
            end
        end
    else
        for j in 1:n
            temp = 0.0
            for i in 1:m
                temp = temp + A[i, j] * x[i]
            end
            y[j] = y[j] + alpha * temp
        end
    end
    nothing
end

"DGER: `A := alpha*x*y' + A` (mit Null-Abfrage auf y(j))."
function dger(alpha::Float64, x::_AV, y::_AV, A::_AM)
    m, n = size(A)
    (m == 0 || n == 0 || alpha == 0.0) && return nothing
    @inbounds for j in 1:n
        if y[j] != 0.0
            temp = alpha * y[j]
            for i in 1:m
                A[i, j] = A[i, j] + x[i] * temp
            end
        end
    end
    nothing
end

"DTRSV: löst `op(A) x = b` in place."
function dtrsv(uplo::Char, trans::Char, diag::Char, A::_AM, x::_AV)
    n = size(A, 1)
    n == 0 && return nothing
    nounit = _up(diag) == 'N'
    up = _up(uplo) == 'U'
    @inbounds if _up(trans) == 'N'
        if up
            for j in n:-1:1
                if x[j] != 0.0
                    nounit && (x[j] = x[j] / A[j, j])
                    temp = x[j]
                    for i in j-1:-1:1
                        x[i] = x[i] - temp * A[i, j]
                    end
                end
            end
        else
            for j in 1:n
                if x[j] != 0.0
                    nounit && (x[j] = x[j] / A[j, j])
                    temp = x[j]
                    for i in j+1:n
                        x[i] = x[i] - temp * A[i, j]
                    end
                end
            end
        end
    else
        if up
            for j in 1:n
                temp = x[j]
                for i in 1:j-1
                    temp = temp - A[i, j] * x[i]
                end
                nounit && (temp = temp / A[j, j])
                x[j] = temp
            end
        else
            for j in n:-1:1
                temp = x[j]
                for i in n:-1:j+1
                    temp = temp - A[i, j] * x[i]
                end
                nounit && (temp = temp / A[j, j])
                x[j] = temp
            end
        end
    end
    nothing
end

"DTRMV: `x := op(A) x` in place."
function dtrmv(uplo::Char, trans::Char, diag::Char, A::_AM, x::_AV)
    n = size(A, 1)
    n == 0 && return nothing
    nounit = _up(diag) == 'N'
    up = _up(uplo) == 'U'
    @inbounds if _up(trans) == 'N'
        if up
            for j in 1:n
                if x[j] != 0.0
                    temp = x[j]
                    for i in 1:j-1
                        x[i] = x[i] + temp * A[i, j]
                    end
                    nounit && (x[j] = x[j] * A[j, j])
                end
            end
        else
            for j in n:-1:1
                if x[j] != 0.0
                    temp = x[j]
                    for i in n:-1:j+1
                        x[i] = x[i] + temp * A[i, j]
                    end
                    nounit && (x[j] = x[j] * A[j, j])
                end
            end
        end
    else
        if up
            for j in n:-1:1
                temp = x[j]
                nounit && (temp = temp * A[j, j])
                for i in j-1:-1:1
                    temp = temp + A[i, j] * x[i]
                end
                x[j] = temp
            end
        else
            for j in 1:n
                temp = x[j]
                nounit && (temp = temp * A[j, j])
                for i in j+1:n
                    temp = temp + A[i, j] * x[i]
                end
                x[j] = temp
            end
        end
    end
    nothing
end

"DSYMV: `y := alpha*A*x + beta*y` mit symmetrischem A."
function dsymv(uplo::Char, alpha::Float64, A::_AM, x::_AV, beta::Float64, y::_AV)
    n = size(A, 1)
    (n == 0 || (alpha == 0.0 && beta == 1.0)) && return nothing
    if beta != 1.0
        if beta == 0.0
            fill!(y, 0.0)
        else
            @inbounds for i in eachindex(y)
                y[i] = beta * y[i]
            end
        end
    end
    alpha == 0.0 && return nothing
    @inbounds if _up(uplo) == 'U'
        for j in 1:n
            temp1 = alpha * x[j]
            temp2 = 0.0
            for i in 1:j-1
                y[i] = y[i] + temp1 * A[i, j]
                temp2 = temp2 + A[i, j] * x[i]
            end
            y[j] = (y[j] + temp1 * A[j, j]) + alpha * temp2
        end
    else
        for j in 1:n
            temp1 = alpha * x[j]
            temp2 = 0.0
            y[j] = y[j] + temp1 * A[j, j]
            for i in j+1:n
                y[i] = y[i] + temp1 * A[i, j]
                temp2 = temp2 + A[i, j] * x[i]
            end
            y[j] = y[j] + alpha * temp2
        end
    end
    nothing
end

"DSYR2: `A := alpha*x*y' + alpha*y*x' + A` (mit Null-Abfrage)."
function dsyr2(uplo::Char, alpha::Float64, x::_AV, y::_AV, A::_AM)
    n = size(A, 1)
    (n == 0 || alpha == 0.0) && return nothing
    up = _up(uplo) == 'U'
    @inbounds for j in 1:n
        if x[j] != 0.0 || y[j] != 0.0
            temp1 = alpha * y[j]
            temp2 = alpha * x[j]
            for i in (up ? (1:j) : (j:n))
                A[i, j] = (A[i, j] + x[i] * temp1) + y[i] * temp2
            end
        end
    end
    nothing
end

# ── Level 3 ───────────────────────────────────────────────────────────────

@inline function _beta_col!(C, j, rows, beta)
    @inbounds if beta == 0.0
        for i in rows
            C[i, j] = 0.0
        end
    elseif beta != 1.0
        for i in rows
            C[i, j] = beta * C[i, j]
        end
    end
end

"DGEMM: `C := alpha*op(A)*op(B) + beta*C` in place (ohne Null-Abfragen)."
function dgemm(transa::Char, transb::Char, alpha::Float64, A::_AM, B::_AM, beta::Float64, C::_AM)
    nota = _up(transa) == 'N'
    notb = _up(transb) == 'N'
    m, n = size(C)
    k = nota ? size(A, 2) : size(A, 1)
    (m == 0 || n == 0 || ((alpha == 0.0 || k == 0) && beta == 1.0)) && return nothing
    if alpha == 0.0
        for j in 1:n
            _beta_col!(C, j, 1:m, beta)
        end
        return nothing
    end
    @inbounds if nota
        for j in 1:n
            _beta_col!(C, j, 1:m, beta)
            for l in 1:k
                temp = alpha * (notb ? B[l, j] : B[j, l])
                for i in 1:m
                    C[i, j] = C[i, j] + temp * A[i, l]
                end
            end
        end
    else
        for j in 1:n
            for i in 1:m
                temp = 0.0
                for l in 1:k
                    temp = temp + A[l, i] * (notb ? B[l, j] : B[j, l])
                end
                C[i, j] = beta == 0.0 ? alpha * temp : alpha * temp + beta * C[i, j]
            end
        end
    end
    nothing
end

"DSYRK: `C := alpha*A*A' + beta*C` bzw. `alpha*A'*A + beta*C` (nur Dreieck `uplo`)."
function dsyrk(uplo::Char, trans::Char, alpha::Float64, A::_AM, beta::Float64, C::_AM)
    n = size(C, 1)
    up = _up(uplo) == 'U'
    notr = _up(trans) == 'N'
    k = notr ? size(A, 2) : size(A, 1)
    (n == 0 || ((alpha == 0.0 || k == 0) && beta == 1.0)) && return nothing
    rows(j) = up ? (1:j) : (j:n)
    if alpha == 0.0
        for j in 1:n
            _beta_col!(C, j, rows(j), beta)
        end
        return nothing
    end
    @inbounds if notr
        for j in 1:n
            _beta_col!(C, j, rows(j), beta)
            for l in 1:k
                if A[j, l] != 0.0
                    temp = alpha * A[j, l]
                    for i in rows(j)
                        C[i, j] = C[i, j] + temp * A[i, l]
                    end
                end
            end
        end
    else
        for j in 1:n
            for i in rows(j)
                temp = 0.0
                for l in 1:k
                    temp = temp + A[l, i] * A[l, j]
                end
                C[i, j] = beta == 0.0 ? alpha * temp : alpha * temp + beta * C[i, j]
            end
        end
    end
    nothing
end

"DSYR2K: `C := alpha*A*B' + alpha*B*A' + beta*C` (mit Null-Abfrage)."
function dsyr2k(uplo::Char, trans::Char, alpha::Float64, A::_AM, B::_AM, beta::Float64, C::_AM)
    n = size(C, 1)
    up = _up(uplo) == 'U'
    notr = _up(trans) == 'N'
    k = notr ? size(A, 2) : size(A, 1)
    (n == 0 || ((alpha == 0.0 || k == 0) && beta == 1.0)) && return nothing
    rows(j) = up ? (1:j) : (j:n)
    if alpha == 0.0
        for j in 1:n
            _beta_col!(C, j, rows(j), beta)
        end
        return nothing
    end
    @inbounds if notr
        for j in 1:n
            _beta_col!(C, j, rows(j), beta)
            for l in 1:k
                if A[j, l] != 0.0 || B[j, l] != 0.0
                    temp1 = alpha * B[j, l]
                    temp2 = alpha * A[j, l]
                    for i in rows(j)
                        C[i, j] = (C[i, j] + A[i, l] * temp1) + B[i, l] * temp2
                    end
                end
            end
        end
    else
        for j in 1:n
            for i in rows(j)
                temp1 = 0.0
                temp2 = 0.0
                for l in 1:k
                    temp1 = temp1 + A[l, i] * B[l, j]
                    temp2 = temp2 + B[l, i] * A[l, j]
                end
                if beta == 0.0
                    C[i, j] = alpha * temp1 + alpha * temp2
                else
                    C[i, j] = (beta * C[i, j] + alpha * temp1) + alpha * temp2
                end
            end
        end
    end
    nothing
end

"DTRSM: löst `op(A) X = alpha B` bzw. `X op(A) = alpha B`; B in place."
function dtrsm(side::Char, uplo::Char, transa::Char, diag::Char, alpha::Float64, A::_AM, B::_AM)
    m, n = size(B)
    (m == 0 || n == 0) && return nothing
    if alpha == 0.0
        fill!(B, 0.0)
        return nothing
    end
    lside = _up(side) == 'L'
    up = _up(uplo) == 'U'
    notr = _up(transa) == 'N'
    nounit = _up(diag) == 'N'
    @inbounds if lside
        if notr
            for j in 1:n
                if alpha != 1.0
                    for i in 1:m
                        B[i, j] = alpha * B[i, j]
                    end
                end
                for k in (up ? (m:-1:1) : (1:m))
                    if B[k, j] != 0.0
                        nounit && (B[k, j] = B[k, j] / A[k, k])
                        for i in (up ? (1:k-1) : (k+1:m))
                            B[i, j] = B[i, j] - B[k, j] * A[i, k]
                        end
                    end
                end
            end
        else
            for j in 1:n
                for i in (up ? (1:m) : (m:-1:1))
                    temp = alpha * B[i, j]
                    for k in (up ? (1:i-1) : (i+1:m))
                        temp = temp - A[k, i] * B[k, j]
                    end
                    nounit && (temp = temp / A[i, i])
                    B[i, j] = temp
                end
            end
        end
    else
        if notr
            for j in (up ? (1:n) : (n:-1:1))
                if alpha != 1.0
                    for i in 1:m
                        B[i, j] = alpha * B[i, j]
                    end
                end
                for k in (up ? (1:j-1) : (j+1:n))
                    if A[k, j] != 0.0
                        for i in 1:m
                            B[i, j] = B[i, j] - A[k, j] * B[i, k]
                        end
                    end
                end
                if nounit
                    temp = 1.0 / A[j, j]
                    for i in 1:m
                        B[i, j] = temp * B[i, j]
                    end
                end
            end
        else
            for k in (up ? (n:-1:1) : (1:n))
                if nounit
                    temp = 1.0 / A[k, k]
                    for i in 1:m
                        B[i, k] = temp * B[i, k]
                    end
                end
                for j in (up ? (1:k-1) : (k+1:n))
                    if A[j, k] != 0.0
                        temp = A[j, k]
                        for i in 1:m
                            B[i, j] = B[i, j] - temp * B[i, k]
                        end
                    end
                end
                if alpha != 1.0
                    for i in 1:m
                        B[i, k] = alpha * B[i, k]
                    end
                end
            end
        end
    end
    nothing
end

"DTRMM: `B := alpha*op(A)*B` bzw. `alpha*B*op(A)` in place."
function dtrmm(side::Char, uplo::Char, transa::Char, diag::Char, alpha::Float64, A::_AM, B::_AM)
    m, n = size(B)
    (m == 0 || n == 0) && return nothing
    if alpha == 0.0
        fill!(B, 0.0)
        return nothing
    end
    lside = _up(side) == 'L'
    up = _up(uplo) == 'U'
    notr = _up(transa) == 'N'
    nounit = _up(diag) == 'N'
    @inbounds if lside
        if notr
            if up
                for j in 1:n
                    for k in 1:m
                        if B[k, j] != 0.0
                            temp = alpha * B[k, j]
                            for i in 1:k-1
                                B[i, j] = B[i, j] + temp * A[i, k]
                            end
                            nounit && (temp = temp * A[k, k])
                            B[k, j] = temp
                        end
                    end
                end
            else
                for j in 1:n
                    for k in m:-1:1
                        if B[k, j] != 0.0
                            temp = alpha * B[k, j]
                            B[k, j] = temp
                            nounit && (B[k, j] = B[k, j] * A[k, k])
                            for i in k+1:m
                                B[i, j] = B[i, j] + temp * A[i, k]
                            end
                        end
                    end
                end
            end
        else
            if up
                for j in 1:n
                    for i in m:-1:1
                        temp = B[i, j]
                        nounit && (temp = temp * A[i, i])
                        for k in 1:i-1
                            temp = temp + A[k, i] * B[k, j]
                        end
                        B[i, j] = alpha * temp
                    end
                end
            else
                for j in 1:n
                    for i in 1:m
                        temp = B[i, j]
                        nounit && (temp = temp * A[i, i])
                        for k in i+1:m
                            temp = temp + A[k, i] * B[k, j]
                        end
                        B[i, j] = alpha * temp
                    end
                end
            end
        end
    else
        if notr
            for j in (up ? (n:-1:1) : (1:n))
                temp = alpha
                nounit && (temp = temp * A[j, j])
                for i in 1:m
                    B[i, j] = temp * B[i, j]
                end
                for k in (up ? (1:j-1) : (j+1:n))
                    if A[k, j] != 0.0
                        temp = alpha * A[k, j]
                        for i in 1:m
                            B[i, j] = B[i, j] + temp * B[i, k]
                        end
                    end
                end
            end
        else
            for k in (up ? (1:n) : (n:-1:1))
                for j in (up ? (1:k-1) : (k+1:n))
                    if A[j, k] != 0.0
                        temp = alpha * A[j, k]
                        for i in 1:m
                            B[i, j] = B[i, j] + temp * B[i, k]
                        end
                    end
                end
                temp = alpha
                nounit && (temp = temp * A[k, k])
                if temp != 1.0
                    for i in 1:m
                        B[i, k] = temp * B[i, k]
                    end
                end
            end
        end
    end
    nothing
end

"`Z[i,k] = sum_j X[i,j]*Y[j,k]` in double, sequenziell ab 0.0 (simple_matprod)."
function _simple_matprod(X::_AM, Y::_AM)
    nrx, ncx = size(X)
    ncy = size(Y, 2)
    Z = zeros(nrx, ncy)
    @inbounds for i in 1:nrx, k in 1:ncy
        s = 0.0
        for j in 1:ncx
            s = s + X[i, j] * Y[j, k]
        end
        Z[i, k] = s
    end
    Z
end

"`Z[i,k] = sum_j X[j,i]*Y[j,k]` (simple_crossprod)."
function _simple_crossprod(X::_AM, Y::_AM)
    nrx, ncx = size(X)
    ncy = size(Y, 2)
    Z = zeros(ncx, ncy)
    @inbounds for i in 1:ncx, k in 1:ncy
        s = 0.0
        for j in 1:nrx
            s = s + X[j, i] * Y[j, k]
        end
        Z[i, k] = s
    end
    Z
end

"`Z[i,k] = sum_j X[i,j]*Y[k,j]` (simple_tcrossprod)."
function _simple_tcrossprod(X::_AM, Y::_AM)
    nrx, ncx = size(X)
    nry = size(Y, 1)
    Z = zeros(nrx, nry)
    @inbounds for i in 1:nrx, k in 1:nry
        s = 0.0
        for j in 1:ncx
            s = s + X[i, j] * Y[k, j]
        end
        Z[i, k] = s
    end
    Z
end
