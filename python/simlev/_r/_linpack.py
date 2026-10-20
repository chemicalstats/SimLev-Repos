"""LINPACK-Routinen aus R's ``src/appl`` (``dqrdc2``, ``dqrsl``, ``dqrls`` und
die Hilfen aus ``dqrutl.f``), bitgleich in numpy.

Die BLAS-Aufrufe (``dnrm2``, ``ddot``, ``daxpy``, ``dscal``) laufen über
:mod:`simlev._r._blas` (Referenz-BLAS 3.12). Spalten der rechten Seite werden
gemeinsam verarbeitet (sie sind in Fortran unabhängig voneinander).
"""
from __future__ import annotations

import math

import numpy as np

from . import _blas as B

__all__ = ["dqrdc2", "dqrsl", "dqrls", "dqrcf", "dqrqty", "dqrqy", "dqrrsd", "dqrxb"]


def _cols_dot(v, X):
    """``ddot(v, X[:, j])`` für alle Spalten ``j`` (sequenziell ab 0)."""
    if X.shape[1] == 0:
        return np.zeros(0)
    if X.shape[0] == 0:
        return np.zeros(X.shape[1])
    return B.seqsum(v[:, None] * X)


def _cols_axpy(t, v, X):
    """``daxpy(t[j], v, X[:, j])`` für alle Spalten (Rückkehr bei ``t == 0``)."""
    nz = t != 0.0
    if not nz.any() or X.shape[0] == 0:
        return
    if nz.all():
        X += v[:, None] * t[None, :]
    else:
        X[:, nz] += v[:, None] * t[None, nz]


def dqrdc2(x, tol):
    """Householder-QR mit begrenzter Pivotisierung (R's ``dqrdc2``).

    ``x`` (n×p, float64) wird in place überschrieben. Liefert
    ``(k, qraux, jpvt)`` mit 1-basiertem ``jpvt``.
    """
    n, p = x.shape
    qraux = np.zeros(p)
    work1 = np.zeros(p)
    work2 = np.zeros(p)
    jpvt = np.arange(1, p + 1, dtype=np.int64)
    if n > 0:
        for j in range(p):
            qraux[j] = B.dnrm2(x[:, j])
            work1[j] = qraux[j]
            work2[j] = qraux[j]
            if work2[j] == 0.0:
                work2[j] = 1.0
    lup = min(n, p)
    k = p + 1
    for l in range(1, lup + 1):
        l0 = l - 1
        while not (l >= k or qraux[l0] >= work2[l0] * tol):
            # Spalte l ans Ende verschieben
            col = x[:, l0].copy()
            x[:, l0:p - 1] = x[:, l:p]
            x[:, p - 1] = col
            i = jpvt[l0]
            t = qraux[l0]
            tt = work1[l0]
            ttt = work2[l0]
            jpvt[l0:p - 1] = jpvt[l:p].copy()
            qraux[l0:p - 1] = qraux[l:p].copy()
            work1[l0:p - 1] = work1[l:p].copy()
            work2[l0:p - 1] = work2[l:p].copy()
            jpvt[p - 1] = i
            qraux[p - 1] = t
            work1[p - 1] = tt
            work2[p - 1] = ttt
            k -= 1
        if l == n:
            continue
        nrmxl = B.dnrm2(x[l0:, l0])
        if nrmxl == 0.0:
            continue
        if x[l0, l0] != 0.0:
            nrmxl = math.copysign(abs(nrmxl), x[l0, l0])
        B.dscal(1.0 / nrmxl, x[l0:, l0])
        x[l0, l0] = 1.0 + x[l0, l0]
        if p >= l + 1:
            v = x[l0:, l0]
            X = x[l0:, l:]
            t = -_cols_dot(v, X) / x[l0, l0]
            _cols_axpy(t, v, X)
            for j in range(l, p):
                if qraux[j] == 0.0:
                    continue
                r = abs(x[l0, j]) / qraux[j]
                tt = 1.0 - r * r
                tt = tt if tt >= 0.0 else 0.0
                t1 = tt
                if abs(t1) < 1e-6:
                    qraux[j] = B.dnrm2(x[l:, j])
                    work1[j] = qraux[j]
                else:
                    qraux[j] = qraux[j] * math.sqrt(t1)
        qraux[l0] = x[l0, l0]
        x[l0, l0] = -nrmxl
    k = min(k - 1, n)
    return k, qraux, jpvt


def dqrsl(x, k, qraux, y, job, qy=None, qty=None, b=None, rsd=None, xb=None):
    """LINPACK ``dqrsl`` für alle Spalten von ``y`` (n×ny).

    Ausgabefelder (n×ny bzw. k×ny) werden in place gefüllt, sofern übergeben
    und von ``job`` verlangt. Liefert INFO.
    """
    n = x.shape[0]
    info = 0
    cqy = job // 10000 != 0
    cqty = job % 10000 != 0
    cb = (job % 1000) // 100 != 0
    cr = (job % 100) // 10 != 0
    cxb = job % 10 != 0
    ju = min(k, n - 1)
    if ju == 0:
        if cqy:
            qy[0, :] = y[0, :]
        if cqty:
            qty[0, :] = y[0, :]
        if cxb:
            xb[0, :] = y[0, :]
        if cb:
            if x[0, 0] != 0.0:
                b[0, :] = y[0, :] / x[0, 0]
            else:
                info = 1
        if cr:
            rsd[0, :] = 0.0
        return info
    if cqy:
        qy[...] = y
    if cqty:
        qty[...] = y
    if cqy:
        for jj in range(1, ju + 1):
            j = ju - jj + 1
            j0 = j - 1
            if qraux[j0] == 0.0:
                continue
            temp = x[j0, j0]
            x[j0, j0] = qraux[j0]
            v = x[j0:, j0]
            t = -_cols_dot(v, qy[j0:, :]) / x[j0, j0]
            _cols_axpy(t, v, qy[j0:, :])
            x[j0, j0] = temp
    if cqty:
        for j in range(1, ju + 1):
            j0 = j - 1
            if qraux[j0] == 0.0:
                continue
            temp = x[j0, j0]
            x[j0, j0] = qraux[j0]
            v = x[j0:, j0]
            t = -_cols_dot(v, qty[j0:, :]) / x[j0, j0]
            _cols_axpy(t, v, qty[j0:, :])
            x[j0, j0] = temp
    if cb:
        b[:k, :] = qty[:k, :]
    kp1 = k + 1
    if cxb:
        xb[:k, :] = qty[:k, :]
    if cr and k < n:
        rsd[k:, :] = qty[k:, :]
    if cxb and kp1 <= n:
        xb[k:, :] = 0.0
    if cr:
        rsd[:k, :] = 0.0
    if cb:
        for jj in range(1, k + 1):
            j = k - jj + 1
            j0 = j - 1
            if x[j0, j0] == 0.0:
                info = j
                break
            b[j0, :] = b[j0, :] / x[j0, j0]
            if j != 1:
                t = -b[j0, :]
                _cols_axpy(t, x[:j0, j0], b[:j0, :])
    if cr or cxb:
        for jj in range(1, ju + 1):
            j = ju - jj + 1
            j0 = j - 1
            if qraux[j0] == 0.0:
                continue
            temp = x[j0, j0]
            x[j0, j0] = qraux[j0]
            v = x[j0:, j0]
            if cr:
                t = -_cols_dot(v, rsd[j0:, :]) / x[j0, j0]
                _cols_axpy(t, v, rsd[j0:, :])
            if cxb:
                t = -_cols_dot(v, xb[j0:, :]) / x[j0, j0]
                _cols_axpy(t, v, xb[j0:, :])
            x[j0, j0] = temp
    return info


def dqrls(x, y, tol):
    """R's ``dqrls`` (wie ``Cdqrls``): liefert dict mit qr, coefficients,
    residuals, effects, rank, pivot, qraux, pivoted.

    ``x`` (n×p) und ``y`` (n×ny) werden kopiert.
    """
    x = np.array(x, dtype=np.float64, order="F", copy=True)
    y = np.array(y, dtype=np.float64, copy=True)
    n, p = x.shape
    ny = y.shape[1]
    k, qraux, jpvt = dqrdc2(x, tol)
    b = np.zeros((p, ny))
    rsd = y.copy()
    qty = y.copy()
    if k > 0:
        bk = np.zeros((k, ny))
        dqrsl(x, k, qraux, y, 1110, qty=qty, b=bk, rsd=rsd)
        b[:k, :] = bk
    else:
        rsd[...] = y
    b[k:, :] = 0.0
    pivoted = bool(np.any(jpvt != np.arange(1, p + 1)))
    return {"qr": x, "coefficients": b, "residuals": rsd, "effects": qty, "rank": int(k),
            "pivot": jpvt, "qraux": qraux, "pivoted": pivoted}


def dqrcf(x, k, qraux, y):
    """Koeffizienten (``dqrcf``); ``y`` (n×ny) wird kopiert. Liefert (b, info)."""
    y = np.array(y, dtype=np.float64, copy=True)
    x = np.array(x, dtype=np.float64, copy=True)
    b = np.zeros((k, y.shape[1]))
    info = dqrsl(x, k, qraux, y.copy(), 100, qty=y, b=b)
    return b, info


def dqrqty(x, k, qraux, y):
    y = np.array(y, dtype=np.float64, copy=True)
    x = np.array(x, dtype=np.float64, copy=True)
    qty = y.copy()
    dqrsl(x, k, qraux, y, 1000, qty=qty)
    return qty


def dqrqy(x, k, qraux, y):
    y = np.array(y, dtype=np.float64, copy=True)
    x = np.array(x, dtype=np.float64, copy=True)
    qy = y.copy()
    dqrsl(x, k, qraux, y, 10000, qy=qy)
    return qy


def dqrrsd(x, k, qraux, y):
    y = np.array(y, dtype=np.float64, copy=True)
    x = np.array(x, dtype=np.float64, copy=True)
    rsd = y.copy()
    qty = y.copy()
    dqrsl(x, k, qraux, y, 10, qty=qty, rsd=rsd)
    return rsd


def dqrxb(x, k, qraux, y):
    y = np.array(y, dtype=np.float64, copy=True)
    x = np.array(x, dtype=np.float64, copy=True)
    xb = y.copy()
    qty = y.copy()
    dqrsl(x, k, qraux, y, 1, qty=qty, xb=xb)
    return xb
