# ─────────────────────────────────────────────────────────────────────────────
# LINPACK-Routinen aus R's src/appl (dqrdc2, dqrsl, dqrls und die Hilfen aus
# dqrutl.f), bitgleich. BLAS-Aufrufe über _blas.jl (Referenz-BLAS 3.12).
# Vorlage: python/simlev/_r/_linpack.py. Eingebunden in RLinalg.
# ─────────────────────────────────────────────────────────────────────────────

"Householder-QR mit begrenzter Pivotisierung (R's dqrdc2); x in place; (k, qraux, jpvt)."
function dqrdc2!(x::_AM, tol::Float64)
    n, p = size(x)
    qraux = zeros(p); work1 = zeros(p); work2 = zeros(p)
    jpvt = collect(1:p)
    if n > 0
        for j in 1:p
            qraux[j] = dnrm2(view(x, :, j))
            work1[j] = qraux[j]
            work2[j] = qraux[j]
            work2[j] == 0.0 && (work2[j] = 1.0)
        end
    end
    lup = min(n, p)
    k = p + 1
    for l in 1:lup
        while !(l >= k || qraux[l] >= work2[l] * tol)
            # Spalte l ans Ende verschieben
            for i in 1:n
                t = x[i, l]
                for jj in l+1:p
                    x[i, jj-1] = x[i, jj]
                end
                x[i, p] = t
            end
            i = jpvt[l]; t = qraux[l]; tt = work1[l]; ttt = work2[l]
            for jj in l+1:p
                jpvt[jj-1] = jpvt[jj]; qraux[jj-1] = qraux[jj]
                work1[jj-1] = work1[jj]; work2[jj-1] = work2[jj]
            end
            jpvt[p] = i; qraux[p] = t; work1[p] = tt; work2[p] = ttt
            k -= 1
        end
        l == n && continue
        nrmxl = dnrm2(view(x, l:n, l))
        nrmxl == 0.0 && continue
        x[l, l] != 0.0 && (nrmxl = copysign(abs(nrmxl), x[l, l]))
        dscal(1.0 / nrmxl, view(x, l:n, l))
        x[l, l] = 1.0 + x[l, l]
        if p >= l + 1
            v = view(x, l:n, l)
            for j in l+1:p
                t = -ddot(v, view(x, l:n, j)) / x[l, l]
                daxpy(t, v, view(x, l:n, j))
                if qraux[j] != 0.0
                    r = abs(x[l, j]) / qraux[j]
                    tt = 1.0 - r * r
                    tt = tt >= 0.0 ? tt : 0.0
                    t1 = tt
                    if abs(t1) < 1e-6
                        qraux[j] = dnrm2(view(x, l+1:n, j))
                        work1[j] = qraux[j]
                    else
                        qraux[j] = qraux[j] * sqrt(t1)
                    end
                end
            end
        end
        qraux[l] = x[l, l]
        x[l, l] = -nrmxl
    end
    k = min(k - 1, n)
    return k, qraux, jpvt
end

"""LINPACK dqrsl für alle Spalten von y (n×ny); Ausgabefelder (Matrizen oder
`nothing`) werden in place gefüllt. Liefert INFO."""
function dqrsl!(x::_AM, k::Int, qraux::_AV, y::_AM, job::Int; qy = nothing, qty = nothing,
                b = nothing, rsd = nothing, xb = nothing)
    n = size(x, 1)
    ny = size(y, 2)
    info = 0
    cqy = job ÷ 10000 != 0
    cqty = job % 10000 != 0
    cb = (job % 1000) ÷ 100 != 0
    cr = (job % 100) ÷ 10 != 0
    cxb = job % 10 != 0
    ju = min(k, n - 1)
    if ju == 0
        for c in 1:ny
            cqy && (qy[1, c] = y[1, c])
            cqty && (qty[1, c] = y[1, c])
            cxb && (xb[1, c] = y[1, c])
        end
        if cb
            if x[1, 1] != 0.0
                for c in 1:ny
                    b[1, c] = y[1, c] / x[1, 1]
                end
            else
                info = 1
            end
        end
        if cr
            for c in 1:ny
                rsd[1, c] = 0.0
            end
        end
        return info
    end
    cqy && copyto!(qy, y)
    cqty && copyto!(qty, y)
    function apply!(M, j)
        temp = x[j, j]
        x[j, j] = qraux[j]
        v = view(x, j:n, j)
        for c in 1:ny
            col = view(M, j:n, c)
            t = -ddot(v, col) / x[j, j]
            daxpy(t, v, col)
        end
        x[j, j] = temp
    end
    if cqy
        for jj in 1:ju
            j = ju - jj + 1
            qraux[j] == 0.0 && continue
            apply!(qy, j)
        end
    end
    if cqty
        for j in 1:ju
            qraux[j] == 0.0 && continue
            apply!(qty, j)
        end
    end
    for c in 1:ny
        if cb
            for i in 1:k
                b[i, c] = qty[i, c]
            end
        end
        if cxb
            for i in 1:k
                xb[i, c] = qty[i, c]
            end
        end
        if cr && k < n
            for i in k+1:n
                rsd[i, c] = qty[i, c]
            end
        end
        if cxb && k + 1 <= n
            for i in k+1:n
                xb[i, c] = 0.0
            end
        end
        if cr
            for i in 1:k
                rsd[i, c] = 0.0
            end
        end
    end
    if cb
        # Spalten unabhängig; INFO wie Fortran (erste Spalte mit Nullpivot bricht ab)
        for c in 1:ny
            for jj in 1:k
                j = k - jj + 1
                if x[j, j] == 0.0
                    info = j
                    break
                end
                b[j, c] = b[j, c] / x[j, j]
                if j != 1
                    t = -b[j, c]
                    daxpy(t, view(x, 1:j-1, j), view(b, 1:j-1, c))
                end
            end
        end
    end
    if cr || cxb
        for jj in 1:ju
            j = ju - jj + 1
            qraux[j] == 0.0 && continue
            temp = x[j, j]
            x[j, j] = qraux[j]
            v = view(x, j:n, j)
            for c in 1:ny
                if cr
                    col = view(rsd, j:n, c)
                    t = -ddot(v, col) / x[j, j]
                    daxpy(t, v, col)
                end
                if cxb
                    col = view(xb, j:n, c)
                    t = -ddot(v, col) / x[j, j]
                    daxpy(t, v, col)
                end
            end
            x[j, j] = temp
        end
    end
    return info
end

"R's dqrls (wie Cdqrls): RList-ähnliches NamedTuple mit qr, coefficients, residuals, effects, rank, pivot, qraux, pivoted."
function dqrls(x0::AbstractMatrix, y0::AbstractMatrix, tol::Float64)
    x = Matrix{Float64}(x0)
    y = Matrix{Float64}(y0)
    n, p = size(x)
    ny = size(y, 2)
    k, qraux, jpvt = dqrdc2!(x, tol)
    b = zeros(p, ny)
    rsd = copy(y)
    qty = copy(y)
    if k > 0
        bk = zeros(k, ny)
        dqrsl!(x, k, qraux, y, 1110; qty = qty, b = bk, rsd = rsd)
        b[1:k, :] .= bk
    else
        copyto!(rsd, y)
    end
    pivoted = any(i -> jpvt[i] != i, 1:p)
    return (qr = x, coefficients = b, residuals = rsd, effects = qty, rank = k, pivot = jpvt,
            qraux = qraux, pivoted = pivoted)
end

"Koeffizienten (dqrcf); y (n×ny) wird kopiert. Liefert (b, info)."
function dqrcf(x0::AbstractMatrix, k::Int, qraux::_AV, y0::AbstractMatrix)
    y = Matrix{Float64}(y0)
    x = Matrix{Float64}(x0)
    b = zeros(k, size(y, 2))
    qty = copy(y)
    info = dqrsl!(x, k, copy(qraux), copy(y), 100; qty = qty, b = b)
    return b, info
end

function dqrqty(x0::AbstractMatrix, k::Int, qraux::_AV, y0::AbstractMatrix)
    y = Matrix{Float64}(y0); x = Matrix{Float64}(x0)
    qty = copy(y)
    dqrsl!(x, k, copy(qraux), y, 1000; qty = qty)
    return qty
end

function dqrqy(x0::AbstractMatrix, k::Int, qraux::_AV, y0::AbstractMatrix)
    y = Matrix{Float64}(y0); x = Matrix{Float64}(x0)
    qy = copy(y)
    dqrsl!(x, k, copy(qraux), y, 10000; qy = qy)
    return qy
end

function dqrrsd(x0::AbstractMatrix, k::Int, qraux::_AV, y0::AbstractMatrix)
    y = Matrix{Float64}(y0); x = Matrix{Float64}(x0)
    rsd = copy(y); qty = copy(y)
    dqrsl!(x, k, copy(qraux), y, 10; qty = qty, rsd = rsd)
    return rsd
end

function dqrxb(x0::AbstractMatrix, k::Int, qraux::_AV, y0::AbstractMatrix)
    y = Matrix{Float64}(y0); x = Matrix{Float64}(x0)
    xb = copy(y); qty = copy(y)
    dqrsl!(x, k, copy(qraux), y, 1; qty = qty, xb = xb)
    return xb
end
