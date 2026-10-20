"""PORT-Bibliothek für ``nlminb`` (R 4.3.3: ``src/library/stats/src/port.c``
und die benötigten Routinen aus ``portsrc.f``), bitgleich in Python.

Konventionen der Übersetzung:

* Alle Felder sind ``numpy``-Arrays mit **1-basierter** Indizierung: Element
  ``k`` des Fortran-Felds steht in ``a[k]`` (``a[0]`` ist ein Platzhalter bzw.
  gehört zum vorigen Element). Ein Fortran-Aktualparameter ``V(L)`` wird als
  Sicht ``v[L - 1:]`` übergeben; Schreibzugriffe wirken wie in Fortran auf das
  Grundfeld.
* Skalare sind ``numpy.float64`` (IEEE-Semantik ohne Ausnahmen bei Division
  durch null); die aufrufende Funktion läuft unter ``np.errstate(all="ignore")``.
* Sprungmarken werden als Zustandsautomat (``lab``) nachgebildet.
* ``DMAX1`` übersetzt gfortran in ``maxsd``; die Operandenreihenfolge (wichtig
  nur bei NaN) ist je Stelle aus dem Maschinencode von R's ``stats.so``
  übernommen (``_max1``: erstes Argument, außer das zweite ist größer;
  ``_max2``: zweites Argument, außer das erste ist größer).
* ``DD7TPR`` und ``DV2NRM`` rufen wie in R die Referenz-BLAS (``ddot``,
  ``dnrm2``).
"""
from __future__ import annotations

import math
import warnings

import numpy as np
import pandas as pd

from . import libm as _libm
from ._blas import dnrm2 as _dnrm2_blas
from .linalg import RError
from .._rnum import NA_REAL

__all__ = ["divset", "port_nlminb"]

_F = np.float64
ZERO = _F(0.0)
ONE = _F(1.0)
TWO = _F(2.0)
THREE = _F(3.0)
FOUR = _F(4.0)
HALF = _F(0.5)
NEGONE = _F(-1.0)
ONEP2 = _F(1.2)

_DBL_EPS = _F(2.220446049250313e-16)
_DBL_MIN = _F(2.2250738585072014e-308)
_DBL_MAX = _F(1.7976931348623157e308)


def _sqrt(x):
    return np.sqrt(_F(x))


def _pow(x, y):
    return _F(_libm.pow(float(x), float(y)))


def _max1(a, b):
    """``maxsd`` mit Ziel ``a``: ``a > b ? a : b``."""
    return a if a > b else b


def _max2(a, b):
    """``maxsd`` mit Ziel ``b``: ``b > a ? b : a``."""
    return b if b > a else a


def _at(a, k):
    """Fortran-Aktualparameter ``A(K)`` (Sicht ab Element ``k``)."""
    return a[k - 1:]


# ── Maschinenkonstanten (DR7MDC über R's d1mach) ─────────────────────────

def dr7mdc(k):
    if k == 1:
        return _DBL_MIN
    if k == 2:
        return _sqrt(_F(256.0) * _DBL_MIN) / _F(16.0)
    if k == 3:
        return _DBL_EPS
    if k == 4:
        return _sqrt(_DBL_EPS)
    if k == 5:
        return _sqrt(_DBL_MAX / _F(256.0)) * _F(16.0)
    if k == 6:
        return _DBL_MAX
    raise ValueError(k)


# ── Ersatzroutinen aus port.c ────────────────────────────────────────────

def dd7tpr(p, x, y):
    """Skalarprodukt (Referenz-BLAS ``ddot``: sequenziell ab 0)."""
    t = ZERO
    for i in range(1, p + 1):
        t = t + x[i] * y[i]
    return t


def dv2nrm(n, x):
    if n <= 0:
        return ZERO
    return _F(_dnrm2_blas(np.array(x[1:n + 1], dtype=np.float64)))


def dv2axy(n, w, a, x, y):
    for i in range(1, n + 1):
        w[i] = a * x[i] + y[i]


def dv7cpy(n, dest, src):
    if n > 0:
        dest[1:n + 1] = np.array(src[1:n + 1])


def dv7ipr(n, ip, x):
    """``x[i] := x[ip[i]]``."""
    xcp = [x[ip[i]] for i in range(1, n + 1)]
    for i in range(1, n + 1):
        x[i] = xcp[i - 1]


def dv7prm(n, ip, x):
    """``x[ip[i]] := x[i]``."""
    xcp = [ZERO] * (n + 1)
    for i in range(1, n + 1):
        xcp[ip[i]] = x[i]
    for i in range(1, n + 1):
        x[i] = xcp[i]


def dv7scl(n, dest, scal, src):
    for i in range(1, n + 1):
        dest[i] = scal * src[i]


def dv7scp(n, dest, c):
    if n > 0:
        dest[1:n + 1] = c


def dv7swp(n, x, y):
    for i in range(1, n + 1):
        t = x[i]
        x[i] = y[i]
        y[i] = t


def i7copy(n, dest, src):
    for i in range(1, n + 1):
        dest[i] = src[i]


def i7pnvr(n, x, y):
    for i in range(1, n + 1):
        x[y[i]] = i


def ditsum(d, g, iv, liv, lv, n, v, x):
    """Iterationsausgabe (``trace``) wie ``ditsum`` in port.c (Rprintf)."""
    if not iv[OUTLEV]:
        return
    if not (int(iv[NITER]) % int(iv[OUTLEV])):
        s = "%3d:%s:" % (int(iv[NITER]), _cg("%#14.8g", 14, v[F]))
        s += "".join(" " + _cg("%#8g", 8, x[i]) for i in range(1, n + 1))
        print(s)


def _cg(fmt, width, val):
    """C-``printf`` einer Zahl (glibc: negatives NaN als ``-nan``)."""
    val = float(val)
    if val != val and math.copysign(1.0, val) < 0:
        return "%*s" % (width, "-nan")
    return fmt % val


# ── iv-/v-Indizes ─────────────────────────────────────────────────────────

AFCTOL = 31
ALGSAV = 51
COVPRT = 14
COVREQ = 15
DTYPE = 16
F = 10
F0 = 13
FDIF = 11
G = 28
HC = 71
IERR = 75
INITH = 25
INITS = 25
IPIVOT = 76
IVNEED = 3
LASTIV = 44
LASTV = 45
LMAT = 42
MXFCAL = 17
MXITER = 18
NEXTV = 47
NFCALL = 6
NFCOV = 52
NFGCAL = 7
NGCOV = 53
NITER = 31
NVDFLT = 50
NVSAVE = 9
OUTLEV = 19
PARPRT = 20
PARSAV = 49
PERM = 58
PRUNIT = 21
QRTYP = 80
RDREQ = 57
RMAT = 78
SOLPRT = 22
STATPR = 23
TOOBIG = 2
VNEED = 4
VSAVE = 60
X0PRT = 24


# ── Voreinstellungen ─────────────────────────────────────────────────────

def dv7dfl(alg, lv, v):
    """DV7DFL: Voreinstellungen in ``v`` (1-basiert)."""
    machep = dr7mdc(3)
    if machep > _F(1e-10):
        v[31] = machep * machep
    else:
        v[31] = _F(1e-20)
    v[22] = _F(0.5)
    sqteps = dr7mdc(4)
    v[41] = _F(0.6)
    v[39] = _F(1e-6)
    mepcrt = _pow(machep, ONE / THREE)
    v[40] = _F(1.0)
    v[19] = _F(0.1)
    v[23] = _F(2.0)
    v[35] = _F(1.0)
    v[36] = _F(1.0)
    v[20] = _F(-0.1)
    v[21] = _F(0.1)
    v[24] = _F(0.1)
    v[25] = _F(4.0)
    v[32] = _max1(_F(1e-10), mepcrt * mepcrt)
    v[37] = v[32]
    v[26] = _F(0.1)
    v[27] = _F(1e-4)
    v[28] = _F(0.75)
    v[29] = _F(0.5)
    v[30] = _F(0.75)
    v[33] = sqteps
    v[34] = _F(1e2) * machep
    if alg == 1:
        v[47] = _max1(_F(1e-6), _F(1e2) * machep)
        v[38] = _F(0.0)
        v[44] = sqteps
        v[42] = mepcrt
        v[43] = sqteps
        v[45] = _F(1.5)
        v[46] = dr7mdc(5)
        v[49] = _F(1e-3)
        v[50] = _F(1e-4)
    else:
        v[43] = _F(0.8)
        v[38] = _F(-1.0)
        v[42] = _F(1e3) * machep


def divset(alg, iv, liv, lv, v):
    """``Rf_divset`` aus port.c (``iv``, ``v`` 1-basiert)."""
    miniv = (0, 82, 59, 103, 103)
    minv = (0, 98, 71, 101, 85)
    if PRUNIT <= liv:
        iv[PRUNIT] = 0
    if ALGSAV <= liv:
        iv[ALGSAV] = alg
    if alg < 1 or alg > 4:
        raise RError("Rf_divset: alg = %d must be 1, 2, 3, or 4" % alg)
    miv = miniv[alg]
    if liv < miv:
        iv[1] = 15
        return
    mv = minv[alg]
    if lv < mv:
        iv[1] = 16
        return
    alg1 = (alg - 1) % 2 + 1
    dv7dfl(alg1, lv, v)
    iv[1] = 12
    if alg > 2:
        raise RError("port algorithms 3 or higher are not supported")
    iv[IVNEED] = 0
    iv[LASTIV] = miv
    iv[LASTV] = mv
    iv[LMAT] = mv + 1
    iv[MXFCAL] = 200
    iv[MXITER] = 150
    iv[OUTLEV] = 0
    iv[PARPRT] = 1
    iv[PERM] = miv + 1
    iv[SOLPRT] = 0
    iv[STATPR] = 0
    iv[VNEED] = 0
    iv[X0PRT] = 1
    if alg1 >= 2:
        iv[DTYPE] = 0
        iv[INITS] = 1
        iv[NFCOV] = 0
        iv[NGCOV] = 0
        iv[NVDFLT] = 25
        iv[PARSAV] = 61 if alg > 2 else 47
        v[AFCTOL] = 0.0
    else:
        iv[COVPRT] = 3
        iv[COVREQ] = 1
        iv[DTYPE] = 1
        iv[HC] = 0
        iv[IERR] = 0
        iv[INITH] = 0
        iv[IPIVOT] = 0
        iv[NVDFLT] = 32
        iv[VSAVE] = 61 if alg > 2 else 58
        iv[PARSAV] = iv[60] + 9
        iv[QRTYP] = 1
        iv[RDREQ] = 3
        iv[RMAT] = 0


# ── kleine lineare Algebra (portsrc.f) ───────────────────────────────────

def dv7vmp(n, x, y, z, k):
    if k >= 0:
        for i in range(1, n + 1):
            x[i] = y[i] * z[i]
    else:
        for i in range(1, n + 1):
            x[i] = y[i] / z[i]


def dv7shf(n, k, x):
    if k >= n:
        return
    t = x[k]
    for i in range(k, n):
        x[i] = x[i + 1]
    x[n] = t


def i7shft(n, k, x):
    if k >= 0:
        if k >= n:
            return
        t = x[k]
        for i in range(k, n):
            x[i] = x[i + 1]
        x[n] = t
        return
    k1 = -k
    if k1 >= n:
        return
    t = x[n]
    nm1 = n - k1
    for ii in range(1, nm1 + 1):
        i = n - ii
        x[i + 1] = x[i]
    x[k1] = t


def drldst(p, d, x, x0):
    emax = ZERO
    xmax = ZERO
    for i in range(1, p + 1):
        t = abs(d[i] * (x[i] - x0[i]))
        if emax < t:
            emax = t
        t = d[i] * (abs(x[i]) + abs(x0[i]))
        if xmax < t:
            xmax = t
    r = ZERO
    if xmax > ZERO:
        r = emax / xmax
    return r


def dh2rfg(a, b):
    """Liefert (DH2RFG, x, y, z)."""
    if b == ZERO:
        return a, ZERO, ZERO, ZERO
    t = abs(a) + abs(b)
    a1 = a / t
    b1 = b / t
    c = _sqrt(a1 * a1 + b1 * b1)
    if a1 > ZERO:
        c = -c
    a1 = a1 - c
    z = b1 / a1
    x = a1 / c
    y = b1 / c
    return t * c, x, y, z


def dh2rfa(n, a, b, x, y, z):
    for i in range(1, n + 1):
        t = a[i] * x + b[i] * y
        a[i] = a[i] + t
        b[i] = b[i] + t * z


def dq7rsh(k, p, havqtr, qtr, r, w):
    if k >= p:
        return
    km1 = k - 1
    k1 = k * km1 // 2
    dv7cpy(k, w, _at(r, k1 + 1))
    wj = w[k]
    pm1 = p - 1
    j1 = k1 + km1
    for j in range(k, pm1 + 1):
        jm1 = j - 1
        jp1 = j + 1
        if jm1 > 0:
            dv7cpy(jm1, _at(r, k1 + 1), _at(r, j1 + 2))
        j1 = j1 + jp1
        k1 = k1 + j
        a = r[j1]
        b = r[j1 + 1]
        if b == ZERO:
            r[k1] = a
            x = ZERO
            z = ZERO
        else:
            r[k1], x, y, z = dh2rfg(a, b)
            if j != pm1:
                i1 = j1
                for i in range(jp1, pm1 + 1):
                    i1 = i1 + i
                    dh2rfa(1, _at(r, i1), _at(r, i1 + 1), x, y, z)
            if havqtr:
                dh2rfa(1, _at(qtr, j), _at(qtr, jp1), x, y, z)
        t = x * wj
        w[j] = wj + t
        wj = t * z
    w[p] = wj
    dv7cpy(p, _at(r, k1 + 1), w)


def dl7vml(n, x, l, y):
    """x = L * y (L untere Dreiecksmatrix, zeilenweise kompakt)."""
    np1 = n + 1
    i0 = n * (n + 1) // 2
    for ii in range(1, n + 1):
        i = np1 - ii
        i0 = i0 - i
        t = ZERO
        for j in range(1, i + 1):
            t = t + l[i0 + j] * y[j]
        x[i] = t


def dl7tvm(n, x, l, y):
    """x = L**T * y.

    Wie im Maschinencode von R (gfortran) wird ``x(i) = 0`` vor dem Laden von
    ``y(i)`` gespeichert; bei ``x is y`` (Aufruf in DRMNGB) ergibt sich 0.
    """
    i0 = 0
    for i in range(1, n + 1):
        x[i] = ZERO
        yi = y[i]
        for j in range(1, i + 1):
            x[j] = x[j] + yi * l[i0 + j]
        i0 = i0 + i


def dl7itv(n, x, l, y):
    """Löst L**T * x = y."""
    for i in range(1, n + 1):
        x[i] = y[i]
    np1 = n + 1
    i0 = n * (n + 1) // 2
    for ii in range(1, n + 1):
        i = np1 - ii
        xi = x[i] / l[i0]
        x[i] = xi
        if i <= 1:
            return
        i0 = i0 - i
        if xi == ZERO:
            continue
        for j in range(1, i):
            x[j] = x[j] - xi * l[i0 + j]


def dl7ivm(n, x, l, y):
    """Löst L * x = y."""
    k = 1
    while k <= n:
        if y[k] != ZERO:
            break
        x[k] = ZERO
        k += 1
    else:
        return
    j = k * (k + 1) // 2
    x[k] = y[k] / l[j]
    if k >= n:
        return
    k = k + 1
    for i in range(k, n + 1):
        t = dd7tpr(i - 1, _at(l, j + 1), x)
        j = j + i
        x[i] = (y[i] - t) / l[j]


def dw7zbf(l, n, s, w, y, z):
    eps = _F(0.1)
    dl7tvm(n, w, l, s)
    shs = dd7tpr(n, w, w)
    ys = dd7tpr(n, y, s)
    if ys >= eps * shs:
        cy = ONE / (_sqrt(ys) * _sqrt(shs))
        cs = ONE / shs
    else:
        theta = (ONE - eps) * shs / (shs - ys)
        epsrt = _sqrt(eps)
        cy = theta / (shs * epsrt)
        cs = (ONE + (theta - ONE) / epsrt) / shs
    dl7ivm(n, z, l, y)
    for i in range(1, n + 1):
        z[i] = cy * z[i] - cs * w[i]


def dl7upd(beta, gamma, l, lam, lplus, n, w, z):
    nu = ONE
    eta = ZERO
    if n > 1:
        nm1 = n - 1
        s = ZERO
        for i in range(1, nm1 + 1):
            j = n - i
            s = s + w[j + 1] * w[j + 1]
            lam[j] = s
        for j in range(1, nm1 + 1):
            wj = w[j]
            a = nu * z[j] - eta * wj
            theta = ONE + a * wj
            s = a * lam[j]
            lj = _sqrt(theta * theta + a * s)
            if theta > ZERO:
                lj = -lj
            lam[j] = lj
            b = theta * wj + s
            gamma[j] = b * nu / lj
            beta[j] = (a - b * eta) / lj
            nu = -nu / lj
            eta = -(eta + (a * a) / (theta - lj)) / lj
    lam[n] = ONE + (nu * z[n] - eta * w[n]) * w[n]
    np1 = n + 1
    jj = n * (n + 1) // 2
    for k in range(1, n + 1):
        j = np1 - k
        lj = lam[j]
        ljj = l[jj]
        lplus[jj] = lj * ljj
        wj = w[j]
        w[j] = ljj * wj
        zj = z[j]
        z[j] = ljj * zj
        if k != 1:
            bj = beta[j]
            gj = gamma[j]
            ij = jj + j
            jp1 = j + 1
            for i in range(jp1, n + 1):
                lij = l[ij]
                lplus[ij] = lj * lij + bj * w[i] + gj * z[i]
                w[i] = w[i] + lij * wj
                z[i] = z[i] + lij * zj
                ij = ij + i
        jj = jj - j


# ── DA7SST: Schritt bewerten ─────────────────────────────────────────────

def da7sst(iv, liv, lv, v):
    IRC, MLSTGD, MODEL, NFCALL_, NFGCAL_, RADINC, RESTOR, STAGE, STGLIM, SWITCH, \
        TOOBIG_, XIRC = 29, 32, 5, 6, 7, 8, 9, 10, 11, 12, 2, 13
    AFCTOL_, DECFAC, DSTNRM, DST0, DSTSAV, F_, FDIF_, FLSTGD, F0_, GTSLST, GTSTEP, \
        INCFAC, LMAXS, NREDUC, PLSTGD, PREDUC, RADFAC, RDFCMN, RDFCMX, RELDX, RFCTOL, \
        SCTOL, STPPAR, TUNER1, TUNER2, TUNER3, XCTOL, XFTOL = \
        31, 22, 2, 3, 18, 10, 11, 12, 13, 14, 4, 23, 36, 6, 15, 7, 16, 24, 25, 17, 32, \
        37, 5, 26, 27, 28, 33, 34
    nfc = iv[NFCALL_]
    iv[SWITCH] = 0
    iv[RESTOR] = 0
    rfac1 = ONE
    goodx = True
    emaxs = ZERO
    i = int(iv[IRC])
    if 1 <= i <= 12:
        lab = {1: 20, 2: 30, 3: 10, 4: 10, 5: 40, 6: 280}.get(i, 220 if i <= 11 else 170)
    else:
        iv[IRC] = 13
        return
    while True:
        if lab == 10:
            iv[STAGE] = 1
            iv[RADINC] = 0
            v[FLSTGD] = v[F0_]
            if iv[TOOBIG_] == 0:
                lab = 110
                continue
            iv[STAGE] = -1
            iv[XIRC] = i
            lab = 60
            continue
        if lab == 20:
            if iv[MODEL] != iv[MLSTGD]:
                lab = 30
                continue
            iv[STAGE] = iv[STGLIM]
            iv[RADINC] = -1
            lab = 110
            continue
        if lab == 30:
            iv[STAGE] = iv[STAGE] + 1
            lab = 40
        if lab == 40:
            if iv[STAGE] > 0:
                lab = 50
                continue
            if iv[TOOBIG_] != 0:
                lab = 60
                continue
            iv[STAGE] = -iv[STAGE]
            i = int(iv[XIRC])
            if i == 1:
                lab = 20
                continue
            if i == 2:
                lab = 30
                continue
            if i in (3, 4):
                lab = 110
                continue
            if i == 5:
                lab = 70
                continue
            lab = 50
        if lab == 50:
            if iv[TOOBIG_] == 0:
                lab = 70
                continue
            iv[TOOBIG_] = 0
            if iv[RADINC] > 0:
                lab = 80
                continue
            iv[STAGE] = -iv[STAGE]
            iv[XIRC] = iv[IRC]
            lab = 60
        if lab == 60:
            iv[TOOBIG_] = 0
            v[RADFAC] = v[DECFAC]
            iv[RADINC] = iv[RADINC] - 1
            iv[IRC] = 5
            iv[RESTOR] = 1
            v[F_] = v[FLSTGD]
            return
        if lab == 70:
            if v[F_] < v[FLSTGD]:
                lab = 110
                continue
            if iv[MODEL] != iv[MLSTGD]:
                iv[MODEL] = iv[MLSTGD]
                iv[SWITCH] = 1
            lab = 80
        if lab == 80:
            if v[FLSTGD] >= v[F0_]:
                lab = 110
                continue
            if iv[STAGE] < iv[STGLIM]:
                goodx = False
            elif nfc < iv[NFGCAL_] + iv[STGLIM] + 2:
                goodx = False
            elif iv[SWITCH] != 0:
                goodx = False
            iv[RESTOR] = 3
            v[F_] = v[FLSTGD]
            v[PREDUC] = v[PLSTGD]
            v[GTSTEP] = v[GTSLST]
            if iv[SWITCH] == 0:
                rfac1 = v[DSTNRM] / v[DSTSAV]
            v[DSTNRM] = v[DSTSAV]
            if goodx:
                v[FDIF_] = v[F0_] - v[F_]
                iv[IRC] = 4
                v[RADFAC] = rfac1
                return
            nfc = iv[NFGCAL_]
            lab = 110
        if lab == 110:
            v[FDIF_] = v[F0_] - v[F_]
            if v[FDIF_] > v[TUNER2] * v[PREDUC]:
                lab = 140
                continue
            if iv[RADINC] > 0:
                lab = 140
                continue
            if not (v[F_] < v[F0_]):
                iv[MLSTGD] = iv[MODEL]
                v[FLSTGD] = v[F_]
                v[F_] = v[F0_]
                iv[RESTOR] = 1
            else:
                iv[NFGCAL_] = nfc
            iv[IRC] = 1
            if not (iv[STAGE] < iv[STGLIM]):
                iv[IRC] = 5
                iv[RADINC] = iv[RADINC] - 1
            lab = 160
            continue
        if lab == 140:
            iv[NFGCAL_] = nfc
            rfac1 = ONE
            v[DSTSAV] = v[DSTNRM]
            if v[FDIF_] > v[PREDUC] * v[TUNER1]:
                lab = 190
                continue
            if iv[STAGE] >= iv[STGLIM]:
                iv[IRC] = 4
            else:
                iv[IRC] = 2
            lab = 160
        if lab == 160:
            iv[XIRC] = iv[IRC]
            emax = v[GTSTEP] + v[FDIF_]
            v[RADFAC] = HALF * rfac1
            if emax < v[GTSTEP]:
                v[RADFAC] = rfac1 * _max2(v[RDFCMN], HALF * v[GTSTEP] / emax)
            lab = 170
        if lab == 170:
            if v[RELDX] <= v[XFTOL]:
                iv[IRC] = 12
                lab = 240
                continue
            iv[IRC] = iv[XIRC]
            if v[F_] < v[F0_]:
                lab = 200
                continue
            lab = 230
            continue
        if lab == 190:
            if v[FDIF_] < (-v[TUNER3] * v[GTSTEP]):
                lab = 210
                continue
            if iv[RADINC] < 0 or iv[RESTOR] == 1 or iv[RESTOR] == 3:
                lab = 210
                continue
            v[RADFAC] = v[RDFCMX]
            gts = v[GTSTEP]
            if v[FDIF_] < (HALF / v[RADFAC] - ONE) * gts:
                v[RADFAC] = _max2(v[INCFAC], HALF * gts / (gts + v[FDIF_]))
            iv[IRC] = 4
            if v[STPPAR] == ZERO:
                lab = 230
                continue
            if v[DST0] >= ZERO and (v[DST0] < TWO * v[DSTNRM] or v[NREDUC] < ONEP2 * v[FDIF_]):
                lab = 230
                continue
            iv[IRC] = 5
            iv[RADINC] = iv[RADINC] + 1
            lab = 200
        if lab == 200:
            v[FLSTGD] = v[F_]
            iv[MLSTGD] = iv[MODEL]
            if iv[RESTOR] == 0:
                iv[RESTOR] = 2
            v[DSTSAV] = v[DSTNRM]
            iv[NFGCAL_] = nfc
            v[PLSTGD] = v[PREDUC]
            v[GTSLST] = v[GTSTEP]
            lab = 230
            continue
        if lab == 210:
            v[RADFAC] = ONE
            iv[IRC] = 3
            lab = 230
            continue
        if lab == 220:
            iv[IRC] = iv[XIRC]
            if not (v[DSTSAV] >= ZERO):
                iv[IRC] = 12
            lab = 240
            continue
        if lab == 230:
            iv[XIRC] = iv[IRC]
            lab = 240
        if lab == 240:
            if iv[RESTOR] == 1 and v[FLSTGD] < v[F0_]:
                iv[RESTOR] = 3
            if abs(v[F_]) < v[AFCTOL_]:
                iv[IRC] = 10
            if HALF * v[FDIF_] > v[PREDUC]:
                return
            emax = v[RFCTOL] * abs(v[F0_])
            emaxs = v[SCTOL] * abs(v[F0_])
            if v[PREDUC] <= emaxs and (v[DSTNRM] > v[LMAXS] or v[STPPAR] == ZERO):
                iv[IRC] = 11
            if not (v[DST0] < ZERO):
                i = 0
                if (v[NREDUC] > ZERO and v[NREDUC] <= emax) or \
                        (v[NREDUC] == ZERO and v[PREDUC] == ZERO):
                    i = 2
                if v[STPPAR] == ZERO and v[RELDX] <= v[XCTOL] and goodx:
                    i = i + 1
                if i > 0:
                    iv[IRC] = i + 6
            lab = 250
        if lab == 250:
            if iv[IRC] > 5 and iv[IRC] != 12:
                return
            if v[STPPAR] == ZERO:
                return
            if v[DSTNRM] > v[LMAXS]:
                lab = 260
                continue
            if v[PREDUC] >= emaxs:
                return
            if v[DST0] <= ZERO:
                lab = 270
                continue
            if HALF * v[DST0] <= v[LMAXS]:
                return
            lab = 270
            continue
        if lab == 260:
            if HALF * v[DSTNRM] <= v[LMAXS]:
                return
            xmax = v[LMAXS] / v[DSTNRM]
            if xmax * (TWO - xmax) * v[PREDUC] >= emaxs:
                return
            lab = 270
        if lab == 270:
            if v[NREDUC] < ZERO:
                lab = 290
                continue
            v[GTSLST] = v[GTSTEP]
            v[DSTSAV] = v[DSTNRM]
            if iv[IRC] == 12:
                v[DSTSAV] = -v[DSTSAV]
            v[PLSTGD] = v[PREDUC]
            i = int(iv[RESTOR])
            iv[RESTOR] = 2
            if i == 3:
                iv[RESTOR] = 0
            iv[IRC] = 6
            return
        if lab == 280:
            v[GTSTEP] = v[GTSLST]
            v[DSTNRM] = abs(v[DSTSAV])
            iv[IRC] = iv[XIRC]
            if v[DSTSAV] <= ZERO:
                iv[IRC] = 12
            v[NREDUC] = -v[PREDUC]
            v[PREDUC] = v[PLSTGD]
            iv[RESTOR] = 3
            lab = 290
        if lab == 290:
            if -v[NREDUC] <= v[SCTOL] * abs(v[F0_]):
                iv[IRC] = 11
            return
        raise RuntimeError("da7sst: Marke %r" % lab)


# ── Doppel-Dogleg-Schritte ───────────────────────────────────────────────

def dd7dog(dig, lv, n, nwtstp, step, v):
    BIAS, DGNORM, DSTNRM, DST0, GRDFAC, GTHG, GTSTEP, NREDUC, NWTFAC, PREDUC, \
        RADIUS, STPPAR = 43, 1, 2, 3, 45, 44, 4, 6, 46, 7, 8, 5
    nwtnrm = v[DST0]
    rlambd = ONE
    if nwtnrm > ZERO:
        rlambd = v[RADIUS] / nwtnrm
    gnorm = v[DGNORM]
    ghinvg = TWO * v[NREDUC]
    v[GRDFAC] = ZERO
    v[NWTFAC] = ZERO
    if not (rlambd < ONE):
        v[STPPAR] = ZERO
        v[DSTNRM] = nwtnrm
        v[GTSTEP] = -ghinvg
        v[PREDUC] = v[NREDUC]
        v[NWTFAC] = -ONE
        for i in range(1, n + 1):
            step[i] = -nwtstp[i]
        return
    v[DSTNRM] = v[RADIUS]
    cfact = gnorm / v[GTHG]
    cfact = cfact * cfact
    cnorm = gnorm * cfact
    relax = ONE - v[BIAS] * (ONE - gnorm * cnorm / ghinvg)
    if not (rlambd < relax):
        v[STPPAR] = ONE - (rlambd - relax) / (ONE - relax)
        t = -rlambd
        v[GTSTEP] = t * ghinvg
        v[PREDUC] = rlambd * (ONE - HALF * rlambd) * ghinvg
        v[NWTFAC] = t
        for i in range(1, n + 1):
            step[i] = t * nwtstp[i]
        return
    if not (cnorm < v[RADIUS]):
        t = -v[RADIUS] / gnorm
        v[GRDFAC] = t
        v[STPPAR] = ONE + cnorm / v[RADIUS]
        v[GTSTEP] = -v[RADIUS] * gnorm
        q = v[GTHG] / gnorm
        v[PREDUC] = v[RADIUS] * (gnorm - HALF * v[RADIUS] * (q * q))
        for i in range(1, n + 1):
            step[i] = t * dig[i]
        return
    ctrnwt = cfact * relax * ghinvg / gnorm
    t1 = ctrnwt - gnorm * (cfact * cfact)
    t2 = v[RADIUS] * (v[RADIUS] / gnorm) - gnorm * (cfact * cfact)
    t = relax * nwtnrm
    femnsq = (t / gnorm) * t - ctrnwt - t1
    t = t2 / (t1 + _sqrt(t1 * t1 + femnsq * t2))
    t1 = (t - ONE) * cfact
    v[GRDFAC] = t1
    t2 = -t * relax
    v[NWTFAC] = t2
    v[STPPAR] = TWO - t
    v[GTSTEP] = t1 * (gnorm * gnorm) + t2 * ghinvg
    q = v[GTHG] * t1
    v[PREDUC] = -t1 * gnorm * ((t2 + ONE) * gnorm) - t2 * (ONE + HALF * t2) * ghinvg - HALF * (q * q)
    for i in range(1, n + 1):
        step[i] = t1 * dig[i] + t2 * nwtstp[i]


_MEPS2 = TWO * _DBL_EPS


def dd7dgb(b, d, dig, dst, g, ipiv, ka, l, lv, p, pc, nwtst, step, td, tg, v, w, x0):
    """Doppel-Dogleg mit Schranken; liefert das neue ``ka``."""
    DGNORM, DST0, DSTNRM, GRDFAC, GTHG, GTSTEP, NREDUC, NWTFAC, PREDUC, RADIUS, \
        STPPAR = 1, 3, 2, 45, 44, 4, 6, 46, 7, 8, 5
    meps2 = _MEPS2
    gnorm0 = v[DGNORM]
    v[DSTNRM] = ZERO
    # NRED ist in Fortran undefiniert, wenn ka < 0 und pc <= 0 (Stapelrest in R);
    # +0 ergibt dieselbe Konvergenzentscheidung wie ein positiver Rest.
    dnwtst = nred = ZERO
    if ka >= 0:
        dnwtst = v[DST0]
        nred = v[NREDUC]
    pred = ZERO
    v[STPPAR] = ZERO
    rad = v[RADIUS]
    gnorm = ZERO
    if pc <= 0:
        dnwtst = ZERO
        dv7scp(p, step, ZERO)
        p1 = 0
        lab = 140
    else:
        p1 = pc
        dv7cpy(p, td, d)
        dv7ipr(p, ipiv, td)
        dv7scp(pc, dst, ZERO)
        dv7cpy(p, tg, g)
        dv7ipr(p, ipiv, tg)
        lab = 30
    while lab == 30:
        dl7ivm(p1, nwtst, l, tg)
        ghinvg = dd7tpr(p1, nwtst, nwtst)
        v[NREDUC] = HALF * ghinvg
        dl7itv(p1, nwtst, l, nwtst)
        dv7vmp(p1, step, nwtst, td, 1)
        v[DST0] = dv2nrm(pc, step)
        if ka < 0:
            ka = 0
            dnwtst = v[DST0]
            nred = v[NREDUC]
        v[RADIUS] = rad - v[DSTNRM]
        if v[RADIUS] <= ZERO:
            lab = 100
            break
        dv7vmp(p1, dig, tg, td, -1)
        gnorm = dv2nrm(p1, dig)
        if gnorm <= ZERO:
            lab = 100
            break
        v[DGNORM] = gnorm
        dv7vmp(p1, dig, dig, td, -1)
        dl7tvm(p1, w, l, dig)
        v[GTHG] = dv2nrm(p1, w)
        ka = ka + 1
        dd7dog(dig, lv, p1, nwtst, step, v)
        t = ONE
        k = 0
        for i in range(1, p1 + 1):
            j = int(ipiv[i])
            x0i = x0[j] + dst[i] / td[i]
            xi = x0i + step[i]
            if xi < b[2 * j - 1]:
                ti = (b[2 * j - 1] - x0i) / step[i]
                j = -i
            elif xi <= b[2 * j]:
                continue
            else:
                ti = (b[2 * j] - x0i) / step[i]
                j = i
            if t <= ti:
                continue
            k = j
            t = ti
        dv7vmp(p1, step, step, td, 1)
        dv2axy(p1, dst, t, step, dst)
        v[DSTNRM] = dv2nrm(pc, dst)
        t1 = t * v[GRDFAC]
        t2 = t * v[NWTFAC]
        q = v[GTHG] * t1
        pred = pred - t1 * gnorm * ((t2 + ONE) * gnorm) - t2 * (ONE + HALF * t2) * ghinvg - \
            HALF * (q * q)
        if k == 0:
            lab = 100
            break
        dl7vml(p1, w, l, w)
        t2 = ONE - t2
        for i in range(1, p1 + 1):
            tg[i] = t2 * tg[i] - t1 * w[i]
        p1m1 = p1 - 1
        j = abs(k)
        if j != p1:
            dq7rsh(j, p1, False, tg, l, w)
            i7shft(p1, j, ipiv)
            dv7shf(p1, j, tg)
            dv7shf(p1, j, td)
            dv7shf(p1, j, dst)
        if k < 0:
            ipiv[p1] = -ipiv[p1]
        p1 = p1m1
        if p1 > 0:
            lab = 30
        else:
            lab = 100
    if lab == 100:
        dv7scp(p, step, ZERO)
        for i in range(1, pc + 1):
            j = abs(int(ipiv[i]))
            step[j] = dst[i] / td[i]
        if p1 < pc:
            dv2axy(p, td, ONE, step, x0)
            k = p1 + 1
            for i in range(k, pc + 1):
                j = int(ipiv[i])
                t = meps2
                if not (j > 0):
                    t = -t
                    j = -j
                    ipiv[i] = j
                t = t * _max1(abs(td[j]), abs(x0[j]))
                step[j] = step[j] + t
    v[DGNORM] = gnorm0
    v[NREDUC] = nred
    v[PREDUC] = pred
    v[RADIUS] = rad
    v[DST0] = dnwtst
    v[GTSTEP] = dd7tpr(p, step, g)
    return ka


# ── Finite-Differenzen-Gradient (Stewart) mit Schranken ──────────────────

def ds3grd(alpha, b, d, eta0, fx, g, irc, p, w, x):
    """DS3GRD; liefert (fx, irc)."""
    C2000, HMAX0, HMIN0, P002 = _F(2.0e3), _F(0.02), _F(5.0e1), _F(0.002)
    FH, FX0, HSAVE, XISAVE = 3, 4, 5, 6
    if irc < 0:
        lab = 80
    elif irc > 0:
        lab = 210
    else:
        w[1] = dr7mdc(3)
        w[2] = _sqrt(w[1])
        w[FX0] = fx
        lab = 20
    i = 0
    h = xih = xi = axibar = alphai = gi = ZERO
    hit = False
    while True:
        if lab == 20:
            i = abs(irc) + 1
            if i > p:
                irc = 0
                fx = w[FX0]
                return fx, irc
            irc = i
            if not (b[2 * i - 1] < b[2 * i]):
                g[i] = ZERO
                continue
            afx = abs(w[FX0])
            machep = w[1]
            h0 = w[2]
            hmin = HMIN0 * machep
            xi = x[i]
            w[XISAVE] = xi
            axi = abs(xi)
            axibar = _max2(axi, ONE / d[i])
            gi = g[i]
            agi = abs(gi)
            eta = abs(eta0)
            if afx > ZERO:
                eta = _max1(eta, agi * axi * machep / afx)
            alphai = alpha[i]
            if alphai == ZERO:
                h = axibar
                lab = 150
                continue
            if gi == ZERO or fx == ZERO:
                h = h0 * axibar
                lab = 150
                continue
            afxeta = afx * eta
            aai = abs(alphai)
            if not (gi * gi <= afxeta * aai):
                h = TWO * _sqrt(afxeta / aai)
                h = h * (ONE - aai * h / (THREE * aai * h + FOUR * agi))
            else:
                h = TWO * _pow(afxeta * agi, ONE / THREE) * _pow(aai, -TWO / THREE)
                h = h * (ONE - TWO * agi / (THREE * aai * h + FOUR * agi))
            h = _max1(h, hmin * axibar)
            if aai * h <= P002 * agi:
                if h >= HMAX0 * axibar:
                    h = h0 * axibar
                if alphai * gi < ZERO:
                    h = -h
                lab = 150
                continue
            discon = C2000 * afxeta
            h = discon / (agi + _sqrt(gi * gi + aai * discon))
            h = _max1(h, hmin * axibar)
            if h >= HMAX0 * axibar:
                h = axibar * _pow(h0, TWO / THREE)
            xih = xi + h
            if xi - h < b[2 * i - 1]:
                if xi + TWO * h > b[2 * i]:
                    lab = 190
                    continue
                lab = 70
                continue
            irc = -i
            if xih <= b[2 * i]:
                lab = 200
                continue
            h = -h
            xih = xi + h
            if xi + TWO * h < b[2 * i - 1]:
                lab = 190
                continue
            lab = 70
            continue
        if lab == 70:
            irc = -(i + p)
            lab = 200
            continue
        if lab == 80:
            i = -irc
            if i <= p:
                h = -w[HSAVE]
                if h > ZERO:
                    g[i] = (w[FH] - fx) / (TWO * h)
                    x[i] = w[XISAVE]
                    lab = 20
                    continue
                w[FH] = fx
                xih = w[XISAVE] + h
                lab = 200
                continue
            i = i - p
            if i <= p:
                w[FH] = fx
                h = TWO * w[HSAVE]
                xih = w[XISAVE] + h
                irc = irc - p
                lab = 200
                continue
            i = i - p
            g[i] = (FOUR * w[FH] - fx - THREE * w[FX0]) / w[HSAVE]
            irc = i
            x[i] = w[XISAVE]
            lab = 20
            continue
        if lab == 150:
            hit = False
            lab = 160
        if lab == 160:
            xih = xi + h
            if h > ZERO:
                if xih <= b[2 * i]:
                    lab = 200
                    continue
            else:
                if xih >= b[2 * i - 1]:
                    lab = 200
                    continue
            if hit:
                lab = 190
                continue
            hit = True
            h = -h
            continue
        if lab == 190:
            irc = i + p
            fx = w[FX0]
            return fx, irc
        if lab == 200:
            x[i] = xih
            w[HSAVE] = h
            return fx, irc
        if lab == 210:
            g[irc] = (fx - w[FX0]) / w[HSAVE]
            x[irc] = w[XISAVE]
            lab = 20
            continue
        raise RuntimeError("ds3grd: Marke %r" % lab)


# ── DPARCK: Parameter prüfen ─────────────────────────────────────────────

def _vmvx():
    vm = [ZERO] * 35
    vx = [ZERO] * 35
    for k, val in {1: 1.0e-3, 2: -0.99, 3: 1.0e-3, 4: 1.0e-2, 5: 1.2, 6: 1.e-2, 7: 1.2, 8: 0.0,
                   9: 0.0, 10: 1.e-3, 11: -1.0, 13: 0.0, 15: 0.0, 16: 0.0, 19: 0.0, 20: -10.0,
                   21: 0.0, 22: 0.0, 23: 0.0, 27: 1.01, 28: 1.e10, 30: 0.0, 31: 0.0, 32: 0.0,
                   34: 0.0}.items():
        vm[k] = _F(val)
    for k, val in {1: 0.9, 2: -1.e-3, 3: 1.e1, 4: 0.8, 5: 1.e2, 6: 0.8, 7: 1.e2, 8: 0.5,
                   9: 0.5, 10: 1.0, 11: 1.0, 14: 0.1, 15: 1.0, 16: 1.0, 19: 1.0, 23: 1.0,
                   24: 1.0, 25: 1.0, 26: 1.0, 27: 1.e10, 29: 1.0, 31: 1.0, 32: 1.0, 33: 1.0,
                   34: 1.0}.items():
        vx[k] = _F(val)
    tiny = dr7mdc(1)
    machep = dr7mdc(3)
    big = dr7mdc(6)
    vm[12] = machep
    vx[12] = big
    vx[13] = big
    vm[14] = machep
    vm[17] = tiny
    vx[17] = big
    vm[18] = tiny
    vx[18] = big
    vx[20] = big
    vx[21] = big
    vx[22] = big
    vm[24] = machep
    vm[25] = machep
    vm[26] = machep
    vx[28] = dr7mdc(5)
    vm[29] = machep
    vx[30] = big
    vm[33] = machep
    return vm, vx


_VM, _VX = _vmvx()


def dparck(alg, d, iv, liv, lv, n, v):
    ALGSAV_, DINIT, DTYPE_, DTYPE0, EPSLON, INITS_, IVNEED_, LASTIV_, LASTV_, LMAT_, \
        NEXTIV, NEXTV_, NVDFLT_, OLDN, PARPRT_, PARSAV_, PERM_, PRUNIT_, VNEED_ = \
        51, 38, 16, 54, 19, 25, 3, 44, 45, 42, 46, 47, 50, 38, 20, 49, 58, 21, 4
    jlim = (0, 0, 24, 0, 24)
    ndflt = (0, 32, 25, 32, 25)
    miniv = (0, 82, 59, 103, 103)
    ijmp = 33
    pu = 0
    if PRUNIT_ <= liv:
        pu = iv[PRUNIT_]
    if not (ALGSAV_ > liv) and alg != iv[ALGSAV_]:
        iv[1] = 67
        return
    if alg < 1 or alg > 4:
        iv[1] = 67
        return
    miv1 = miniv[alg]
    if iv[1] == 15:
        if LASTIV_ <= liv:
            iv[LASTIV_] = miv1
        if LASTV_ <= liv:
            iv[LASTV_] = 0
        return
    alg1 = (alg - 1) % 2 + 1
    if iv[1] == 0:
        divset(alg, iv, liv, lv, v)
    iv1 = int(iv[1])
    if iv1 == 13 or iv1 == 12:
        miv2 = miv1
        if PERM_ <= liv:
            miv1 = max(miv1, int(iv[PERM_]) - 1)
        if IVNEED_ <= liv:
            miv2 = miv1 + max(int(iv[IVNEED_]), 0)
        if LASTIV_ <= liv:
            iv[LASTIV_] = miv2
        if liv < miv1:
            return _dparck300(iv, liv, lv, pu, miv1)
        iv[IVNEED_] = 0
        iv[LASTV_] = max(int(iv[VNEED_]), 0) + iv[LMAT_] - 1
        iv[VNEED_] = 0
        if liv < miv2:
            return _dparck300(iv, liv, lv, pu, miv1)
        if lv < iv[LASTV_]:
            iv[1] = 16
            return
    if 12 <= iv1 <= 14:
        if n < 1:
            iv[1] = 81
            return
        if iv1 != 14:
            iv[NEXTIV] = iv[PERM_]
        if iv1 != 14:
            iv[NEXTV_] = iv[LMAT_]
        if iv1 == 13:
            return
        k = int(iv[PARSAV_]) - EPSLON
        dv7dfl(alg1, lv - k, _at(v, k + 1))
        iv[DTYPE0] = 2 - alg1
        iv[OLDN] = n
    else:
        if n != iv[OLDN]:
            iv[1] = 17
            return
        if not (1 <= iv1 <= 11):
            iv[1] = 80
            return
    if iv1 == 14:
        iv1 = 12
    m = 0
    i = 1
    j = jlim[alg1]
    k = EPSLON
    ndfalt = ndflt[alg1]
    for _ in range(ndfalt):
        vk = v[k]
        if not (vk >= _VM[i] and vk <= _VX[i]):
            m = k
        k = k + 1
        i = i + 1
        if i == j:
            i = ijmp
    if iv[NVDFLT_] != ndfalt:
        iv[1] = 51
        return
    if not ((iv[DTYPE_] > 0 or v[DINIT] > ZERO) and iv1 == 12):
        for i in range(1, n + 1):
            if not (d[i] > ZERO):
                m = 18
    if m != 0:
        iv[1] = m
        return
    # pu == 0 in R: keine Ausgabe der geänderten Werte
    if pu == 0 or iv[PARPRT_] == 0:
        return
    iv[DTYPE0] = iv[DTYPE_]
    parsv1 = int(iv[PARSAV_])
    dv7cpy(int(iv[NVDFLT_]), _at(v, parsv1), _at(v, EPSLON))


def _dparck300(iv, liv, lv, pu, miv1):
    iv[1] = 15
    if pu == 0:
        return
    if liv < miv1:
        return
    if lv < iv[45]:
        iv[1] = 16


# ── DRMNGB: Iterationen mit Schranken (Gradient vom Aufrufer) ────────────

def drmngb(b, d, fx, g, iv, liv, lv, n, v, x):
    CNVCOD, DG, INITH_, IRC, IVNEED_, KAGQT, MODE, MODEL, MXFCAL_, MXITER_, NC, \
        NEXTIV, NEXTV_, NFCALL_, NFGCAL_, NGCALL, NITER_, NWTSTP, PERM_, RADINC, RESTOR, \
        STEP, STGLIM, STLSTG, TOOBIG_, XIRC, X0 = \
        55, 37, 25, 29, 3, 33, 35, 5, 17, 18, 48, 46, 47, 6, 7, 30, 31, 34, 58, 8, 9, \
        40, 11, 41, 2, 13, 43
    DGNORM, DINIT, DSTNRM, F_, F0_, FDIF_, GTSTEP, INCFAC, LMAT_, LMAX0, LMAXS, PREDUC, \
        RADFAC, RADIUS, RAD0, RELDX, TUNER4, TUNER5, VNEED_ = \
        1, 38, 2, 10, 13, 11, 4, 23, 42, 35, 36, 7, 16, 8, 9, 17, 29, 30, 4
    rstrst = 0
    i = int(iv[1])
    if i == 1:
        lab = 70
    elif i == 2:
        lab = 80
    else:
        if iv[1] == 0:
            divset(2, iv, liv, lv, v)
        if 12 <= iv[1] <= 13:
            iv[VNEED_] = iv[VNEED_] + n * (n + 19) // 2
            iv[IVNEED_] = iv[IVNEED_] + n
        dparck(2, d, iv, liv, lv, n, v)
        i = int(iv[1]) - 2
        if i > 12:
            return
        if 1 <= i <= 6:
            lab = 250
        elif i in (7, 9):
            lab = 190
        elif i == 8:
            lab = 150
        elif i == 12:
            lab = 30
        else:
            lab = 20
    while True:
        if lab == 20:
            l = int(iv[LMAT_])
            iv[X0] = l + n * (n + 1) // 2
            iv[STEP] = iv[X0] + 2 * n
            iv[STLSTG] = iv[STEP] + 2 * n
            iv[NWTSTP] = iv[STLSTG] + n
            iv[DG] = iv[NWTSTP] + 2 * n
            iv[NEXTV_] = iv[DG] + 2 * n
            iv[NEXTIV] = iv[PERM_] + n
            if iv[1] == 13:
                iv[1] = 14
                return
            lab = 30
        if lab == 30:
            iv[NITER_] = 0
            iv[NFCALL_] = 1
            iv[NGCALL] = 1
            iv[NFGCAL_] = 1
            iv[MODE] = -1
            iv[MODEL] = 1
            iv[STGLIM] = 1
            iv[TOOBIG_] = 0
            iv[CNVCOD] = 0
            iv[RADINC] = 0
            iv[NC] = n
            v[RAD0] = ZERO
            ipi = int(iv[PERM_])
            bad = False
            for i in range(1, n + 1):
                iv[ipi] = i
                ipi = ipi + 1
                if b[2 * i - 1] > b[2 * i]:
                    bad = True
                    break
            if bad:
                iv[1] = 82
                lab = 430
                continue
            if v[DINIT] >= ZERO:
                dv7scp(n, d, v[DINIT])
            if iv[INITH_] == 1:
                l = int(iv[LMAT_])
                dv7scp(n * (n + 1) // 2, _at(v, l), ZERO)
                k = l - 1
                for i in range(1, n + 1):
                    k = k + i
                    t = d[i]
                    if t <= ZERO:
                        t = ONE
                    v[k] = t
            iv[1] = 1
            lab = 440
            continue
        if lab == 70:
            v[F_] = fx
            if iv[MODE] >= 0:
                lab = 250
                continue
            v[F0_] = fx
            iv[1] = 2
            if iv[TOOBIG_] == 0:
                return
            iv[1] = 63
            lab = 430
            continue
        if lab == 80:
            if iv[TOOBIG_] != 0:
                iv[1] = 65
                lab = 430
                continue
            ipi = int(iv[PERM_])
            ipn = ipi + n
            n1 = n
            np1 = n + 1
            l = int(iv[LMAT_])
            w1 = int(iv[NWTSTP]) + n
            k = n - int(iv[NC])
            for i in range(1, n + 1):
                ipn = ipn - 1
                j = int(iv[ipn])
                if not (b[2 * j - 1] >= b[2 * j]):
                    xi = x[j]
                    gi = g[j]
                    if not ((xi <= b[2 * j - 1] and gi > ZERO) or (xi >= b[2 * j] and gi < ZERO)):
                        if i <= k:
                            iv[CNVCOD] = 0
                        continue
                i1 = np1 - i
                if i1 < n1:
                    i7shft(n1, i1, _at(iv, ipi))
                    dq7rsh(i1, n1, False, g, _at(v, l), _at(v, w1))
                n1 = n1 - 1
            iv[NC] = n1
            v[DGNORM] = ZERO
            if n1 > 0:
                dg1 = int(iv[DG])
                dv7vmp(n, _at(v, dg1), g, d, -1)
                dv7ipr(n, _at(iv, ipi), _at(v, dg1))
                v[DGNORM] = dv2nrm(n1, _at(v, dg1))
            if iv[CNVCOD] != 0:
                lab = 420
                continue
            if iv[MODE] == 0:
                lab = 370
                continue
            v[RADIUS] = v[LMAX0]
            iv[MODE] = 0
            lab = 140
        if lab == 140:
            ditsum(d, g, iv, liv, lv, n, v, x)
            lab = 150
        if lab == 150:
            k = int(iv[NITER_])
            if not (k < iv[MXITER_]):
                iv[1] = 10
                lab = 430
                continue
            lab = 160
        if lab == 160:
            iv[NITER_] = k + 1
            if k != 0:
                t = v[RADFAC] * v[DSTNRM]
                if v[RADFAC] < ONE or t > v[RADIUS]:
                    v[RADIUS] = t
            x01 = int(iv[X0])
            v[F0_] = v[F_]
            iv[IRC] = 4
            iv[KAGQT] = -1
            dv7cpy(n, _at(v, x01), x)
            lab = 180
        if lab == 180:
            # STOPX() ist in R immer .FALSE.
            lab = 200
        if lab == 190:
            if v[F_] >= v[F0_]:
                lab = 200
            else:
                v[RADFAC] = ONE
                k = int(iv[NITER_])
                lab = 160
                continue
        if lab == 200:
            if not (iv[NFCALL_] < iv[MXFCAL_]):
                iv[1] = 9
                if v[F_] >= v[F0_]:
                    lab = 430
                    continue
                iv[CNVCOD] = iv[1]
                lab = 360
                continue
            lab = 220
        if lab == 220:
            step1 = int(iv[STEP])
            dg1 = int(iv[DG])
            nwtst1 = int(iv[NWTSTP])
            w1 = nwtst1 + n
            dstep1 = step1 + n
            ipi = int(iv[PERM_])
            l = int(iv[LMAT_])
            tg1 = dg1 + n
            x01 = int(iv[X0])
            td1 = x01 + n
            iv[KAGQT] = dd7dgb(b, d, _at(v, dg1), _at(v, dstep1), g, _at(iv, ipi), int(iv[KAGQT]),
                               _at(v, l), lv, n, int(iv[NC]), _at(v, nwtst1), _at(v, step1),
                               _at(v, td1), _at(v, tg1), v, _at(v, w1), _at(v, x01))
            if iv[IRC] == 6:
                if iv[RESTOR] != 2:
                    lab = 250
                    continue
                rstrst = 2
                lab = 260
                continue
            iv[TOOBIG_] = 0
            if v[DSTNRM] <= ZERO:
                lab = 250
                continue
            if iv[IRC] == 5 and not (v[RADFAC] <= ONE) and not (v[PREDUC] > ONEP2 * v[FDIF_]):
                if iv[RESTOR] != 2:
                    lab = 250
                    continue
                rstrst = 0
                lab = 260
                continue
            dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
            iv[NFCALL_] = iv[NFCALL_] + 1
            iv[1] = 1
            lab = 440
            continue
        if lab == 250:
            rstrst = 3
            lab = 260
        if lab == 260:
            x01 = int(iv[X0])
            v[RELDX] = drldst(n, d, x, _at(v, x01))
            da7sst(iv, liv, lv, v)
            step1 = int(iv[STEP])
            lstgst = int(iv[STLSTG])
            i = int(iv[RESTOR]) + 1
            if i == 2:
                dv7cpy(n, x, _at(v, x01))
            elif i == 3:
                dv7cpy(n, _at(v, lstgst), x)
            elif i == 4:
                dv7cpy(n, x, _at(v, lstgst))
                dv2axy(n, _at(v, step1), NEGONE, _at(v, x01), x)
                v[RELDX] = drldst(n, d, x, _at(v, x01))
                iv[RESTOR] = rstrst
            k = int(iv[IRC])
            if k in (1, 5):
                v[RADIUS] = v[RADFAC] * v[DSTNRM]
                lab = 180
                continue
            if k in (2, 3, 4):
                lab = 340
                continue
            if k == 6:
                v[RADIUS] = v[LMAXS]
                lab = 220
                continue
            if 7 <= k <= 12:
                iv[CNVCOD] = k - 4
                if v[F_] >= v[F0_]:
                    lab = 420
                    continue
                if iv[XIRC] == 14:
                    lab = 420
                    continue
                iv[XIRC] = 14
                lab = 340
                continue
            if k == 13:
                iv[1] = 64
                lab = 430
                continue
            if k == 14:
                lab = 370
                continue
            # sonst: weiter bei 310
            v[RADIUS] = v[RADFAC] * v[DSTNRM]
            lab = 180
            continue
        if lab == 340:
            x01 = int(iv[X0])
            step1 = int(iv[STEP])
            dv2axy(n, _at(v, step1), NEGONE, _at(v, x01), x)
            if iv[IRC] == 3:
                ipi = int(iv[PERM_])
                dv7cpy(n, _at(v, x01), _at(v, step1))
                dv7ipr(n, _at(iv, ipi), _at(v, x01))
                l = int(iv[LMAT_])
                dl7tvm(n, _at(v, x01), _at(v, l), _at(v, x01))
                dl7vml(n, _at(v, x01), _at(v, l), _at(v, x01))
                temp1 = int(iv[STLSTG])
                temp0 = temp1 - 1
                for i in range(1, n + 1):
                    j = int(iv[ipi])
                    ipi = ipi + 1
                    k = temp0 + j
                    v[k] = v[x01]
                    x01 = x01 + 1
            lab = 360
        if lab == 360:
            g01 = int(iv[NWTSTP]) + n
            dv7cpy(n, _at(v, g01), g)
            iv[NGCALL] = iv[NGCALL] + 1
            iv[TOOBIG_] = 0
            iv[1] = 2
            return
        if lab == 370:
            g01 = int(iv[NWTSTP]) + n
            dv2axy(n, _at(v, g01), NEGONE, _at(v, g01), g)
            step1 = int(iv[STEP])
            temp1 = int(iv[STLSTG])
            if iv[IRC] == 3:
                dv2axy(n, _at(v, temp1), NEGONE, _at(v, g01), _at(v, temp1))
                dv7vmp(n, _at(v, temp1), _at(v, temp1), d, -1)
                if dv2nrm(n, _at(v, temp1)) <= v[DGNORM] * v[TUNER4] or \
                        not (dd7tpr(n, g, _at(v, step1)) >= v[GTSTEP] * v[TUNER5]):
                    v[RADFAC] = v[INCFAC]
            w1 = int(iv[NWTSTP])
            z = int(iv[X0])
            l = int(iv[LMAT_])
            ipi = int(iv[PERM_])
            dv7ipr(n, _at(iv, ipi), _at(v, step1))
            dv7ipr(n, _at(iv, ipi), _at(v, g01))
            dw7zbf(_at(v, l), n, _at(v, step1), _at(v, w1), _at(v, g01), _at(v, z))
            dl7upd(_at(v, temp1), _at(v, step1), _at(v, l), _at(v, g01), _at(v, l), n,
                   _at(v, w1), _at(v, z))
            iv[1] = 2
            lab = 140
            continue
        if lab == 420:
            iv[1] = iv[CNVCOD]
            iv[CNVCOD] = 0
            lab = 430
        if lab == 430:
            ditsum(d, g, iv, liv, lv, n, v, x)
            return
        if lab == 440:
            for i in range(1, n + 1):
                if x[i] < b[2 * i - 1]:
                    x[i] = b[2 * i - 1]
                if x[i] > b[2 * i]:
                    x[i] = b[2 * i]
            return
        raise RuntimeError("drmngb: Marke %r" % lab)


# ── DRMNFB: ohne Gradient, mit Schranken ─────────────────────────────────

def drmnfb(b, d, fx, iv, liv, lv, p, v, x):
    ETA0, F_, G_, LMAT_, NEXTV_, NGCALL, NITER_, PERM_, SGIRC, TOOBIG_, VNEED_ = \
        42, 10, 28, 42, 47, 30, 31, 58, 57, 2, 4
    iv1 = int(iv[1])
    if iv1 == 1:
        lab = 10
    elif iv1 == 2:
        lab = 50
    else:
        if iv[1] == 0:
            divset(2, iv, liv, lv, v)
        iv1 = int(iv[1])
        if iv1 == 12 or iv1 == 13:
            iv[VNEED_] = iv[VNEED_] + 2 * p + 6
        if iv1 == 14 or (2 < iv1 < 12):
            lab = 10
        else:
            g1 = 1
            if iv1 == 12:
                iv[1] = 13
            lab = 20
    while True:
        if lab == 10:
            g1 = int(iv[G_])
            lab = 20
        if lab == 20:
            drmngb(b, d, fx, _at(v, g1), iv, liv, lv, p, v, x)
            if iv[1] < 2:
                return
            if iv[1] > 2:
                if iv[1] != 14:
                    return
                iv[G_] = iv[NEXTV_] + p + 6
                iv[NEXTV_] = iv[G_] + p
                if iv1 != 13:
                    lab = 10
                    continue
                return
            if iv[NITER_] == 0:
                dv7scp(p, _at(v, g1), ZERO)
            j = int(iv[LMAT_])
            alpha0 = g1 - p - 1
            ipi = int(iv[PERM_])
            for i in range(1, p + 1):
                k = alpha0 + int(iv[ipi])
                v[k] = dd7tpr(i, _at(v, j), _at(v, j))
                ipi = ipi + 1
                j = j + i
            iv[NGCALL] = iv[NGCALL] - 1
            iv[SGIRC] = 0
            fx = v[F_]
            lab = 60
        if lab == 50:
            if iv[TOOBIG_] != 0:
                lab = 10
                continue
            lab = 60
        if lab == 60:
            g1 = int(iv[G_])
            alpha = g1 - p
            w = alpha - 6
            fx, irc = ds3grd(_at(v, alpha), b, d, v[ETA0], fx, _at(v, g1), int(iv[SGIRC]), p,
                             _at(v, w), x)
            iv[SGIRC] = irc
            i = irc
            if i == 0:
                lab = 10
                continue
            if i > p:
                iv[TOOBIG_] = 1
                lab = 10
                continue
            iv[NGCALL] = iv[NGCALL] + 1
            return
        raise RuntimeError("drmnfb: Marke %r" % lab)


# ── port.c: Treiber ──────────────────────────────────────────────────────

def nlminb_iterate(b, d, fx, g, h, iv, liv, lv, n, v, x):
    fx = _F(fx)
    if b is not None:
        if g is not None:
            if h is not None:
                drmnhb(b, d, fx, g, h, iv, liv, lv, n, v, x)
            else:
                drmngb(b, d, fx, g, iv, liv, lv, n, v, x)
        else:
            drmnfb(b, d, fx, iv, liv, lv, n, v, x)
    else:
        if g is not None:
            if h is not None:
                drmnh(d, fx, g, h, iv, liv, lv, n, v, x)
            else:
                drmng(d, fx, g, iv, liv, lv, n, v, x)
        else:
            drmnf(d, fx, iv, liv, lv, n, v, x)


def _as_real(val):
    """``asReal`` einer R-Rückgabe (erstes Element; leer/NULL -> NA)."""
    if val is None:
        return NA_REAL
    if isinstance(val, (pd.Series, pd.DataFrame)):
        val = val.to_numpy()
    if isinstance(val, (bool, np.bool_)):
        return 1.0 if val else 0.0
    if isinstance(val, (int, float, np.integer, np.floating)):
        return float(val)
    a = np.asarray(val)
    if a.size == 0:
        return NA_REAL
    e = a.ravel()[0]
    if isinstance(e, (str, np.str_)):
        try:
            return float(e)
        except ValueError:
            warnings.warn("NAs introduced by coercion", stacklevel=4)
            return NA_REAL
    if e is None:
        return NA_REAL
    return float(e)


def _num_vec(val):
    if isinstance(val, (pd.Series, pd.DataFrame)):
        val = val.to_numpy()
    return np.atleast_1d(np.asarray(val, dtype=np.float64)).ravel()


def _check_gv(gr, hs, xw, n, g, h):
    """``check_gv`` aus port.c (Gradient und ggf. Hesse-Matrix holen und prüfen)."""
    gv = _num_vec(gr(xw()))
    if gv.size != n:
        raise RError("gradient function must return a numeric vector of length %d" % n)
    g[1:n + 1] = gv
    for i in range(1, n + 1):
        if g[i] != g[i]:
            raise RError("NA/NaN gradient evaluation")
    if h is not None:
        hv = hs(xw())
        if isinstance(hv, pd.DataFrame):
            hv = hv.to_numpy()
        # port.c ruft REAL() vor der Prüfung auf: integer/logical -> R-Fehler
        kind = None
        if isinstance(hv, (bool, np.bool_)) or (isinstance(hv, np.ndarray) and hv.dtype.kind == "b"):
            kind = "logical"
        elif isinstance(hv, (int, np.integer)) or (isinstance(hv, np.ndarray) and hv.dtype.kind in "iu"):
            kind = "integer"
        elif isinstance(hv, str) or (isinstance(hv, np.ndarray) and hv.dtype.kind in "USO"):
            kind = "character"
        if kind is not None:
            raise RError("REAL() can only be applied to a 'numeric', not a '%s'" % kind)
        ok = isinstance(hv, np.ndarray) and hv.ndim == 2 and hv.shape == (n, n) and \
            hv.dtype.kind == "f"
        if not ok:
            raise RError("Hessian function must return a square numeric matrix of order %d" % n)
        pos = 1
        for i in range(n):
            for j in range(i + 1):
                h[pos] = hv[i, j]
                if h[pos] != h[pos]:
                    raise RError("NA/NaN Hessian evaluation")
                pos += 1


def port_nlminb(fn, gr, hs, low, upp, d, iv, v, x0, names):
    """``port_nlminb`` aus port.c; ``iv``/``v`` 1-basiert (werden verändert).

    ``fn``, ``gr``, ``hs`` sind Funktionen eines Parametervektors; ``low``/
    ``upp`` ``None`` oder Länge n; liefert den End-``par`` (ndarray).
    """
    n = int(d.size)
    if n < 1:
        raise RError("'d' must be a nonempty numeric vector")
    liv = iv.size - 1
    lv = v.size - 1
    x = np.zeros(n + 1, dtype=np.float64)
    x[1:] = x0
    dd = np.zeros(n + 1, dtype=np.float64)
    dd[1:] = d
    b = None
    if low is not None and upp is not None and low.size == n and upp.size == n:
        b = np.zeros(2 * n + 1, dtype=np.float64)
        b[1::2] = low
        b[2::2] = upp
    g = h = None
    if gr is not None:
        g = np.zeros(n + 1, dtype=np.float64)
        if hs is not None:
            h = np.zeros(n * (n + 1) // 2 + 1, dtype=np.float64)

    def xw():
        p = x[1:].copy()
        return pd.Series(p, index=names) if names is not None else p

    fx = math.inf
    while True:
        with np.errstate(all="ignore"):
            nlminb_iterate(b, dd, fx, g, h, iv, liv, lv, n, v, x)
        if iv[1] == 2 and g is not None:
            _check_gv(gr, hs, xw, n, g, h)
        else:
            fx = _as_real(fn(xw()))
            if fx != fx:
                warnings.warn("NA/NaN function evaluation", stacklevel=3)
                fx = math.inf
        if not (iv[1] < 3):
            break
    return x[1:].copy()


# ── Unbeschränkte Varianten: DS7GRD, DRMNG, DRMNF ────────────────────────

def ds7grd(alpha, d, eta0, fx, g, irc, n, w, x):
    """DS7GRD; liefert (fx, irc)."""
    C2000, HMAX0, HMIN0, P002 = _F(2.0e3), _F(0.02), _F(5.0e1), _F(0.002)
    FH, FX0, HSAVE, XISAVE = 3, 4, 5, 6
    if irc < 0:
        h = -w[HSAVE]
        i = abs(irc)
        if not (h > ZERO):
            w[FH] = fx
            x[i] = w[XISAVE] + h
            w[HSAVE] = h
            return fx, irc
        g[i] = (w[FH] - fx) / (TWO * h)
        x[i] = w[XISAVE]
    elif irc > 0:
        g[irc] = (fx - w[FX0]) / w[HSAVE]
        x[irc] = w[XISAVE]
    else:
        w[1] = dr7mdc(3)
        w[2] = _sqrt(w[1])
        w[FX0] = fx
    # Marke 110
    i = abs(irc) + 1
    if i > n:
        fx = w[FX0]
        irc = 0
        return fx, irc
    irc = i
    afx = abs(w[FX0])
    machep = w[1]
    h0 = w[2]
    hmin = HMIN0 * machep
    w[XISAVE] = x[i]
    axi = abs(x[i])
    axibar = _max2(axi, ONE / d[i])
    gi = g[i]
    agi = abs(gi)
    eta = abs(eta0)
    if afx > ZERO:
        eta = _max1(eta, agi * axi * machep / afx)
    alphai = alpha[i]
    if alphai == ZERO:
        h = axibar
    elif gi == ZERO or fx == ZERO:
        h = h0 * axibar
    else:
        afxeta = afx * eta
        aai = abs(alphai)
        if not (gi * gi <= afxeta * aai):
            h = TWO * _sqrt(afxeta / aai)
            h = h * (ONE - aai * h / (THREE * aai * h + FOUR * agi))
        else:
            h = TWO * _pow(afxeta * agi, ONE / THREE) * _pow(aai, -TWO / THREE)
            h = h * (ONE - TWO * agi / (THREE * aai * h + FOUR * agi))
        h = _max1(h, hmin * axibar)
        if aai * h <= P002 * agi:
            if h >= HMAX0 * axibar:
                h = h0 * axibar
            if alphai * gi < ZERO:
                h = -h
        else:
            discon = C2000 * afxeta
            h = discon / (agi + _sqrt(gi * gi + aai * discon))
            h = _max1(h, hmin * axibar)
            if h >= HMAX0 * axibar:
                h = axibar * _pow(h0, TWO / THREE)
            irc = -i
    x[i] = w[XISAVE] + h
    w[HSAVE] = h
    return fx, irc


def drmng(d, fx, g, iv, liv, lv, n, v, x):
    CNVCOD, DG, G0, INITH_, IRC, KAGQT, MODE, MODEL, MXFCAL_, MXITER_, NFCALL_, NFGCAL_, \
        NGCALL, NITER_, NWTSTP, RADINC, RESTOR, STEP, STGLIM, STLSTG, TOOBIG_, VNEED_, XIRC, \
        X0 = 55, 37, 48, 25, 29, 33, 35, 5, 17, 18, 6, 7, 30, 31, 34, 8, 9, 40, 11, 41, 2, 4, \
        13, 43
    DGNORM, DINIT, DSTNRM, DST0, F_, F0_, FDIF_, GTHG, GTSTEP, INCFAC, LMAT_, LMAX0, LMAXS, \
        NEXTV_, NREDUC, PREDUC, RADFAC, RADIUS, RAD0, RELDX, TUNER4, TUNER5 = \
        1, 38, 2, 3, 10, 13, 11, 44, 4, 23, 42, 35, 36, 47, 6, 7, 16, 8, 9, 17, 29, 30
    rstrst = 0
    k = 0
    i = int(iv[1])
    if i == 1:
        lab = 50
    elif i == 2:
        lab = 60
    else:
        if iv[1] == 0:
            divset(2, iv, liv, lv, v)
        if iv[1] == 12 or iv[1] == 13:
            iv[VNEED_] = iv[VNEED_] + n * (n + 13) // 2
        dparck(2, d, iv, liv, lv, n, v)
        i = int(iv[1]) - 2
        if i > 12:
            return
        if 1 <= i <= 6:
            lab = 190
        elif i in (7, 9):
            lab = 120
        elif i == 8:
            lab = 90
        elif i == 12:
            lab = 20
        else:
            lab = 10
    while True:
        if lab == 10:
            l = int(iv[LMAT_])
            iv[X0] = l + n * (n + 1) // 2
            iv[STEP] = iv[X0] + n
            iv[STLSTG] = iv[STEP] + n
            iv[G0] = iv[STLSTG] + n
            iv[NWTSTP] = iv[G0] + n
            iv[DG] = iv[NWTSTP] + n
            iv[NEXTV_] = iv[DG] + n
            if iv[1] == 13:
                iv[1] = 14
                return
            lab = 20
        if lab == 20:
            iv[NITER_] = 0
            iv[NFCALL_] = 1
            iv[NGCALL] = 1
            iv[NFGCAL_] = 1
            iv[MODE] = -1
            iv[MODEL] = 1
            iv[STGLIM] = 1
            iv[TOOBIG_] = 0
            iv[CNVCOD] = 0
            iv[RADINC] = 0
            v[RAD0] = ZERO
            if v[DINIT] >= ZERO:
                dv7scp(n, d, v[DINIT])
            if iv[INITH_] == 1:
                l = int(iv[LMAT_])
                dv7scp(n * (n + 1) // 2, _at(v, l), ZERO)
                k = l - 1
                for i in range(1, n + 1):
                    k = k + i
                    t = d[i]
                    if t <= ZERO:
                        t = ONE
                    v[k] = t
            iv[1] = 1
            return
        if lab == 50:
            v[F_] = fx
            if iv[MODE] >= 0:
                lab = 190
                continue
            v[F0_] = fx
            iv[1] = 2
            if iv[TOOBIG_] == 0:
                return
            iv[1] = 63
            lab = 350
            continue
        if lab == 60:
            if iv[TOOBIG_] != 0:
                iv[1] = 65
                lab = 350
                continue
            dg1 = int(iv[DG])
            dv7vmp(n, _at(v, dg1), g, d, -1)
            v[DGNORM] = dv2nrm(n, _at(v, dg1))
            if iv[CNVCOD] != 0:
                lab = 340
                continue
            if iv[MODE] == 0:
                lab = 300
                continue
            v[RADIUS] = v[LMAX0]
            iv[MODE] = 0
            lab = 80
        if lab == 80:
            ditsum(d, g, iv, liv, lv, n, v, x)
            lab = 90
        if lab == 90:
            k = int(iv[NITER_])
            if not (k < iv[MXITER_]):
                iv[1] = 10
                lab = 350
                continue
            lab = 100
        if lab == 100:
            iv[NITER_] = k + 1
            if k > 0:
                v[RADIUS] = v[RADFAC] * v[DSTNRM]
            g01 = int(iv[G0])
            x01 = int(iv[X0])
            v[F0_] = v[F_]
            iv[IRC] = 4
            iv[KAGQT] = -1
            dv7cpy(n, _at(v, x01), x)
            dv7cpy(n, _at(v, g01), g)
            lab = 130   # STOPX() ist .FALSE.
        if lab == 120:
            if v[F_] >= v[F0_]:
                lab = 130
            else:
                v[RADFAC] = ONE
                k = int(iv[NITER_])
                lab = 100
                continue
        if lab == 130:
            if not (iv[NFCALL_] < iv[MXFCAL_]):
                iv[1] = 9
                if v[F_] >= v[F0_]:
                    lab = 350
                    continue
                iv[CNVCOD] = iv[1]
                lab = 290
                continue
            lab = 150
        if lab == 150:
            step1 = int(iv[STEP])
            dg1 = int(iv[DG])
            nwtst1 = int(iv[NWTSTP])
            if iv[KAGQT] < 0:
                l = int(iv[LMAT_])
                dl7ivm(n, _at(v, nwtst1), _at(v, l), g)
                v[NREDUC] = HALF * dd7tpr(n, _at(v, nwtst1), _at(v, nwtst1))
                dl7itv(n, _at(v, nwtst1), _at(v, l), _at(v, nwtst1))
                dv7vmp(n, _at(v, step1), _at(v, nwtst1), d, 1)
                v[DST0] = dv2nrm(n, _at(v, step1))
                dv7vmp(n, _at(v, dg1), _at(v, dg1), d, -1)
                dl7tvm(n, _at(v, step1), _at(v, l), _at(v, dg1))
                v[GTHG] = dv2nrm(n, _at(v, step1))
                iv[KAGQT] = 0
            dd7dog(_at(v, dg1), lv, n, _at(v, nwtst1), _at(v, step1), v)
            if iv[IRC] == 6:
                if iv[RESTOR] != 2:
                    lab = 190
                    continue
                rstrst = 2
                lab = 200
                continue
            iv[TOOBIG_] = 0
            if v[DSTNRM] <= ZERO:
                lab = 190
                continue
            if iv[IRC] == 5 and not (v[RADFAC] <= ONE) and not (v[PREDUC] > ONEP2 * v[FDIF_]):
                if iv[RESTOR] != 2:
                    lab = 190
                    continue
                rstrst = 0
                lab = 200
                continue
            x01 = int(iv[X0])
            step1 = int(iv[STEP])
            dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
            iv[NFCALL_] = iv[NFCALL_] + 1
            iv[1] = 1
            return
        if lab == 190:
            rstrst = 3
            lab = 200
        if lab == 200:
            x01 = int(iv[X0])
            v[RELDX] = drldst(n, d, x, _at(v, x01))
            da7sst(iv, liv, lv, v)
            step1 = int(iv[STEP])
            lstgst = int(iv[STLSTG])
            i = int(iv[RESTOR]) + 1
            if i == 2:
                dv7cpy(n, x, _at(v, x01))
            elif i == 3:
                dv7cpy(n, _at(v, lstgst), _at(v, step1))
            elif i == 4:
                dv7cpy(n, _at(v, step1), _at(v, lstgst))
                dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
                v[RELDX] = drldst(n, d, x, _at(v, x01))
                iv[RESTOR] = rstrst
            k = int(iv[IRC])
            if k in (2, 3, 4):
                lab = 280
                continue
            if k == 6:
                v[RADIUS] = v[LMAXS]
                lab = 150
                continue
            if 7 <= k <= 12:
                iv[CNVCOD] = k - 4
                if v[F_] >= v[F0_]:
                    lab = 340
                    continue
                if iv[XIRC] == 14:
                    lab = 340
                    continue
                iv[XIRC] = 14
                lab = 280
                continue
            if k == 13:
                iv[1] = 64
                lab = 350
                continue
            if k == 14:
                lab = 300
                continue
            v[RADIUS] = v[RADFAC] * v[DSTNRM]
            lab = 130   # 110: STOPX() ist .FALSE.
            continue
        if lab == 280:
            if iv[IRC] == 3:
                step1 = int(iv[STEP])
                temp1 = int(iv[STLSTG])
                l = int(iv[LMAT_])
                dl7tvm(n, _at(v, temp1), _at(v, l), _at(v, step1))
                dl7vml(n, _at(v, temp1), _at(v, l), _at(v, temp1))
            lab = 290
        if lab == 290:
            iv[NGCALL] = iv[NGCALL] + 1
            iv[1] = 2
            return
        if lab == 300:
            g01 = int(iv[G0])
            dv2axy(n, _at(v, g01), NEGONE, _at(v, g01), g)
            step1 = int(iv[STEP])
            temp1 = int(iv[STLSTG])
            if iv[IRC] == 3:
                dv2axy(n, _at(v, temp1), NEGONE, _at(v, g01), _at(v, temp1))
                dv7vmp(n, _at(v, temp1), _at(v, temp1), d, -1)
                if dv2nrm(n, _at(v, temp1)) <= v[DGNORM] * v[TUNER4] or \
                        not (dd7tpr(n, g, _at(v, step1)) >= v[GTSTEP] * v[TUNER5]):
                    v[RADFAC] = v[INCFAC]
            w = int(iv[NWTSTP])
            z = int(iv[X0])
            l = int(iv[LMAT_])
            dw7zbf(_at(v, l), n, _at(v, step1), _at(v, w), _at(v, g01), _at(v, z))
            dl7upd(_at(v, temp1), _at(v, step1), _at(v, l), _at(v, g01), _at(v, l), n,
                   _at(v, w), _at(v, z))
            iv[1] = 2
            lab = 80
            continue
        if lab == 340:
            iv[1] = iv[CNVCOD]
            iv[CNVCOD] = 0
            lab = 350
        if lab == 350:
            ditsum(d, g, iv, liv, lv, n, v, x)
            return
        raise RuntimeError("drmng: Marke %r" % lab)


def drmnf(d, fx, iv, liv, lv, n, v, x):
    ETA0, F_, G_, LMAT_, NEXTV_, NGCALL, NITER_, SGIRC, TOOBIG_, VNEED_ = \
        42, 10, 28, 42, 47, 30, 31, 57, 2, 4
    iv1 = int(iv[1])
    if iv1 == 1:
        lab = 10
    elif iv1 == 2:
        lab = 50
    else:
        if iv[1] == 0:
            divset(2, iv, liv, lv, v)
        iv1 = int(iv[1])
        if iv1 == 12 or iv1 == 13:
            iv[VNEED_] = iv[VNEED_] + 2 * n + 6
        if iv1 == 14 or (2 < iv1 < 12):
            lab = 10
        else:
            g1 = 1
            if iv1 == 12:
                iv[1] = 13
            lab = 20
    while True:
        if lab == 10:
            g1 = int(iv[G_])
            lab = 20
        if lab == 20:
            drmng(d, fx, _at(v, g1), iv, liv, lv, n, v, x)
            if iv[1] < 2:
                return
            if iv[1] > 2:
                if iv[1] != 14:
                    return
                iv[G_] = iv[NEXTV_] + n + 6
                iv[NEXTV_] = iv[G_] + n
                if iv1 != 13:
                    lab = 10
                    continue
                return
            if iv[NITER_] == 0:
                dv7scp(n, _at(v, g1), ZERO)
            j = int(iv[LMAT_])
            k = g1 - n
            for i in range(1, n + 1):
                v[k] = dd7tpr(i, _at(v, j), _at(v, j))
                k = k + 1
                j = j + i
            iv[NGCALL] = iv[NGCALL] - 1
            iv[SGIRC] = 0
            fx = v[F_]
            lab = 60
        if lab == 50:
            if iv[TOOBIG_] != 0:
                lab = 10
                continue
            lab = 60
        if lab == 60:
            g1 = int(iv[G_])
            alpha = g1 - n
            w = alpha - 6
            fx, irc = ds7grd(_at(v, alpha), d, v[ETA0], fx, _at(v, g1), int(iv[SGIRC]), n,
                             _at(v, w), x)
            iv[SGIRC] = irc
            if irc == 0:
                lab = 10
                continue
            iv[NGCALL] = iv[NGCALL] + 1
            return
        raise RuntimeError("drmnf: Marke %r" % lab)


# ── Varianten mit Hesse-Matrix: Hilfsroutinen ────────────────────────────

def _min1(a, b):
    """``minsd`` mit Ziel ``a``: ``a < b ? a : b``."""
    return a if a < b else b


def _min2(a, b):
    """``minsd`` mit Ziel ``b``: ``b < a ? b : a``."""
    return b if b < a else a


def dd7dup(d, hdiag, iv, liv, lv, n, v):
    DFAC, DTOL, DTYPE_, NITER_ = 41, 59, 16, 31
    i = int(iv[DTYPE_])
    if i != 1 and iv[NITER_] > 0:
        return
    dtoli = int(iv[DTOL])
    d0i = dtoli + n
    vdfac = v[DFAC]
    for i in range(1, n + 1):
        t = _max1(_sqrt(abs(hdiag[i])), vdfac * d[i])
        if t < v[dtoli]:
            t = _max1(v[dtoli], v[d0i])
        d[i] = t
        dtoli = dtoli + 1
        d0i = d0i + 1


def dl7srt(n1, n, l, a):
    """Cholesky-Zerlegung (Zeilen n1..n); liefert ``irc``."""
    i0 = n1 * (n1 - 1) // 2
    for i in range(n1, n + 1):
        td = ZERO
        if i != 1:
            j0 = 0
            im1 = i - 1
            for j in range(1, im1 + 1):
                t = ZERO
                if j != 1:
                    jm1 = j - 1
                    for k in range(1, jm1 + 1):
                        t = t + l[i0 + k] * l[j0 + k]
                ij = i0 + j
                j0 = j0 + j
                t = (a[ij] - t) / l[j0]
                l[ij] = t
                td = td + t * t
        i0 = i0 + i
        t = a[i0] - td
        if t <= ZERO:
            l[i0] = t
            return i
        l[i0] = _sqrt(t)
    return 0


def dl7svn(p, l, x, y):
    """Schätzung des kleinsten Singulärwerts von L."""
    R9973 = _F(9973.0)
    ix = 2
    pm1 = p - 1
    ii = 0
    j0 = p * pm1 // 2
    jj = j0 + p
    if l[jj] == ZERO:
        return ZERO
    ix = (3432 * ix) % 9973
    b = HALF * (ONE + _F(ix) / R9973)
    xplus = b / l[jj]
    x[p] = xplus
    if p > 1:
        for i in range(1, pm1 + 1):
            ii = ii + i
            if l[ii] == ZERO:
                return ZERO
            ji = j0 + i
            x[i] = xplus * l[ji]
        for jjj in range(1, pm1 + 1):
            j = p - jjj
            ix = (3432 * ix) % 9973
            b = HALF * (ONE + _F(ix) / R9973)
            xplus = (b - x[j])
            xminus = (-b - x[j])
            splus = abs(xplus)
            sminus = abs(xminus)
            jm1 = j - 1
            j0 = j * jm1 // 2
            jj = j0 + j
            xplus = xplus / l[jj]
            xminus = xminus / l[jj]
            for i in range(1, jm1 + 1):
                ji = j0 + i
                splus = splus + abs(x[i] + l[ji] * xplus)
                sminus = sminus + abs(x[i] + l[ji] * xminus)
            if sminus > splus:
                xplus = xminus
            x[j] = xplus
            if jm1 > 0:
                dv2axy(jm1, x, xplus, _at(l, j0 + 1), x)
    t = ONE / dv2nrm(p, x)
    for i in range(1, p + 1):
        x[i] = t * x[i]
    for j in range(1, p + 1):
        jm1 = j - 1
        j0 = j * jm1 // 2
        jj = j0 + j
        t = ZERO
        if jm1 > 0:
            t = dd7tpr(jm1, _at(l, j0 + 1), y)
        y[j] = (x[j] - t) / l[jj]
    return ONE / dv2nrm(p, y)


def ds7lvm(p, y, s, x):
    """y = S * x (S symmetrisch, unteres Dreieck zeilenweise)."""
    j = 1
    for i in range(1, p + 1):
        y[i] = dd7tpr(i, _at(s, j), x)
        j = j + i
    if p <= 1:
        return
    j = 1
    for i in range(2, p + 1):
        xi = x[i]
        im1 = i - 1
        j = j + 1
        for k in range(1, im1 + 1):
            y[k] = y[k] + s[j] * xi
            j = j + 1


def ds7ipr(p, ip, h):
    """Symmetrische Permutation von H (kompakt) nach ip; ip wird zurückgesetzt."""
    for i in range(1, p + 1):
        j = int(ip[i])
        if j == i:
            continue
        ip[i] = abs(j)
        if j < 0:
            continue
        k = i
        while True:
            j1 = j
            k1 = k
            if j > k:
                j1 = k
                k1 = j
            kmj = k1 - j1
            l = j1 - 1
            jm = j1 * l // 2
            km = k1 * (k1 - 1) // 2
            if l > 0:
                for m in range(1, l + 1):
                    jm = jm + 1
                    t = h[jm]
                    km = km + 1
                    h[jm] = h[km]
                    h[km] = t
            km = km + 1
            kk = km + kmj
            jm = jm + 1
            t = h[jm]
            h[jm] = h[kk]
            h[kk] = t
            j1 = l
            l = kmj - 1
            if l > 0:
                for m in range(1, l + 1):
                    jm = jm + j1 + m
                    t = h[jm]
                    km = km + 1
                    h[jm] = h[km]
                    h[km] = t
            if k1 < p:
                l = p - k1
                k1 = k1 - 1
                km = kk
                for m in range(1, l + 1):
                    km = km + k1 + m
                    jm = km - kmj
                    t = h[jm]
                    h[jm] = h[km]
                    h[km] = t
            k = j
            j = int(ip[k])
            ip[k] = -j
            if not (j > i):
                break


_BIG = dr7mdc(6)
_DGXFAC = _F(50.0) * dr7mdc(3)


def dg7qts(d, dig, dihdi, ka, l, p, step, v, w):
    """Goldfeld-Quandt-Trotter-Schritt (More-Hebden); liefert das neue ``ka``."""
    DGNORM, DSTNRM, DST0, EPSLON, GTSTEP, NREDUC, PHMNFC, PHMXFC, PREDUC, RADIUS, RAD0, \
        STPPAR = 1, 2, 3, 19, 4, 6, 20, 21, 7, 8, 9, 5
    EPSFAC, KAPPA, P001, SIX = _F(50.0), _F(2.0), _F(1.0e-3), _F(6.0)
    big = _BIG
    dggdmx = p + 1
    emax = dggdmx + 1
    emin = emax + 1
    lk0 = emin + 1
    phipin = lk0 + 1
    uk0 = phipin + 1
    dstsav = uk0 + 1
    diag0 = dstsav
    diag = diag0 + 1
    q0 = diag0 + p
    q = q0 + 1
    X = q + p
    rad = v[RADIUS]
    radsq = rad * rad
    phimax = v[PHMXFC] * rad
    phimin = v[PHMNFC] * rad
    psifac = big
    t1 = TWO * v[EPSLON] / (THREE * (FOUR * (v[PHMNFC] + ONE) * (KAPPA + ONE) + KAPPA + TWO) * rad)
    if t1 < big * _min2(rad, ONE):
        psifac = t1 / rad
    oldphi = ZERO
    eps = v[EPSLON]
    irc = 0
    restrt = False
    kalim = ka + 50
    # in Fortran ggf. undefinierte Größen
    phi = ZERO
    gtsta = ZERO
    dst = ZERO
    alphak = ZERO
    lk = ZERO
    uk = ZERO
    kamin = 0
    delta = ZERO
    twopsi = ZERO
    si = ZERO
    sw = ZERO
    t = ZERO
    if ka >= 0:
        lab = 290
    else:
        k = 0
        uk = NEGONE
        ka = 0
        kalim = 50
        v[DGNORM] = dv2nrm(p, dig)
        v[NREDUC] = ZERO
        v[DST0] = ZERO
        kamin = 3
        if v[DGNORM] == ZERO:
            kamin = 0
        j = 0
        for i in range(1, p + 1):
            j = j + i
            k1 = diag0 + i
            w[k1] = dihdi[j]
        t1 = ZERO
        j = p * (p + 1) // 2
        for i in range(1, j + 1):
            t = abs(dihdi[i])
            if t1 < t:
                t1 = t
        w[dggdmx] = t1
        lab = 30
    while True:
        if lab == 30:
            irc = dl7srt(1, p, l, dihdi)
            if irc == 0:
                lab = 50
                continue
            j = irc * (irc + 1) // 2
            t = l[j]
            l[j] = ONE
            for i in range(1, irc + 1):
                w[i] = ZERO
            w[irc] = ONE
            dl7itv(irc, w, l, w)
            t1 = dv2nrm(irc, w)
            lk = -t / t1 / t1
            v[DST0] = -lk
            lab = 210 if restrt else 70
            continue
        if lab == 50:
            lk = ZERO
            t = dl7svn(p, l, _at(w, q), _at(w, q))
            if not (t >= ONE) and v[DGNORM] >= t * t * big:
                lab = 70
                continue
            dl7ivm(p, _at(w, q), l, dig)
            gtsta = dd7tpr(p, _at(w, q), _at(w, q))
            v[NREDUC] = HALF * gtsta
            dl7itv(p, _at(w, q), l, _at(w, q))
            dst = dv2nrm(p, _at(w, q))
            v[DST0] = dst
            phi = dst - rad
            if phi <= phimax:
                alphak = ZERO
                lab = 270
                continue
            lab = 210 if restrt else 70
            continue
        if lab == 70:
            k = 0
            for i in range(1, p + 1):
                wi = ZERO
                for j in range(1, i):
                    k = k + 1
                    t = abs(dihdi[k])
                    wi = wi + t
                    w[j] = w[j] + t
                w[i] = wi
                k = k + 1
            k = 1
            t1 = w[diag] - w[1]
            for i in range(2, p + 1):
                j = diag0 + i
                t = w[j] - w[i]
                if t >= t1:
                    continue
                t1 = t
                k = i
            sk = w[k]
            j = diag0 + k
            akk = w[j]
            k1 = k * (k - 1) // 2 + 1
            inc = 1
            t = ZERO
            for i in range(1, p + 1):
                if i != k:
                    aki = abs(dihdi[k1])
                    si = w[i]
                    j = diag0 + i
                    t1 = HALF * (akk - w[j] + si - aki)
                    t1 = t1 + _sqrt(t1 * t1 + sk * aki)
                    if t < t1:
                        t = t1
                    if i < k:
                        k1 = k1 + inc
                        continue
                inc = i
                k1 = k1 + inc
            w[emin] = akk - t
            uk = v[DGNORM] / rad - w[emin]
            if v[DGNORM] == ZERO:
                uk = uk + P001 + P001 * uk
            if uk <= ZERO:
                uk = P001
            k = 1
            t1 = w[diag] + w[1]
            for i in range(2, p + 1):
                j = diag0 + i
                t = w[j] + w[i]
                if t <= t1:
                    continue
                t1 = t
                k = i
            sk = w[k]
            j = diag0 + k
            akk = w[j]
            k1 = k * (k - 1) // 2 + 1
            inc = 1
            t = ZERO
            for i in range(1, p + 1):
                if i != k:
                    aki = abs(dihdi[k1])
                    si = w[i]
                    j = diag0 + i
                    t1 = HALF * (w[j] + si - aki - akk)
                    t1 = t1 + _sqrt(t1 * t1 + sk * aki)
                    if t < t1:
                        t = t1
                    if i < k:
                        k1 = k1 + inc
                        continue
                inc = i
                k1 = k1 + inc
            w[emax] = akk + t
            lk = _max1(lk, v[DGNORM] / rad - w[emax])
            alphak = abs(v[STPPAR]) * v[RAD0] / rad
            alphak = _min2(uk, _max1(alphak, lk))
            if irc != 0:
                lab = 210
                continue
            dl7ivm(p, w, l, _at(w, q))
            t = dv2nrm(p, w)
            w[phipin] = rad / t / t
            lk = _max1(lk, phi * w[phipin])
            lab = 210
        if lab == 210:
            ka = ka + 1
            if -v[DST0] >= alphak or alphak < lk or alphak >= uk:
                alphak = uk * _max2(P001, _sqrt(lk / uk))
            if alphak <= ZERO:
                alphak = HALF * uk
            if alphak <= ZERO:
                alphak = uk
            k = 0
            for i in range(1, p + 1):
                k = k + i
                j = diag0 + i
                dihdi[k] = w[j] + alphak
            irc = dl7srt(1, p, l, dihdi)
            if irc != 0:
                j = (irc * (irc + 1)) // 2
                t = l[j]
                l[j] = ONE
                for i in range(1, irc + 1):
                    w[i] = ZERO
                w[irc] = ONE
                dl7itv(irc, w, l, w)
                t1 = dv2nrm(irc, w)
                lk = alphak - t / t1 / t1
                v[DST0] = -lk
                if uk < lk:
                    uk = lk
                if alphak < lk:
                    continue
                t = P001 * alphak
                if t <= ZERO:
                    t = P001
                lk = alphak + t
                if uk <= lk:
                    uk = lk + t
                continue
            # Marke 240
            dl7ivm(p, _at(w, q), l, dig)
            gtsta = dd7tpr(p, _at(w, q), _at(w, q))
            dl7itv(p, _at(w, q), l, _at(w, q))
            dst = dv2nrm(p, _at(w, q))
            phi = dst - rad
            if phi <= phimax and phi >= phimin:
                lab = 270
                continue
            if phi == oldphi:
                lab = 270
                continue
            oldphi = phi
            if phi < ZERO:
                lab = 330
                continue
            lab = 250
        if lab == 250:
            if ka >= kalim:
                lab = 270
                continue
            if phi < ZERO:
                uk = _min1(uk, alphak)
            if kamin == 0:
                lab = 210
                continue
            dl7ivm(p, w, l, _at(w, q))
            t1 = dv2nrm(p, w)
            alphak = alphak + (phi / t1) * (dst / t1) * (dst / rad)
            lk = _max2(lk, alphak)
            alphak = lk
            lab = 210
            continue
        if lab == 270:
            for i in range(1, p + 1):
                j = q0 + i
                step[i] = -w[j] / d[i]
            v[GTSTEP] = -gtsta
            v[PREDUC] = HALF * (abs(alphak) * dst * dst + gtsta)
            lab = 410
            continue
        if lab == 290:
            if v[DST0] <= ZERO or v[DST0] - rad > phimax:
                lab = 310
                continue
            restrt = True
            ka = ka + 1
            k = 0
            for i in range(1, p + 1):
                k = k + i
                j = diag0 + i
                dihdi[k] = w[j]
            uk = NEGONE
            lab = 30
            continue
        if lab == 310:
            kamin = ka + 3
            if v[DGNORM] == ZERO:
                kamin = 0
            if ka == 0:
                lab = 50
                continue
            dst = w[dstsav]
            alphak = abs(v[STPPAR])
            phi = dst - rad
            t = v[DGNORM] / rad
            uk = t - w[emin]
            if v[DGNORM] == ZERO:
                uk = uk + P001 + P001 * uk
            if uk <= ZERO:
                uk = P001
            if not (rad > v[RAD0]):
                lk = ZERO
                if alphak > ZERO:
                    lk = w[lk0]
                lk = _max1(lk, t - w[emax])
                if v[DST0] > ZERO:
                    lk = _max1(lk, (v[DST0] - rad) * w[phipin])
                lab = 250
                continue
            if alphak > ZERO:
                uk = _min1(uk, w[uk0])
            lk = _max1(_max2(ZERO, -v[DST0]), t - w[emax])
            if v[DST0] > ZERO:
                lk = _max1(lk, (v[DST0] - rad) * w[phipin])
            lab = 250
            continue
        if lab == 330:
            delta = alphak + _min1(ZERO, v[DST0])
            twopsi = alphak * dst * dst + gtsta
            if ka < kamin and not (psifac >= big) and delta >= psifac * twopsi:
                lab = 370
                continue
            # Marke 340
            t = dl7svn(p, l, _at(w, X), w)
            for i in range(1, p + 1):
                w[i] = t * w[i]
            dl7itv(p, w, l, w)
            t2 = ONE / dv2nrm(p, w)
            for i in range(1, p + 1):
                w[i] = t2 * w[i]
            t = t2 * t
            sw = dd7tpr(p, _at(w, q), w)
            t1 = (rad + dst) * (rad - dst)
            root = _sqrt(sw * sw + t1)
            if sw < ZERO:
                root = -root
            si = t1 / (sw + root)
            q2 = t2 * si
            if q2 * q2 <= eps * (dst * dst + alphak * radsq):
                lab = 380
                continue
            if v[DST0] <= ZERO:
                v[DST0] = _min1(v[DST0], t2 * t2 - alphak)
            lk = _max1(lk, -v[DST0])
            lab = 370
        if lab == 370:
            if delta > _DGXFAC * w[dggdmx]:
                lab = 250
                continue
            lab = 270
            continue
        if lab == 380:
            alphak = -alphak
            v[PREDUC] = HALF * twopsi
            t1 = ZERO
            t = si * (alphak * sw - HALF * si * (alphak + t * dd7tpr(p, _at(w, X), w)))
            if not (t < eps * twopsi / SIX):
                v[PREDUC] = v[PREDUC] + t
                dst = rad
                t1 = -si
            for i in range(1, p + 1):
                j = q0 + i
                w[j] = t1 * w[i] - w[j]
                step[i] = w[j] / d[i]
            v[GTSTEP] = dd7tpr(p, dig, _at(w, q))
            lab = 410
        if lab == 410:
            v[DSTNRM] = dst
            v[STPPAR] = alphak
            w[lk0] = lk
            w[uk0] = uk
            v[RAD0] = rad
            w[dstsav] = dst
            j = 0
            for i in range(1, p + 1):
                j = j + i
                k = diag0 + i
                dihdi[j] = w[k]
            return ka
        raise RuntimeError("dg7qts: Marke %r" % lab)


def ds7bqn(b, d, dst, ipiv, ipiv1, ipiv2, kb, l, lv, ns, p, p1, step, td, tg, v, w, x, x0):
    """DS7BQN; liefert (kb, ns, p1)."""
    DSTNRM, GTSTEP, PHMNFC, PHMXFC, PREDUC, RADIUS, STPPAR = 2, 4, 20, 21, 7, 8, 5
    FUDGE = _F(1.0001)
    meps2 = _MEPS2
    dstmax = FUDGE * (ONE + v[PHMXFC]) * v[RADIUS]
    dstmin = (ONE + v[PHMNFC]) * v[RADIUS]
    dst1 = ZERO
    p0 = p1
    ns = 0
    for i in range(1, p + 1):
        ipiv1[i] = i
        ipiv2[i] = i
    for i in range(1, p1 + 1):
        w[i] = -step[i] * td[i]
    alpha = abs(v[STPPAR])
    v[PREDUC] = ZERO
    gts = -v[GTSTEP]
    if kb < 0:
        dv7scp(p, dst, ZERO)
    kb = 1
    while True:
        # Marke 30
        t = ONE
        k = 0
        for i in range(1, p1 + 1):
            j = int(ipiv[i])
            dx = w[i] / d[j]
            xi = x[j] - dx
            if xi < b[2 * j - 1]:
                ti = (x[j] - b[2 * j - 1]) / dx
                k = -i
            elif xi <= b[2 * j]:
                continue
            else:
                ti = (x[j] - b[2 * j]) / dx
                k = i
            if t <= ti:
                continue
            t = ti
        if p > p1:
            dv7cpy(p - p1, _at(step, p1 + 1), _at(dst, p1 + 1))
        dv2axy(p1, step, -t, w, dst)
        dst0 = dst1
        dst1 = dv2nrm(p, step)
        if not (dst1 <= dstmax):
            if not (p1 >= p0):
                if dst0 < dstmin:
                    kb = 0
                break
            k = 0
        v[DSTNRM] = dst1
        dv7cpy(p1, dst, step)
        t1 = ONE - t
        for i in range(1, p1 + 1):
            tg[i] = t1 * tg[i]
        if alpha > ZERO:
            dv2axy(p1, tg, t * alpha, w, tg)
        v[PREDUC] = v[PREDUC] + t * ((ONE - HALF * t) * gts + HALF * alpha * t * dd7tpr(p1, w, w))
        if k == 0:
            break
        p1m1 = p1 - 1
        j = abs(k)
        if j != p1:
            ns = ns + 1
            ipiv2[p1] = j
            dq7rsh(j, p1, False, tg, l, w)
            i7shft(p1, j, ipiv)
            i7shft(p1, j, ipiv1)
            dv7shf(p1, j, tg)
            dv7shf(p1, j, dst)
        if k < 0:
            ipiv[p1] = -ipiv[p1]
        p1 = p1m1
        if p1 <= 0:
            break
        dl7ivm(p1, w, l, tg)
        gts = dd7tpr(p1, w, w)
        dl7itv(p1, w, l, w)
    # Marke 110
    for i in range(1, p + 1):
        j = abs(int(ipiv[i]))
        step[j] = dst[i] / d[j]
    if p1 < p0:
        k = p1 + 1
        for i in range(k, p0 + 1):
            j = int(ipiv[i])
            t = meps2
            if not (j > 0):
                t = -t
                j = -j
                ipiv[i] = j
            t = t * _max1(abs(x[j]), abs(x0[j]))
            step[j] = step[j] + t
    dv2axy(p, x, ONE, step, x0)
    if ns > 0:
        dv7ipr(p0, ipiv1, td)
    return kb, ns, p1


def dg7qsb(b, d, dihdi, g, ipiv, ipiv1, ipiv2, ka, l, lv, p, p0, pc, step, td, tg, v, w, x, x0):
    """DG7QSB; liefert (ka, p0)."""
    DST0, DSTNRM, GTSTEP, NREDUC, PREDUC, RADIUS = 3, 2, 4, 6, 7, 8
    p1 = pc
    nred = ds0 = ZERO
    if ka >= 0:
        nred = v[NREDUC]
        ds0 = v[DST0]
    else:
        p0 = 0
        ka = -1
    kinit = -1
    if p0 == p1:
        kinit = ka
    dv7cpy(p, x, x0)
    pred = ZERO
    rad = v[RADIUS]
    kb = -1
    v[DSTNRM] = ZERO
    if not (p1 > 0):
        nred = ZERO
        ds0 = ZERO
        dv7scp(p, step, ZERO)
    else:
        dv7cpy(p, td, d)
        dv7ipr(p, ipiv, td)
        dv7vmp(p, tg, g, d, -1)
        dv7ipr(p, ipiv, tg)
        while True:
            k = kinit
            kinit = -1
            v[RADIUS] = rad - v[DSTNRM]
            k = dg7qts(td, tg, dihdi, k, l, p1, step, v, w)
            p0 = p1
            if ka < 0:
                nred = v[NREDUC]
                ds0 = v[DST0]
            ka = k
            v[RADIUS] = rad
            p10 = p1
            kb, ns, p1 = ds7bqn(b, d, _at(step, p + 1), ipiv, ipiv1, ipiv2, kb, l, lv, 0, p, p1,
                                step, td, tg, v, w, x, x0)
            if ns > 0:
                ds7ipr(p10, ipiv1, dihdi)
            pred = pred + v[PREDUC]
            if ns != 0:
                p0 = 0
            if not (kb <= 0):
                break
    v[DST0] = ds0
    v[NREDUC] = nred
    v[PREDUC] = pred
    v[GTSTEP] = dd7tpr(p, g, step)
    return ka, p0


# ── DRMNH / DRMNHB: Gradient und Hesse-Matrix vom Aufrufer ───────────────

def drmnh(d, fx, g, h, iv, liv, lv, n, v, x):
    lh = n * (n + 1) // 2
    CNVCOD, DG, DTOL, DTYPE_, IRC, KAGQT, LMAT_, MODE, MODEL, MXFCAL_, MXITER_, NEXTV_, \
        NFCALL_, NFGCAL_, NGCALL, NITER_, RADINC, RESTOR, STEP, STGLIM, STLSTG, TOOBIG_, \
        VNEED_, W, XIRC, X0 = 55, 37, 59, 16, 29, 33, 42, 35, 5, 17, 18, 47, 6, 7, 30, 31, 8, \
        9, 40, 11, 41, 2, 4, 34, 13, 43
    DGNORM, DINIT, DSTNRM, DTINIT, D0INIT, F_, F0_, FDIF_, GTSTEP, INCFAC, LMAX0, LMAXS, \
        PHMXFC, PREDUC, RADFAC, RADIUS, RAD0, RELDX, STPPAR, TUNER4, TUNER5 = \
        1, 38, 2, 39, 40, 10, 13, 11, 4, 23, 35, 36, 21, 7, 16, 8, 9, 17, 5, 29, 30
    rstrst = 0
    k = 0
    i = int(iv[1])
    if i == 1:
        lab = 30
    elif i == 2:
        lab = 40
    else:
        if iv[1] == 0:
            divset(2, iv, liv, lv, v)
        if iv[1] == 12 or iv[1] == 13:
            iv[VNEED_] = iv[VNEED_] + n * (n + 21) // 2 + 7
        dparck(2, d, iv, liv, lv, n, v)
        i = int(iv[1]) - 2
        if i > 12:
            return
        nn1o2 = n * (n + 1) // 2
        lab = 0
        if lh >= nn1o2:
            if 1 <= i <= 6:
                lab = 220
            elif i in (7, 9):
                lab = 160
            elif i == 8:
                lab = 120
            elif i in (10, 11):
                lab = 10
            elif i == 12:
                lab = 20
        if lab == 0:
            iv[1] = 66
            lab = 400
    while True:
        if lab == 10:
            nn1o2 = n * (n + 1) // 2
            iv[DTOL] = iv[LMAT_] + nn1o2
            iv[X0] = iv[DTOL] + 2 * n
            iv[STEP] = iv[X0] + n
            iv[STLSTG] = iv[STEP] + n
            iv[DG] = iv[STLSTG] + n
            iv[W] = iv[DG] + n
            iv[NEXTV_] = iv[W] + 4 * n + 7
            if iv[1] == 13:
                iv[1] = 14
                return
            lab = 20
        if lab == 20:
            iv[NITER_] = 0
            iv[NFCALL_] = 1
            iv[NGCALL] = 1
            iv[NFGCAL_] = 1
            iv[MODE] = -1
            iv[MODEL] = 1
            iv[STGLIM] = 1
            iv[TOOBIG_] = 0
            iv[CNVCOD] = 0
            iv[RADINC] = 0
            v[RAD0] = ZERO
            v[STPPAR] = ZERO
            if v[DINIT] >= ZERO:
                dv7scp(n, d, v[DINIT])
            k = int(iv[DTOL])
            if v[DTINIT] > ZERO:
                dv7scp(n, _at(v, k), v[DTINIT])
            k = k + n
            if v[D0INIT] > ZERO:
                dv7scp(n, _at(v, k), v[D0INIT])
            iv[1] = 1
            return
        if lab == 30:
            v[F_] = fx
            if iv[MODE] >= 0:
                lab = 220
                continue
            v[F0_] = fx
            iv[1] = 2
            if iv[TOOBIG_] == 0:
                return
            iv[1] = 63
            lab = 400
            continue
        if lab == 40:
            if iv[TOOBIG_] != 0:
                iv[1] = 65
                lab = 400
                continue
            dg1 = int(iv[DG])
            if iv[DTYPE_] > 0:
                k = dg1
                j = 0
                for i in range(1, n + 1):
                    j = j + i
                    v[k] = h[j]
                    k = k + 1
                dd7dup(d, _at(v, dg1), iv, liv, lv, n, v)
            dg1 = int(iv[DG])
            k = dg1
            for i in range(1, n + 1):
                v[k] = g[i] / d[i]
                k = k + 1
            v[DGNORM] = dv2nrm(n, _at(v, dg1))
            k = 1
            for i in range(1, n + 1):
                t = ONE / d[i]
                for j in range(1, i + 1):
                    h[k] = t * h[k] / d[j]
                    k = k + 1
            if iv[CNVCOD] != 0:
                lab = 390
                continue
            if iv[MODE] == 0:
                lab = 350
                continue
            v[RADIUS] = v[LMAX0] / (ONE + v[PHMXFC])
            iv[MODE] = 0
            lab = 110
        if lab == 110:
            ditsum(d, g, iv, liv, lv, n, v, x)
            lab = 120
        if lab == 120:
            k = int(iv[NITER_])
            if not (k < iv[MXITER_]):
                iv[1] = 10
                lab = 400
                continue
            lab = 130
        if lab == 130:
            iv[NITER_] = k + 1
            dg1 = int(iv[DG])
            x01 = int(iv[X0])
            v[F0_] = v[F_]
            iv[IRC] = 4
            iv[KAGQT] = -1
            dv7cpy(n, _at(v, x01), x)
            if k != 0:
                step1 = int(iv[STEP])
                k = step1
                for i in range(1, n + 1):
                    v[k] = d[i] * v[k]
                    k = k + 1
                v[RADIUS] = v[RADFAC] * dv2nrm(n, _at(v, step1))
            lab = 170   # 150: STOPX() ist .FALSE.
        if lab == 160:
            if v[F_] >= v[F0_]:
                lab = 170
            else:
                v[RADFAC] = ONE
                k = int(iv[NITER_])
                lab = 130
                continue
        if lab == 170:
            if not (iv[NFCALL_] < iv[MXFCAL_]):
                iv[1] = 9
                if v[F_] >= v[F0_]:
                    lab = 400
                    continue
                iv[CNVCOD] = iv[1]
                lab = 340
                continue
            lab = 190
        if lab == 190:
            step1 = int(iv[STEP])
            dg1 = int(iv[DG])
            l = int(iv[LMAT_])
            w1 = int(iv[W])
            iv[KAGQT] = dg7qts(d, _at(v, dg1), h, int(iv[KAGQT]), _at(v, l), n, _at(v, step1),
                               v, _at(v, w1))
            if iv[IRC] == 6:
                if iv[RESTOR] != 2:
                    lab = 220
                    continue
                rstrst = 2
                lab = 230
                continue
            iv[TOOBIG_] = 0
            if v[DSTNRM] <= ZERO:
                lab = 220
                continue
            if iv[IRC] == 5 and not (v[RADFAC] <= ONE) and not (v[PREDUC] > ONEP2 * v[FDIF_]):
                if iv[RESTOR] != 2:
                    lab = 220
                    continue
                rstrst = 0
                lab = 230
                continue
            x01 = int(iv[X0])
            step1 = int(iv[STEP])
            dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
            iv[NFCALL_] = iv[NFCALL_] + 1
            iv[1] = 1
            return
        if lab == 220:
            rstrst = 3
            lab = 230
        if lab == 230:
            x01 = int(iv[X0])
            v[RELDX] = drldst(n, d, x, _at(v, x01))
            da7sst(iv, liv, lv, v)
            step1 = int(iv[STEP])
            lstgst = int(iv[STLSTG])
            i = int(iv[RESTOR]) + 1
            if i == 2:
                dv7cpy(n, x, _at(v, x01))
            elif i == 3:
                dv7cpy(n, _at(v, lstgst), _at(v, step1))
            elif i == 4:
                dv7cpy(n, _at(v, step1), _at(v, lstgst))
                dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
                v[RELDX] = drldst(n, d, x, _at(v, x01))
                iv[RESTOR] = rstrst
            k = int(iv[IRC])
            if k in (2, 3, 4):
                lab = 310
                continue
            if k == 6:
                v[RADIUS] = v[LMAXS]
                lab = 190
                continue
            if 7 <= k <= 12:
                iv[CNVCOD] = k - 4
                if v[F_] >= v[F0_]:
                    lab = 390
                    continue
                if iv[XIRC] == 14:
                    lab = 390
                    continue
                iv[XIRC] = 14
                lab = 310
                continue
            if k == 13:
                iv[1] = 64
                lab = 400
                continue
            if k == 14:
                lab = 350
                continue
            v[RADIUS] = v[RADFAC] * v[DSTNRM]
            lab = 170   # 150: STOPX() ist .FALSE.
            continue
        if lab == 310:
            if iv[IRC] == 3:
                temp1 = lstgst
                k = x01
                for i in range(1, n + 1):
                    v[k] = d[i] * v[step1]
                    k = k + 1
                    step1 = step1 + 1
                ds7lvm(n, _at(v, temp1), h, _at(v, x01))
                for i in range(1, n + 1):
                    v[temp1] = d[i] * v[temp1] + g[i]
                    temp1 = temp1 + 1
            lab = 340
        if lab == 340:
            iv[NGCALL] = iv[NGCALL] + 1
            iv[TOOBIG_] = 0
            iv[1] = 2
            return
        if lab == 350:
            iv[1] = 2
            if iv[IRC] == 3:
                temp1 = int(iv[STLSTG])
                step1 = int(iv[STEP])
                k = temp1
                for i in range(1, n + 1):
                    v[k] = (v[k] - g[i]) / d[i]
                    k = k + 1
                if dv2nrm(n, _at(v, temp1)) <= v[DGNORM] * v[TUNER4] or \
                        not (dd7tpr(n, g, _at(v, step1)) >= v[GTSTEP] * v[TUNER5]):
                    v[RADFAC] = v[INCFAC]
            lab = 110
            continue
        if lab == 390:
            iv[1] = iv[CNVCOD]
            iv[CNVCOD] = 0
            lab = 400
        if lab == 400:
            ditsum(d, g, iv, liv, lv, n, v, x)
            return
        raise RuntimeError("drmnh: Marke %r" % lab)


def drmnhb(b, d, fx, g, h, iv, liv, lv, n, v, x):
    lh = n * (n + 1) // 2
    CNVCOD, DG, DTOL, DTYPE_, IRC, IVNEED_, KAGQT, LMAT_, MODE, MODEL, MXFCAL_, MXITER_, N0, \
        NC, NEXTIV, NEXTV_, NFCALL_, NFGCAL_, NGCALL, NITER_, PERM_, RADINC, RESTOR, STEP, \
        STGLIM, TOOBIG_, VNEED_, W, XIRC, X0 = 55, 37, 59, 16, 29, 3, 33, 42, 35, 5, 17, 18, \
        41, 48, 46, 47, 6, 7, 30, 31, 58, 8, 9, 40, 11, 2, 4, 34, 13, 43
    DGNORM, DINIT, DSTNRM, DTINIT, D0INIT, F_, F0_, FDIF_, GTSTEP, INCFAC, LMAX0, LMAXS, \
        PHMXFC, PREDUC, RADFAC, RADIUS, RAD0, RELDX, STPPAR, TUNER4, TUNER5 = \
        1, 38, 2, 39, 40, 10, 13, 11, 4, 23, 35, 36, 21, 7, 16, 8, 9, 17, 5, 29, 30
    rstrst = 0
    k = 0
    i = int(iv[1])
    if i == 1:
        lab = 50
    elif i == 2:
        lab = 60
    else:
        if iv[1] == 0:
            divset(2, iv, liv, lv, v)
        if 12 <= iv[1] <= 13:
            iv[VNEED_] = iv[VNEED_] + n * (n + 27) // 2 + 7
            iv[IVNEED_] = iv[IVNEED_] + 3 * n
        dparck(2, d, iv, liv, lv, n, v)
        i = int(iv[1]) - 2
        if i > 12:
            return
        nn1o2 = n * (n + 1) // 2
        lab = 0
        if lh >= nn1o2:
            if 1 <= i <= 6:
                lab = 250
            elif i in (7, 9):
                lab = 190
            elif i == 8:
                lab = 150
            elif i in (10, 11):
                lab = 20
            elif i == 12:
                lab = 30
        if lab == 0:
            iv[1] = 81
            lab = 440
    while True:
        if lab == 20:
            nn1o2 = n * (n + 1) // 2
            iv[DTOL] = iv[LMAT_] + nn1o2
            iv[X0] = iv[DTOL] + 2 * n
            iv[STEP] = iv[X0] + 2 * n
            iv[DG] = iv[STEP] + 3 * n
            iv[W] = iv[DG] + 2 * n
            iv[NEXTV_] = iv[W] + 4 * n + 7
            iv[NEXTIV] = iv[PERM_] + 3 * n
            if iv[1] == 13:
                iv[1] = 14
                return
            lab = 30
        if lab == 30:
            iv[NITER_] = 0
            iv[NFCALL_] = 1
            iv[NGCALL] = 1
            iv[NFGCAL_] = 1
            iv[MODE] = -1
            iv[MODEL] = 1
            iv[STGLIM] = 1
            iv[TOOBIG_] = 0
            iv[CNVCOD] = 0
            iv[RADINC] = 0
            iv[NC] = n
            v[RAD0] = ZERO
            v[STPPAR] = ZERO
            if v[DINIT] >= ZERO:
                dv7scp(n, d, v[DINIT])
            k = int(iv[DTOL])
            if v[DTINIT] > ZERO:
                dv7scp(n, _at(v, k), v[DTINIT])
            k = k + n
            if v[D0INIT] > ZERO:
                dv7scp(n, _at(v, k), v[D0INIT])
            ipi = int(iv[PERM_])
            bad = False
            for i in range(1, n + 1):
                iv[ipi] = i
                ipi = ipi + 1
                if b[2 * i - 1] > b[2 * i]:
                    bad = True
                    break
            if bad:
                iv[1] = 82
                lab = 440
                continue
            iv[1] = 1
            lab = 450
            continue
        if lab == 50:
            v[F_] = fx
            if iv[MODE] >= 0:
                lab = 250
                continue
            v[F0_] = fx
            iv[1] = 2
            if iv[TOOBIG_] == 0:
                return
            iv[1] = 63
            lab = 440
            continue
        if lab == 60:
            if iv[TOOBIG_] != 0:
                iv[1] = 65
                lab = 440
                continue
            dg1 = int(iv[DG])
            if iv[DTYPE_] > 0:
                k = dg1
                j = 0
                for i in range(1, n + 1):
                    j = j + i
                    v[k] = h[j]
                    k = k + 1
                dd7dup(d, _at(v, dg1), iv, liv, lv, n, v)
            dg1 = int(iv[DG])
            dv7vmp(n, _at(v, dg1), g, d, -1)
            k = 1
            for i in range(1, n + 1):
                t = ONE / d[i]
                for j in range(1, i + 1):
                    h[k] = t * h[k] / d[j]
                    k = k + 1
            ipi = int(iv[PERM_])
            ipn = ipi + n
            ipiv2 = ipn - 1
            i7pnvr(n, _at(iv, ipn), _at(iv, ipi))
            k = int(iv[NC])
            for i in range(1, n + 1):
                if not (b[2 * i - 1] >= b[2 * i]):
                    xi = x[i]
                    gi = g[i]
                    if not ((xi <= b[2 * i - 1] and gi > ZERO) or (xi >= b[2 * i] and gi < ZERO)):
                        iv[ipi] = i
                        ipi = ipi + 1
                        j = ipiv2 + i
                        if iv[j] > k:
                            iv[CNVCOD] = 0
                        continue
                ipn = ipn - 1
                iv[ipn] = i
            iv[NC] = ipn - iv[PERM_]
            ipi = int(iv[PERM_])
            ds7ipr(n, _at(iv, ipi), h)
            dv7ipr(n, _at(iv, ipi), _at(v, dg1))
            v[DGNORM] = ZERO
            if iv[NC] > 0:
                v[DGNORM] = dv2nrm(int(iv[NC]), _at(v, dg1))
            if iv[CNVCOD] != 0:
                lab = 430
                continue
            if iv[MODE] == 0:
                lab = 380
                continue
            v[RADIUS] = v[LMAX0] / (ONE + v[PHMXFC])
            iv[MODE] = 0
            lab = 140
        if lab == 140:
            ditsum(d, g, iv, liv, lv, n, v, x)
            lab = 150
        if lab == 150:
            k = int(iv[NITER_])
            if not (k < iv[MXITER_]):
                iv[1] = 10
                lab = 440
                continue
            lab = 160
        if lab == 160:
            iv[NITER_] = k + 1
            x01 = int(iv[X0])
            v[F0_] = v[F_]
            iv[IRC] = 4
            iv[KAGQT] = -1
            dv7cpy(n, _at(v, x01), x)
            if k != 0:
                step1 = int(iv[STEP])
                k = step1
                for i in range(1, n + 1):
                    v[k] = d[i] * v[k]
                    k = k + 1
                t = v[RADFAC] * dv2nrm(n, _at(v, step1))
                if v[RADFAC] < ONE or t > v[RADIUS]:
                    v[RADIUS] = t
            lab = 200   # 180: STOPX() ist .FALSE.
        if lab == 190:
            if v[F_] >= v[F0_]:
                lab = 200
            else:
                v[RADFAC] = ONE
                k = int(iv[NITER_])
                lab = 160
                continue
        if lab == 200:
            if not (iv[NFCALL_] < iv[MXFCAL_]):
                iv[1] = 9
                if v[F_] >= v[F0_]:
                    lab = 440
                    continue
                iv[CNVCOD] = iv[1]
                lab = 370
                continue
            lab = 220
        if lab == 220:
            step1 = int(iv[STEP])
            l = int(iv[LMAT_])
            w1 = int(iv[W])
            ipi = int(iv[PERM_])
            ipn = ipi + n
            ipiv2 = ipn + n
            tg1 = int(iv[DG])
            td1 = tg1 + n
            x01 = int(iv[X0])
            x11 = x01 + n
            ka, p0 = dg7qsb(b, d, h, g, _at(iv, ipi), _at(iv, ipn), _at(iv, ipiv2), int(iv[KAGQT]),
                            _at(v, l), lv, n, int(iv[N0]), int(iv[NC]), _at(v, step1),
                            _at(v, td1), _at(v, tg1), v, _at(v, w1), _at(v, x11), _at(v, x01))
            iv[KAGQT] = ka
            iv[N0] = p0
            if iv[IRC] == 6:
                if iv[RESTOR] != 2:
                    lab = 250
                    continue
                rstrst = 2
                lab = 260
                continue
            iv[TOOBIG_] = 0
            if v[DSTNRM] <= ZERO:
                lab = 250
                continue
            if iv[IRC] == 5 and not (v[RADFAC] <= ONE) and not (v[PREDUC] > ONEP2 * v[FDIF_]):
                if iv[RESTOR] != 2:
                    lab = 250
                    continue
                rstrst = 0
                lab = 260
                continue
            dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
            iv[NFCALL_] = iv[NFCALL_] + 1
            iv[1] = 1
            lab = 450
            continue
        if lab == 250:
            rstrst = 3
            lab = 260
        if lab == 260:
            x01 = int(iv[X0])
            v[RELDX] = drldst(n, d, x, _at(v, x01))
            da7sst(iv, liv, lv, v)
            step1 = int(iv[STEP])
            lstgst = step1 + 2 * n
            i = int(iv[RESTOR]) + 1
            if i == 2:
                dv7cpy(n, x, _at(v, x01))
            elif i == 3:
                dv7cpy(n, _at(v, lstgst), x)
            elif i == 4:
                dv7cpy(n, x, _at(v, lstgst))
                dv2axy(n, _at(v, step1), NEGONE, _at(v, x01), x)
                v[RELDX] = drldst(n, d, x, _at(v, x01))
                iv[RESTOR] = rstrst
            k = int(iv[IRC])
            if k in (2, 3, 4):
                lab = 340
                continue
            if k == 6:
                v[RADIUS] = v[LMAXS]
                lab = 220
                continue
            if 7 <= k <= 12:
                iv[CNVCOD] = k - 4
                if v[F_] >= v[F0_]:
                    lab = 430
                    continue
                if iv[XIRC] == 14:
                    lab = 430
                    continue
                iv[XIRC] = 14
                lab = 340
                continue
            if k == 13:
                iv[1] = 64
                lab = 440
                continue
            if k == 14:
                lab = 380
                continue
            v[RADIUS] = v[RADFAC] * v[DSTNRM]
            lab = 200   # 180: STOPX() ist .FALSE.
            continue
        if lab == 340:
            if iv[IRC] == 3:
                temp1 = lstgst
                k = temp1
                step0 = step1 - 1
                ipi = int(iv[PERM_])
                for i in range(1, n + 1):
                    j = int(iv[ipi])
                    ipi = ipi + 1
                    step1 = step0 + j
                    v[k] = d[j] * v[step1]
                    k = k + 1
                ds7lvm(n, _at(v, x01), h, _at(v, temp1))
                temp0 = temp1 - 1
                ipi = int(iv[PERM_])
                for i in range(1, n + 1):
                    j = int(iv[ipi])
                    ipi = ipi + 1
                    temp1 = temp0 + j
                    v[temp1] = d[j] * v[x01] + g[j]
                    x01 = x01 + 1
            lab = 370
        if lab == 370:
            iv[NGCALL] = iv[NGCALL] + 1
            iv[TOOBIG_] = 0
            iv[1] = 2
            lab = 450
            continue
        if lab == 380:
            iv[1] = 2
            if iv[IRC] == 3:
                step1 = int(iv[STEP])
                temp1 = step1 + 2 * n
                k = temp1
                for i in range(1, n + 1):
                    v[k] = (v[k] - g[i]) / d[i]
                    k = k + 1
                if dv2nrm(n, _at(v, temp1)) <= v[DGNORM] * v[TUNER4] or \
                        not (dd7tpr(n, g, _at(v, step1)) >= v[GTSTEP] * v[TUNER5]):
                    v[RADFAC] = v[INCFAC]
            lab = 140
            continue
        if lab == 430:
            iv[1] = iv[CNVCOD]
            iv[CNVCOD] = 0
            lab = 440
        if lab == 440:
            ditsum(d, g, iv, liv, lv, n, v, x)
            return
        if lab == 450:
            for i in range(1, n + 1):
                if x[i] < b[2 * i - 1]:
                    x[i] = b[2 * i - 1]
                if x[i] > b[2 * i]:
                    x[i] = b[2 * i]
            return
        raise RuntimeError("drmnhb: Marke %r" % lab)
