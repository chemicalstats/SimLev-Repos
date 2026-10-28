"""LAPACK-Routinen, wie R sie über die Referenz-LAPACK 3.12 nutzt.

Zwei Wege:

* **reine Ports** (numpy, bitgleich zur Referenz-LAPACK, unabhängig von einer
  System-Bibliothek): ``dpotrf``/``dpotrf2``, ``dgetrf``/``dgetrf2``,
  ``dlaswp``, ``dgetrs``, ``dgesv``, ``dlange``, ``dgecon`` (mit ``dlacn2``,
  ``dlatrs``, ``drscl``), ``dpotri`` (``dtrtri``/``dtrti2``,
  ``dlauum``/``dlauu2``) und für Eigenwerte ohne Vektoren der
  ``dsyevr``-Pfad ``dlansy`` → ``dsytrd`` (``dlatrd``, ``dsytd2``,
  ``dlarfg``) → ``dsterf``. Blockgrößen wie ``ILAENV`` der Referenz.
* **System-LAPACK über ctypes** (``dsyevr`` mit Eigenvektoren; dessen
  ``dstemr``/``dormtr`` sind zu groß für einen Port). Gesucht wird
  ``$SIMLEV_LAPACK``, dann die Referenz-LAPACK des Systems
  (``/usr/lib/x86_64-linux-gnu/lapack/liblapack.so.3``), dann
  ``ctypes.util.find_library("lapack")``. Fehlt sie, wird mit Warnung auf
  ``numpy.linalg.eigh`` ausgewichen (wie die Julia-Fassung auf
  LinearAlgebra) – dann ist Bitgleichheit mit R **nicht** garantiert.

Bitgleichheit der ctypes-Ergebnisse gilt genau dann, wenn dieselbe
Referenz-LAPACK/BLAS geladen wird, die auch R nutzt.
"""
from __future__ import annotations

import ctypes
import warnings
import ctypes.util
import math
import os

import numpy as np

from . import _blas as B

__all__ = ["dlamch", "dpotrf", "dpotrf2", "dgetrf", "dgetrf2", "dlaswp", "dgetrs", "dgesv",
           "dlange", "dgecon", "dlatrs", "dpotri", "dtrtri", "dlauum", "dlansy", "dsytrd",
           "dsterf", "dsyevr_values", "dsyevr", "system_lapack"]

_SFMIN = 2.2250738585072014e-308      # DLAMCH('S')
_EPS = 2.0 ** -53                      # DLAMCH('E')
_PREC = 2.0 ** -52                     # DLAMCH('P')
_HUGE = 1.7976931348623157e308         # DLAMCH('O')


def dlamch(c):
    c = c.upper()[0]
    return {"S": _SFMIN, "E": _EPS, "P": _PREC, "O": _HUGE, "B": 2.0, "U": _SFMIN,
            "N": 53.0, "R": 1.0, "M": -1021.0, "L": 1024.0}[c]


def _isnan(x):
    return x != x


# ── Cholesky ──────────────────────────────────────────────────────────────

def dpotrf2(uplo, A):
    """Rekursive Cholesky-Zerlegung (DPOTRF2); ``A`` in place; liefert INFO."""
    n = A.shape[0]
    if n == 0:
        return 0
    if n == 1:
        a = A[0, 0]
        if a <= 0.0 or _isnan(a):
            return 1
        A[0, 0] = math.sqrt(a)
        return 0
    n1 = n // 2
    iinfo = dpotrf2(uplo, A[:n1, :n1])
    if iinfo != 0:
        return iinfo
    if uplo.upper() == "U":
        B.dtrsm("L", "U", "T", "N", 1.0, A[:n1, :n1], A[:n1, n1:])
        B.dsyrk("U", "T", -1.0, A[:n1, n1:], 1.0, A[n1:, n1:])
    else:
        B.dtrsm("R", "L", "T", "N", 1.0, A[:n1, :n1], A[n1:, :n1])
        B.dsyrk("L", "N", -1.0, A[n1:, :n1], 1.0, A[n1:, n1:])
    iinfo = dpotrf2(uplo, A[n1:, n1:])
    if iinfo != 0:
        return iinfo + n1
    return 0


def dpotrf(uplo, A, nb=64):
    """Cholesky-Zerlegung (DPOTRF, Blockgröße 64 wie ILAENV); liefert INFO."""
    n = A.shape[0]
    if n == 0:
        return 0
    if nb <= 1 or nb >= n:
        return dpotrf2(uplo, A)
    up = uplo.upper() == "U"
    for j in range(1, n + 1, nb):
        jb = min(nb, n - j + 1)
        j0 = j - 1
        if up:
            B.dsyrk("U", "T", -1.0, A[:j0, j0:j0 + jb], 1.0, A[j0:j0 + jb, j0:j0 + jb])
            info = dpotrf2("U", A[j0:j0 + jb, j0:j0 + jb])
            if info != 0:
                return info + j - 1
            if j + jb <= n:
                B.dgemm("T", "N", -1.0, A[:j0, j0:j0 + jb], A[:j0, j0 + jb:], 1.0,
                        A[j0:j0 + jb, j0 + jb:])
                B.dtrsm("L", "U", "T", "N", 1.0, A[j0:j0 + jb, j0:j0 + jb], A[j0:j0 + jb, j0 + jb:])
        else:
            B.dsyrk("L", "N", -1.0, A[j0:j0 + jb, :j0], 1.0, A[j0:j0 + jb, j0:j0 + jb])
            info = dpotrf2("L", A[j0:j0 + jb, j0:j0 + jb])
            if info != 0:
                return info + j - 1
            if j + jb <= n:
                B.dgemm("N", "T", -1.0, A[j0 + jb:, :j0], A[j0:j0 + jb, :j0], 1.0,
                        A[j0 + jb:, j0:j0 + jb])
                B.dtrsm("R", "L", "T", "N", 1.0, A[j0:j0 + jb, j0:j0 + jb], A[j0 + jb:, j0:j0 + jb])
    return 0


# ── LU ────────────────────────────────────────────────────────────────────

def dlaswp(A, k1, k2, ipiv, incx=1):
    """Zeilenvertauschungen (DLASWP); ``k1``, ``k2``, ``ipiv`` 1-basiert."""
    if A.shape[1] == 0:
        return
    rng = range(k1, k2 + 1) if incx > 0 else range(k2, k1 - 1, -1)
    for i in rng:
        ip = int(ipiv[i - 1])
        if ip != i:
            t = A[i - 1, :].copy()
            A[i - 1, :] = A[ip - 1, :]
            A[ip - 1, :] = t


def dgetrf2(A, ipiv):
    """Rekursive LU-Zerlegung mit Zeilenpivotisierung (DGETRF2); INFO."""
    m, n = A.shape
    if m == 0 or n == 0:
        return 0
    info = 0
    if m == 1:
        ipiv[0] = 1
        if A[0, 0] == 0.0:
            info = 1
    elif n == 1:
        i = B.idamax(A[:, 0])
        ipiv[0] = i + 1
        if A[i, 0] != 0.0:
            if i != 0:
                t = A[0, 0]
                A[0, 0] = A[i, 0]
                A[i, 0] = t
            if abs(A[0, 0]) >= _SFMIN:
                B.dscal(1.0 / A[0, 0], A[1:, 0])
            else:
                A[1:, 0] = A[1:, 0] / A[0, 0]
        else:
            info = 1
    else:
        mn = min(m, n)
        n1 = mn // 2
        iinfo = dgetrf2(A[:, :n1], ipiv[:n1])
        if info == 0 and iinfo > 0:
            info = iinfo
        dlaswp(A[:, n1:], 1, n1, ipiv)
        B.dtrsm("L", "L", "N", "U", 1.0, A[:n1, :n1], A[:n1, n1:])
        B.dgemm("N", "N", -1.0, A[n1:, :n1], A[:n1, n1:], 1.0, A[n1:, n1:])
        iinfo = dgetrf2(A[n1:, n1:], ipiv[n1:])
        if info == 0 and iinfo > 0:
            info = iinfo + n1
        for i in range(n1, mn):
            ipiv[i] += n1
        dlaswp(A[:, :n1], n1 + 1, mn, ipiv)
    return info


def dgetrf(A, ipiv, nb=64):
    """LU-Zerlegung (DGETRF, Blockgröße 64); ``ipiv`` 1-basiert; INFO."""
    m, n = A.shape
    if m == 0 or n == 0:
        return 0
    mn = min(m, n)
    if nb <= 1 or nb >= mn:
        return dgetrf2(A, ipiv)
    info = 0
    for j in range(1, mn + 1, nb):
        jb = min(mn - j + 1, nb)
        j0 = j - 1
        iinfo = dgetrf2(A[j0:, j0:j0 + jb], ipiv[j0:j0 + jb])
        if info == 0 and iinfo > 0:
            info = iinfo + j - 1
        for i in range(j, min(m, j + jb - 1) + 1):
            ipiv[i - 1] += j - 1
        dlaswp(A[:, :j0], j, j + jb - 1, ipiv)
        if j + jb <= n:
            dlaswp(A[:, j0 + jb:], j, j + jb - 1, ipiv)
            B.dtrsm("L", "L", "N", "U", 1.0, A[j0:j0 + jb, j0:j0 + jb], A[j0:j0 + jb, j0 + jb:])
            if j + jb <= m:
                B.dgemm("N", "N", -1.0, A[j0 + jb:, j0:j0 + jb], A[j0:j0 + jb, j0 + jb:], 1.0,
                        A[j0 + jb:, j0 + jb:])
    return info


def dgetrs(trans, A, ipiv, Bm):
    """Löst mit der LU-Zerlegung (DGETRS); ``Bm`` in place."""
    n = A.shape[0]
    if n == 0 or Bm.shape[1] == 0:
        return
    if trans.upper() == "N":
        dlaswp(Bm, 1, n, ipiv, 1)
        B.dtrsm("L", "L", "N", "U", 1.0, A, Bm)
        B.dtrsm("L", "U", "N", "N", 1.0, A, Bm)
    else:
        B.dtrsm("L", "U", "T", "N", 1.0, A, Bm)
        B.dtrsm("L", "L", "T", "U", 1.0, A, Bm)
        dlaswp(Bm, 1, n, ipiv, -1)


def dgesv(A, Bm, ipiv):
    """DGESV: ``A`` (LU), ``Bm`` (Lösung) in place; INFO."""
    info = dgetrf(A, ipiv)
    if info == 0:
        dgetrs("N", A, ipiv, Bm)
    return info


# ── Normen und Konditionsschätzung ─────────────────────────────────────────

def dlange(norm, A):
    m, n = A.shape
    if min(m, n) == 0:
        return 0.0
    c = norm.upper()
    value = 0.0
    if c == "M":
        for j in range(n):
            for t in np.abs(A[:, j]).tolist():
                if value < t or t != t:
                    value = t
    elif c in ("O", "1"):
        for j in range(n):
            s = float(B.seqsum(np.abs(A[:, j])))
            if value < s or s != s:
                value = s
    elif c == "I":
        work = np.zeros(m)
        for j in range(n):
            work = work + np.abs(A[:, j])
        for t in work.tolist():
            if value < t or t != t:
                value = t
    else:
        raise NotImplementedError(norm)
    return value


def drscl(sa, x):
    """``x := x / sa`` ohne Über-/Unterlauf (DRSCL)."""
    if x.shape[0] <= 0:
        return
    smlnum = _SFMIN
    bignum = 1.0 / smlnum
    cden = sa
    cnum = 1.0
    while True:
        cden1 = cden * smlnum
        cnum1 = cnum / bignum
        if abs(cden1) > abs(cnum) and cnum != 0.0:
            mul = smlnum
            done = False
            cden = cden1
        elif abs(cnum1) > abs(cden):
            mul = bignum
            done = False
            cnum = cnum1
        else:
            mul = cnum / cden
            done = True
        B.dscal(mul, x)
        if done:
            return


def _fmax(a, b):
    # gfortran MAX(a, b) für endliche Werte
    return a if a >= b else b


def _fmin(a, b):
    return a if a <= b else b


def dlatrs(uplo, trans, diag, normin, A, x, cnorm):
    """Dreieckslöser mit Skalierung gegen Überlauf (DLATRS).

    ``x`` und ``cnorm`` in place; liefert ``scale``.
    """
    n = A.shape[0]
    upper = uplo.upper() == "U"
    notran = trans.upper() == "N"
    nounit = diag.upper() == "N"
    scale = 1.0
    if n == 0:
        return scale
    smlnum = _SFMIN / _PREC
    bignum = 1.0 / smlnum
    if normin.upper() == "N":
        if upper:
            for j in range(n):
                cnorm[j] = B.dasum(A[:j, j])
        else:
            for j in range(n - 1):
                cnorm[j] = B.dasum(A[j + 1:, j])
            cnorm[n - 1] = 0.0
    imax = B.idamax(cnorm)
    tmax = cnorm[imax]
    if tmax <= bignum:
        tscal = 1.0
    else:
        if tmax <= _HUGE:
            tscal = 1.0 / (smlnum * tmax)
            B.dscal(tscal, cnorm)
        else:
            tmax = 0.0
            if upper:
                for j in range(1, n):
                    tmax = _fmax(dlange("M", A[:j, j:j + 1]), tmax)
            else:
                for j in range(n - 1):
                    tmax = _fmax(dlange("M", A[j + 1:, j:j + 1]), tmax)
            if tmax <= _HUGE:
                tscal = 1.0 / (smlnum * tmax)
                for j in range(n):
                    if cnorm[j] <= _HUGE:
                        cnorm[j] = cnorm[j] * tscal
                    else:
                        cnorm[j] = 0.0
                        rr = range(j) if upper else range(j + 1, n)
                        for i in rr:
                            cnorm[j] = cnorm[j] + tscal * abs(A[i, j])
            else:
                B.dtrsv(uplo, trans, diag, A, x)
                return scale
    j = B.idamax(x)
    xmax = abs(x[j])
    xbnd = xmax
    if notran:
        if upper:
            jfirst, jlast, jinc = n - 1, 0, -1
        else:
            jfirst, jlast, jinc = 0, n - 1, 1
        jr = range(jfirst, jlast + jinc, jinc)
        if tscal != 1.0:
            grow = 0.0
        elif nounit:
            grow = 1.0 / _fmax(xbnd, smlnum)
            xbnd = grow
            stopped = False
            for j in jr:
                if grow <= smlnum:
                    stopped = True
                    break
                tjj = abs(A[j, j])
                xbnd = _fmin(xbnd, _fmin(1.0, tjj) * grow)
                if tjj + cnorm[j] >= smlnum:
                    grow = grow * (tjj / (tjj + cnorm[j]))
                else:
                    grow = 0.0
            if not stopped:
                grow = xbnd
        else:
            grow = _fmin(1.0, 1.0 / _fmax(xbnd, smlnum))
            for j in jr:
                if grow <= smlnum:
                    break
                grow = grow * (1.0 / (1.0 + cnorm[j]))
    else:
        if upper:
            jfirst, jlast, jinc = 0, n - 1, 1
        else:
            jfirst, jlast, jinc = n - 1, 0, -1
        jr = range(jfirst, jlast + jinc, jinc)
        if tscal != 1.0:
            grow = 0.0
        elif nounit:
            grow = 1.0 / _fmax(xbnd, smlnum)
            xbnd = grow
            stopped = False
            for j in jr:
                if grow <= smlnum:
                    stopped = True
                    break
                xj = 1.0 + cnorm[j]
                grow = _fmin(grow, xbnd / xj)
                tjj = abs(A[j, j])
                if xj > tjj:
                    xbnd = xbnd * (tjj / xj)
            if not stopped:
                grow = _fmin(grow, xbnd)
        else:
            grow = _fmin(1.0, 1.0 / _fmax(xbnd, smlnum))
            for j in jr:
                if grow <= smlnum:
                    break
                xj = 1.0 + cnorm[j]
                grow = grow / xj
    if grow * tscal > smlnum:
        B.dtrsv(uplo, trans, diag, A, x)
    else:
        if xmax > bignum:
            scale = bignum / xmax
            B.dscal(scale, x)
            xmax = bignum
        if notran:
            for j in jr:
                xj = abs(x[j])
                skip = False
                if nounit:
                    tjjs = A[j, j] * tscal
                else:
                    tjjs = tscal
                    if tscal == 1.0:
                        skip = True
                if not skip:
                    tjj = abs(tjjs)
                    if tjj > smlnum:
                        if tjj < 1.0:
                            if xj > tjj * bignum:
                                rec = 1.0 / xj
                                B.dscal(rec, x)
                                scale = scale * rec
                                xmax = xmax * rec
                        x[j] = x[j] / tjjs
                        xj = abs(x[j])
                    elif tjj > 0.0:
                        if xj > tjj * bignum:
                            rec = (tjj * bignum) / xj
                            if cnorm[j] > 1.0:
                                rec = rec / cnorm[j]
                            B.dscal(rec, x)
                            scale = scale * rec
                            xmax = xmax * rec
                        x[j] = x[j] / tjjs
                        xj = abs(x[j])
                    else:
                        x[:] = 0.0
                        x[j] = 1.0
                        xj = 1.0
                        scale = 0.0
                        xmax = 0.0
                if xj > 1.0:
                    rec = 1.0 / xj
                    if cnorm[j] > (bignum - xmax) * rec:
                        rec = rec * 0.5
                        B.dscal(rec, x)
                        scale = scale * rec
                elif xj * cnorm[j] > (bignum - xmax):
                    B.dscal(0.5, x)
                    scale = scale * 0.5
                if upper:
                    if j > 0:
                        B.daxpy(-x[j] * tscal, A[:j, j], x[:j])
                        i = B.idamax(x[:j])
                        xmax = abs(x[i])
                else:
                    if j < n - 1:
                        B.daxpy(-x[j] * tscal, A[j + 1:, j], x[j + 1:])
                        i = j + 1 + B.idamax(x[j + 1:])
                        xmax = abs(x[i])
        else:
            for j in jr:
                xj = abs(x[j])
                uscal = tscal
                rec = 1.0 / _fmax(xmax, 1.0)
                if cnorm[j] > (bignum - xj) * rec:
                    rec = rec * 0.5
                    if nounit:
                        tjjs = A[j, j] * tscal
                    else:
                        tjjs = tscal
                    tjj = abs(tjjs)
                    if tjj > 1.0:
                        rec = _fmin(1.0, rec * tjj)
                        uscal = uscal / tjjs
                    if rec < 1.0:
                        B.dscal(rec, x)
                        scale = scale * rec
                        xmax = xmax * rec
                sumj = 0.0
                if uscal == 1.0:
                    if upper:
                        sumj = B.ddot(A[:j, j], x[:j])
                    elif j < n - 1:
                        sumj = B.ddot(A[j + 1:, j], x[j + 1:])
                else:
                    rr = range(j) if upper else range(j + 1, n)
                    for i in rr:
                        sumj = sumj + (A[i, j] * uscal) * x[i]
                if uscal == tscal:
                    x[j] = x[j] - sumj
                    xj = abs(x[j])
                    skip = False
                    if nounit:
                        tjjs = A[j, j] * tscal
                    else:
                        tjjs = tscal
                        if tscal == 1.0:
                            skip = True
                    if not skip:
                        tjj = abs(tjjs)
                        if tjj > smlnum:
                            if tjj < 1.0:
                                if xj > tjj * bignum:
                                    rec = 1.0 / xj
                                    B.dscal(rec, x)
                                    scale = scale * rec
                                    xmax = xmax * rec
                            x[j] = x[j] / tjjs
                        elif tjj > 0.0:
                            if xj > tjj * bignum:
                                rec = (tjj * bignum) / xj
                                B.dscal(rec, x)
                                scale = scale * rec
                                xmax = xmax * rec
                            x[j] = x[j] / tjjs
                        else:
                            x[:] = 0.0
                            x[j] = 1.0
                            scale = 0.0
                            xmax = 0.0
                else:
                    x[j] = x[j] / tjjs - sumj
                xmax = _fmax(xmax, abs(x[j]))
        scale = scale / tscal
    if tscal != 1.0:
        B.dscal(1.0 / tscal, cnorm)
    return scale


class _Lacn2:
    """Zustand von DLACN2 (umgekehrte Kommunikation)."""

    def __init__(self, n):
        self.n = n
        self.v = np.zeros(n)
        self.isgn = np.zeros(n, dtype=np.int64)
        self.isave = [0, 0, 0]
        self.est = 0.0

    def step(self, x, kase):
        n = self.n
        isave = self.isave
        if kase == 0:
            x[:] = 1.0 / float(n)
            isave[0] = 1
            return 1
        st = isave[0]
        if st == 1:
            if n == 1:
                self.v[0] = x[0]
                self.est = abs(self.v[0])
                return 0
            self.est = B.dasum(x)
            x[:] = np.where(x >= 0.0, 1.0, -1.0)
            self.isgn[:] = x.astype(np.int64)
            isave[0] = 2
            return 2
        if st == 2:
            isave[1] = B.idamax(x)
            isave[2] = 2
            return self._l50(x)
        if st == 3:
            self.v[:] = x
            estold = self.est
            self.est = B.dasum(self.v)
            xs = np.where(x >= 0.0, 1, -1)
            if np.array_equal(xs, self.isgn):
                return self._l120(x)
            if self.est <= estold:
                return self._l120(x)
            x[:] = np.where(x >= 0.0, 1.0, -1.0)
            self.isgn[:] = x.astype(np.int64)
            isave[0] = 4
            return 2
        if st == 4:
            jlast = isave[1]
            isave[1] = B.idamax(x)
            if x[jlast] != abs(x[isave[1]]) and isave[2] < 5:
                isave[2] += 1
                return self._l50(x)
            return self._l120(x)
        if st == 5:
            temp = 2.0 * (B.dasum(x) / float(3 * n))
            if temp > self.est:
                self.v[:] = x
                self.est = temp
            return 0
        raise RuntimeError("dlacn2")

    def _l50(self, x):
        x[:] = 0.0
        x[self.isave[1]] = 1.0
        self.isave[0] = 3
        return 1

    def _l120(self, x):
        n = self.n
        altsgn = 1.0
        for i in range(n):
            x[i] = altsgn * (1.0 + float(i) / float(n - 1))
            altsgn = -altsgn
        self.isave[0] = 5
        return 1


def dgecon(norm, A, anorm):
    """Kehrwert der Konditionszahl aus der LU-Zerlegung ``A`` (DGECON)."""
    n = A.shape[0]
    onenrm = norm in ("1", "O", "o")
    if n == 0:
        return 1.0
    if anorm == 0.0:
        return 0.0
    if anorm != anorm:
        return anorm
    if anorm > _HUGE:
        return 0.0
    smlnum = _SFMIN
    ainvnm = 0.0
    normin = "N"
    kase1 = 1 if onenrm else 2
    kase = 0
    x = np.zeros(n)
    cl = np.zeros(n)
    cu = np.zeros(n)
    st = _Lacn2(n)
    while True:
        kase = st.step(x, kase)
        ainvnm = st.est
        if kase == 0:
            break
        if kase == kase1:
            sl = dlatrs("L", "N", "U", normin, A, x, cl)
            su = dlatrs("U", "N", "N", normin, A, x, cu)
        else:
            su = dlatrs("U", "T", "N", normin, A, x, cu)
            sl = dlatrs("L", "T", "U", normin, A, x, cl)
        scale = sl * su
        normin = "Y"
        if scale != 1.0:
            ix = B.idamax(x)
            if scale < abs(x[ix]) * smlnum or scale == 0.0:
                return 0.0
            drscl(scale, x)
    if ainvnm != 0.0:
        return (1.0 / ainvnm) / anorm
    return 0.0


# ── Inverse aus Cholesky ──────────────────────────────────────────────────

def dtrti2(uplo, diag, A):
    n = A.shape[0]
    nounit = diag.upper() == "N"
    if uplo.upper() == "U":
        for j in range(n):
            if nounit:
                A[j, j] = 1.0 / A[j, j]
                ajj = -A[j, j]
            else:
                ajj = -1.0
            B.dtrmv("U", "N", diag, A[:j, :j], A[:j, j])
            B.dscal(ajj, A[:j, j])
    else:
        for j in range(n - 1, -1, -1):
            if nounit:
                A[j, j] = 1.0 / A[j, j]
                ajj = -A[j, j]
            else:
                ajj = -1.0
            if j < n - 1:
                B.dtrmv("L", "N", diag, A[j + 1:, j + 1:], A[j + 1:, j])
                B.dscal(ajj, A[j + 1:, j])
    return 0


def dtrtri(uplo, diag, A, nb=64):
    n = A.shape[0]
    if n == 0:
        return 0
    nounit = diag.upper() == "N"
    if nounit:
        for i in range(n):
            if A[i, i] == 0.0:
                return i + 1
    if nb <= 1 or nb >= n:
        return dtrti2(uplo, diag, A)
    if uplo.upper() == "U":
        for j in range(1, n + 1, nb):
            jb = min(nb, n - j + 1)
            j0 = j - 1
            B.dtrmm("L", "U", "N", diag, 1.0, A[:j0, :j0], A[:j0, j0:j0 + jb])
            B.dtrsm("R", "U", "N", diag, -1.0, A[j0:j0 + jb, j0:j0 + jb], A[:j0, j0:j0 + jb])
            dtrti2("U", diag, A[j0:j0 + jb, j0:j0 + jb])
    else:
        nn = ((n - 1) // nb) * nb + 1
        for j in range(nn, 0, -nb):
            jb = min(nb, n - j + 1)
            j0 = j - 1
            if j + jb <= n:
                B.dtrmm("L", "L", "N", diag, 1.0, A[j0 + jb:, j0 + jb:], A[j0 + jb:, j0:j0 + jb])
                B.dtrsm("R", "L", "N", diag, -1.0, A[j0:j0 + jb, j0:j0 + jb], A[j0 + jb:, j0:j0 + jb])
            dtrti2("L", diag, A[j0:j0 + jb, j0:j0 + jb])
    return 0


def dlauu2(uplo, A):
    n = A.shape[0]
    if n == 0:
        return
    if uplo.upper() == "U":
        for i in range(n):
            aii = A[i, i]
            if i < n - 1:
                A[i, i] = B.ddot(A[i, i:], A[i, i:])
                B.dgemv("N", 1.0, A[:i, i + 1:], A[i, i + 1:], aii, A[:i, i])
            else:
                B.dscal(aii, A[:i + 1, i])
    else:
        for i in range(n):
            aii = A[i, i]
            if i < n - 1:
                A[i, i] = B.ddot(A[i:, i], A[i:, i])
                B.dgemv("T", 1.0, A[i + 1:, :i], A[i + 1:, i], aii, A[i, :i])
            else:
                B.dscal(aii, A[i, :i + 1])


def dlauum(uplo, A, nb=64):
    n = A.shape[0]
    if n == 0:
        return
    if nb <= 1 or nb >= n:
        dlauu2(uplo, A)
        return
    if uplo.upper() == "U":
        for i in range(1, n + 1, nb):
            ib = min(nb, n - i + 1)
            i0 = i - 1
            B.dtrmm("R", "U", "T", "N", 1.0, A[i0:i0 + ib, i0:i0 + ib], A[:i0, i0:i0 + ib])
            dlauu2("U", A[i0:i0 + ib, i0:i0 + ib])
            if i + ib <= n:
                B.dgemm("N", "T", 1.0, A[:i0, i0 + ib:], A[i0:i0 + ib, i0 + ib:], 1.0, A[:i0, i0:i0 + ib])
                B.dsyrk("U", "N", 1.0, A[i0:i0 + ib, i0 + ib:], 1.0, A[i0:i0 + ib, i0:i0 + ib])
    else:
        for i in range(1, n + 1, nb):
            ib = min(nb, n - i + 1)
            i0 = i - 1
            B.dtrmm("L", "L", "T", "N", 1.0, A[i0:i0 + ib, i0:i0 + ib], A[i0:i0 + ib, :i0])
            dlauu2("L", A[i0:i0 + ib, i0:i0 + ib])
            if i + ib <= n:
                B.dgemm("T", "N", 1.0, A[i0 + ib:, i0:i0 + ib], A[i0 + ib:, :i0], 1.0, A[i0:i0 + ib, :i0])
                B.dsyrk("L", "T", 1.0, A[i0 + ib:, i0:i0 + ib], 1.0, A[i0:i0 + ib, i0:i0 + ib])


def dpotri(uplo, A):
    n = A.shape[0]
    if n == 0:
        return 0
    info = dtrtri(uplo, "N", A)
    if info > 0:
        return info
    dlauum(uplo, A)
    return 0


# ── Symmetrische Eigenwerte (nur Werte) ──────────────────────────────────

def dlansy(norm, uplo, A):
    n = A.shape[0]
    if n == 0:
        return 0.0
    if norm.upper() != "M":
        raise NotImplementedError(norm)
    tri = np.triu(A) if uplo.upper() == "U" else np.tril(A)
    a = np.abs(tri)
    if np.isnan(a).any():          # einmal NaN, bleibt NaN (VALUE.LT.SUM ist dann falsch)
        return math.nan
    return max(0.0, float(a.max()))


def dlapy2(x, y):
    xn = x != x
    yn = y != y
    r = None
    if xn:
        r = x
    if yn:
        r = y
    if not (xn or yn):
        xa = abs(x)
        ya = abs(y)
        w = _fmax(xa, ya)
        z = _fmin(xa, ya)
        if z == 0.0 or w > _HUGE:
            r = w
        else:
            q = z / w
            r = w * math.sqrt(1.0 + q * q)
    return r


def dlarfg(n, alpha, x):
    """Householder-Reflektor (DLARFG); ``x`` in place; liefert (beta/alpha, tau)."""
    if n <= 1:
        return alpha, 0.0
    xnorm = B.dnrm2(x)
    if xnorm == 0.0:
        return alpha, 0.0
    beta = -math.copysign(dlapy2(alpha, xnorm), alpha)
    safmin = _SFMIN / _EPS
    knt = 0
    if abs(beta) < safmin:
        rsafmn = 1.0 / safmin
        while True:
            knt += 1
            B.dscal(rsafmn, x)
            beta = beta * rsafmn
            alpha = alpha * rsafmn
            if not (abs(beta) < safmin and knt < 20):
                break
        xnorm = B.dnrm2(x)
        beta = -math.copysign(dlapy2(alpha, xnorm), alpha)
    tau = (beta - alpha) / beta
    B.dscal(1.0 / (alpha - beta), x)
    for _ in range(knt):
        beta = beta * safmin
    return beta, tau


def _dsytd2_lower(A, d, e, tau):
    n = A.shape[0]
    if n <= 0:
        return
    for i in range(n - 1):
        beta, taui = dlarfg(n - i - 1, A[i + 1, i], A[i + 2:, i])
        A[i + 1, i] = beta
        e[i] = A[i + 1, i]
        if taui != 0.0:
            A[i + 1, i] = 1.0
            v = A[i + 1:, i]
            w = tau[i:n - 1]
            B.dsymv("L", taui, A[i + 1:, i + 1:], v, 0.0, w)
            alpha = -((0.5 * taui) * B.ddot(w, v))
            B.daxpy(alpha, v, w)
            B.dsyr2("L", -1.0, v, w, A[i + 1:, i + 1:])
            A[i + 1, i] = e[i]
        d[i] = A[i, i]
        tau[i] = taui
    d[n - 1] = A[n - 1, n - 1]


def _dsytd2_upper(A, d, e, tau):
    n = A.shape[0]
    if n <= 0:
        return
    for i in range(n - 2, -1, -1):          # I = N-1..1 (1-basiert) → i = I-1
        I = i + 1
        beta, taui = dlarfg(I, A[I - 1, I], A[:I - 1, I])
        A[I - 1, I] = beta
        e[I - 1] = A[I - 1, I]
        if taui != 0.0:
            A[I - 1, I] = 1.0
            v = A[:I, I]
            w = tau[:I]
            B.dsymv("U", taui, A[:I, :I], v, 0.0, w)
            alpha = -((0.5 * taui) * B.ddot(w, v))
            B.daxpy(alpha, v, w)
            B.dsyr2("U", -1.0, v, w, A[:I, :I])
            A[I - 1, I] = e[I - 1]
        d[I] = A[I, I]
        tau[I - 1] = taui
    d[0] = A[0, 0]


def _dlatrd_lower(A, nb, e, tau, W):
    n = A.shape[0]
    if n <= 0:
        return
    for i in range(nb):
        B.dgemv("N", -1.0, A[i:, :i], W[i, :i], 1.0, A[i:, i])
        B.dgemv("N", -1.0, W[i:, :i], A[i, :i], 1.0, A[i:, i])
        if i < n - 1:
            beta, t = dlarfg(n - i - 1, A[i + 1, i], A[i + 2:, i])
            A[i + 1, i] = beta
            tau[i] = t
            e[i] = A[i + 1, i]
            A[i + 1, i] = 1.0
            v = A[i + 1:, i]
            wcol = W[i + 1:, i]
            B.dsymv("L", 1.0, A[i + 1:, i + 1:], v, 0.0, wcol)
            B.dgemv("T", 1.0, W[i + 1:, :i], v, 0.0, W[:i, i])
            B.dgemv("N", -1.0, A[i + 1:, :i], W[:i, i], 1.0, wcol)
            B.dgemv("T", 1.0, A[i + 1:, :i], v, 0.0, W[:i, i])
            B.dgemv("N", -1.0, W[i + 1:, :i], W[:i, i], 1.0, wcol)
            B.dscal(tau[i], wcol)
            alpha = -((0.5 * tau[i]) * B.ddot(wcol, v))
            B.daxpy(alpha, v, wcol)


def dsytrd(uplo, A, d, e, tau, lwork):
    """Reduktion auf Tridiagonalform (DSYTRD; ``uplo='L'`` blockweise)."""
    n = A.shape[0]
    if n == 0:
        return
    nb = 32                                   # ILAENV(1, 'DSYTRD')
    nx = n
    ldwork = n
    if 1 < nb < n:
        nx = max(nb, 32)                      # ILAENV(3, 'DSYTRD')
        if nx < n:
            iws = ldwork * nb
            if lwork < iws:
                nb = max(lwork // ldwork, 1)
                if nb < 2:                    # ILAENV(2, 'DSYTRD')
                    nx = n
        else:
            nx = n
    else:
        nb = 1
    if uplo.upper() == "U":
        if nx < n:
            raise NotImplementedError("dsytrd: Blockfassung nur für uplo='L'")
        _dsytd2_upper(A, d, e, tau)
        return
    i = 1
    if n - nx >= 1:
        for i in range(1, n - nx + 1, nb):
            i0 = i - 1
            W = np.zeros((n - i + 1, nb))
            _dlatrd_lower(A[i0:, i0:], nb, e[i0:], tau[i0:], W)
            B.dsyr2k("L", "N", -1.0, A[i0 + nb:, i0:i0 + nb], W[nb:, :], 1.0, A[i0 + nb:, i0 + nb:])
            for j in range(i, i + nb):
                A[j, j - 1] = e[j - 1]
                d[j - 1] = A[j - 1, j - 1]
        i = i + nb
    i0 = i - 1
    _dsytd2_lower(A[i0:, i0:], d[i0:], e[i0:], tau[i0:])


def dlae2(a, b, c):
    sm = a + c
    df = a - c
    adf = abs(df)
    tb = b + b
    ab = abs(tb)
    if abs(a) > abs(c):
        acmx, acmn = a, c
    else:
        acmx, acmn = c, a
    if adf > ab:
        q = ab / adf
        rt = adf * math.sqrt(1.0 + q * q)
    elif adf < ab:
        q = adf / ab
        rt = ab * math.sqrt(1.0 + q * q)
    else:
        rt = ab * math.sqrt(2.0)
    if sm < 0.0:
        rt1 = 0.5 * (sm - rt)
        rt2 = (acmx / rt1) * acmn - (b / rt1) * b
    elif sm > 0.0:
        rt1 = 0.5 * (sm + rt)
        rt2 = (acmx / rt1) * acmn - (b / rt1) * b
    else:
        rt1 = 0.5 * rt
        rt2 = -0.5 * rt
    return rt1, rt2


def _dlascl_g(cfrom, cto, v):
    """DLASCL Typ 'G' auf einen Vektor (in place)."""
    if v.shape[0] == 0:
        return
    smlnum = _SFMIN
    bignum = 1.0 / smlnum
    cfromc = cfrom
    ctoc = cto
    while True:
        cfrom1 = cfromc * smlnum
        if cfrom1 == cfromc:
            mul = ctoc / cfromc
            done = True
        else:
            cto1 = ctoc / bignum
            if cto1 == ctoc:
                mul = ctoc
                done = True
                cfromc = 1.0
            elif abs(cfrom1) > abs(ctoc) and ctoc != 0.0:
                mul = smlnum
                done = False
                cfromc = cfrom1
            elif abs(cto1) > abs(cfromc):
                mul = bignum
                done = False
                ctoc = cto1
            else:
                mul = ctoc / cfromc
                done = True
                if mul == 1.0:
                    return
        v *= mul
        if done:
            return


def _dlanst_m(d, e):
    n = d.shape[0]
    if n <= 0:
        return 0.0
    anorm = abs(d[n - 1])
    for i in range(n - 1):
        s = abs(d[i])
        if anorm < s or s != s:
            anorm = s
        s = abs(e[i])
        if anorm < s or s != s:
            anorm = s
    return anorm


def dsterf(d, e):
    """Eigenwerte einer symmetrischen Tridiagonalmatrix (DSTERF); ``d`` in place.

    Liefert INFO (0 = konvergiert); ``d`` aufsteigend sortiert.
    """
    n = d.shape[0]
    if n <= 1:
        return 0
    # 1-basierte Hilfsfelder
    D = np.concatenate([[0.0], d.astype(np.float64)]).tolist()
    E = [0.0] + list(map(float, e[:n - 1])) + [0.0]
    eps = _EPS
    eps2 = eps * eps
    safmin = _SFMIN
    safmax = 1.0 / safmin
    ssfmax = math.sqrt(safmax) / 3.0
    ssfmin = math.sqrt(safmin) / eps2
    nmaxit = n * 30
    sigma = 0.0
    jtot = 0
    l1 = 1
    sqrt = math.sqrt
    copysign = math.copysign
    while True:
        # Label 10
        if l1 > n:
            Dn = np.array(D[1:])
            Dn.sort()
            d[:] = Dn
            return 0
        if l1 > 1:
            E[l1 - 1] = 0.0
        m = n
        for mm in range(l1, n):
            if abs(E[mm]) <= (sqrt(abs(D[mm])) * sqrt(abs(D[mm + 1]))) * eps:
                E[mm] = 0.0
                m = mm
                break
        l = l1
        lsv = l
        lend = m
        lendsv = lend
        l1 = m + 1
        if lend == l:
            continue
        sub_d = np.array(D[l:lend + 1])
        sub_e = np.array(E[l:lend])
        anorm = _dlanst_m(sub_d, sub_e)
        iscale = 0
        if anorm == 0.0:
            continue
        if anorm > ssfmax:
            iscale = 1
            _dlascl_g(anorm, ssfmax, sub_d)
            _dlascl_g(anorm, ssfmax, sub_e)
        elif anorm < ssfmin:
            iscale = 2
            _dlascl_g(anorm, ssfmin, sub_d)
            _dlascl_g(anorm, ssfmin, sub_e)
        if iscale:
            D[l:lend + 1] = sub_d.tolist()
            E[l:lend] = sub_e.tolist()
        for i in range(l, lend):
            E[i] = E[i] * E[i]
        if abs(D[lend]) < abs(D[l]):
            lend = lsv
            l = lendsv
        if lend >= l:
            # QL-Iteration
            while True:
                # Label 50
                m = lend
                if l != lend:
                    for mm in range(l, lend):
                        if abs(E[mm]) <= eps2 * abs(D[mm] * D[mm + 1]):
                            m = mm
                            break
                if m < lend:
                    E[m] = 0.0
                p = D[l]
                if m == l:
                    D[l] = p
                    l = l + 1
                    if l <= lend:
                        continue
                    break
                if m == l + 1:
                    rte = sqrt(E[l])
                    rt1, rt2 = dlae2(D[l], rte, D[l + 1])
                    D[l] = rt1
                    D[l + 1] = rt2
                    E[l] = 0.0
                    l = l + 2
                    if l <= lend:
                        continue
                    break
                if jtot == nmaxit:
                    break
                jtot += 1
                rte = sqrt(E[l])
                sigma = (D[l + 1] - p) / (2.0 * rte)
                r = dlapy2(sigma, 1.0)
                sigma = p - (rte / (sigma + copysign(r, sigma)))
                c = 1.0
                s = 0.0
                gamma = D[m] - sigma
                p = gamma * gamma
                for i in range(m - 1, l - 1, -1):
                    bb = E[i]
                    r = p + bb
                    if i != m - 1:
                        E[i + 1] = s * r
                    oldc = c
                    c = p / r
                    s = bb / r
                    oldgam = gamma
                    alpha = D[i]
                    gamma = c * (alpha - sigma) - s * oldgam
                    D[i + 1] = oldgam + (alpha - gamma)
                    if c != 0.0:
                        p = (gamma * gamma) / c
                    else:
                        p = oldc * bb
                E[l] = s * p
                D[l] = sigma + gamma
        else:
            # QR-Iteration
            while True:
                # Label 100
                m = lend
                for mm in range(l, lend, -1):
                    if abs(E[mm - 1]) <= eps2 * abs(D[mm] * D[mm - 1]):
                        m = mm
                        break
                if m > lend:
                    E[m - 1] = 0.0
                p = D[l]
                if m == l:
                    D[l] = p
                    l = l - 1
                    if l >= lend:
                        continue
                    break
                if m == l - 1:
                    rte = sqrt(E[l - 1])
                    rt1, rt2 = dlae2(D[l], rte, D[l - 1])
                    D[l] = rt1
                    D[l - 1] = rt2
                    E[l - 1] = 0.0
                    l = l - 2
                    if l >= lend:
                        continue
                    break
                if jtot == nmaxit:
                    break
                jtot += 1
                rte = sqrt(E[l - 1])
                sigma = (D[l - 1] - p) / (2.0 * rte)
                r = dlapy2(sigma, 1.0)
                sigma = p - (rte / (sigma + copysign(r, sigma)))
                c = 1.0
                s = 0.0
                gamma = D[m] - sigma
                p = gamma * gamma
                for i in range(m, l):
                    bb = E[i]
                    r = p + bb
                    if i != m:
                        E[i - 1] = s * r
                    oldc = c
                    c = p / r
                    s = bb / r
                    oldgam = gamma
                    alpha = D[i + 1]
                    gamma = c * (alpha - sigma) - s * oldgam
                    D[i] = oldgam + (alpha - gamma)
                    if c != 0.0:
                        p = (gamma * gamma) / c
                    else:
                        p = oldc * bb
                E[l - 1] = s * p
                D[l] = sigma + gamma
        # Label 150
        if iscale == 1:
            sub = np.array(D[lsv:lendsv + 1])
            _dlascl_g(ssfmax, anorm, sub)
            D[lsv:lendsv + 1] = sub.tolist()
        if iscale == 2:
            sub = np.array(D[lsv:lendsv + 1])
            _dlascl_g(ssfmin, anorm, sub)
            D[lsv:lendsv + 1] = sub.tolist()
        if jtot < nmaxit:
            continue
        info = sum(1 for i in range(1, n) if E[i] != 0.0)
        d[:] = np.array(D[1:])
        return info


def dsyevr_values(A):
    """Eigenwerte (aufsteigend) wie ``dsyevr(JOBZ='N', RANGE='A', UPLO='L')``.

    ``A`` wird nicht verändert. Liefert ``(w, info)``; ``info != 0`` heißt,
    dass ``dsterf`` nicht konvergierte (R fiele dann auf ``dstebz`` zurück).
    """
    A = np.array(A, dtype=np.float64, order="F", copy=True)
    n = A.shape[0]
    if n == 0:
        return np.zeros(0), 0
    if n == 1:
        return np.array([A[0, 0]]), 0
    safmin = _SFMIN
    eps = _PREC
    smlnum = safmin / eps
    bignum = 1.0 / smlnum
    rmin = math.sqrt(smlnum)
    rmax = min(math.sqrt(bignum), 1.0 / math.sqrt(math.sqrt(safmin)))
    iscale = 0
    anrm = dlansy("M", "L", A)
    sigma = 1.0
    if 0.0 < anrm < rmin:
        iscale = 1
        sigma = rmin / anrm
    elif anrm > rmax:
        iscale = 1
        sigma = rmax / anrm
    if iscale:
        for j in range(n):
            A[j:, j] *= sigma
    lwork = max(33 * n, 26 * n)               # LWKOPT aus der Arbeitsfeldabfrage
    llwork = lwork - 5 * n
    d = np.zeros(n)
    e = np.zeros(n)
    tau = np.zeros(n)
    dsytrd("L", A, d, e, tau, llwork)
    w = d.copy()
    ee = e[:n - 1].copy()
    info = dsterf(w, ee)
    if iscale:
        w *= (1.0 / sigma)
    return w, info


# ── System-LAPACK (ctypes) ────────────────────────────────────────────────

_SYS = {"lib": False}


def system_lapack():
    """Lädt die Referenz-LAPACK des Systems (oder ``None``)."""
    if _SYS["lib"] is not False:
        return _SYS["lib"]
    cands = []
    env = os.environ.get("SIMLEV_LAPACK")
    if env:
        cands.append(env)
    cands += ["/usr/lib/x86_64-linux-gnu/lapack/liblapack.so.3",
              "/usr/lib/aarch64-linux-gnu/lapack/liblapack.so.3",
              "/usr/lib64/liblapack.so.3", "/usr/lib/liblapack.so.3"]
    fl = ctypes.util.find_library("lapack")
    if fl:
        cands.append(fl)
    lib = None
    for c in cands:
        try:
            lib = ctypes.CDLL(c)
            getattr(lib, "dsyevr_")
            break
        except (OSError, AttributeError):
            lib = None
            if env and c == env:
                warnings.warn("SIMLEV_LAPACK=%s: keine LAPACK-Bibliothek mit dsyevr_ ladbar; "
                              "suche die System-LAPACK." % env, stacklevel=3)
    _SYS["lib"] = lib
    return lib


def _warn_fallback(name):
    if not _SYS.get("warned"):
        _SYS["warned"] = True
        warnings.warn("eigen(): keine System-LAPACK gefunden, Eigenvektoren \u00fcber %s berechnet "
                      "(nicht bitgleich zu R; Pfad zur Referenz-LAPACK \u00fcber SIMLEV_LAPACK setzen)." % name,
                      stacklevel=4)


def _sys_dsyevr(lib, A, jobz):
    I = ctypes.c_int
    D = ctypes.c_double
    n = A.shape[0]
    a = np.array(A, dtype=np.float64, order="F", copy=True)
    w = np.zeros(n)
    z = np.zeros((n, n), order="F") if jobz == "V" else np.zeros((1, 1), order="F")
    isuppz = np.zeros(max(1, 2 * n), dtype=np.int32)
    nn = I(n)
    vl = D(0.0)
    vu = D(0.0)
    il = I(0)
    iu = I(0)
    abstol = D(0.0)
    m = I(0)
    info = I(0)
    ldz = I(n if jobz == "V" else 1)
    p = lambda arr: arr.ctypes.data_as(ctypes.c_void_p)  # noqa: E731
    f = lib.dsyevr_
    tmp = np.zeros(1)
    itmp = np.zeros(1, dtype=np.int32)
    lw = I(-1)
    liw = I(-1)
    cj = ctypes.c_char_p(jobz.encode())
    ca = ctypes.c_char_p(b"A")
    cu = ctypes.c_char_p(b"L")
    one = ctypes.c_size_t(1)
    f(cj, ca, cu, ctypes.byref(nn), p(a), ctypes.byref(nn), ctypes.byref(vl), ctypes.byref(vu),
      ctypes.byref(il), ctypes.byref(iu), ctypes.byref(abstol), ctypes.byref(m), p(w), p(z),
      ctypes.byref(ldz), p(isuppz), p(tmp), ctypes.byref(lw), p(itmp), ctypes.byref(liw),
      ctypes.byref(info), one, one, one)
    if info.value != 0:
        return None, None, info.value
    lwork = int(tmp[0])
    liwork = int(itmp[0])
    work = np.zeros(max(1, lwork))
    iwork = np.zeros(max(1, liwork), dtype=np.int32)
    lw = I(lwork)
    liw = I(liwork)
    f(cj, ca, cu, ctypes.byref(nn), p(a), ctypes.byref(nn), ctypes.byref(vl), ctypes.byref(vu),
      ctypes.byref(il), ctypes.byref(iu), ctypes.byref(abstol), ctypes.byref(m), p(w), p(z),
      ctypes.byref(ldz), p(isuppz), p(work), ctypes.byref(lw), p(iwork), ctypes.byref(liw),
      ctypes.byref(info), one, one, one)
    return w, (np.array(z) if jobz == "V" else None), info.value


def dsyevr(A, only_values=False, backend="auto"):
    """Symmetrische Eigenzerlegung wie R's ``La_rs`` (``dsyevr``, uplo 'L').

    Liefert ``(values_aufsteigend, vectors_or_None, info, backend_name)``.
    ``backend``: ``"auto"`` (Werte: reiner Port; Vektoren: System-LAPACK,
    sonst numpy), ``"port"``, ``"system"``, ``"fallback"``.
    """
    A = np.asarray(A, dtype=np.float64)
    if backend in ("auto", "port") and only_values:
        w, info = dsyevr_values(A)
        if info == 0 or backend == "port":
            return w, None, info, "port"
    if backend in ("auto", "system"):
        lib = system_lapack()
        if lib is not None:
            w, z, info = _sys_dsyevr(lib, A, "N" if only_values else "V")
            return w, z, info, "system"
        if backend == "system":
            raise RuntimeError("System-LAPACK nicht gefunden")
    # Ersatzweg: nicht bitgleich garantiert
    L = np.tril(A) + np.tril(A, -1).T
    _warn_fallback("numpy")
    if only_values:
        return np.linalg.eigvalsh(L), None, 0, "numpy"
    w, z = np.linalg.eigh(L)
    return w, z, 0, "numpy"
