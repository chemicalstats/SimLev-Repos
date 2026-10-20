# ─────────────────────────────────────────────────────────────────────────────
# R's FFT (src/library/stats/src/fft.c: Singletons gemischte Basis,
# fft_factor/fft_work/fftmx), bitgleich. fftmx ist voller Sprünge; er ist hier
# als Zustandsautomat mit den Marken der C-Quelle umgesetzt (wie die Vorlage
# python/simlev/_r/_fft.py; Felder mit Python-Indizes über `_Off`).
# Eingebunden in RStats.
# ─────────────────────────────────────────────────────────────────────────────

"Feld mit verschobenem Index: `z[i]` greift auf `z.v[i + z.o]` zu."
struct _Off{T,V<:AbstractVector{T}}
    v::V
    o::Int
end
@inline Base.getindex(z::_Off, i::Int) = @inbounds z.v[i+z.o]
@inline Base.setindex!(z::_Off, x, i::Int) = @inbounds (z.v[i+z.o] = x)

const _M_PI_4 = 0.785398163397448309615660845820
const _M_SQRT_3 = 1.732050807568877293527446341506

mutable struct _Fac
    old_n::Int
    nfac::Vector{Int}      # 0-basiert über _Off
    m_fac::Int
    kt::Int
    maxf::Int
    maxp::Int
end
_Fac() = _Fac(0, zeros(Int, 20), 0, 0, 0, 0)

_isqrt_c(k::Int) = trunc(Int, sqrt(Float64(k)))

"Faktorisierung wie fft_factor; liefert Zustand (maxf == 0: Fehler)."
function fft_factor(n::Int, st::_Fac = _Fac())
    if n <= 0
        st.old_n = 0; st.maxf = 0; st.maxp = 0
        return st
    end
    st.old_n = n
    st.m_fac = 0
    nfac = _Off(st.nfac, 1)
    k = n
    k == 1 && return st
    while k % 16 == 0
        nfac[st.m_fac] = 4
        st.m_fac += 1
        k ÷= 16
    end
    kchanged = 0
    sqrtk = _isqrt_c(k)
    j = 3
    while j <= sqrtk
        jj = j * j
        while k % jj == 0
            nfac[st.m_fac] = j
            st.m_fac += 1
            k ÷= jj
            kchanged = 1
        end
        if kchanged != 0
            kchanged = 0
            sqrtk = _isqrt_c(k)
        end
        j += 2
    end
    if k <= 4
        st.kt = st.m_fac
        nfac[st.m_fac] = k
        k != 1 && (st.m_fac += 1)
    else
        if k % 4 == 0
            nfac[st.m_fac] = 2
            st.m_fac += 1
            k ÷= 4
        end
        st.kt = st.m_fac
        st.maxp = max(st.kt + st.kt + 2, k - 1)
        j = 2
        while true
            if k % j == 0
                nfac[st.m_fac] = j
                st.m_fac += 1
                k ÷= j
            end
            j = ((j + 1) ÷ 2) * 2 + 1
            j <= k || break
        end
    end
    st.m_fac <= st.kt + 1 && (st.maxp = st.m_fac + st.kt + 1)
    if st.m_fac + st.kt > 20
        st.old_n = 0; st.maxf = 0; st.maxp = 0
        return st
    end
    if st.kt != 0
        j = st.kt
        while j != 0
            j -= 1
            nfac[st.m_fac] = nfac[j]
            st.m_fac += 1
        end
    end
    kt = st.kt
    maxf = nfac[st.m_fac-kt-1]
    kt > 0 && (maxf = max(nfac[kt-1], maxf))
    kt > 1 && (maxf = max(nfac[kt-2], maxf))
    kt > 2 && (maxf = max(nfac[kt-3], maxf))
    st.maxf = maxf
    return st
end

"In-place-FFT der Vektoren `a` (Real), `b` (Imag); verschränkt wie COMPLEX(z) in R."
function fft_work!(a::Vector{Float64}, b::Vector{Float64}, nseg::Int, n::Int, nspn::Int, isn::Int, st::_Fac)
    st.old_n == 0 && return false
    (n != st.old_n || nseg <= 0 || nspn <= 0 || isn == 0) && return false
    mf = st.maxf
    nspan = n * nspn
    ntot = nspan * nseg
    N = length(a)
    Zj = zeros(2 * N + 3)
    for k in 1:N
        Zj[2k] = a[k]          # Python Z[2k-1]
        Zj[2k+1] = b[k]        # Python Z[2k]
    end
    A = _Off(Zj, 1)            # a[k] = Z[k]
    B = _Off(Zj, 2)            # b[k] = Z[k+1]
    at = _Off(zeros(mf + 2), 1)
    ck = _Off(zeros(mf + 2), 1)
    bt = _Off(zeros(mf + 2), 1)
    sk = _Off(zeros(mf + 2), 1)
    np_ = _Off(zeros(Int, st.maxp + 2), 1)
    nfac = _Off(copy(st.nfac), 1)
    _fftmx!(A, B, ntot, n, nspan, isn, st.m_fac, st.kt, at, ck, bt, sk, np_, nfac)
    for k in 1:N
        a[k] = Zj[2k]
        b[k] = Zj[2k+1]
    end
    return true
end

function _fftmx!(a, b, ntot, n, nspan, isn, m, kt, at, ck, bt, sk, np, nfac)
    cos = SimLev.RLibm.c_cos
    sin = SimLev.RLibm.c_sin
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
    if isn <= 0
        s72 = -s72
        s120 = -s120
        rad = -rad
    end
    kspan = ks
    nn = nt - inc
    jc = ks ÷ n
    lim = 32
    klim = lim * jc
    i = 0
    jf = 0
    maxf = nfac[m-kt-1]
    kt > 0 && (maxf = max(nfac[kt-1], maxf))

    L = :start
    while true
        if L === :start
            dr = (8.0 * jc) / kspan
            cd = sin(0.5 * dr * rad)
            cd = 2.0 * cd * cd
            sd = sin(dr * rad)
            kk = 1
            i += 1
            if nfac[i-1] != 2
                L = :L110; continue
            end
            kspan ÷= 2
            k1 = kspan + 2
            while true
                while true
                    k2 = kk + kspan
                    ak = a[k2]
                    bk = b[k2]
                    a[k2] = a[kk] - ak
                    b[k2] = b[kk] - bk
                    a[kk] = a[kk] + ak
                    b[kk] = b[kk] + bk
                    kk = k2 + kspan
                    kk <= nn || break
                end
                kk -= nn
                kk <= jc || break
            end
            if kk > kspan
                L = :fin; continue
            end
            L = :L60; continue
        elseif L === :L60
            c1 = 1.0 - cd
            s1 = sd
            mm = min(k1 ÷ 2, klim)
            L = :L80; continue
        elseif L === :L70
            ak = c1 - (cd * c1 + sd * s1)
            s1 = (sd * c1 - cd * s1) + s1
            c1 = ak
            L = :L80; continue
        elseif L === :L80
            while true
                k2 = kk + kspan
                ak = a[kk] - a[k2]
                bk = b[kk] - b[k2]
                a[kk] = a[kk] + a[k2]
                b[kk] = b[kk] + b[k2]
                a[k2] = c1 * ak - s1 * bk
                b[k2] = s1 * ak + c1 * bk
                kk = k2 + kspan
                kk < nt || break
            end
            k2 = kk - nt
            c1 = -c1
            kk = k1 - k2
            if kk > k2
                L = :L80; continue
            end
            kk += jc
            if kk <= mm
                L = :L70; continue
            end
            if kk >= k2
                k1 = k1 + inc + inc
                kk = (k1 - kspan) ÷ 2 + jc
                if kk <= jc + jc
                    L = :L60; continue
                end
                L = :start; continue
            end
            s1 = ((kk - 1) ÷ jc) * dr * rad
            c1 = cos(s1)
            s1 = sin(s1)
            mm = min(k1 ÷ 2, mm + klim)
            L = :L80; continue
        elseif L === :L100
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
            if kk < nn
                L = :L100; continue
            end
            kk = kk - nn
            if kk <= kspan
                L = :L100; continue
            end
            L = :L290; continue
        elseif L === :L110
            if nfac[i-1] != 4
                L = :f_odd; continue
            end
            kspnn = kspan
            kspan ÷= 4
            L = :L120; continue
        elseif L === :L120
            c1 = 1.0
            s1 = 0.0
            mm = min(kspan, klim)
            L = :L150; continue
        elseif L === :L130
            c2 = c1 - (cd * c1 + sd * s1)
            s1 = (sd * c1 - cd * s1) + s1
            c1 = c2
            L = :L140; continue
        elseif L === :L140
            c2 = c1 * c1 - s1 * s1
            s2 = c1 * s1 * 2.0
            c3 = c2 * c1 - s2 * s1
            s3 = c2 * s1 + s2 * c1
            L = :L150; continue
        elseif L === :L150
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
            if isn < 0
                L = :L180; continue
            end
            akp = akm - bjm
            akm = akm + bjm
            bkp = bkm + ajm
            bkm = bkm - ajm
            if s1 == 0.0
                L = :L190; continue
            end
            L = :L160; continue
        elseif L === :L160
            a[k1] = akp * c1 - bkp * s1
            b[k1] = akp * s1 + bkp * c1
            a[k2] = ajp * c2 - bjp * s2
            b[k2] = ajp * s2 + bjp * c2
            a[k3] = akm * c3 - bkm * s3
            b[k3] = akm * s3 + bkm * c3
            kk = k3 + kspan
            if kk <= nt
                L = :L150; continue
            end
            L = :L170; continue
        elseif L === :L170
            kk = kk - nt + jc
            if kk <= mm
                L = :L130; continue
            end
            if kk < kspan
                L = :L200; continue
            end
            kk = kk - kspan + inc
            if kk <= jc
                L = :L120; continue
            end
            if kspan == jc
                L = :fin; continue
            end
            L = :start; continue
        elseif L === :L180
            akp = akm + bjm
            akm = akm - bjm
            bkp = bkm - ajm
            bkm = bkm + ajm
            if s1 != 0.0
                L = :L160; continue
            end
            L = :L190; continue
        elseif L === :L190
            a[k1] = akp
            b[k1] = bkp
            a[k2] = ajp
            b[k2] = bjp
            a[k3] = akm
            b[k3] = bkm
            kk = k3 + kspan
            if kk <= nt
                L = :L150; continue
            end
            L = :L170; continue
        elseif L === :L200
            s1 = ((kk - 1) ÷ jc) * dr * rad
            c1 = cos(s1)
            s1 = sin(s1)
            mm = min(kspan, mm + klim)
            L = :L140; continue
        elseif L === :f5
            c2 = c72 * c72 - s72 * s72
            s2 = 2.0 * c72 * s72
            L = :L220; continue
        elseif L === :L220
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
            if kk < nn
                L = :L220; continue
            end
            kk = kk - nn
            if kk <= kspan
                L = :L220; continue
            end
            L = :L290; continue
        elseif L === :f_odd
            k = nfac[i-1]
            kspnn = kspan
            kspan ÷= k
            if k == 3
                L = :L100; continue
            end
            if k == 5
                L = :f5; continue
            end
            if k == jf
                L = :L250; continue
            end
            jf = k
            s1 = rad / (k / 8.0)
            c1 = cos(s1)
            s1 = sin(s1)
            ck[jf] = 1.0
            sk[jf] = 0.0
            j = 1
            while j < k
                ck[j] = ck[k] * c1 + sk[k] * s1
                sk[j] = ck[k] * s1 - sk[k] * c1
                k -= 1
                ck[k] = ck[j]
                sk[k] = -sk[j]
                j += 1
            end
            L = :L250; continue
        elseif L === :L250
            k1 = kk
            k2 = kk + kspnn
            aa = a[kk]
            bb = b[kk]
            ak = aa
            bk = bb
            j = 1
            k1 = k1 + kspan
            while true
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
                k1 < k2 || break
            end
            a[kk] = ak
            b[kk] = bk
            k1 = kk
            k2 = kk + kspnn
            j = 1
            while true
                k1 += kspan
                k2 -= kspan
                jj = j
                ak = aa
                bk = bb
                aj = 0.0
                bj = 0.0
                k = 2
                while k < jf
                    ak = ak + at[k] * ck[jj]
                    bk = bk + bt[k] * ck[jj]
                    k += 1
                    aj = aj + at[k] * sk[jj]
                    bj = bj + bt[k] * sk[jj]
                    jj += j
                    jj > jf && (jj -= jf)
                    k += 1
                end
                k = jf - j
                a[k1] = ak - bj
                b[k1] = bk + aj
                a[k2] = ak + bj
                b[k2] = bk - aj
                j += 1
                j < k || break
            end
            kk = kk + kspnn
            if kk <= nn
                L = :L250; continue
            end
            kk = kk - nn
            if kk <= kspan
                L = :L250; continue
            end
            L = :L290; continue
        elseif L === :L290
            if i == m
                L = :fin; continue
            end
            kk = jc + 1
            L = :L300; continue
        elseif L === :L300
            c2 = 1.0 - cd
            s1 = sd
            mm = min(kspan, klim)
            nxt = :none
            while true
                c1 = c2
                s2 = s1
                kk += kspan
                while true
                    while true
                        ak = a[kk]
                        a[kk] = c2 * ak - s2 * b[kk]
                        b[kk] = s2 * ak + c2 * b[kk]
                        kk += kspnn
                        kk <= nt || break
                    end
                    ak = s1 * s2
                    s2 = s1 * c2 + c1 * s2
                    c2 = c1 * c2 - ak
                    kk += -nt + kspan
                    kk <= kspnn || break
                end
                kk += -kspnn + jc
                if kk <= mm
                    c2 = c1 - (cd * c1 + sd * s1)
                    s1 = s1 + (sd * c1 - cd * s1)
                    continue
                end
                if kk >= kspan
                    kk = kk - kspan + jc + inc
                    nxt = kk <= jc + jc ? :L300 : :start
                    break
                end
                s1 = ((kk - 1) ÷ jc) * dr * rad
                c2 = cos(s1)
                s1 = sin(s1)
                mm = min(kspan, mm + klim)
            end
            L = nxt; continue
        elseif L === :fin
            np[1] = ks
            if kt == 0
                L = :L440; continue
            end
            k = kt + kt + 1
            m < k && (k -= 1)
            np[k+1] = jc
            j = 1
            while j < k
                np[j+1] = np[j] ÷ nfac[j-1]
                np[k] = np[k+1] * nfac[j-1]
                j += 1
                k -= 1
            end
            k3 = np[k+1]
            kspan = np[2]
            kk = jc + 1
            k2 = kspan + 1
            j = 1
            L = n == ntot ? :L370 : :L400
            continue
        elseif L === :L370
            while true
                ak = a[kk]
                a[kk] = a[k2]
                a[k2] = ak
                bk = b[kk]
                b[kk] = b[k2]
                b[k2] = bk
                kk += inc
                k2 += kspan
                k2 < ks || break
            end
            L = :L380; continue
        elseif L === :L380
            while true
                k2 -= np[j]
                j += 1
                k2 += np[j+1]
                k2 > np[j] || break
            end
            j = 1
            jump = false
            while true
                if kk < k2
                    jump = true
                    break
                end
                kk += inc
                k2 += kspan
                k2 < ks || break
            end
            if jump
                L = :L370; continue
            end
            if kk < ks
                L = :L380; continue
            end
            jc = k3
            L = :L440; continue
        elseif L === :L400
            k = kk + jc
            while true
                ak = a[kk]
                a[kk] = a[k2]
                a[k2] = ak
                bk = b[kk]
                b[kk] = b[k2]
                b[k2] = bk
                kk += inc
                k2 += inc
                kk < k || break
            end
            kk += ks - jc
            k2 += ks - jc
            if kk < nt
                L = :L400; continue
            end
            k2 += -nt + kspan
            kk += -nt + jc
            if k2 < ks
                L = :L400; continue
            end
            jump = false
            while true
                while true
                    k2 -= np[j]
                    j += 1
                    k2 += np[j+1]
                    k2 > np[j] || break
                end
                j = 1
                while true
                    if kk < k2
                        jump = true
                        break
                    end
                    kk += jc
                    k2 += kspan
                    k2 < ks || break
                end
                jump && break
                kk < ks || break
            end
            if jump
                L = :L400; continue
            end
            jc = k3
            L = :L440; continue
        elseif L === :L440
            2 * kt + 1 >= m && return nothing
            kspnn = np[kt+1]
            nn = m - kt
            nfac[nn] = 1
            j = nn
            while j > kt
                nfac[j-1] = nfac[j-1] * nfac[j]
                j -= 1
            end
            kt += 1
            nn = nfac[kt-1] - 1
            jj = 0
            j = 0
            L = :L480; continue
        elseif L === :L460
            jj -= k2
            k2 = kk
            k += 1
            kk = nfac[k-1]
            L = :L470; continue
        elseif L === :L470
            jj += kk
            if jj >= k2
                L = :L460; continue
            end
            np[j] = jj
            L = :L480; continue
        elseif L === :L480
            k2 = nfac[kt-1]
            k = kt + 1
            kk = nfac[k-1]
            j += 1
            if j <= nn
                L = :L470; continue
            end
            j = 0
            L = :L500; continue
        elseif L === :L500
            while true
                j += 1
                kk = np[j]
                kk < 0 || break
            end
            while kk != j
                while true
                    k = kk
                    kk = np[k]
                    np[k] = -kk
                    kk != j || break
                end
                k3 = kk
                while true
                    j += 1
                    kk = np[j]
                    kk < 0 || break
                end
            end
            np[j] = -j
            if j != nn
                L = :L500; continue
            end
            maxf *= inc
            L = :L570; continue
        elseif L === :ord
            while true
                j -= 1
                np[j] < 0 || break
            end
            jj = jc
            L = :L520; continue
        elseif L === :L520
            kspan = min(jj, maxf)
            jj -= kspan
            k = np[j]
            kk = jc * k + i + jj
            k1 = kk + kspan
            k2 = 1
            while k1 != kk
                at[k2] = a[k1]
                bt[k2] = b[k1]
                k1 -= inc
                k2 += 1
            end
            while true
                k1 = kk + kspan
                k2 = k1 - jc * (k + np[k])
                k = -np[k]
                while true
                    a[k1] = a[k2]
                    b[k1] = b[k2]
                    k1 -= inc
                    k2 -= inc
                    k1 != kk || break
                end
                kk = k2
                k != j || break
            end
            k1 = kk + kspan
            k2 = 1
            while k1 > kk
                a[k1] = at[k2]
                b[k1] = bt[k2]
                k1 -= inc
                k2 += 1
            end
            if jj != 0
                L = :L520; continue
            end
            if j != 1
                L = :ord; continue
            end
            L = :L570; continue
        elseif L === :L570
            j = k3 + 1
            nt = nt - kspnn
            i = nt - inc + 1
            if nt >= 0
                L = :ord; continue
            end
            return nothing
        else
            error("fftmx: unbekannte Marke $L")
        end
    end
end

"R's `fft(z, inverse)` für Real-/Imaginärteile; `dims` für die mehrdimensionale Transformation."
function fft_vec(re, im; inverse::Bool = false, dims = nothing)
    a = collect(Float64, re)
    b = collect(Float64, im)
    inv = inverse ? 2 : -2
    if length(a) > 1
        if dims === nothing
            n = length(a)
            st = fft_factor(n)
            st.maxf == 0 && error("fft factorization error")
            fft_work!(a, b, 1, n, 1, inv, st)
        else
            for d in dims
                if d > 1
                    st = fft_factor(d)
                    st.maxf == 0 && error("fft factorization error")
                end
            end
            nseg = length(a)
            n = 1
            nspn = 1
            for d in dims
                if d > 1
                    nspn *= n
                    n = d
                    nseg ÷= n
                    st = fft_factor(n)
                    fft_work!(a, b, nseg, n, nspn, inv, st)
                end
            end
        end
    end
    return a, b
end
