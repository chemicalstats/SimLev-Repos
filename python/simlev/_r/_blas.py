"""Referenz-BLAS (netlib 3.12, wie ``libblas.so.3``), bitgleich in numpy.

Die Routinen arbeiten auf 2-D-``float64``-Arrays (Sichten, in place) und
halten die Schleifen- und Rechenreihenfolge der Fortran-Quellen exakt ein.
Vektorisiert wird nur über Indizes, deren Rechnungen voneinander unabhängig
sind; Akkumulationen (Skalarprodukte) laufen sequenziell wie in Fortran
(``numpy.add.accumulate`` ist streng sequenziell).

Wie die System-Bibliothek (nicht R's eigene, gepatchte ``blas.f``) enthalten
``dsyrk``, ``dtrsm``, ``dtrmm``, ``dtrmv``, ``dtrsv``, ``dger``, ``dsyr2``,
``dsyr2k`` die Null-Abfragen von netlib (``IF (B(K,J).NE.ZERO)``);
``dgemm`` und ``dgemv`` haben sie seit LAPACK 3.10 nicht mehr.

Indizes sind 0-basiert; ``idamax`` liefert 0-basiert.
"""
from __future__ import annotations

import numpy as np

__all__ = ["dgemm", "dgemv", "dsyrk", "dtrsm", "dtrsv", "dtrmv", "dtrmm", "dger",
           "dsymv", "dsyr2", "dsyr2k", "ddot", "daxpy", "dscal", "dnrm2", "idamax",
           "dswap", "dasum", "seqdot", "seqsum"]

_CHUNK = 1 << 21          # Elemente je Block bei 3-D-Akkumulation


def seqsum(P, s0=None):
    """Sequenzielle Summe entlang Achse 0: ``((s0 + P[0]) + P[1]) + ...``.

    Ohne ``s0`` beginnt die Summe bei ``+0.0`` (wie ``TEMP = ZERO``).
    """
    P = np.asarray(P)
    k = P.shape[0]
    if k == 0:
        out = np.zeros(P.shape[1:], dtype=P.dtype)
        if s0 is not None:
            out = out + s0
        return out
    first = (P[0] + (P.dtype.type(0) if s0 is None else s0))
    if k == 1:
        return np.array(first, dtype=P.dtype)
    Q = np.empty_like(P)
    Q[0] = first
    Q[1:] = P[1:]
    return np.add.accumulate(Q, axis=0)[-1]


def seqdot(A, B):
    """``T[i, j] = sum_l A[l, i] * B[l, j]`` sequenziell über ``l`` ab ``0.0``.

    ``A``: (k, m), ``B``: (k, n). Ergebnis (m, n).
    """
    k, m = A.shape
    n = B.shape[1]
    T = np.zeros((m, n))
    if k == 0 or m == 0 or n == 0:
        return T
    step = max(1, _CHUNK // max(1, m * n))
    if step == 1 and k > 64:
        for l in range(k):
            T += A[l][:, None] * B[l][None, :]
        return T
    for s in range(0, k, step):
        e = min(k, s + step)
        P = A[s:e, :, None] * B[s:e, None, :]
        P[0] += T
        T = np.add.accumulate(P, axis=0)[-1]
    return T


def _seqdot_vec(A, x):
    """``t[j] = sum_i A[i, j] * x[i]`` sequenziell (ab 0.0)."""
    m, n = A.shape
    if m == 0:
        return np.zeros(n)
    P = A * x[:, None]
    P[0] += 0.0
    return np.add.accumulate(P, axis=0)[-1] if m > 1 else P[0].copy()


# ── Level 1 ───────────────────────────────────────────────────────────────

def ddot(x, y):
    """DDOT (inc 1, auch entrollt links-assoziativ = sequenziell)."""
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    n = x.shape[0]
    if n <= 0:
        return 0.0
    return float(seqsum(x * y))


def daxpy(da, x, y):
    """``y += da * x`` in place (Rückkehr bei ``da == 0``)."""
    if x.shape[0] <= 0 or da == 0.0:
        return
    y += da * x


def dscal(da, x):
    """``x = da * x`` in place."""
    if x.shape[0] <= 0:
        return
    x *= da


def dswap(x, y):
    t = x.copy()
    x[...] = y
    y[...] = t


def dasum(x):
    x = np.asarray(x, dtype=np.float64)
    if x.shape[0] <= 0:
        return 0.0
    return float(seqsum(np.abs(x)))


def idamax(x):
    """Erster Index (0-basiert) mit maximalem ``|x|``; -1 für leere Vektoren."""
    n = x.shape[0]
    if n < 1:
        return -1
    if n == 1:
        return 0
    a = np.abs(x)
    if a[0] != a[0]:
        return 0
    a = np.where(a != a, -1.0, a)
    return int(np.argmax(a))


_TSML = 2.0 ** -511
_TBIG = 2.0 ** 486
_SSML = 2.0 ** 537
_SBIG = 2.0 ** -538
_MAXN = np.finfo(np.float64).max


def dnrm2(x):
    """DNRM2 aus LAPACK 3.10+ (Blue/Anderson, drei Akkumulatoren)."""
    x = np.asarray(x, dtype=np.float64)
    n = x.shape[0]
    if n <= 0:
        return 0.0
    ax = np.abs(x)
    big = ax > _TBIG
    sml = ax < _TSML
    med = ~(big | sml)
    if big.any():
        abig = float(seqsum((ax[big] * _SBIG) * (ax[big] * _SBIG)))
        first_big = int(np.argmax(big))
        sm = sml.copy()
        sm[first_big:] = False
        asml = float(seqsum((ax[sm] * _SSML) * (ax[sm] * _SSML))) if sm.any() else 0.0
    else:
        abig = 0.0
        asml = float(seqsum((ax[sml] * _SSML) * (ax[sml] * _SSML))) if sml.any() else 0.0
    amed = float(seqsum(ax[med] * ax[med])) if med.any() else 0.0
    if abig > 0.0:
        if amed > 0.0 or amed > _MAXN or amed != amed:
            abig = abig + (amed * _SBIG) * _SBIG
        scl = 1.0 / _SBIG
        sumsq = abig
    elif asml > 0.0:
        if amed > 0.0 or amed > _MAXN or amed != amed:
            amed = np.sqrt(amed)
            asml = np.sqrt(asml) / _SSML
            if asml > amed:
                ymin, ymax = amed, asml
            else:
                ymin, ymax = asml, amed
            scl = 1.0
            r = ymin / ymax
            sumsq = (ymax * ymax) * (1.0 + r * r)
        else:
            scl = 1.0 / _SSML
            sumsq = asml
    else:
        scl = 1.0
        sumsq = amed
    return float(scl * np.sqrt(sumsq))


# ── Level 2 ───────────────────────────────────────────────────────────────

def dgemv(trans, alpha, A, x, beta, y):
    """``y := alpha*op(A)*x + beta*y`` in place (DGEMV, ohne Null-Abfragen)."""
    m, n = A.shape
    if m == 0 or n == 0 or (alpha == 0.0 and beta == 1.0):
        return
    if beta != 1.0:
        if beta == 0.0:
            y[...] = 0.0
        else:
            y *= beta
    if alpha == 0.0:
        return
    if trans.upper() == "N":
        for j in range(n):
            temp = alpha * x[j]
            y += temp * A[:, j]
    else:
        t = _seqdot_vec(A, x)
        y += alpha * t


def dger(alpha, x, y, A):
    """``A := alpha*x*y' + A`` (mit Null-Abfrage auf ``y(j)``)."""
    m, n = A.shape
    if m == 0 or n == 0 or alpha == 0.0:
        return
    for j in range(n):
        if y[j] != 0.0:
            temp = alpha * y[j]
            A[:, j] += x * temp


def dtrsv(uplo, trans, diag, A, x):
    """Löst ``op(A) x = b`` in place (DTRSV)."""
    n = A.shape[0]
    if n == 0:
        return
    nounit = diag.upper() == "N"
    up = uplo.upper() == "U"
    if trans.upper() == "N":
        if up:
            for j in range(n - 1, -1, -1):
                if x[j] != 0.0:
                    if nounit:
                        x[j] = x[j] / A[j, j]
                    temp = x[j]
                    if j > 0:
                        x[:j] -= temp * A[:j, j]
        else:
            for j in range(n):
                if x[j] != 0.0:
                    if nounit:
                        x[j] = x[j] / A[j, j]
                    temp = x[j]
                    if j + 1 < n:
                        x[j + 1:] -= temp * A[j + 1:, j]
    else:
        if up:
            for j in range(n):
                temp = x[j]
                for i in range(j):
                    temp = temp - A[i, j] * x[i]
                if nounit:
                    temp = temp / A[j, j]
                x[j] = temp
        else:
            for j in range(n - 1, -1, -1):
                temp = x[j]
                for i in range(n - 1, j, -1):
                    temp = temp - A[i, j] * x[i]
                if nounit:
                    temp = temp / A[j, j]
                x[j] = temp


def dtrmv(uplo, trans, diag, A, x):
    """``x := op(A) x`` in place (DTRMV)."""
    n = A.shape[0]
    if n == 0:
        return
    nounit = diag.upper() == "N"
    up = uplo.upper() == "U"
    if trans.upper() == "N":
        if up:
            for j in range(n):
                if x[j] != 0.0:
                    temp = x[j]
                    if j > 0:
                        x[:j] += temp * A[:j, j]
                    if nounit:
                        x[j] = x[j] * A[j, j]
        else:
            for j in range(n - 1, -1, -1):
                if x[j] != 0.0:
                    temp = x[j]
                    if j + 1 < n:
                        x[j + 1:] += temp * A[j + 1:, j]
                    if nounit:
                        x[j] = x[j] * A[j, j]
    else:
        if up:
            for j in range(n - 1, -1, -1):
                temp = x[j]
                if nounit:
                    temp = temp * A[j, j]
                for i in range(j - 1, -1, -1):
                    temp = temp + A[i, j] * x[i]
                x[j] = temp
        else:
            for j in range(n):
                temp = x[j]
                if nounit:
                    temp = temp * A[j, j]
                for i in range(j + 1, n):
                    temp = temp + A[i, j] * x[i]
                x[j] = temp


def dsymv(uplo, alpha, A, x, beta, y):
    """``y := alpha*A*x + beta*y`` mit symmetrischem ``A`` (DSYMV)."""
    n = A.shape[0]
    if n == 0 or (alpha == 0.0 and beta == 1.0):
        return
    if beta != 1.0:
        if beta == 0.0:
            y[...] = 0.0
        else:
            y *= beta
    if alpha == 0.0:
        return
    if uplo.upper() == "U":
        for j in range(n):
            temp1 = alpha * x[j]
            if j > 0:
                col = A[:j, j]
                y[:j] += temp1 * col
                temp2 = float(seqsum(col * x[:j]))
            else:
                temp2 = 0.0
            y[j] = (y[j] + temp1 * A[j, j]) + alpha * temp2
    else:
        for j in range(n):
            temp1 = alpha * x[j]
            y[j] = y[j] + temp1 * A[j, j]
            if j + 1 < n:
                col = A[j + 1:, j]
                y[j + 1:] += temp1 * col
                temp2 = float(seqsum(col * x[j + 1:]))
            else:
                temp2 = 0.0
            y[j] = y[j] + alpha * temp2


def dsyr2(uplo, alpha, x, y, A):
    """``A := alpha*x*y' + alpha*y*x' + A`` (DSYR2, mit Null-Abfrage)."""
    n = A.shape[0]
    if n == 0 or alpha == 0.0:
        return
    up = uplo.upper() == "U"
    for j in range(n):
        if x[j] != 0.0 or y[j] != 0.0:
            temp1 = alpha * y[j]
            temp2 = alpha * x[j]
            if up:
                A[:j + 1, j] = (A[:j + 1, j] + x[:j + 1] * temp1) + y[:j + 1] * temp2
            else:
                A[j:, j] = (A[j:, j] + x[j:] * temp1) + y[j:] * temp2


# ── Level 3 ───────────────────────────────────────────────────────────────

def _beta_scale(C, beta):
    if beta == 0.0:
        C[...] = 0.0
    elif beta != 1.0:
        C *= beta


def dgemm(transa, transb, alpha, A, B, beta, C):
    """``C := alpha*op(A)*op(B) + beta*C`` in place (DGEMM, ohne Null-Abfragen).

    ``A``, ``B`` sind die (ungespiegelten) Arrays; ``op`` nach ``trans*``.
    """
    nota = transa.upper() == "N"
    notb = transb.upper() == "N"
    m, n = C.shape
    k = A.shape[1] if nota else A.shape[0]
    if m == 0 or n == 0 or ((alpha == 0.0 or k == 0) and beta == 1.0):
        return
    if alpha == 0.0:
        _beta_scale(C, beta)
        return
    if nota:
        # Spalte j: Beta-Skalierung, dann C(:,j) += (alpha*B(l,j)) * A(:,l), l = 1..k
        _beta_scale(C, beta)
        Bk = B if notb else B.T          # Bk[l, j]
        for l in range(k):
            temp = alpha * Bk[l, :]
            C += A[:, l][:, None] * temp[None, :]
    else:
        Bk = B if notb else B.T          # Bk[l, j]
        T = seqdot(A, Bk)                # T[i, j] = sum_l A(l,i) * B(l,j)
        if beta == 0.0:
            C[...] = alpha * T
        else:
            C[...] = alpha * T + beta * C


def dsyrk(uplo, trans, alpha, A, beta, C):
    """``C := alpha*A*A' + beta*C`` bzw. ``alpha*A'*A + beta*C`` (DSYRK).

    Nur das durch ``uplo`` gewählte Dreieck von ``C`` wird geschrieben.
    """
    n = C.shape[0]
    up = uplo.upper() == "U"
    notr = trans.upper() == "N"
    k = A.shape[1] if notr else A.shape[0]
    if n == 0 or ((alpha == 0.0 or k == 0) and beta == 1.0):
        return
    mask = np.triu(np.ones((n, n), dtype=bool)) if up else np.tril(np.ones((n, n), dtype=bool))
    if alpha == 0.0:
        if beta == 0.0:
            C[mask] = 0.0
        else:
            C[mask] = beta * C[mask]
        return
    if notr:
        T = C.copy()
        if beta == 0.0:
            T[mask] = 0.0
        elif beta != 1.0:
            T[mask] = beta * T[mask]
        for l in range(k):
            a = A[:, l]
            nz = a != 0.0               # IF (A(J,L).NE.ZERO) – Spaltenindex j
            if not nz.any():
                continue
            temp = alpha * a
            upd = a[:, None] * temp[None, :]
            if nz.all():
                T += upd
            else:
                T[:, nz] += upd[:, nz]
        C[mask] = T[mask]
    else:
        T = seqdot(A, A)
        if beta == 0.0:
            C[mask] = (alpha * T)[mask]
        else:
            C[mask] = (alpha * T + beta * C)[mask]


def dsyr2k(uplo, trans, alpha, A, B, beta, C):
    """``C := alpha*A*B' + alpha*B*A' + beta*C`` (DSYR2K, mit Null-Abfrage)."""
    n = C.shape[0]
    up = uplo.upper() == "U"
    notr = trans.upper() == "N"
    k = A.shape[1] if notr else A.shape[0]
    if n == 0 or ((alpha == 0.0 or k == 0) and beta == 1.0):
        return
    mask = np.triu(np.ones((n, n), dtype=bool)) if up else np.tril(np.ones((n, n), dtype=bool))
    if alpha == 0.0:
        if beta == 0.0:
            C[mask] = 0.0
        else:
            C[mask] = beta * C[mask]
        return
    if notr:
        T = C.copy()
        if beta == 0.0:
            T[mask] = 0.0
        elif beta != 1.0:
            T[mask] = beta * T[mask]
        for l in range(k):
            a = A[:, l]
            b = B[:, l]
            nz = (a != 0.0) | (b != 0.0)
            if not nz.any():
                continue
            temp1 = alpha * b
            temp2 = alpha * a
            upd1 = a[:, None] * temp1[None, :]
            upd2 = b[:, None] * temp2[None, :]
            if nz.all():
                T = (T + upd1) + upd2
            else:
                T[:, nz] = (T[:, nz] + upd1[:, nz]) + upd2[:, nz]
        C[mask] = T[mask]
    else:
        T1 = seqdot(A, B)
        T2 = seqdot(B, A)
        if beta == 0.0:
            R = alpha * T1 + alpha * T2
        else:
            R = (beta * C + alpha * T1) + alpha * T2
        C[mask] = R[mask]


def dtrsm(side, uplo, transa, diag, alpha, A, B):
    """Löst ``op(A) X = alpha B`` bzw. ``X op(A) = alpha B``; ``B`` in place."""
    m, n = B.shape
    if m == 0 or n == 0:
        return
    if alpha == 0.0:
        B[...] = 0.0
        return
    lside = side.upper() == "L"
    up = uplo.upper() == "U"
    notr = transa.upper() == "N"
    nounit = diag.upper() == "N"
    if lside:
        if notr:
            if alpha != 1.0:
                B *= alpha
            ks = range(m - 1, -1, -1) if up else range(m)
            for k in ks:
                bk = B[k, :]
                nz = bk != 0.0
                if not nz.any():
                    continue
                allnz = nz.all()
                if nounit:
                    if allnz:
                        B[k, :] = bk / A[k, k]
                    else:
                        B[k, nz] = bk[nz] / A[k, k]
                sl = slice(0, k) if up else slice(k + 1, m)
                if (k > 0) if up else (k + 1 < m):
                    col = A[sl, k][:, None]
                    if allnz:
                        B[sl, :] -= B[k, :][None, :] * col
                    else:
                        B[sl, nz] -= B[k, nz][None, :] * col
        else:
            if up:
                for i in range(m):
                    temp = alpha * B[i, :]
                    for k in range(i):
                        temp = temp - A[k, i] * B[k, :]
                    if nounit:
                        temp = temp / A[i, i]
                    B[i, :] = temp
            else:
                for i in range(m - 1, -1, -1):
                    temp = alpha * B[i, :]
                    for k in range(i + 1, m):
                        temp = temp - A[k, i] * B[k, :]
                    if nounit:
                        temp = temp / A[i, i]
                    B[i, :] = temp
    else:
        if notr:
            js = range(n) if up else range(n - 1, -1, -1)
            for j in js:
                if alpha != 1.0:
                    B[:, j] = alpha * B[:, j]
                ks = range(j) if up else range(j + 1, n)
                for k in ks:
                    if A[k, j] != 0.0:
                        B[:, j] -= A[k, j] * B[:, k]
                if nounit:
                    temp = 1.0 / A[j, j]
                    B[:, j] = temp * B[:, j]
        else:
            ks = range(n - 1, -1, -1) if up else range(n)
            for k in ks:
                if nounit:
                    temp = 1.0 / A[k, k]
                    B[:, k] = temp * B[:, k]
                js = range(k) if up else range(k + 1, n)
                for j in js:
                    if A[j, k] != 0.0:
                        temp = A[j, k]
                        B[:, j] -= temp * B[:, k]
                if alpha != 1.0:
                    B[:, k] = alpha * B[:, k]


def dtrmm(side, uplo, transa, diag, alpha, A, B):
    """``B := alpha*op(A)*B`` bzw. ``alpha*B*op(A)`` in place (DTRMM)."""
    m, n = B.shape
    if m == 0 or n == 0:
        return
    if alpha == 0.0:
        B[...] = 0.0
        return
    lside = side.upper() == "L"
    up = uplo.upper() == "U"
    notr = transa.upper() == "N"
    nounit = diag.upper() == "N"
    if lside:
        if notr:
            if up:
                for k in range(m):
                    bk = B[k, :]
                    nz = bk != 0.0
                    if not nz.any():
                        continue
                    temp = alpha * bk
                    if k > 0:
                        upd = temp[None, :] * A[:k, k][:, None]
                        B[:k, nz] += upd[:, nz]
                    if nounit:
                        temp = temp * A[k, k]
                    B[k, nz] = temp[nz]
            else:
                for k in range(m - 1, -1, -1):
                    bk = B[k, :]
                    nz = bk != 0.0
                    if not nz.any():
                        continue
                    temp = alpha * bk
                    newk = temp.copy()
                    if nounit:
                        newk = newk * A[k, k]
                    B[k, nz] = newk[nz]
                    if k + 1 < m:
                        upd = temp[None, :] * A[k + 1:, k][:, None]
                        B[k + 1:, nz] += upd[:, nz]
        else:
            if up:
                for i in range(m - 1, -1, -1):
                    temp = B[i, :].copy()
                    if nounit:
                        temp = temp * A[i, i]
                    for k in range(i):
                        temp = temp + A[k, i] * B[k, :]
                    B[i, :] = alpha * temp
            else:
                for i in range(m):
                    temp = B[i, :].copy()
                    if nounit:
                        temp = temp * A[i, i]
                    for k in range(i + 1, m):
                        temp = temp + A[k, i] * B[k, :]
                    B[i, :] = alpha * temp
    else:
        if notr:
            js = range(n - 1, -1, -1) if up else range(n)
            for j in js:
                temp = alpha
                if nounit:
                    temp = temp * A[j, j]
                B[:, j] = temp * B[:, j]
                ks = range(j) if up else range(j + 1, n)
                for k in ks:
                    if A[k, j] != 0.0:
                        temp = alpha * A[k, j]
                        B[:, j] += temp * B[:, k]
        else:
            ks = range(n) if up else range(n - 1, -1, -1)
            for k in ks:
                js = range(k) if up else range(k + 1, n)
                for j in js:
                    if A[j, k] != 0.0:
                        temp = alpha * A[j, k]
                        B[:, j] += temp * B[:, k]
                temp = alpha
                if nounit:
                    temp = temp * A[k, k]
                if temp != 1.0:
                    B[:, k] = temp * B[:, k]
