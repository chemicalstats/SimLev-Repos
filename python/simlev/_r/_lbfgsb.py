"""L-BFGS-B wie in R (``src/appl/lbfgsb.c``, Version 2.3 von Zhu/Byrd/Lu/
Nocedal in R's C-Fassung), bitgleich als reiner Python-Port.

Die Indizes folgen der C-Quelle (1-basiert, Felder mit Platzhalter an
Stelle 0, Matrizen spaltenweise flach). BLAS-Aufrufe (``ddot``, ``daxpy``,
``dscal``, ``dcopy``) und LINPACK (``dpofa`` in R's Fassung, ``dtrsl``) sind
als skalare Schleifen nachgebildet (Referenz-BLAS: ``ddot`` sequenziell ab
0, ``daxpy`` kehrt bei ``a == 0`` zurück).

Öffentlich: :func:`lbfgsb` (Signatur wie R's C-Funktion ``lbfgsb`` aus
``optim.c``).
"""
from __future__ import annotations

import math

import numpy as np

__all__ = ["lbfgsb"]

_DBL_EPSILON = np.float64(2.220446049250313e-16)
_Z = np.float64(0.0)
_O = np.float64(1.0)
_sqrt = np.sqrt


def _p(fmt, *a):
    print(fmt % a, end="")


# ── BLAS/LINPACK (skalar) ────────────────────────────────────────────────

def _ddot(n, x, xb, y, yb):
    s = _Z
    for k in range(n):
        s = s + x[xb + k] * y[yb + k]
    return s


def _daxpy(n, a, x, xb, y, yb):
    if n <= 0 or a == 0.0:
        return
    for k in range(n):
        y[yb + k] = y[yb + k] + a * x[xb + k]


def _dcopy(n, x, xb, y, yb):
    for k in range(n):
        y[yb + k] = x[xb + k]


def _dscal(n, a, x, xb):
    for k in range(n):
        x[xb + k] = a * x[xb + k]


def _dpofa(a, base, lda, n):
    """R's ``dpofa`` (mit eps-Test); Element (i,j) = a[base+(i-1)+(j-1)*lda]."""
    eps = 1e-14
    for j in range(1, n + 1):
        info = j
        s = _Z
        jm1 = j - 1
        cj = base + (j - 1) * lda
        for k in range(1, jm1 + 1):
            ck = base + (k - 1) * lda
            t = a[cj + k - 1] - _ddot(k - 1, a, ck, a, cj)
            t = t / a[ck + k - 1]
            a[cj + k - 1] = t
            s = s + t * t
        ajj = a[cj + j - 1]
        s = ajj - s
        if s <= eps * abs(ajj):
            return info
        a[cj + j - 1] = _sqrt(s)
    return 0


def _dtrsl(t, base, ldt, n, b, bb, job):
    """LINPACK ``dtrsl``; T(i,j) = t[base+(i-1)+(j-1)*ldt], b(k) = b[bb+k-1]."""
    def T(i, j):
        return t[base + (i - 1) + (j - 1) * ldt]
    for info in range(1, n + 1):
        if T(info, info) == 0.0:
            return info
    kase = 1
    if job % 10 != 0:
        kase = 2
    if (job % 100) // 10 != 0:
        kase += 2
    if kase == 1:
        b[bb] = b[bb] / T(1, 1)
        for j in range(2, n + 1):
            temp = -b[bb + j - 2]
            _daxpy(n - j + 1, temp, t, base + (j - 1) + (j - 2) * ldt, b, bb + j - 1)
            b[bb + j - 1] = b[bb + j - 1] / T(j, j)
    elif kase == 2:
        b[bb + n - 1] = b[bb + n - 1] / T(n, n)
        for jj in range(2, n + 1):
            j = n - jj + 1
            temp = -b[bb + j]
            _daxpy(j, temp, t, base + j * ldt, b, bb)
            b[bb + j - 1] = b[bb + j - 1] / T(j, j)
    elif kase == 3:
        b[bb + n - 1] = b[bb + n - 1] / T(n, n)
        for jj in range(2, n + 1):
            j = n - jj + 1
            b[bb + j - 1] = b[bb + j - 1] - _ddot(jj - 1, t, base + j + (j - 1) * ldt, b, bb + j)
            b[bb + j - 1] = b[bb + j - 1] / T(j, j)
    else:
        b[bb] = b[bb] / T(1, 1)
        for j in range(2, n + 1):
            b[bb + j - 1] = b[bb + j - 1] - _ddot(j - 1, t, base + (j - 1) * ldt, b, bb)
            b[bb + j - 1] = b[bb + j - 1] / T(j, j)
    return 0


def _cmax(a, b):
    # C-Makro max(a, b): (a < b) ? b : a
    return b if a < b else a


def _cmin(a, b):
    # C-Makro min(a, b): (a > b) ? b : a
    return b if a > b else a


# ── Hauptteil ─────────────────────────────────────────────────────────────

class _State:
    pass


class _LBFGSB:
    def __init__(self, n, m):
        self.n = n
        self.m = m
        # Arbeitsfelder (1-basiert, Index 0 ungenutzt), mit Nullen wie S_alloc
        self.ws = [_Z] * (n * m + 1)
        self.wy = [_Z] * (n * m + 1)
        self.sy = [_Z] * (m * m + 1)
        self.ss = [_Z] * (m * m + 1)
        self.wt = [_Z] * (m * m + 1)
        self.wn = [_Z] * (4 * m * m + 1)
        self.snd = [_Z] * (4 * m * m + 1)
        self.z = [_Z] * (n + 1)
        self.r = [_Z] * (n + 1)
        self.d = [_Z] * (n + 1)
        self.t = [_Z] * (n + 1)
        self.wa = [_Z] * (8 * m + 1)
        self.indx = [0] * (n + 1)
        self.iwhere = [0] * (n + 1)
        self.indx2 = [0] * (n + 1)
        self.csave = ""
        self.ls = _State()        # statische Variablen von dcsrch

    # Matrixindizes (1-basiert, spaltenweise)
    def Wn(self, i, j):  # n×m
        return i + (j - 1) * self.n

    def Mm(self, i, j):  # m×m
        return i + (j - 1) * self.m

    def M2(self, i, j):  # 2m×2m
        return i + (j - 1) * 2 * self.m

    # ------------------------------------------------------------------
    def mainlb(self, x, l, u, nbd, f, g, factr, pgtol, task, iprint, isave):
        """Eine Etappe von ``mainlb``; liefert (task, f)."""
        n, m = self.n, self.m
        S = self
        if task.startswith("START"):
            S.epsmch = _DBL_EPSILON
            S.fold = _Z
            S.dnorm = _Z
            S.gd = _Z
            S.sbgnrm = _Z
            S.stp = _Z
            S.xstep = _Z
            S.stpmx = _Z
            S.gdold = _Z
            S.dtd = _Z
            S.col = 0
            S.head = 1
            S.theta = _O
            S.iupdat = 0
            S.updatd = False
            S.iback = 0
            S.itail = 0
            S.ifun = 0
            S.iword = 0
            S.nact = 0
            S.ileave = 0
            S.nenter = 0
            S.iter = 0
            S.nfgv = 0
            S.nint = 0
            S.nintol = 0
            S.nskip = 0
            S.nfree = n
            S.tol = factr * S.epsmch
            S.word = "---"
            S.info = 0
            S.k = 0
            task = self.errclb(n, m, factr, l, u, nbd, task)
            if task.startswith("ERROR"):
                self.prn3lb(x, f, task, iprint)
                return task, f
            self.prn1lb(l, u, x, iprint)
            self.active(l, u, nbd, x, iprint)
            task = "FG_START"
            return self._finish(x, f, task, iprint, isave)
        else:
            if task.startswith("FG_LN"):
                return self._L666(x, l, u, nbd, f, g, task, iprint, isave)
            if task.startswith("NEW_X"):
                return self._L777(x, l, u, nbd, f, g, pgtol, task, iprint, isave)
            if task.startswith("FG_ST"):
                return self._L111(x, l, u, nbd, f, g, pgtol, task, iprint, isave)
            if task.startswith("STOP"):
                if task[6:9] == "CPU":
                    _dcopy(n, self.t, 1, x, 1)
                    _dcopy(n, self.r, 1, g, 1)
                    f = S.fold
                return self._finish(x, f, task, iprint, isave)
            task = "FG_START"
            return self._finish(x, f, task, iprint, isave)

    def _finish(self, x, f, task, iprint, isave):
        isave[12] = self.nfgv
        self.prn3lb(x, f, task, iprint)
        return task, f

    def _reset(self):
        self.info = 0
        self.col = 0
        self.head = 1
        self.theta = _O
        self.iupdat = 0
        self.updatd = False

    def _L111(self, x, l, u, nbd, f, g, pgtol, task, iprint, isave):
        S = self
        S.nfgv = 1
        S.sbgnrm = self.projgr(l, u, nbd, x, g)
        if iprint >= 1:
            _p("At iterate %5d  f= %12.5g  |proj g|= %12.5g\n", S.iter, f, S.sbgnrm)
        if S.sbgnrm <= pgtol:
            task = "CONVERGENCE: NORM OF PROJECTED GRADIENT <= PGTOL"
            return self._finish(x, f, task, iprint, isave)
        return self._L222(x, l, u, nbd, f, g, task, iprint, isave)

    def _L222(self, x, l, u, nbd, f, g, task, iprint, isave):
        S = self
        n = self.n
        while True:
            if iprint >= 99:
                _p("Iteration %5d\n", S.iter)
            S.iword = -1
            goto333 = False
            if (not S.cnstnd) and S.col > 0:
                _dcopy(n, x, 1, self.z, 1)
                S.wrk = S.updatd
                S.nint = 0
                goto333 = True
            if not goto333:
                info = self.cauchy(x, l, u, nbd, g, iprint)
                if info != 0:
                    if iprint >= 1:
                        _p("%s\n%s\n", "Singular triangular system detected;",
                           "   refresh the lbfgs memory and restart the iteration.")
                    self._reset()
                    continue
                S.nintol += S.nint
                self.freev(iprint)
                S.nact = n - S.nfree
            # L333
            restart = False
            if not (S.nfree == 0 or S.col == 0):
                if S.wrk:
                    S.info = self.formk()
                if S.info != 0:
                    if iprint >= 0:
                        _p("%s\n%s\n", "Nonpositive definiteness in Cholesky factorization in formk;",
                           "   refresh the lbfgs memory and restart the iteration.")
                    self._reset()
                    continue
                S.info = self.cmprlb(x, g)
                if S.info == 0:
                    S.info = self.subsm(l, u, nbd, x, iprint)
                if S.info != 0:
                    if iprint >= 1:
                        _p("%s\n%s\n", "Singular triangular system detected;",
                           "   refresh the lbfgs memory and restart the iteration.")
                    self._reset()
                    restart = True
            if restart:
                continue
            # L555
            for i in range(1, n + 1):
                self.d[i] = self.z[i] - x[i]
            break
        return self._L666(x, l, u, nbd, f, g, task, iprint, isave)

    def _L666(self, x, l, u, nbd, f, g, task, iprint, isave):
        S = self
        n = self.n
        task = self.lnsrlb(l, u, nbd, x, f, g, task)
        if S.info != 0 or S.iback >= 20:
            _dcopy(n, self.t, 1, x, 1)
            _dcopy(n, self.r, 1, g, 1)
            f = S.fold
            if S.col == 0:
                if S.info == 0:
                    S.info = -9
                    S.nfgv -= 1
                    S.ifun -= 1
                    S.iback -= 1
                task = "ERROR: ABNORMAL_TERMINATION_IN_LNSRCH"
                S.iter += 1
                return self._finish(x, f, task, iprint, isave)
            else:
                if iprint >= 1:
                    _p("%s\n%s\n", "Bad direction in the line search;",
                       "   refresh the lbfgs memory and restart the iteration.")
                if S.info == 0:
                    S.nfgv -= 1
                self._reset()
                task = "RESTART_FROM_LNSRCH"
                return self._L222(x, l, u, nbd, f, g, task, iprint, isave)
        elif task.startswith("FG_LN"):
            return self._finish(x, f, task, iprint, isave)
        else:
            S.iter += 1
            S.sbgnrm = self.projgr(l, u, nbd, x, g)
            self.prn2lb(x, f, g, iprint)
            return self._finish(x, f, task, iprint, isave)

    def _L777(self, x, l, u, nbd, f, g, pgtol, task, iprint, isave):
        S = self
        n = self.n
        if S.sbgnrm <= pgtol:
            task = "CONVERGENCE: NORM OF PROJECTED GRADIENT <= PGTOL"
            return self._finish(x, f, task, iprint, isave)
        d1 = abs(S.fold)
        d2 = abs(f)
        d1 = _cmax(d1, d2)
        ddum = _cmax(d1, 1.0)
        if S.fold - f <= S.tol * ddum:
            task = "CONVERGENCE: REL_REDUCTION_OF_F <= FACTR*EPSMCH"
            if S.iback >= 10:
                S.info = -5
            return self._finish(x, f, task, iprint, isave)
        r = self.r
        for i in range(1, n + 1):
            r[i] = g[i] - r[i]
        rr = _ddot(n, r, 1, r, 1)
        if S.stp == 1.0:
            dr = S.gd - S.gdold
            ddum = -S.gdold
        else:
            dr = (S.gd - S.gdold) * S.stp
            _dscal(n, S.stp, self.d, 1)
            ddum = -S.gdold * S.stp
        if dr <= S.epsmch * ddum:
            S.nskip += 1
            S.updatd = False
            if iprint >= 1:
                _p("ys=%10.3e  -gs=%10.3e, BFGS update SKIPPED\n", dr, ddum)
            return self._L222(x, l, u, nbd, f, g, task, iprint, isave)
        S.updatd = True
        S.iupdat += 1
        self.matupd(rr, dr)
        S.info = self.formt()
        if S.info != 0:
            if iprint >= 0:
                _p("%s\n%s\n", "Nonpositive definiteness in Cholesky factorization in formt();",
                   "   refresh the lbfgs memory and restart the iteration.")
            self._reset()
        return self._L222(x, l, u, nbd, f, g, task, iprint, isave)

    # ------------------------------------------------------------------
    def active(self, l, u, nbd, x, iprint):
        n = self.n
        nbdd = 0
        self.prjctd = False
        self.cnstnd = False
        self.boxed = True
        for i in range(1, n + 1):
            if nbd[i] > 0:
                if nbd[i] <= 2 and x[i] <= l[i]:
                    if x[i] < l[i]:
                        self.prjctd = True
                        x[i] = l[i]
                    nbdd += 1
                elif nbd[i] >= 2 and x[i] >= u[i]:
                    if x[i] > u[i]:
                        self.prjctd = True
                        x[i] = u[i]
                    nbdd += 1
        iwhere = self.iwhere
        for i in range(1, n + 1):
            if nbd[i] != 2:
                self.boxed = False
            if nbd[i] == 0:
                iwhere[i] = -1
            else:
                self.cnstnd = True
                if nbd[i] == 2 and u[i] - l[i] <= 0.0:
                    iwhere[i] = 3
                else:
                    iwhere[i] = 0
        if iprint >= 0:
            if self.prjctd:
                _p("The initial X is infeasible.  Restart with its projection.\n")
            if not self.cnstnd:
                _p("This problem is unconstrained.\n")
        if iprint > 0:
            _p("At X0, %d variables are exactly at the bounds\n", nbdd)

    def bmv(self, col, v, vb, p, pb):
        """bmv(m, sy, wt, col, v, p): v(k) = v[vb+k-1], p(k) = p[pb+k-1]."""
        m = self.m
        sy = self.sy
        Mm = self.Mm
        if col == 0:
            return 0
        p[pb + col] = v[vb + col]
        for i in range(2, col + 1):
            i2 = col + i
            s = _Z
            for k in range(1, i):
                s = s + sy[Mm(i, k)] * v[vb + k - 1] / sy[Mm(k, k)]
            p[pb + i2 - 1] = v[vb + i2 - 1] + s
        info = _dtrsl(self.wt, 1, m, col, p, pb + col, 11)
        if info != 0:
            return info
        for i in range(1, col + 1):
            p[pb + i - 1] = v[vb + i - 1] / _sqrt(sy[Mm(i, i)])
        info = _dtrsl(self.wt, 1, m, col, p, pb + col, 1)
        if info != 0:
            return info
        for i in range(1, col + 1):
            p[pb + i - 1] = -p[pb + i - 1] / _sqrt(sy[Mm(i, i)])
        for i in range(1, col + 1):
            s = _Z
            for k in range(i + 1, col + 1):
                s = s + sy[Mm(k, i)] * p[pb + col + k - 1] / sy[Mm(i, i)]
            p[pb + i - 1] = p[pb + i - 1] + s
        return 0

    def cauchy(self, x, l, u, nbd, g, iprint):
        S = self
        n, m = self.n, self.m
        wy, ws = self.wy, self.ws
        Wn = self.Wn
        xcp = self.z
        d = self.d
        t = self.t
        iwhere = self.iwhere
        iorder = self.indx2
        wa = self.wa
        P = 1             # p   = wa[1..2m]
        C = 2 * m + 1     # c   = wa[2m+1..4m]
        WBP = 4 * m + 1   # wbp = wa[4m+1..6m]
        V = 6 * m + 1     # v   = wa[6m+1..8m]
        col = S.col
        theta = S.theta
        if S.sbgnrm <= 0.0:
            if iprint >= 0:
                _p("Subgnorm = 0.  GCP = X.\n")
            _dcopy(n, x, 1, xcp, 1)
            return 0
        bnded = True
        nfree = n + 1
        nbreak = 0
        ibkmin = 0
        bkmin = _Z
        col2 = col << 1
        f1 = _Z
        tl = _Z
        tu = _Z
        if iprint >= 99:
            _p("\n---------------- CAUCHY entered-------------------\n\n")
        for i in range(1, col2 + 1):
            wa[P + i - 1] = _Z
        for i in range(1, n + 1):
            neggi = -g[i]
            if iwhere[i] != 3 and iwhere[i] != -1:
                if nbd[i] <= 2:
                    tl = x[i] - l[i]
                if nbd[i] >= 2:
                    tu = u[i] - x[i]
                xlower = nbd[i] <= 2 and tl <= 0.0
                xupper = nbd[i] >= 2 and tu <= 0.0
                iwhere[i] = 0
                if xlower:
                    if neggi <= 0.0:
                        iwhere[i] = 1
                elif xupper:
                    if neggi >= 0.0:
                        iwhere[i] = 2
                else:
                    if abs(neggi) <= 0.0:
                        iwhere[i] = -3
            pointr = S.head
            if iwhere[i] != 0 and iwhere[i] != -1:
                d[i] = _Z
            else:
                d[i] = neggi
                f1 -= neggi * neggi
                for j in range(1, col + 1):
                    wa[P + j - 1] += wy[Wn(i, pointr)] * neggi
                    wa[P + col + j - 1] += ws[Wn(i, pointr)] * neggi
                    pointr = pointr % m + 1
                if nbd[i] <= 2 and nbd[i] != 0 and neggi < 0.0:
                    nbreak += 1
                    iorder[nbreak] = i
                    t[nbreak] = tl / (-neggi)
                    if nbreak == 1 or t[nbreak] < bkmin:
                        bkmin = t[nbreak]
                        ibkmin = nbreak
                elif nbd[i] >= 2 and neggi > 0.0:
                    nbreak += 1
                    iorder[nbreak] = i
                    t[nbreak] = tu / neggi
                    if nbreak == 1 or t[nbreak] < bkmin:
                        bkmin = t[nbreak]
                        ibkmin = nbreak
                else:
                    nfree -= 1
                    iorder[nfree] = i
                    if abs(neggi) > 0.0:
                        bnded = False
        if theta != 1.0:
            _dscal(col, theta, wa, P + col)
        _dcopy(n, x, 1, xcp, 1)
        if nbreak == 0 and nfree == n + 1:
            if iprint > 100:
                _p("Cauchy X =  ")
                for i in range(1, n + 1):
                    _p("%g ", xcp[i])
                _p("\n")
            return 0
        for j in range(1, col2 + 1):
            wa[C + j - 1] = _Z
        f2 = -theta * f1
        f2_org = f2
        if col > 0:
            info = self.bmv(col, wa, P, wa, V)
            if info != 0:
                return info
            f2 -= _ddot(col2, wa, V, wa, P)
        dtm = -f1 / f2
        tsum = _Z
        S.nint = 1
        if iprint >= 99:
            _p("There are %d  breakpoints\n", nbreak)
        goto999 = False
        if nbreak != 0:
            nleft = nbreak
            it = 1
            tj = _Z
            while True:
                # L777
                tj0 = tj
                if it == 1:
                    tj = bkmin
                    ibp = iorder[ibkmin]
                else:
                    if it == 2:
                        if ibkmin != nbreak:
                            t[ibkmin] = t[nbreak]
                            iorder[ibkmin] = iorder[nbreak]
                    self.hpsolb(nleft, t, iorder, it - 2)
                    tj = t[nleft]
                    ibp = iorder[nleft]
                dt = tj - tj0
                if dt != 0 and iprint >= 100:
                    _p("\nPiece    %3i f1, f2 at start point %11.4e %11.4e\n", S.nint, f1, f2)
                    _p("Distance to the next break point =  %11.4e\n", dt)
                    _p("Distance to the stationary point =  %11.4e\n", dtm)
                if dtm < dt:
                    break                     # → L888
                tsum += dt
                nleft -= 1
                it += 1
                dibp = d[ibp]
                d[ibp] = _Z
                if dibp > 0.0:
                    zibp = u[ibp] - x[ibp]
                    xcp[ibp] = u[ibp]
                    iwhere[ibp] = 2
                else:
                    zibp = l[ibp] - x[ibp]
                    xcp[ibp] = l[ibp]
                    iwhere[ibp] = 1
                if iprint >= 100:
                    _p("Variable  %d  is fixed.\n", ibp)
                if nleft == 0 and nbreak == n:
                    dtm = dt
                    goto999 = True
                    break
                S.nint += 1
                dibp2 = dibp * dibp
                f1 += ((dt * f2 + dibp2) - (theta * dibp) * zibp)
                f2 -= theta * dibp2
                if col > 0:
                    _daxpy(col2, dt, wa, P, wa, C)
                    pointr = S.head
                    for j in range(1, col + 1):
                        wa[WBP + j - 1] = wy[Wn(ibp, pointr)]
                        wa[WBP + col + j - 1] = theta * ws[Wn(ibp, pointr)]
                        pointr = pointr % m + 1
                    info = self.bmv(col, wa, WBP, wa, V)
                    if info != 0:
                        return info
                    wmc = _ddot(col2, wa, C, wa, V)
                    wmp = _ddot(col2, wa, P, wa, V)
                    wmw = _ddot(col2, wa, WBP, wa, V)
                    _daxpy(col2, -dibp, wa, WBP, wa, P)
                    f1 += dibp * wmc
                    f2 += ((2.0 * dibp) * wmp - dibp2 * wmw)
                d1 = S.epsmch * f2_org
                if f2 < d1:
                    f2 = d1
                if nleft > 0:
                    dtm = -f1 / f2
                    continue
                elif bnded:
                    f1 = _Z
                    f2 = _Z
                    dtm = _Z
                else:
                    dtm = -f1 / f2
                break
        if not goto999:
            # L888
            if iprint >= 99:
                _p("\nGCP found in this segment\n")
                _p("Piece    %3i f1, f2 at start point %11.4e %11.4e\n", S.nint, f1, f2)
                _p("Distance to the stationary point =  %11.4e\n", dtm)
            if dtm <= 0.0:
                dtm = _Z
            tsum += dtm
            _daxpy(n, tsum, d, 1, xcp, 1)
        # L999
        if col > 0:
            _daxpy(col2, dtm, wa, P, wa, C)
        if iprint >= 100:
            _p("Cauchy X =  ")
            for i in range(1, n + 1):
                _p("%g ", xcp[i])
            _p("\n")
        if iprint >= 99:
            _p("\n---------------- exit CAUCHY----------------------\n\n")
        return 0

    def cmprlb(self, x, g):
        S = self
        n, m = self.n, self.m
        Wn = self.Wn
        r = self.r
        z = self.z
        wa = self.wa
        indx = self.indx
        col = S.col
        if (not S.cnstnd) and col > 0:
            for i in range(1, n + 1):
                r[i] = -g[i]
        else:
            nf = S.nfree
            for i in range(1, nf + 1):
                k = indx[i]
                r[i] = -S.theta * (z[k] - x[k]) - g[k]
            info = self.bmv(col, wa, 2 * m + 1, wa, 1)
            if info != 0:
                return -8
            pointr = S.head
            wy, ws = self.wy, self.ws
            for j in range(1, col + 1):
                a1 = wa[j]
                a2 = S.theta * wa[col + j]
                for i in range(1, nf + 1):
                    k = indx[i]
                    r[i] += (wy[Wn(k, pointr)] * a1 + ws[Wn(k, pointr)] * a2)
                pointr = pointr % m + 1
        return 0

    def errclb(self, n, m, factr, l, u, nbd, task):
        if n <= 0:
            task = "ERROR: N .LE. 0"
        if m <= 0:
            task = "ERROR: M .LE. 0"
        if factr < 0.0:
            task = "ERROR: FACTR .LT. 0"
        for i in range(1, n + 1):
            if nbd[i] < 0 or nbd[i] > 3:
                task = "ERROR: INVALID NBD"
                self.info = -6
                self.k = i
            if nbd[i] == 2:
                if l[i] > u[i]:
                    task = "ERROR: NO FEASIBLE SOLUTION"
                    self.info = -7
                    self.k = i
        return task

    def formk(self):
        S = self
        n, m = self.n, self.m
        ind = self.indx
        indx2 = self.indx2
        wn = self.wn
        wn1 = self.snd
        ws, wy, sy = self.ws, self.wy, self.sy
        Wn, Mm, M2 = self.Wn, self.Mm, self.M2
        col = S.col
        head = S.head
        if S.updatd:
            if S.iupdat > m:
                for jy in range(1, m):
                    js = m + jy
                    i2 = m - jy
                    _dcopy(i2, wn1, M2(jy + 1, jy + 1), wn1, M2(jy, jy))
                    _dcopy(i2, wn1, M2(js + 1, js + 1), wn1, M2(js, js))
                    _dcopy(m - 1, wn1, M2(m + 2, jy + 1), wn1, M2(m + 1, jy))
            pbegin = 1
            pend = S.nfree
            dbegin = S.nfree + 1
            dend = n
            iy = col
            is_ = m + col
            ipntr = head + col - 1
            if ipntr > m:
                ipntr -= m
            jpntr = head
            for jy in range(1, col + 1):
                js = m + jy
                temp1 = _Z
                temp2 = _Z
                temp3 = _Z
                for k in range(pbegin, pend + 1):
                    k1 = ind[k]
                    temp1 += wy[Wn(k1, ipntr)] * wy[Wn(k1, jpntr)]
                for k in range(dbegin, dend + 1):
                    k1 = ind[k]
                    temp2 += ws[Wn(k1, ipntr)] * ws[Wn(k1, jpntr)]
                    temp3 += ws[Wn(k1, ipntr)] * wy[Wn(k1, jpntr)]
                wn1[M2(iy, jy)] = temp1
                wn1[M2(is_, js)] = temp2
                wn1[M2(is_, jy)] = temp3
                jpntr = jpntr % m + 1
            jy = col
            jpntr = head + col - 1
            if jpntr > m:
                jpntr -= m
            ipntr = head
            for i in range(1, col + 1):
                is_ = m + i
                temp3 = _Z
                for k in range(pbegin, pend + 1):
                    k1 = ind[k]
                    temp3 += ws[Wn(k1, ipntr)] * wy[Wn(k1, jpntr)]
                ipntr = ipntr % m + 1
                wn1[M2(is_, jy)] = temp3
            upcl = col - 1
        else:
            upcl = col
        ipntr = head
        for iy in range(1, upcl + 1):
            is_ = m + iy
            jpntr = head
            for jy in range(1, iy + 1):
                js = m + jy
                temp1 = _Z
                temp2 = _Z
                temp3 = _Z
                temp4 = _Z
                for k in range(1, S.nenter + 1):
                    k1 = indx2[k]
                    temp1 += wy[Wn(k1, ipntr)] * wy[Wn(k1, jpntr)]
                    temp2 += ws[Wn(k1, ipntr)] * ws[Wn(k1, jpntr)]
                for k in range(S.ileave, n + 1):
                    k1 = indx2[k]
                    temp3 += wy[Wn(k1, ipntr)] * wy[Wn(k1, jpntr)]
                    temp4 += ws[Wn(k1, ipntr)] * ws[Wn(k1, jpntr)]
                wn1[M2(iy, jy)] = (wn1[M2(iy, jy)] + temp1) - temp3
                wn1[M2(is_, js)] = (wn1[M2(is_, js)] - temp2) + temp4
                jpntr = jpntr % m + 1
            ipntr = ipntr % m + 1
        ipntr = head
        for is_ in range(m + 1, m + upcl + 1):
            jpntr = head
            for jy in range(1, upcl + 1):
                temp1 = _Z
                temp3 = _Z
                for k in range(1, S.nenter + 1):
                    k1 = indx2[k]
                    temp1 += ws[Wn(k1, ipntr)] * wy[Wn(k1, jpntr)]
                for k in range(S.ileave, n + 1):
                    k1 = indx2[k]
                    temp3 += ws[Wn(k1, ipntr)] * wy[Wn(k1, jpntr)]
                if is_ <= jy + m:
                    wn1[M2(is_, jy)] += temp1 - temp3
                else:
                    wn1[M2(is_, jy)] += -temp1 + temp3
                jpntr = jpntr % m + 1
            ipntr = ipntr % m + 1
        m2 = m << 1
        for iy in range(1, col + 1):
            is_ = col + iy
            is1 = m + iy
            for jy in range(1, iy + 1):
                js = col + jy
                js1 = m + jy
                wn[M2(jy, iy)] = wn1[M2(iy, jy)] / S.theta
                wn[M2(js, is_)] = wn1[M2(is1, js1)] * S.theta
            for jy in range(1, iy):
                wn[M2(jy, is_)] = -wn1[M2(is1, jy)]
            for jy in range(iy, col + 1):
                wn[M2(jy, is_)] = wn1[M2(is1, jy)]
            wn[M2(iy, iy)] += sy[Mm(iy, iy)]
        info = _dpofa(wn, 1, m2, col)
        if info != 0:
            return -1
        col2 = col << 1
        for js in range(col + 1, col2 + 1):
            _dtrsl(wn, 1, m2, col, wn, M2(1, js), 11)
        for is_ in range(col + 1, col2 + 1):
            for js in range(is_, col2 + 1):
                wn[M2(is_, js)] += _ddot(col, wn, M2(1, is_), wn, M2(1, js))
        info = _dpofa(wn, M2(col + 1, col + 1), m2, col)
        if info != 0:
            return -2
        return 0

    def formt(self):
        S = self
        m = self.m
        wt, sy, ss = self.wt, self.sy, self.ss
        Mm = self.Mm
        col = S.col
        for j in range(1, col + 1):
            wt[Mm(1, j)] = S.theta * ss[Mm(1, j)]
        for i in range(2, col + 1):
            for j in range(i, col + 1):
                k1 = (j if i > j else i - 1)      # C-Makro: min(i,j) - 1
                ddum = _Z
                for k in range(1, k1 + 1):
                    ddum += sy[Mm(i, k)] * sy[Mm(j, k)] / sy[Mm(k, k)]
                wt[Mm(i, j)] = ddum + S.theta * ss[Mm(i, j)]
        info = _dpofa(wt, 1, m, col)
        if info != 0:
            return -3
        return 0

    def freev(self, iprint):
        S = self
        n = self.n
        indx = self.indx
        indx2 = self.indx2
        iwhere = self.iwhere
        S.nenter = 0
        S.ileave = n + 1
        if S.iter > 0 and S.cnstnd:
            for i in range(1, S.nfree + 1):
                k = indx[i]
                if iwhere[k] > 0:
                    S.ileave -= 1
                    indx2[S.ileave] = k
                    if iprint >= 100:
                        _p("Variable %d leaves the set of free variables\n", k)
            for i in range(S.nfree + 1, n + 1):
                k = indx[i]
                if iwhere[k] <= 0:
                    S.nenter += 1
                    indx2[S.nenter] = k
                    if iprint >= 100:
                        _p("Variable %d enters the set of free variables\n", k)
                if iprint >= 100:
                    _p("%d variables leave; %d variables enter\n", n + 1 - S.ileave, S.nenter)
        S.wrk = S.ileave < n + 1 or S.nenter > 0 or S.updatd
        S.nfree = 0
        iact = n + 1
        for i in range(1, n + 1):
            if iwhere[i] <= 0:
                S.nfree += 1
                indx[S.nfree] = i
            else:
                iact -= 1
                indx[iact] = i
        if iprint >= 99:
            _p("%d  variables are free at GCP on iteration %d\n", S.nfree, S.iter + 1)

    @staticmethod
    def hpsolb(n, t, iorder, iheap):
        if iheap == 0:
            for k in range(2, n + 1):
                ddum = t[k]
                indxin = iorder[k]
                i = k
                while i > 1:
                    j = i // 2
                    if ddum < t[j]:
                        t[i] = t[j]
                        iorder[i] = iorder[j]
                        i = j
                    else:
                        break
                t[i] = ddum
                iorder[i] = indxin
        if n > 1:
            i = 1
            out = t[1]
            indxou = iorder[1]
            ddum = t[n]
            indxin = iorder[n]
            while True:
                j = i + i
                if j <= n - 1:
                    if t[j + 1] < t[j]:
                        j += 1
                    if t[j] < ddum:
                        t[i] = t[j]
                        iorder[i] = iorder[j]
                        i = j
                        continue
                break
            t[i] = ddum
            iorder[i] = indxin
            t[n] = out
            iorder[n] = indxou

    def lnsrlb(self, l, u, nbd, x, f, g, task):
        S = self
        n = self.n
        d, t, r, z = self.d, self.t, self.r, self.z
        stpmin = _Z
        ftol = 0.001
        gtol = 0.9
        xtol = 0.1
        if not task.startswith("FG_LN"):
            S.dtd = _ddot(n, d, 1, d, 1)
            S.dnorm = _sqrt(S.dtd)
            S.stpmx = 1e10
            if S.cnstnd:
                if S.iter == 0:
                    S.stpmx = _O
                else:
                    for i in range(1, n + 1):
                        a1 = d[i]
                        if nbd[i] != 0:
                            if a1 < 0.0 and nbd[i] <= 2:
                                a2 = l[i] - x[i]
                                if a2 >= 0.0:
                                    S.stpmx = _Z
                                elif a1 * S.stpmx < a2:
                                    S.stpmx = a2 / a1
                            elif a1 > 0.0 and nbd[i] >= 2:
                                a2 = u[i] - x[i]
                                if a2 <= 0.0:
                                    S.stpmx = _Z
                                elif a1 * S.stpmx > a2:
                                    S.stpmx = a2 / a1
            if S.iter == 0 and not S.boxed:
                d1 = 1.0 / S.dnorm if S.dnorm != 0.0 else math.inf
                S.stp = _cmin(d1, S.stpmx)
            else:
                S.stp = _O
            _dcopy(n, x, 1, t, 1)
            _dcopy(n, g, 1, r, 1)
            S.fold = f
            S.ifun = 0
            S.iback = 0
            S.csave = "START"
        # L556
        S.gd = _ddot(n, g, 1, d, 1)
        if S.ifun == 0:
            S.gdold = S.gd
            if S.gd >= 0.0:
                S.info = -4
                return task
        S.csave = self.dcsrch(f, S.gd, ftol, gtol, xtol, stpmin, S.stpmx, S.csave)
        S.xstep = S.stp * S.dnorm
        if not S.csave.startswith("CONV") and not S.csave.startswith("WARN"):
            task = "FG_LNSRCH"
            S.ifun += 1
            S.nfgv += 1
            S.iback = S.ifun - 1
            if S.stp == 1.0:
                _dcopy(n, z, 1, x, 1)
            else:
                for i in range(1, n + 1):
                    x[i] = S.stp * d[i] + t[i]
        else:
            task = "NEW_X"
        return task

    def matupd(self, rr, dr):
        S = self
        n, m = self.n, self.m
        ws, wy, sy, ss = self.ws, self.wy, self.sy, self.ss
        Wn, Mm = self.Wn, self.Mm
        d, r = self.d, self.r
        if S.iupdat <= m:
            S.col = S.iupdat
            S.itail = (S.head + S.iupdat - 2) % m + 1
        else:
            S.itail = S.itail % m + 1
            S.head = S.head % m + 1
        _dcopy(n, d, 1, ws, Wn(1, S.itail))
        _dcopy(n, r, 1, wy, Wn(1, S.itail))
        S.theta = rr / dr
        col = S.col
        if S.iupdat > m:
            for j in range(1, col):
                _dcopy(j, ss, Mm(2, j + 1), ss, Mm(1, j))
                _dcopy(col - j, sy, Mm(j + 1, j + 1), sy, Mm(j, j))
        pointr = S.head
        for j in range(1, col):
            sy[Mm(col, j)] = _ddot(n, d, 1, wy, Wn(1, pointr))
            ss[Mm(j, col)] = _ddot(n, ws, Wn(1, pointr), d, 1)
            pointr = pointr % m + 1
        if S.stp == 1.0:
            ss[Mm(col, col)] = S.dtd
        else:
            ss[Mm(col, col)] = S.stp * S.stp * S.dtd
        sy[Mm(col, col)] = dr

    def projgr(self, l, u, nbd, x, g):
        sbgnrm = _Z
        for i in range(1, self.n + 1):
            gi = g[i]
            if nbd[i] != 0:
                if gi < 0.0:
                    if nbd[i] >= 2:
                        d1 = x[i] - u[i]
                        if gi < d1:
                            gi = d1
                else:
                    if nbd[i] <= 2:
                        d1 = x[i] - l[i]
                        if gi > d1:
                            gi = d1
            d1 = abs(gi)
            if sbgnrm < d1:
                sbgnrm = d1
        return sbgnrm

    def subsm(self, l, u, nbd, x, iprint):
        S = self
        n, m = self.n, self.m
        ind = self.indx
        d = self.r              # subsm(..., &z[1], &r[1], ...) → x = z, d = r
        xx = self.z
        ws, wy = self.ws, self.wy
        wn = self.wn
        wv = self.wa            # wv = wa[1..2m]
        M2 = self.M2
        theta = S.theta
        col = S.col
        ns = S.nfree
        if ns <= 0:
            return 0
        pointr = S.head
        for i in range(1, col + 1):
            temp1 = _Z
            temp2 = _Z
            for j in range(1, ns + 1):
                k = ind[j]
                temp1 += wy[k + (pointr - 1) * n] * d[j]
                temp2 += ws[k + (pointr - 1) * n] * d[j]
            wv[i] = temp1
            wv[col + i] = theta * temp2
            pointr = pointr % m + 1
        m2 = m << 1
        col2 = col << 1
        info = _dtrsl(wn, 1, m2, col2, wv, 1, 11)
        if info != 0:
            return info
        for i in range(1, col + 1):
            wv[i] = -wv[i]
        info = _dtrsl(wn, 1, m2, col2, wv, 1, 1)
        if info != 0:
            return info
        pointr = S.head
        for jy in range(1, col + 1):
            js = col + jy
            for i in range(1, ns + 1):
                k = ind[i]
                d[i] += (wy[k + (pointr - 1) * n] * wv[jy] / theta + ws[k + (pointr - 1) * n] * wv[js])
            pointr = pointr % m + 1
        for i in range(1, ns + 1):
            d[i] /= theta
        alpha = _O
        temp1 = alpha
        ibd = 0
        for i in range(1, ns + 1):
            k = ind[i]
            dk = d[i]
            if nbd[k] != 0:
                if dk < 0.0 and nbd[k] <= 2:
                    temp2 = l[k] - xx[k]
                    if temp2 >= 0.0:
                        temp1 = _Z
                    elif dk * alpha < temp2:
                        temp1 = temp2 / dk
                elif dk > 0.0 and nbd[k] >= 2:
                    temp2 = u[k] - xx[k]
                    if temp2 <= 0.0:
                        temp1 = _Z
                    elif dk * alpha > temp2:
                        temp1 = temp2 / dk
                if temp1 < alpha:
                    alpha = temp1
                    ibd = i
        if alpha < 1.0:
            dk = d[ibd]
            k = ind[ibd]
            if dk > 0.0:
                xx[k] = u[k]
                d[ibd] = _Z
            elif dk < 0.0:
                xx[k] = l[k]
                d[ibd] = _Z
        for i in range(1, ns + 1):
            xx[ind[i]] += alpha * d[i]
        S.iword = 1 if alpha < 1.0 else 0
        return 0

    def dcsrch(self, f, g, ftol, gtol, xtol, stpmin, stpmax, task):
        L = self.ls
        S = self
        if task.startswith("START"):
            if S.stp < stpmin:
                task = "ERROR: STP .LT. STPMIN"
            if S.stp > stpmax:
                task = "ERROR: STP .GT. STPMAX"
            if g >= 0.0:
                task = "ERROR: INITIAL G .GE. ZERO"
            if ftol < 0.0:
                task = "ERROR: FTOL .LT. ZERO"
            if gtol < 0.0:
                task = "ERROR: GTOL .LT. ZERO"
            if xtol < 0.0:
                task = "ERROR: XTOL .LT. ZERO"
            if stpmin < 0.0:
                task = "ERROR: STPMIN .LT. ZERO"
            if stpmax < stpmin:
                task = "ERROR: STPMAX .LT. STPMIN"
            if task.startswith("ERROR"):
                return task
            L.brackt = False
            L.stage = 1
            L.finit = f
            L.ginit = g
            L.gtest = ftol * L.ginit
            L.width = stpmax - stpmin
            L.width1 = L.width / 0.5
            L.stx = _Z
            L.fx = L.finit
            L.gx = L.ginit
            L.sty = _Z
            L.fy = L.finit
            L.gy = L.ginit
            L.stmin = _Z
            L.stmax = S.stp + S.stp * 4.0
            return "FG"
        ftest = L.finit + S.stp * L.gtest
        if L.stage == 1 and f <= ftest and g >= 0.0:
            L.stage = 2
        if L.brackt and (S.stp <= L.stmin or S.stp >= L.stmax):
            task = "WARNING: ROUNDING ERRORS PREVENT PROGRESS"
        if L.brackt and L.stmax - L.stmin <= xtol * L.stmax:
            task = "WARNING: XTOL TEST SATISFIED"
        if S.stp == stpmax and f <= ftest and g <= L.gtest:
            task = "WARNING: STP = STPMAX"
        if S.stp == stpmin and (f > ftest or g >= L.gtest):
            task = "WARNING: STP = STPMIN"
        if f <= ftest and abs(g) <= gtol * (-L.ginit):
            task = "CONVERGENCE"
        if task.startswith("WARN") or task.startswith("CONV"):
            return task
        if L.stage == 1 and f <= L.fx and f > ftest:
            fm = f - S.stp * L.gtest
            fxm = L.fx - L.stx * L.gtest
            fym = L.fy - L.sty * L.gtest
            gm = g - L.gtest
            gxm = L.gx - L.gtest
            gym = L.gy - L.gtest
            (L.stx, fxm, gxm, L.sty, fym, gym, S.stp, L.brackt) = _dcstep(
                L.stx, fxm, gxm, L.sty, fym, gym, S.stp, fm, gm, L.brackt, L.stmin, L.stmax)
            L.fx = fxm + L.stx * L.gtest
            L.fy = fym + L.sty * L.gtest
            L.gx = gxm + L.gtest
            L.gy = gym + L.gtest
        else:
            (L.stx, L.fx, L.gx, L.sty, L.fy, L.gy, S.stp, L.brackt) = _dcstep(
                L.stx, L.fx, L.gx, L.sty, L.fy, L.gy, S.stp, f, g, L.brackt, L.stmin, L.stmax)
        if L.brackt:
            if abs(L.sty - L.stx) >= L.width1 * 0.66:
                S.stp = L.stx + (L.sty - L.stx) * 0.5
            L.width1 = L.width
            L.width = abs(L.sty - L.stx)
        if L.brackt:
            L.stmin = _cmin(L.stx, L.sty)
            L.stmax = _cmax(L.stx, L.sty)
        else:
            L.stmin = S.stp + (S.stp - L.stx) * 1.1
            L.stmax = S.stp + (S.stp - L.stx) * 4.0
        if S.stp < stpmin:
            S.stp = stpmin
        if S.stp > stpmax:
            S.stp = stpmax
        if (L.brackt and (S.stp <= L.stmin or S.stp >= L.stmax)) or \
                (L.brackt and (L.stmax - L.stmin <= xtol * L.stmax)):
            S.stp = L.stx
        return "FG"

    # Ausgaben (wie R's prn*lb)
    def prn1lb(self, l, u, x, iprint):
        if iprint >= 0:
            _p("N = %d, M = %d machine precision = %g\n", self.n, self.m, self.epsmch)
            if iprint >= 100:
                for title, v in (("L =", l), ("X0 =", x), ("U =", u)):
                    _p("%s ", title)
                    for i in range(1, self.n + 1):
                        _p("%g ", v[i])
                    _p("\n")

    def prn2lb(self, x, f, g, iprint):
        S = self
        if iprint >= 99:
            _p("LINE SEARCH %d times; norm of step = %g\n", S.iback, S.xstep)
            if iprint > 100:
                for title, v in (("X =", x), ("G =", g)):
                    _p("%s ", title)
                    for i in range(1, self.n + 1):
                        _p("%g ", v[i])
                    _p("\n")
        elif iprint > 0 and S.iter % iprint == 0:
            _p("At iterate %5d  f = %12.5g  |proj g|=  %12.5g\n", S.iter, f, S.sbgnrm)

    def prn3lb(self, x, f, task, iprint):
        S = self
        if task.startswith("CONV"):
            if iprint >= 0:
                _p("\niterations %d\nfunction evaluations %d\nsegments explored during Cauchy searches %d\n"
                   "BFGS updates skipped %d\nactive bounds at final generalized Cauchy point %d\n"
                   "norm of the final projected gradient %g\nfinal function value %g\n\n",
                   S.iter, S.nfgv, S.nintol, S.nskip, S.nact, S.sbgnrm, f)
            if iprint >= 100:
                _p("%s ", "X =")
                for i in range(1, self.n + 1):
                    _p("%g ", x[i])
                _p("\n")
            if iprint >= 1:
                _p("F = %g\n", f)
        if iprint >= 0:
            msgs = {-1: "Matrix in 1st Cholesky factorization in formk is not Pos. Def.",
                    -2: "Matrix in 2st Cholesky factorization in formk is not Pos. Def.",
                    -3: "Matrix in the Cholesky factorization in formt is not Pos. Def.",
                    -4: "Derivative >= 0, backtracking line search impossible.",
                    -5: "Warning:  more than 10 function and gradient evaluations\n   in the last line search\n",
                    -8: "The triangular system is singular.",
                    -9: "Line search cannot locate an adequate point after 20 function\nand gradient evaluations\n"}
            if S.info in msgs:
                _p("%s", msgs[S.info])
            elif S.info == -6:
                _p("Input nbd(%d) is invalid", S.k)
            elif S.info == -7:
                _p("l(%d) > u(%d).  No feasible solution", S.k, S.k)


def _dcstep(stx, fx, dx, sty, fy, dy, stp, fp, dp, brackt, stpmin, stpmax):
    sqrt = math.sqrt
    sgnd = dp * (dx / abs(dx))
    if fp > fx:
        theta = (fx - fp) * 3.0 / (stp - stx) + dx + dp
        s = _cmax(_cmax(abs(theta), abs(dx)), abs(dp))
        d1 = theta / s
        gamm = s * sqrt(d1 * d1 - dx / s * (dp / s))
        if stp < stx:
            gamm = -gamm
        p = gamm - dx + theta
        q = gamm - dx + gamm + dp
        r = p / q
        stpc = stx + r * (stp - stx)
        stpq = stx + dx / ((fx - fp) / (stp - stx) + dx) / 2.0 * (stp - stx)
        if abs(stpc - stx) < abs(stpq - stx):
            stpf = stpc
        else:
            stpf = stpc + (stpq - stpc) / 2.0
        brackt = True
    elif sgnd < 0.0:
        theta = (fx - fp) * 3.0 / (stp - stx) + dx + dp
        s = _cmax(_cmax(abs(theta), abs(dx)), abs(dp))
        d1 = theta / s
        gamm = s * sqrt(d1 * d1 - dx / s * (dp / s))
        if stp > stx:
            gamm = -gamm
        p = gamm - dp + theta
        q = gamm - dp + gamm + dx
        r = p / q
        stpc = stp + r * (stx - stp)
        stpq = stp + dp / (dp - dx) * (stx - stp)
        if abs(stpc - stp) > abs(stpq - stp):
            stpf = stpc
        else:
            stpf = stpq
        brackt = True
    elif abs(dp) < abs(dx):
        theta = (fx - fp) * 3.0 / (stp - stx) + dx + dp
        s = _cmax(_cmax(abs(theta), abs(dx)), abs(dp))
        d1 = theta / s
        d1 = d1 * d1 - dx / s * (dp / s)
        gamm = 0.0 if d1 < 0 else s * sqrt(d1)
        if stp > stx:
            gamm = -gamm
        p = gamm - dp + theta
        q = gamm + (dx - dp) + gamm
        r = p / q
        if r < 0.0 and gamm != 0.0:
            stpc = stp + r * (stx - stp)
        elif stp > stx:
            stpc = stpmax
        else:
            stpc = stpmin
        stpq = stp + dp / (dp - dx) * (stx - stp)
        if brackt:
            if abs(stpc - stp) < abs(stpq - stp):
                stpf = stpc
            else:
                stpf = stpq
            d1 = stp + (sty - stp) * 0.66
            if stp > stx:
                stpf = _cmin(d1, stpf)
            else:
                stpf = _cmax(d1, stpf)
        else:
            if abs(stpc - stp) > abs(stpq - stp):
                stpf = stpc
            else:
                stpf = stpq
            stpf = _cmin(stpmax, stpf)
            stpf = _cmax(stpmin, stpf)
    else:
        if brackt:
            theta = (fp - fy) * 3.0 / (sty - stp) + dy + dp
            s = _cmax(_cmax(abs(theta), abs(dy)), abs(dp))
            d1 = theta / s
            gamm = s * sqrt(d1 * d1 - dy / s * (dp / s))
            if stp > sty:
                gamm = -gamm
            p = gamm - dp + theta
            q = gamm - dp + gamm + dy
            r = p / q
            stpc = stp + r * (sty - stp)
            stpf = stpc
        elif stp > stx:
            stpf = stpmax
        else:
            stpf = stpmin
    if fp > fx:
        sty = stp
        fy = fp
        dy = dp
    else:
        if sgnd < 0.0:
            sty = stx
            fy = fx
            dy = dx
        stx = stp
        fx = fp
        dx = dp
    stp = stpf
    return stx, fx, dx, sty, fy, dy, stp, brackt


def lbfgsb(n, m, x, l, u, nbd, fminfn, fmingr, factr, pgtol, maxit, trace=0, nREPORT=10):
    """R's ``lbfgsb()`` aus ``optim.c``.

    ``x``, ``l``, ``u``: Listen/Arrays der Länge ``n`` (``x`` wird nicht
    verändert); ``nbd``: 0 frei, 1 unten, 2 beide, 3 oben.
    ``fminfn(x) -> float``, ``fmingr(x) -> Liste`` (0-basierte Listen).
    Liefert ``(x, Fmin, fail, fncount, grcount, msg)``.
    """
    from .linalg import RError
    if n == 0:
        f = fminfn([float(v) for v in u])
        return [], f, 0, 1, 0, "NOTHING TO DO"
    if nREPORT <= 0:
        raise RError('REPORT must be > 0 (method = "L-BFGS-B")')
    tr = {2: 0, 3: nREPORT, 4: 99, 5: 100, 6: 101}.get(trace, -1)
    F = np.float64
    X = [_Z] + [F(v) for v in x]
    Lw = [_Z] + [F(v) for v in l]
    Uw = [_Z] + [F(v) for v in u]
    NB = [0] + [int(v) for v in nbd]
    G = [_Z] * (n + 1)
    st = _LBFGSB(n, m)
    isave = [0] * 21
    task = "START"
    f = _Z
    fail = 0
    it = 0
    with np.errstate(all="ignore"):
        while True:
            task, f = st.mainlb(X, Lw, Uw, NB, f, G, F(factr), F(pgtol), task, tr, isave)
            if task.startswith("FG"):
                f = F(fminfn([float(v) for v in X[1:]]))
                if not math.isfinite(f):
                    raise RError("L-BFGS-B needs finite values of 'fn'")
                gg = fmingr([float(v) for v in X[1:]])
                for i in range(n):
                    G[i + 1] = F(gg[i])
            elif task.startswith("NEW_X"):
                it += 1
                if trace == 1 and (it % nREPORT == 0):
                    _p("iter %4d value %f\n", it, f)
                if it > maxit:
                    fail = 1
                    break
            elif task.startswith("WARN"):
                fail = 51
                break
            elif task.startswith("CONV"):
                break
            elif task.startswith("ERROR"):
                fail = 52
                break
            else:
                fail = 52
                break
    cnt = isave[12]
    if trace:
        _p("final  value %f \n", f)
        if it < maxit and fail == 0:
            _p("converged\n")
        else:
            _p("stopped after %i iterations\n", it)
    return [float(v) for v in X[1:]], float(f), fail, cnt, cnt, task
