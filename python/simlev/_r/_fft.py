"""R's FFT (``src/library/stats/src/fft.c``: Singletons gemischte Basis,
``fft_factor``/``fft_work``/``fftmx``), bitgleich als Python-Port.

``fftmx`` ist voller Sprünge; er ist hier als Zustandsautomat mit den
Marken der C-Quelle umgesetzt (1-basierte Felder wie dort).
"""
from __future__ import annotations

import math

__all__ = ["fft_factor", "fft_work", "fft_vec"]

_M_PI_4 = 0.785398163397448309615660845820
_M_SQRT_3 = 1.732050807568877293527446341506


class _Fac:
    def __init__(self):
        self.old_n = 0
        self.nfac = [0] * 20
        self.m_fac = 0
        self.kt = 0
        self.maxf = 0
        self.maxp = 0


def fft_factor(n, st=None):
    """Faktorisierung wie ``fft_factor``; liefert Zustandsobjekt (maxf==0: Fehler)."""
    st = st or _Fac()
    if n <= 0:
        st.old_n = 0
        st.maxf = 0
        st.maxp = 0
        return st
    st.old_n = n
    st.m_fac = 0
    nfac = st.nfac
    k = n
    if k == 1:
        return st
    while k % 16 == 0:
        nfac[st.m_fac] = 4
        st.m_fac += 1
        k //= 16
    kchanged = 0
    sqrtk = int(math.sqrt(k))
    j = 3
    while j <= sqrtk:
        jj = j * j
        while k % jj == 0:
            nfac[st.m_fac] = j
            st.m_fac += 1
            k //= jj
            kchanged = 1
        if kchanged:
            kchanged = 0
            sqrtk = int(math.sqrt(k))
        j += 2
    if k <= 4:
        st.kt = st.m_fac
        nfac[st.m_fac] = k
        if k != 1:
            st.m_fac += 1
    else:
        if k % 4 == 0:
            nfac[st.m_fac] = 2
            st.m_fac += 1
            k //= 4
        st.kt = st.m_fac
        st.maxp = max(st.kt + st.kt + 2, k - 1)
        j = 2
        while True:
            if k % j == 0:
                nfac[st.m_fac] = j
                st.m_fac += 1
                k //= j
            j = ((j + 1) // 2) * 2 + 1
            if not (j <= k):
                break
    if st.m_fac <= st.kt + 1:
        st.maxp = st.m_fac + st.kt + 1
    if st.m_fac + st.kt > 20:
        st.old_n = 0
        st.maxf = 0
        st.maxp = 0
        return st
    if st.kt != 0:
        j = st.kt
        while j != 0:
            j -= 1
            nfac[st.m_fac] = nfac[j]
            st.m_fac += 1
    kt = st.kt
    maxf = nfac[st.m_fac - kt - 1]
    if kt > 0:
        maxf = max(nfac[kt - 1], maxf)
    if kt > 1:
        maxf = max(nfac[kt - 2], maxf)
    if kt > 2:
        maxf = max(nfac[kt - 3], maxf)
    st.maxf = maxf
    return st


def fft_work(a, b, nseg, n, nspn, isn, st):
    """In-place-FFT der Listen ``a`` (Real), ``b`` (Imag) (0-basiert).

    Wie in R liegen Real- und Imaginärteile verschränkt im Speicher
    (``COMPLEX(z)[i].r``/``.i``) und ``isn = ±2`` schreitet in Zweierschritten.
    """
    import numpy as _np
    if st.old_n == 0:
        return False
    if n != st.old_n or nseg <= 0 or nspn <= 0 or isn == 0:
        return False
    mf = st.maxf
    nspan = n * nspn
    ntot = nspan * nseg
    N = len(a)
    Z = _np.zeros(2 * N + 2)
    Z[1:2 * N + 1:2] = a
    Z[2:2 * N + 2:2] = b
    A = Z            # a[k] = Z[k]   (a-- in C, a = &z[0].r)
    Bv = Z[1:]       # b[k] = Z[k+1] (b = &z[0].i)
    at = [0.0] * (mf + 2)
    ck = [0.0] * (mf + 2)
    bt = [0.0] * (mf + 2)
    sk = [0.0] * (mf + 2)
    np_ = [0] * (st.maxp + 2)
    nfac = list(st.nfac)
    with _np.errstate(all="ignore"):
        _fftmx(A, Bv, ntot, n, nspan, isn, st.m_fac, st.kt, at, ck, bt, sk, np_, nfac)
    a[:] = Z[1:2 * N + 1:2].tolist()
    b[:] = Z[2:2 * N + 2:2].tolist()
    return True


def _fftmx(a, b, ntot, n, nspan, isn, m, kt, at, ck, bt, sk, np_, nfac):  # noqa: C901
    cos = math.cos
    sin = math.sin
    np = np_
    aa = aj = ajm = ajp = ak = akm = akp = 0.0
    bb = bj = bjm = bjp = bk = bkm = bkp = 0.0
    c1 = c2 = c3 = c72 = cd = 0.0
    dr = rad = 0.0
    s1 = s120 = s2 = s3 = s72 = sd = 0.0
    i = inc = j = jc = jf = jj = 0
    k = k1 = k2 = k3 = k4 = kk = klim = ks = kspan = kspnn = 0
    lim = maxf = mm = nn = nt = 0

    inc = abs(isn)
    nt = inc * ntot
    ks = inc * nspan
    rad = _M_PI_4
    s72 = rad / 0.625
    c72 = cos(s72)
    s72 = sin(s72)
    s120 = 0.5 * _M_SQRT_3
    if isn <= 0:
        s72 = -s72
        s120 = -s120
        rad = -rad
    kspan = ks
    nn = nt - inc
    jc = ks // n
    lim = 32
    klim = lim * jc
    i = 0
    jf = 0
    maxf = nfac[m - kt - 1]
    if kt > 0:
        maxf = max(nfac[kt - 1], maxf)

    L = "start"
    while True:
        if L == "start":
            dr = (8.0 * jc) / kspan
            cd = sin(0.5 * dr * rad)
            cd = 2.0 * cd * cd
            sd = sin(dr * rad)
            kk = 1
            i += 1
            if nfac[i - 1] != 2:
                L = "L110"
                continue
            kspan //= 2
            k1 = kspan + 2
            while True:
                while True:
                    k2 = kk + kspan
                    ak = a[k2]
                    bk = b[k2]
                    a[k2] = a[kk] - ak
                    b[k2] = b[kk] - bk
                    a[kk] += ak
                    b[kk] += bk
                    kk = k2 + kspan
                    if not (kk <= nn):
                        break
                kk -= nn
                if not (kk <= jc):
                    break
            if kk > kspan:
                L = "fin"
                continue
            L = "L60"
            continue
        if L == "L60":
            c1 = 1.0 - cd
            s1 = sd
            mm = min(k1 // 2, klim)
            L = "L80"
            continue
        if L == "L70":
            ak = c1 - (cd * c1 + sd * s1)
            s1 = (sd * c1 - cd * s1) + s1
            c1 = ak
            L = "L80"
            continue
        if L == "L80":
            while True:
                k2 = kk + kspan
                ak = a[kk] - a[k2]
                bk = b[kk] - b[k2]
                a[kk] += a[k2]
                b[kk] += b[k2]
                a[k2] = c1 * ak - s1 * bk
                b[k2] = s1 * ak + c1 * bk
                kk = k2 + kspan
                if not (kk < nt):
                    break
            k2 = kk - nt
            c1 = -c1
            kk = k1 - k2
            if kk > k2:
                L = "L80"
                continue
            kk += jc
            if kk <= mm:
                L = "L70"
                continue
            if kk >= k2:
                k1 = k1 + inc + inc
                kk = (k1 - kspan) // 2 + jc
                if kk <= jc + jc:
                    L = "L60"
                    continue
                L = "start"
                continue
            s1 = ((kk - 1) // jc) * dr * rad
            c1 = cos(s1)
            s1 = sin(s1)
            mm = min(k1 // 2, mm + klim)
            L = "L80"
            continue
        if L == "L100":
            k1 = kk + kspan
            k2 = k1 + kspan
            ak = a[kk]
            bk = b[kk]
            aj = a[k1] + a[k2]
            bj = b[k1] + b[k2]
            a[kk] = ak + aj
            b[kk] = bk + bj
            ak = -0.5 * aj + ak
            bk = -0.5 * bj + bk
            aj = (a[k1] - a[k2]) * s120
            bj = (b[k1] - b[k2]) * s120
            a[k1] = ak - bj
            b[k1] = bk + aj
            a[k2] = ak + bj
            b[k2] = bk - aj
            kk = k2 + kspan
            if kk < nn:
                L = "L100"
                continue
            kk = kk - nn
            if kk <= kspan:
                L = "L100"
                continue
            L = "L290"
            continue
        if L == "L110":
            if nfac[i - 1] != 4:
                L = "f_odd"
                continue
            kspnn = kspan
            kspan //= 4
            L = "L120"
            continue
        if L == "L120":
            c1 = 1.0
            s1 = 0.0
            mm = min(kspan, klim)
            L = "L150"
            continue
        if L == "L130":
            c2 = c1 - (cd * c1 + sd * s1)
            s1 = (sd * c1 - cd * s1) + s1
            c1 = c2
            L = "L140"
            continue
        if L == "L140":
            c2 = c1 * c1 - s1 * s1
            s2 = c1 * s1 * 2.0
            c3 = c2 * c1 - s2 * s1
            s3 = c2 * s1 + s2 * c1
            L = "L150"
            continue
        if L == "L150":
            k1 = kk + kspan
            k2 = k1 + kspan
            k3 = k2 + kspan
            akp = a[kk] + a[k2]
            akm = a[kk] - a[k2]
            ajp = a[k1] + a[k3]
            ajm = a[k1] - a[k3]
            a[kk] = akp + ajp
            ajp = akp - ajp
            bkp = b[kk] + b[k2]
            bkm = b[kk] - b[k2]
            bjp = b[k1] + b[k3]
            bjm = b[k1] - b[k3]
            b[kk] = bkp + bjp
            bjp = bkp - bjp
            if isn < 0:
                L = "L180"
                continue
            akp = akm - bjm
            akm = akm + bjm
            bkp = bkm + ajm
            bkm = bkm - ajm
            if s1 == 0.0:
                L = "L190"
                continue
            L = "L160"
            continue
        if L == "L160":
            a[k1] = akp * c1 - bkp * s1
            b[k1] = akp * s1 + bkp * c1
            a[k2] = ajp * c2 - bjp * s2
            b[k2] = ajp * s2 + bjp * c2
            a[k3] = akm * c3 - bkm * s3
            b[k3] = akm * s3 + bkm * c3
            kk = k3 + kspan
            if kk <= nt:
                L = "L150"
                continue
            L = "L170"
            continue
        if L == "L170":
            kk = kk - nt + jc
            if kk <= mm:
                L = "L130"
                continue
            if kk < kspan:
                L = "L200"
                continue
            kk = kk - kspan + inc
            if kk <= jc:
                L = "L120"
                continue
            if kspan == jc:
                L = "fin"
                continue
            L = "start"
            continue
        if L == "L180":
            akp = akm + bjm
            akm = akm - bjm
            bkp = bkm - ajm
            bkm = bkm + ajm
            if s1 != 0.0:
                L = "L160"
                continue
            L = "L190"
            continue
        if L == "L190":
            a[k1] = akp
            b[k1] = bkp
            a[k2] = ajp
            b[k2] = bjp
            a[k3] = akm
            b[k3] = bkm
            kk = k3 + kspan
            if kk <= nt:
                L = "L150"
                continue
            L = "L170"
            continue
        if L == "L200":
            s1 = ((kk - 1) // jc) * dr * rad
            c1 = cos(s1)
            s1 = sin(s1)
            mm = min(kspan, mm + klim)
            L = "L140"
            continue
        if L == "f5":
            c2 = c72 * c72 - s72 * s72
            s2 = 2.0 * c72 * s72
            L = "L220"
            continue
        if L == "L220":
            k1 = kk + kspan
            k2 = k1 + kspan
            k3 = k2 + kspan
            k4 = k3 + kspan
            akp = a[k1] + a[k4]
            akm = a[k1] - a[k4]
            bkp = b[k1] + b[k4]
            bkm = b[k1] - b[k4]
            ajp = a[k2] + a[k3]
            ajm = a[k2] - a[k3]
            bjp = b[k2] + b[k3]
            bjm = b[k2] - b[k3]
            aa = a[kk]
            bb = b[kk]
            a[kk] = aa + akp + ajp
            b[kk] = bb + bkp + bjp
            ak = akp * c72 + ajp * c2 + aa
            bk = bkp * c72 + bjp * c2 + bb
            aj = akm * s72 + ajm * s2
            bj = bkm * s72 + bjm * s2
            a[k1] = ak - bj
            a[k4] = ak + bj
            b[k1] = bk + aj
            b[k4] = bk - aj
            ak = akp * c2 + ajp * c72 + aa
            bk = bkp * c2 + bjp * c72 + bb
            aj = akm * s2 - ajm * s72
            bj = bkm * s2 - bjm * s72
            a[k2] = ak - bj
            a[k3] = ak + bj
            b[k2] = bk + aj
            b[k3] = bk - aj
            kk = k4 + kspan
            if kk < nn:
                L = "L220"
                continue
            kk = kk - nn
            if kk <= kspan:
                L = "L220"
                continue
            L = "L290"
            continue
        if L == "f_odd":
            k = nfac[i - 1]
            kspnn = kspan
            kspan //= k
            if k == 3:
                L = "L100"
                continue
            if k == 5:
                L = "f5"
                continue
            if k == jf:
                L = "L250"
                continue
            jf = k
            s1 = rad / (k / 8.0)
            c1 = cos(s1)
            s1 = sin(s1)
            ck[jf] = 1.0
            sk[jf] = 0.0
            j = 1
            while j < k:
                ck[j] = ck[k] * c1 + sk[k] * s1
                sk[j] = ck[k] * s1 - sk[k] * c1
                k -= 1
                ck[k] = ck[j]
                sk[k] = -sk[j]
                j += 1
            L = "L250"
            continue
        if L == "L250":
            k1 = kk
            k2 = kk + kspnn
            aa = a[kk]
            bb = b[kk]
            ak = aa
            bk = bb
            j = 1
            k1 = k1 + kspan
            while True:
                # L260
                k2 = k2 - kspan
                j += 1
                at[j] = a[k1] + a[k2]
                ak = at[j] + ak
                bt[j] = b[k1] + b[k2]
                bk = bt[j] + bk
                j += 1
                at[j] = a[k1] - a[k2]
                bt[j] = b[k1] - b[k2]
                k1 = k1 + kspan
                if not (k1 < k2):
                    break
            a[kk] = ak
            b[kk] = bk
            k1 = kk
            k2 = kk + kspnn
            j = 1
            while True:
                # L270
                k1 += kspan
                k2 -= kspan
                jj = j
                ak = aa
                bk = bb
                aj = 0.0
                bj = 0.0
                k = 2
                while k < jf:
                    ak += at[k] * ck[jj]
                    bk += bt[k] * ck[jj]
                    k += 1
                    aj += at[k] * sk[jj]
                    bj += bt[k] * sk[jj]
                    jj += j
                    if jj > jf:
                        jj -= jf
                    k += 1
                k = jf - j
                a[k1] = ak - bj
                b[k1] = bk + aj
                a[k2] = ak + bj
                b[k2] = bk - aj
                j += 1
                if not (j < k):
                    break
            kk = kk + kspnn
            if kk <= nn:
                L = "L250"
                continue
            kk = kk - nn
            if kk <= kspan:
                L = "L250"
                continue
            L = "L290"
            continue
        if L == "L290":
            if i == m:
                L = "fin"
                continue
            kk = jc + 1
            L = "L300"
            continue
        if L == "L300":
            c2 = 1.0 - cd
            s1 = sd
            mm = min(kspan, klim)
            nxt = None
            while True:
                c1 = c2
                s2 = s1
                kk += kspan
                while True:
                    while True:
                        ak = a[kk]
                        a[kk] = c2 * ak - s2 * b[kk]
                        b[kk] = s2 * ak + c2 * b[kk]
                        kk += kspnn
                        if not (kk <= nt):
                            break
                    ak = s1 * s2
                    s2 = s1 * c2 + c1 * s2
                    c2 = c1 * c2 - ak
                    kk += -nt + kspan
                    if not (kk <= kspnn):
                        break
                kk += -kspnn + jc
                if kk <= mm:
                    c2 = c1 - (cd * c1 + sd * s1)
                    s1 = s1 + (sd * c1 - cd * s1)
                    continue
                if kk >= kspan:
                    kk = kk - kspan + jc + inc
                    if kk <= jc + jc:
                        nxt = "L300"
                    else:
                        nxt = "start"
                    break
                s1 = ((kk - 1) // jc) * dr * rad
                c2 = cos(s1)
                s1 = sin(s1)
                mm = min(kspan, mm + klim)
            L = nxt
            continue
        if L == "fin":
            np[1] = ks
            if kt == 0:
                L = "L440"
                continue
            k = kt + kt + 1
            if m < k:
                k -= 1
            np[k + 1] = jc
            j = 1
            while j < k:
                np[j + 1] = np[j] // nfac[j - 1]
                np[k] = np[k + 1] * nfac[j - 1]
                j += 1
                k -= 1
            k3 = np[k + 1]
            kspan = np[2]
            kk = jc + 1
            k2 = kspan + 1
            j = 1
            if n == ntot:
                L = "L370"
            else:
                L = "L400"
            continue
        if L == "L370":
            while True:
                ak = a[kk]
                a[kk] = a[k2]
                a[k2] = ak
                bk = b[kk]
                b[kk] = b[k2]
                b[k2] = bk
                kk += inc
                k2 += kspan
                if not (k2 < ks):
                    break
            L = "L380"
            continue
        if L == "L380":
            while True:
                k2 -= np[j]
                j += 1
                k2 += np[j + 1]
                if not (k2 > np[j]):
                    break
            j = 1
            jump = False
            while True:
                if kk < k2:
                    jump = True
                    break
                kk += inc
                k2 += kspan
                if not (k2 < ks):
                    break
            if jump:
                L = "L370"
                continue
            if kk < ks:
                L = "L380"
                continue
            jc = k3
            L = "L440"
            continue
        if L == "L400":
            k = kk + jc
            while True:
                ak = a[kk]
                a[kk] = a[k2]
                a[k2] = ak
                bk = b[kk]
                b[kk] = b[k2]
                b[k2] = bk
                kk += inc
                k2 += inc
                if not (kk < k):
                    break
            kk += ks - jc
            k2 += ks - jc
            if kk < nt:
                L = "L400"
                continue
            k2 += -nt + kspan
            kk += -nt + jc
            if k2 < ks:
                L = "L400"
                continue
            jump = False
            while True:
                while True:
                    k2 -= np[j]
                    j += 1
                    k2 += np[j + 1]
                    if not (k2 > np[j]):
                        break
                j = 1
                while True:
                    if kk < k2:
                        jump = True
                        break
                    kk += jc
                    k2 += kspan
                    if not (k2 < ks):
                        break
                if jump:
                    break
                if not (kk < ks):
                    break
            if jump:
                L = "L400"
                continue
            jc = k3
            L = "L440"
            continue
        if L == "L440":
            if 2 * kt + 1 >= m:
                return
            kspnn = np[kt + 1]
            nn = m - kt
            nfac[nn] = 1
            j = nn
            while j > kt:
                nfac[j - 1] *= nfac[j]
                j -= 1
            kt += 1
            nn = nfac[kt - 1] - 1
            jj = 0
            j = 0
            L = "L480"
            continue
        if L == "L460":
            jj -= k2
            k2 = kk
            k += 1
            kk = nfac[k - 1]
            L = "L470"
            continue
        if L == "L470":
            jj += kk
            if jj >= k2:
                L = "L460"
                continue
            np[j] = jj
            L = "L480"
            continue
        if L == "L480":
            k2 = nfac[kt - 1]
            k = kt + 1
            kk = nfac[k - 1]
            j += 1
            if j <= nn:
                L = "L470"
                continue
            j = 0
            L = "L500"
            continue
        if L == "L500":
            # Eintritt mitten in die äußere do-while-Schleife
            while True:
                j += 1
                kk = np[j]
                if not (kk < 0):
                    break
            while kk != j:
                while True:
                    k = kk
                    kk = np[k]
                    np[k] = -kk
                    if not (kk != j):
                        break
                k3 = kk
                while True:
                    j += 1
                    kk = np[j]
                    if not (kk < 0):
                        break
            np[j] = -j
            if j != nn:
                L = "L500"
                continue
            maxf *= inc
            L = "L570"
            continue
        if L == "ord":
            while True:
                j -= 1
                if not (np[j] < 0):
                    break
            jj = jc
            L = "L520"
            continue
        if L == "L520":
            kspan = min(jj, maxf)
            jj -= kspan
            k = np[j]
            kk = jc * k + i + jj
            k1 = kk + kspan
            k2 = 1
            while k1 != kk:
                at[k2] = a[k1]
                bt[k2] = b[k1]
                k1 -= inc
                k2 += 1
            while True:
                k1 = kk + kspan
                k2 = k1 - jc * (k + np[k])
                k = -np[k]
                while True:
                    a[k1] = a[k2]
                    b[k1] = b[k2]
                    k1 -= inc
                    k2 -= inc
                    if not (k1 != kk):
                        break
                kk = k2
                if not (k != j):
                    break
            k1 = kk + kspan
            k2 = 1
            while k1 > kk:
                a[k1] = at[k2]
                b[k1] = bt[k2]
                k1 -= inc
                k2 += 1
            if jj != 0:
                L = "L520"
                continue
            if j != 1:
                L = "ord"
                continue
            L = "L570"
            continue
        if L == "L570":
            j = k3 + 1
            nt = nt - kspnn
            i = nt - inc + 1
            if nt >= 0:
                L = "ord"
                continue
            return
        raise RuntimeError("fftmx: unbekannte Marke " + str(L))


def fft_vec(re, im, inverse=False, dims=None):
    """R's ``fft(z, inverse)`` für Real-/Imaginärteile (Listen/Arrays).

    ``dims``: Dimensionen für die räumliche Transformation (Matrix/Array).
    Liefert (re, im) als Listen.
    """
    from .linalg import RError
    a = [float(v) for v in re]
    b = [float(v) for v in im]
    inv = 2 if inverse else -2
    if len(a) > 1:
        if dims is None:
            n = len(a)
            st = fft_factor(n)
            if st.maxf == 0:
                raise RError("fft factorization error")
            fft_work(a, b, 1, n, 1, inv, st)
        else:
            for d in dims:
                if d > 1:
                    st = fft_factor(d)
                    if st.maxf == 0:
                        raise RError("fft factorization error")
            nseg = len(a)
            n = 1
            nspn = 1
            for d in dims:
                if d > 1:
                    nspn *= n
                    n = d
                    nseg //= n
                    st = fft_factor(n)
                    fft_work(a, b, nseg, n, nspn, inv, st)
    return a, b
