#!/usr/bin/env python3
"""core/tools/gen_constants.py – Konstanten der C-Bibliothek slc (SimLev core, Etappe 9).

Erzeugt ``core/slc_constants.h``. Alle Werte werden hier selbst hergeleitet, nur mit der
Python-Standardbibliothek (``fractions``, ``decimal``); es gibt keine übernommenen
Koeffiziententabellen.

Aufruf::

    python3 core/tools/gen_constants.py            # schreibt core/slc_constants.h
    python3 core/tools/gen_constants.py --check    # Ende 1, wenn die Datei abweicht

Hergeleitet werden:

* mathematische Konstanten (pi nach Machin, sqrt(2 pi), ln sqrt(2 pi), ln 2, 1/sqrt(2), ...);
* Bernoulli-Zahlen B_2 ... B_16 exakt als Brüche (Rekursion sum_{k=0}^{m} C(m+1, k) B_k = 0,
  DLMF 24.5.3) und daraus die Glieder der Stirling-Reihe B_2k / (2k (2k-1)) (DLMF 5.11.1);
* die Euler-Mascheroni-Konstante und zeta(k) - 1 (k = 2 ... 30) über die Euler-Maclaurin-Formel
  (DLMF 2.10.1) mit den eigenen Bernoulli-Zahlen; Probe gegen zeta(2) = pi^2/6, zeta(4) = pi^4/90;
* die Glieder der Reihe ln Gamma(2 + e) = (1 - gamma) e + sum_{k>=2} (-1)^k (zeta(k) - 1) e^k / k
  (DLMF 5.7.3 mit ln Gamma(2 + e) = ln Gamma(1 + e) + ln(1 + e));
* Stützwerte der Normalverteilung an x_j = j/8 (j = 0 ... 40): phi(x_j), D(x_j) = Phi(x_j) - 1/2
  und Q(x_j) = 1 - Phi(x_j), über Phi(x) - 1/2 = phi(x) sum x^(2n+1) / (1 3 ... (2n+1))
  (DLMF 7.6.2 mit z = x / sqrt 2); je Wert als Paar hi + lo (hi = gerundeter Wert, lo = Rest);
* Stützwerte von erfc an z_j = j/8 (j = 0 ... 28) über DLMF 7.6.2 und (2/sqrt pi) e^(-z_j^2);
* die ersten Glieder der Umkehrreihe von Phi um 1/2 (Startwert von qnorm) per Reihenumkehr
  mit Brüchen aus Phi(x) - 1/2 = phi(0) sum (-1)^n x^(2n+1) / (2^n n! (2n+1)) (DLMF 7.6.1);
* N2: rationale Näherungen für qnorm in drei Zonen, selbst angepasst an die eigene Referenz
  (kleinste Quadrate im relativen Fehler nach Sanathanan/Koerner 1963, Umgewichtung nach
  Lawson 1961; Einzelheiten bei ``qnorm_fits``), dazu sqrt(2 pi) als hi + lo und geteilt;
* das Inkrement von SplitMix64: die ungerade Zahl nächst 2^64 / goldener Schnitt
  (Steele, Lea, Flood 2014, Abschnitt 3);
* das Sprungpolynom von xoshiro256 für 2^128 Schritte: Minimalpolynom P der linearen
  Zustandsabbildung über GF(2) per Berlekamp-Massey (Massey 1969) aus einer Bitfolge der Abbildung,
  dann x^(2^128) mod P durch 128-maliges Quadrieren; Probe gegen den von Blackman und Vigna
  (2021) veröffentlichten Wert und Probe des Verfahrens mit kleinen Sprungweiten gegen Schritt
  für Schritt.

Ausgabe: Dezimalzahlen mit 21 gültigen Ziffern (eindeutig rückführbar auf den double-Wert;
``--check`` prüft auch das) und im Kommentar als Hex-Gleitkommazahl.
"""
from __future__ import annotations

import argparse
import math
import os
import sys
from decimal import Decimal, getcontext
from fractions import Fraction

getcontext().prec = 60
D = Decimal

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "slc_constants.h")

M64 = (1 << 64) - 1


# ── Grundkonstanten ─────────────────────────────────────────────────────────

def atan_inv(n: int) -> Decimal:
    """atan(1/n) über die Reihe sum (-1)^k / ((2k+1) n^(2k+1))."""
    x = D(1) / n
    x2 = x * x
    term = x
    s = D(0)
    k = 0
    eps = D(10) ** (-(getcontext().prec + 5))
    while abs(term) > eps:
        s += term / (2 * k + 1) * (1 if k % 2 == 0 else -1)
        term *= x2
        k += 1
    return s


PI = 16 * atan_inv(5) - 4 * atan_inv(239)          # Machin (1706)
LN2 = D(2).ln()
SQRT2 = D(2).sqrt()
SQRT2PI = (2 * PI).sqrt()
LNSQRT2PI = (2 * PI).ln() / 2
SQRTPI = PI.sqrt()


def bernoulli(nmax: int) -> list[Fraction]:
    """B_0 ... B_nmax (B_1 = -1/2) aus sum_{k=0}^{m} C(m+1, k) B_k = 0."""
    B = [Fraction(0)] * (nmax + 1)
    B[0] = Fraction(1)
    for m in range(1, nmax + 1):
        s = Fraction(0)
        for k in range(m):
            s += math.comb(m + 1, k) * B[k]
        B[m] = -s / (m + 1)
    return B


BERN = bernoulli(60)


def frac_to_dec(f: Fraction) -> Decimal:
    return D(f.numerator) / D(f.denominator)


def euler_gamma() -> Decimal:
    """gamma = H_N - ln N - 1/(2N) + sum_k B_2k / (2k N^2k) (Euler-Maclaurin)."""
    N = 200
    h = sum(D(1) / n for n in range(1, N + 1))
    g = h - D(N).ln() - D(1) / (2 * N)
    for k in range(1, 25):
        g += frac_to_dec(BERN[2 * k]) / (2 * k * D(N) ** (2 * k))
    return g


def zeta_minus_1(k: int) -> Decimal:
    """zeta(k) - 1 = sum_{n=2}^{N-1} n^-k + Euler-Maclaurin-Rest ab N."""
    N = 30
    s = sum(D(n) ** (-k) for n in range(2, N))
    s += D(N) ** (1 - k) / (k - 1) + D(N) ** (-k) / 2
    for j in range(1, 25):
        # (k)_{2j-1} = k (k+1) ... (k+2j-2)
        poch = 1
        for i in range(2 * j - 1):
            poch *= (k + i)
        s += frac_to_dec(BERN[2 * j]) / math.factorial(2 * j) * poch * D(N) ** (-k - 2 * j + 1)
    return s


GAMMA = euler_gamma()


# ── Normalverteilung und erfc ───────────────────────────────────────────────

def phi_dec(x: Decimal) -> Decimal:
    return (-(x * x) / 2).exp() / SQRT2PI


def Dnorm_half(x: Decimal) -> Decimal:
    """Phi(x) - 1/2 = phi(x) sum_{n>=0} x^(2n+1) / (1 3 ... (2n+1))  (DLMF 7.6.2, z = x/sqrt 2)."""
    s = D(0)
    term = x
    n = 0
    eps = D(10) ** (-(getcontext().prec + 5))
    while abs(term) > eps * abs(s) or n < 3:
        s += term
        n += 1
        term = term * x * x / (2 * n + 1)
    return phi_dec(x) * s


def erf_dec(z: Decimal) -> Decimal:
    """erf z = (2/sqrt pi) e^(-z^2) sum 2^n z^(2n+1) / (1 3 ... (2n+1))  (DLMF 7.6.2)."""
    s = D(0)
    term = z
    n = 0
    eps = D(10) ** (-(getcontext().prec + 5))
    while abs(term) > eps * abs(s) or n < 3:
        s += term
        n += 1
        term = term * 2 * z * z / (2 * n + 1)
    return 2 / SQRTPI * (-(z * z)).exp() * s


def inverse_series_coeffs(nterms: int) -> list[Fraction]:
    """Umkehrreihe x = s + c3 s^3 + c5 s^5 + ... zu s = x - x^3/6 + x^5/40 - ...

    s = (Phi(x) - 1/2) / phi(0) = sum (-1)^n x^(2n+1) / (2^n n! (2n+1))  (DLMF 7.6.1, z = x/sqrt 2).
    Reihenumkehr durch Koeffizientenvergleich mit Brüchen.
    """
    N = 2 * nterms + 1
    a = [Fraction(0)] * (N + 1)
    for n in range(0, N // 2 + 1):
        if 2 * n + 1 <= N:
            a[2 * n + 1] = Fraction((-1) ** n, 2 ** n * math.factorial(n) * (2 * n + 1))
    # gesucht b mit x = sum b_k s^k; einsetzen: s = sum a_j (sum b_k s^k)^j
    b = [Fraction(0)] * (N + 1)
    b[1] = Fraction(1)

    def compose(bb):
        # Potenzreihe sum a_j x(s)^j bis Ordnung N
        res = [Fraction(0)] * (N + 1)
        p = [Fraction(0)] * (N + 1)
        p[0] = Fraction(1)
        for j in range(1, N + 1):
            q = [Fraction(0)] * (N + 1)
            for i, pi in enumerate(p):
                if pi == 0:
                    continue
                for k in range(1, N + 1 - i):
                    if bb[k]:
                        q[i + k] += pi * bb[k]
            p = q
            if a[j]:
                for i in range(N + 1):
                    res[i] += a[j] * p[i]
        return res

    for k in range(2, N + 1):
        r = compose(b)
        # Koeffizient von s^k muss 0 sein (k >= 2); b_k geht mit a_1 b_k = b_k ein
        b[k] = b[k] - r[k]
    return b


def taylor_poly(c: Fraction, k: Fraction, hmax: Fraction = Fraction(1, 16), nmax: int = 60):
    """Taylor-Glieder von g(h) = exp(-k ((c + h)^2 - c^2)) = sum b_n h^n, exakt als Brüche.

    Aus g' = -2k (c + h) g folgt (n+1) b_{n+1} = -2kc b_n - 2k b_{n-1}, b_0 = 1 (für k = 1/2 die
    Normaldichte phi, für k = 1 die Ableitung von erfc, DLMF 7.10.1). Liefert (s, e, N): s_n = b_n/(n+1)
    (Glieder von S(h) = sum b_n h^(n+1)/(n+1) = h sum s_n h^n), e_n = b_n (E(h) = sum e_n h^n) und den
    Grad N, ab dem der Rest für |h| <= hmax unter 2^-63 relativ liegt:
    sum_{n>N} |b_n| hmax^n <= 2^-63 * 1/2 (S(h)/h und E(h) sind für |h| <= 1/16, c <= 5 größer als 1/2).
    """
    b = [Fraction(1), -2 * k * c]
    for n in range(1, nmax):
        b.append((-2 * k * c * b[n] - 2 * k * b[n - 1]) / (n + 1))
    bound = Fraction(1, 2 ** 64)
    N = None
    for cand in range(4, nmax - 1):
        tail = sum(abs(b[n]) * hmax ** n for n in range(cand + 1, nmax))
        if tail <= bound:
            N = cand
            break
    assert N is not None, c
    s = [b[n] / (n + 1) for n in range(N + 1)]
    e = [b[n] for n in range(N + 1)]
    return s, e, N


# ── N2: rationale Näherungen für qnorm (selbst angepasst) ───────────────────
#
# Drei Zonen in p (unteres Ende; das obere über 1 - p bzw. die Symmetrie):
#
#   A  |q| <= q_A, q = p - 1/2, q_A = Phi(1.5) - 1/2 (also |x| <= 1.5):
#        x = s (1 + w G(z)),  s = sqrt(2 pi) q,  w = q^2,  z = 1/4 - w = p (1 - p).
#      Aus der Umkehrreihe (Reihenumkehr von DLMF 7.6.1) ist x/s - 1 = s^2/6 + ... eine gerade
#      Funktion von q; G = (x/s - 1)/w ist daher eine Funktion von w mit G(0) = pi/3. Ihre nächste
#      Singularität liegt bei w = 1/4 (p = 0 bzw. 1); in der Variablen z = 1/4 - w liegen die Pole
#      der angepassten rationalen Funktion bei z < 0, alle Koeffizienten werden positiv (Horner ohne
#      Auslöschung). G = P_7(z)/Q_8(z), Q(0) = 1. Diese Zone braucht in slc_normal.c keinen
#      Korrekturschritt (s als Doppelwort; der Rest x - s ist höchstens 28 % von x).
#   B  Phi(-1.5) > p >= 2.8e-7 (5.0034 > -x > 1.5): -x = P_4(t)/Q_4(t), t = sqrt(-2 ln p);
#      danach ein Halley-Schritt (Startfehler < 1e-11 relativ).
#   C  p < 2.8e-7 bis 2^-1074 (-x bis 38.5): -x = P_5(t)/Q_5(t); danach ein Newton-Schritt auf
#      ln Q (Startfehler < 1e-10 relativ).
#
# Anpassung: Stützstellen nach Tschebyschow in x (je Zone n Stellen; cos per Taylor-Reihe in
# decimal, damit das Ergebnis nicht von der libm abhängt); Zielwerte aus der eigenen Referenz
# (Phi - 1/2 nach DLMF 7.6.2, Q im Rand per Kettenbruch DLMF 7.9.2); g ~ P/Q mit kleinsten
# Quadraten im relativen Fehler, linearisiert (P - g Q)/(g Q_alt) und iteriert (Sanathanan,
# Koerner 1963), danach Umgewichtung w_i <- w_i |e_i| Richtung Minimax (Lawson 1961); behalten
# wird die Iteration mit dem kleinsten größten Fehler an den Stützstellen. Lineare Gleichungen
# per Gauß-Elimination mit Spaltenpivot in decimal (60 Stellen), Variable dabei auf [0, 1]
# skaliert. Prüfung danach mit den auf double gerundeten Koeffizienten (exakt ausgewertet) auf
# einem dichteren Gitter (qn_fit_check). Keine Koeffizienten aus veröffentlichten Programmen.

QN_XA = D("1.5")            # Grenze der Zone A in |x|
QN_PC = D("2.8e-7")         # Grenze Zone B / C in p (wie bisher: x < -5.0034)


def dec_cos(x: Decimal) -> Decimal:
    """cos x über die Taylor-Reihe (|x| <= pi)."""
    s = D(0)
    term = D(1)
    k = 0
    eps = D(10) ** (-(getcontext().prec + 5))
    while abs(term) > eps:
        s += term
        k += 2
        term = -term * x * x / (k * (k - 1))
    return s


def cheb_nodes(a: Decimal, b: Decimal, n: int) -> list[Decimal]:
    return [(a + b) / 2 + (b - a) / 2 * dec_cos(PI * (2 * k + 1) / (2 * n)) for k in range(n)]


def q_upper(a: Decimal) -> Decimal:
    """Q(a) = 1 - Phi(a) für a >= 0: bis a = 10 als 1/2 - D(a) (DLMF 7.6.2, mit 110 Stellen),
    sonst Kettenbruch DLMF 7.9.2 mit 400 Gliedern von unten."""
    if a <= 10:
        old = getcontext().prec
        getcontext().prec = 110
        v = D(1) / 2 - Dnorm_half(a)
        getcontext().prec = old
        return +v
    z = a / SQRT2
    f = D(0)
    for k in range(400, 1, -1):
        f = (-(2 * k - 3) * (2 * k - 2)) / (2 * z * z + 4 * k - 3 + f)
    f = 2 * z / (2 * z * z + 1 + f)
    return f * (-(z * z)).exp() / SQRTPI / 2


def lin_solve(A, b):
    """Gauß-Elimination mit Spaltenpivot (decimal)."""
    n = len(b)
    M = [row[:] + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        piv = max(range(c, n), key=lambda r: abs(M[r][c]))
        M[c], M[piv] = M[piv], M[c]
        for r in range(c + 1, n):
            f = M[r][c] / M[c][c]
            if f:
                for k in range(c, n + 1):
                    M[r][k] -= f * M[c][k]
    x = [D(0)] * n
    for c in range(n - 1, -1, -1):
        x[c] = (M[c][n] - sum(M[c][k] * x[k] for k in range(c + 1, n))) / M[c][c]
    return x


def poly_dec(c, z):
    s = D(0)
    for a in reversed(c):
        s = s * z + a
    return s


def rat_fit(zs, gs, nP, nQ, scale, iters=8, lawson=30):
    """g ~ P(z)/Q(z) mit Q(0) = 1 im relativen Fehler (Sanathanan-Koerner, dann Lawson).
    Rückgabe (größter Fehler an den Stützstellen, P, Q) mit Koeffizienten in z."""
    zz = [z / scale for z in zs]
    wt = [D(1)] * len(zs)
    qold = [D(1)] * len(zs)
    best = None
    nu = nP + 1 + nQ
    for it in range(iters + lawson):
        A = [[D(0)] * nu for _ in range(nu)]
        b = [D(0)] * nu
        for z, g, w, qo in zip(zz, gs, wt, qold):
            den = g * qo
            zp = [D(1)]
            for _ in range(max(nP, nQ)):
                zp.append(zp[-1] * z)
            row = [zp[k] / den for k in range(nP + 1)] + [-g * zp[k] / den for k in range(1, nQ + 1)]
            rhs = g / den
            for i in range(nu):
                ri = row[i] * w
                b[i] += ri * rhs
                Ai = A[i]
                for j in range(nu):
                    Ai[j] += ri * row[j]
        x = lin_solve(A, b)
        P = x[:nP + 1]
        Q = [D(1)] + x[nP + 1:]
        errs = [(poly_dec(P, z) / poly_dec(Q, z) - g) / g for z, g in zip(zz, gs)]
        m = max(abs(e) for e in errs)
        if best is None or m < best[0]:
            best = (m, P, Q)
        if it < iters:
            qold = [poly_dec(Q, z) for z in zz]
        else:
            s = sum(w * abs(e) for w, e in zip(wt, errs))
            wt = [w * abs(e) / s * len(wt) for w, e in zip(wt, errs)]
    m, P, Q = best
    return m, [a / scale ** k for k, a in enumerate(P)], [a / scale ** k for k, a in enumerate(Q)]


def qn_zone_a_target(x: Decimal):
    """(z, G) zu x in Zone A"""
    q = Dnorm_half(x)
    w = q * q
    return D(1) / 4 - w, (x / (SQRT2PI * q) - 1) / w


def qn_zone_t_target(a: Decimal):
    """(t, -x) zu -x = a > 0 in den Zonen B, C"""
    return (-2 * q_upper(a).ln()).sqrt(), a


def qnorm_fits():
    """Anpassung der drei Zonen; Rückgabe dict Zone -> (P, Q, Fehler an den Stützstellen, Bereich)."""
    res = {}
    za = [qn_zone_a_target(x) for x in cheb_nodes(D(0), QN_XA + D("0.005"), 120)]
    m, P, Q = rat_fit([z for z, _ in za], [g for _, g in za], 7, 8, D(1) / 4)
    res["a"] = (P, Q, m, (D(0), QN_XA + D("0.005")))
    zb = [qn_zone_t_target(a) for a in cheb_nodes(QN_XA - D("0.005"), D("5.01"), 80)]
    m, P, Q = rat_fit([t for t, _ in zb], [g for _, g in zb], 4, 4, D(6))
    res["b"] = (P, Q, m, (QN_XA - D("0.005"), D("5.01")))
    zc = [qn_zone_t_target(a) for a in cheb_nodes(D(5), D("38.6"), 80)]
    m, P, Q = rat_fit([t for t, _ in zc], [g for _, g in zc], 5, 5, D(40))
    res["c"] = (P, Q, m, (D(5), D("38.6")))
    return res


def qn_fit_check(res):
    """Fehler der auf double gerundeten Näherungen (exakt ausgewertet) auf einem dichten Gitter;
    Grenzen: Zone A |G - G_ref|/G_ref < 4e-16 (geht mit höchstens 28 % in x ein), B < 1e-11,
    C < 1e-10 (relativ in x)."""
    out = {}
    for zone, target, n, lim in (("a", qn_zone_a_target, 700, D("4e-16")), ("b", qn_zone_t_target, 300, D("1e-11")),
                                 ("c", qn_zone_t_target, 300, D("1e-10"))):
        P, Q, _, (lo, hi) = res[zone]
        Pd = [D(float(c)) for c in P]
        Qd = [D(float(c)) for c in Q]
        worst = D(0)
        for k in range(1, n + 1):
            x = lo + (hi - lo) * k / (n + 1)
            z, g = target(x)
            e = abs(poly_dec(Pd, z) / poly_dec(Qd, z) - g) / g
            worst = max(worst, e)
        assert worst < lim, (zone, worst)
        out[zone] = worst
    return out


# ── SplitMix64 und xoshiro256 ───────────────────────────────────────────────

def golden_gamma() -> int:
    phi = (1 + D(5).sqrt()) / 2
    g = int(D(2) ** 64 / phi)
    return g | 1


def rotl(x, k):
    return ((x << k) | (x >> (64 - k))) & M64


def xoshiro_step(s):
    """Lineare Zustandsabbildung von xoshiro256 (Blackman, Vigna 2021, Abb. 'xoshiro256')."""
    s0, s1, s2, s3 = s
    t = (s1 << 17) & M64
    s2 ^= s0
    s3 ^= s1
    s1 ^= s2
    s0 ^= s3
    s2 ^= t
    s3 = rotl(s3, 45)
    return [s0, s1, s2, s3]


def berlekamp_massey(bits):
    """Kürzestes lineares Schieberegister über GF(2) (Massey 1969); Polynom als int (Bit i = x^i).

    Liefert das Verbindungspolynom C(x) = 1 + c_1 x + ... + c_L x^L und L."""
    C = 1
    B = 1
    L = 0
    m = 1
    for n in range(len(bits)):
        # Diskrepanz
        d = bits[n]
        for i in range(1, L + 1):
            if (C >> i) & 1:
                d ^= bits[n - i]
        if d == 0:
            m += 1
        elif 2 * L <= n:
            T = C
            C ^= B << m
            L = n + 1 - L
            B = T
            m = 1
        else:
            C ^= B << m
            m += 1
    return C, L


def poly_mulmod(a, b, p, deg):
    r = 0
    while b:
        if b & 1:
            r ^= a
        b >>= 1
        a <<= 1
        if (a >> deg) & 1:
            a ^= p
    return r


def jump_poly(exp2: int):
    """x^(2^exp2) mod P(x) mit P = charakteristisches Polynom der Zustandsabbildung."""
    # Bitfolge: niedrigstes Bit von s[0] über 2 * 256 + 64 Schritte, Start beliebig ungleich 0
    s = [0x0123456789ABCDEF, 0x1122334455667788, 0x99AABBCCDDEEFF00, 0x0F1E2D3C4B5A6978]
    bits = []
    for _ in range(2 * 256 + 64):
        bits.append(s[0] & 1)
        s = xoshiro_step(s)
    C, L = berlekamp_massey(bits)
    assert L == 256, L
    # Verbindungspolynom C(x) -> charakteristisches Polynom P(x) = x^L C(1/x) (Spiegelung)
    P = 0
    for i in range(L + 1):
        if (C >> i) & 1:
            P |= 1 << (L - i)
    r = 2  # x
    for _ in range(exp2):
        r = poly_mulmod(r, r, P, L)
    return r, P


def apply_poly(poly, s):
    """poly(T) s: sum der Koeffizienten c_i T^i s, i = 0 ... 255 (Schema des Sprungs)."""
    acc = [0, 0, 0, 0]
    for i in range(256):
        if (poly >> i) & 1:
            acc = [acc[j] ^ s[j] for j in range(4)]
        s = xoshiro_step(s)
    return acc


def check_jump_method(P):
    """x^k mod P angewandt = k Einzelschritte, für einige k (Probe des Verfahrens)."""
    s0 = [0xDEADBEEF, 0x12345678ABCDEF01, 0xFEDCBA9876543210, 0x0BADC0DE]
    for k in (1, 2, 3, 100, 255, 256, 257, 1000, 4097):
        r = 1
        base = 2
        e = k
        while e:
            if e & 1:
                r = poly_mulmod(r, base, P, 256)
            base = poly_mulmod(base, base, P, 256)
            e >>= 1
        s = list(s0)
        for _ in range(k):
            s = xoshiro_step(s)
        assert apply_poly(r, s0) == s, k


# veröffentlichter Wert (Blackman, Vigna 2021; Sprung um 2^128 für xoshiro256)
PUBLISHED_JUMP = (0x180ec6d33cfd0aba, 0xd5a61266f0c9392c, 0xa9582618e03fc9aa, 0x39abdc4529b1661c)


# ── Ausgabe ─────────────────────────────────────────────────────────────────

def dbl(x) -> float:
    """Decimal -> nächstgelegener double (über die exakte Dezimaldarstellung)."""
    return float(x)


def fmt(x: float) -> str:
    if x == 0.0:
        return "0.0" if math.copysign(1.0, x) > 0 else "-0.0"
    s = "%.20e" % x       # 21 gültige Ziffern
    assert float(s) == x
    return s


def hi_lo(v: Decimal):
    hi = dbl(v)
    lo = dbl(v - D(hi))
    return hi, lo


def build() -> str:
    L = []
    w = L.append
    w("/* core/slc_constants.h – Konstanten der C-Bibliothek slc (SimLev core, Etappe 9)")
    w(" *")
    w(" * ERZEUGT von core/tools/gen_constants.py – nicht von Hand ändern.")
    w(" * Herleitung: siehe Kopf von gen_constants.py (nur Python-Standardbibliothek,")
    w(" * decimal mit 60 Stellen, fractions). 21 gültige Ziffern; Hex-Wert im Kommentar.")
    w(" */")
    w("#ifndef SLC_CONSTANTS_H")
    w("#define SLC_CONSTANTS_H")
    w("")
    w("/* Tabellen nur in den Dateien, die sie brauchen: SLC_NEED_GAMMA_TABLES, SLC_NEED_NORMAL_TABLES,")
    w(" * SLC_NEED_JUMP vor dem Einbinden setzen (sonst Warnungen über unbenutzte static-Felder). */")
    w("#include <stdint.h>")
    w("")

    def c(name, v, note):
        x = dbl(v) if isinstance(v, Decimal) else float(v)
        w("#define %-22s %s  /* %s; %s */" % (name, fmt(x), x.hex(), note))

    w("/* ── mathematische Konstanten ── */")
    c("SLC_PI", PI, "pi (Machin)")
    c("SLC_SQRT2", SQRT2, "sqrt(2)")
    c("SLC_M_1_SQRT2", 1 / SQRT2, "1/sqrt(2)")
    c("SLC_SQRT2PI", SQRT2PI, "sqrt(2 pi)")
    c("SLC_M_1_SQRT2PI", 1 / SQRT2PI, "1/sqrt(2 pi) = phi(0)")
    c("SLC_LN_SQRT2PI", LNSQRT2PI, "ln sqrt(2 pi)")
    c("SLC_LN_2PI", 2 * LNSQRT2PI, "ln(2 pi)")
    c("SLC_LN2", LN2, "ln 2")
    c("SLC_M_2_SQRTPI", 2 / SQRTPI, "2/sqrt(pi)")
    c("SLC_M_1_SQRTPI", 1 / SQRTPI, "1/sqrt(pi)")
    c("SLC_LN_SQRTPI", SQRTPI.ln(), "ln sqrt(pi)")
    c("SLC_EULER_GAMMA", GAMMA, "Euler-Mascheroni (Euler-Maclaurin)")
    c("SLC_LGAMMA_HALF", SQRTPI.ln(), "ln Gamma(1/2) = ln sqrt(pi)")
    c("SLC_TWO_M53", D(2) ** -53, "2^-53")
    c("SLC_TWO_M52", D(2) ** -52, "2^-52")
    w("")

    # Stirling
    w("/* ── Stirling-Reihe (DLMF 5.11.1): Glied k = B_2k / (2k (2k-1)), k = 1 ... 8 ── */")
    w("#define SLC_STIRLING_N 8")
    w("#ifdef SLC_NEED_GAMMA_TABLES")
    w("static const double slc_stirling[SLC_STIRLING_N] = {")
    for k in range(1, 9):
        f = BERN[2 * k] / (2 * k * (2 * k - 1))
        x = float(f)
        w("    %s,  /* %s = B_%d/(%d*%d) = %s */" % (fmt(x), x.hex(), 2 * k, 2 * k, 2 * k - 1, f))
    w("};")
    w("#endif /* SLC_NEED_GAMMA_TABLES */")
    w("")

    # ln Gamma(2 + e)
    K = 30
    w("/* ── ln Gamma(2 + e) = sum_{k=1}^{%d} c_k e^k (DLMF 5.7.3): c_1 = 1 - gamma, ── */" % K)
    w("/*    c_k = (-1)^k (zeta(k) - 1) / k; zeta per Euler-Maclaurin                    */")
    w("#define SLC_LG2_N %d" % K)
    w("#ifdef SLC_NEED_GAMMA_TABLES")
    w("static const double slc_lg2[SLC_LG2_N] = {")
    coeffs = [1 - GAMMA]
    for k in range(2, K + 1):
        coeffs.append((-1) ** k * zeta_minus_1(k) / k)
    for k, v in enumerate(coeffs, start=1):
        x = dbl(v)
        w("    %s,  /* c_%d = %s */" % (fmt(x), k, x.hex()))
    w("};")
    w("#endif /* SLC_NEED_GAMMA_TABLES */")
    w("")

    # Normal tables
    NJ = 40
    w("/* ── Normalverteilung an x_j = j/8, j = 0 ... %d (DLMF 7.6.2 mit z = x/sqrt 2) ── */" % NJ)
    w("/*    je Zeile: phi(x_j); D(x_j) = Phi(x_j) - 1/2 als hi, lo; Q(x_j) = 1 - Phi(x_j) als hi, lo */")
    w("#define SLC_NT_N %d" % (NJ + 1))
    w("#define SLC_NT_STEP 0.125")
    w("#define SLC_NT_XMAX %s" % fmt(NJ / 8))
    w("#ifdef SLC_NEED_NORMAL_TABLES")
    w("static const double slc_ntab[SLC_NT_N][5] = {")
    for j in range(NJ + 1):
        x = D(j) / 8
        ph = phi_dec(x)
        dd = Dnorm_half(x)
        q = D(1) / 2 - dd
        dh, dl = hi_lo(dd)
        qh, ql = hi_lo(q)
        w("    { %s, %s, %s, %s, %s },  /* x = %s */" % (fmt(dbl(ph)), fmt(dh), fmt(dl), fmt(qh), fmt(ql), j / 8))
    w("};")
    w("#endif /* SLC_NEED_NORMAL_TABLES */")
    w("")

    EJ = 28
    w("/* ── erfc an z_j = j/8, j = 0 ... %d (DLMF 7.6.2): erfc hi, lo; (2/sqrt pi) e^(-z_j^2) ── */" % EJ)
    w("#define SLC_ET_N %d" % (EJ + 1))
    w("#define SLC_ET_STEP 0.125")
    w("#define SLC_ET_ZMAX %s" % fmt(EJ / 8))
    w("#ifdef SLC_NEED_NORMAL_TABLES")
    w("static const double slc_etab[SLC_ET_N][3] = {")
    for j in range(EJ + 1):
        z = D(j) / 8
        e = 1 - erf_dec(z)
        eh, el = hi_lo(e)
        g = 2 / SQRTPI * (-(z * z)).exp()
        w("    { %s, %s, %s },  /* z = %s */" % (fmt(eh), fmt(el), fmt(dbl(g)), j / 8))
    w("};")
    w("#endif /* SLC_NEED_NORMAL_TABLES */")
    w("")

    def polytab(name, centers, k):
        rows = [taylor_poly(cj, k) for cj in centers]
        deg = max(r[2] for r in rows)
        w("/* ── %s: Taylor-Polynome je Stützpunkt (exakt mit Brüchen, Grad je Zeile in [0]) ── */" % name)
        w("/*    S(h) = h (s_0 + s_1 h + ... + s_N h^N), E(h) = e_0 + e_1 h + ... + e_N h^N; Rest < 2^-63 */")
        w("#define %s_DEG %d" % (name.upper(), deg))
        w("#ifdef SLC_NEED_NORMAL_TABLES")
        for part, idx in (("S", 0), ("E", 1)):
            if name == "slc_epoly" and part == "E":
                continue
            w("static const double %s_%s[%d][%s_DEG + 2] = {" % (name, part, len(centers), name.upper()))
            for cj, r in zip(centers, rows):
                coef = r[idx]
                w("    { %d, %s },  /* c = %s */" % (r[2], ", ".join(fmt(float(q)) for q in coef)
                                                   + ", 0.0" * (deg - r[2]), float(cj)))
            w("};")
        w("#endif /* SLC_NEED_NORMAL_TABLES */")
        w("")

    polytab("slc_npoly", [Fraction(j, 8) for j in range(NJ + 1)], Fraction(1, 2))
    polytab("slc_epoly", [Fraction(j, 8) for j in range(EJ + 1)], Fraction(1))
    w("")

    b = inverse_series_coeffs(3)
    w("/* ── Startwert qnorm: x = s + c3 s^3 + c5 s^5, s = sqrt(2 pi) (p - 1/2) (Reihenumkehr) ── */")
    w("#define SLC_QN_C3 %s  /* %s */" % (fmt(float(b[3])), b[3]))
    w("#define SLC_QN_C5 %s  /* %s */" % (fmt(float(b[5])), b[5]))
    w("")

    # N2: qnorm-Zonen und selbst angepasste rationale Näherungen (Herleitung bei qnorm_fits)
    res = qnorm_fits()
    chk = qn_fit_check(res)
    s2h = dbl(SQRT2PI)
    s2l = dbl(SQRT2PI - D(s2h))
    c27 = 134217729.0
    t_ = c27 * s2h
    s2a = t_ - (t_ - s2h)
    s2b = s2h - s2a
    qa = dbl(Dnorm_half(QN_XA))
    w("/* ── N2: qnorm in drei Zonen mit selbst angepassten rationalen Näherungen (gen_constants.py, ── */")
    w("/*    qnorm_fits: Sanathanan-Koerner + Lawson an der eigenen Referenz, Stützstellen nach         */")
    w("/*    Tschebyschow). Zone A |p - 1/2| <= SLC_QN_QA: x = s (1 + w G(z)), s = sqrt(2 pi) q,          */")
    w("/*    w = q^2, z = 1/4 - w, G = P_7(z)/Q_8(z). Zone B p >= SLC_QN_PC: -x = P_4(t)/Q_4(t), Zone C:  */")
    w("/*    -x = P_5(t)/Q_5(t), t = sqrt(-2 ln p). Fehler (Stützstellen; dichtes Gitter mit den        */")
    w("/*    double-Koeffizienten): A (in G) %.1e; %.1e, B %.1e; %.1e, C %.1e; %.1e   */"
      % (res["a"][2], chk["a"], res["b"][2], chk["b"], res["c"][2], chk["c"]))
    w("#define SLC_QN_QA %s  /* %s; Phi(1.5) - 1/2 */" % (fmt(qa), qa.hex()))
    w("#define SLC_QN_PC %s  /* %s; Grenze Zone B/C */" % (fmt(float(QN_PC)), float(QN_PC).hex()))
    w("#define SLC_SQRT2PI_LO %s  /* %s; sqrt(2 pi) - SLC_SQRT2PI */" % (fmt(s2l), s2l.hex()))
    w("#define SLC_SQRT2PI_H26 %s  /* %s; Veltkamp-Teilung von SLC_SQRT2PI (hi, 26 Bit) */" % (fmt(s2a), s2a.hex()))
    w("#define SLC_SQRT2PI_L26 %s  /* %s; (lo) */" % (fmt(s2b), s2b.hex()))
    assert s2a + s2b == s2h
    w("#ifdef SLC_NEED_NORMAL_TABLES")
    for zone, names in (("a", ("slc_qn_ap", "slc_qn_aq")), ("b", ("slc_qn_bp", "slc_qn_bq")),
                        ("c", ("slc_qn_cp", "slc_qn_cq"))):
        P, Q = res[zone][0], res[zone][1]
        for nm, cf in zip(names, (P, Q)):
            w("static const double %s[%d] = {  /* Koeffizient von z^0 (bzw. t^0) zuerst */" % (nm, len(cf)))
            w("    " + ",\n    ".join(fmt(dbl(c)) for c in cf))
            w("};")
    w("#endif /* SLC_NEED_NORMAL_TABLES */")
    w("")

    gg = golden_gamma()
    w("/* ── SplitMix64 (Steele, Lea, Flood 2014): Inkrement = ungerade Zahl nächst 2^64/phi ── */")
    w("#define SLC_SPLITMIX_GAMMA UINT64_C(0x%016x)" % gg)
    w("")

    jp, P = jump_poly(128)
    check_jump_method(P)
    words = tuple((jp >> (64 * i)) & M64 for i in range(4))
    assert words == PUBLISHED_JUMP, [hex(x) for x in words]
    w("/* ── xoshiro256: Sprungpolynom x^(2^128) mod P(x), Bit i = Koeffizient von x^i ── */")
    w("/*    P = charakteristisches Polynom (Berlekamp-Massey); gleich dem veröffentlichten Wert */")
    w("/*    (Blackman, Vigna 2021). P(x) als Probe: */")
    w("/*    0x%064x */" % P)
    w("#ifdef SLC_NEED_JUMP")
    w("static const uint64_t slc_jump128[4] = {")
    w("    " + ", ".join("UINT64_C(0x%016x)" % x for x in words))
    w("};")
    w("#endif /* SLC_NEED_JUMP */")
    w("")
    w("#endif /* SLC_CONSTANTS_H */")
    return "\n".join(L) + "\n"


def self_checks():
    # zeta-Probe
    z2 = zeta_minus_1(2) + 1
    z4 = zeta_minus_1(4) + 1
    assert abs(z2 - PI * PI / 6) < D(10) ** -45, z2
    assert abs(z4 - PI ** 4 / 90) < D(10) ** -45, z4
    # gamma-Probe: ln Gamma(2 + 1) = ln 2 aus der Reihe 5.7.3 (|z| < 2 konvergent, langsam bei 1)
    # Probe stattdessen: Phi(0) - 1/2 = 0, Q(8 Glieder) gegen erfc-Beziehung Q(x) = erfc(x/sqrt2)/2
    for x in (D("0.5"), D("1.75"), D(3)):
        q = D(1) / 2 - Dnorm_half(x)
        e = (1 - erf_dec(x / SQRT2)) / 2
        assert abs(q - e) < D(10) ** -50 * max(q, D(1e-30))
    # Bernoulli
    assert BERN[2] == Fraction(1, 6) and BERN[4] == Fraction(-1, 30) and BERN[12] == Fraction(-691, 2730)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args(argv)
    self_checks()
    txt = build()
    if a.check:
        try:
            with open(a.out, encoding="utf-8") as fh:
                old = fh.read()
        except FileNotFoundError:
            old = None
        if old != txt:
            print("gen_constants: %s weicht ab" % a.out)
            return 1
        print("gen_constants: %s aktuell" % a.out)
        return 0
    with open(a.out, "w", encoding="utf-8") as fh:
        fh.write(txt)
    print("gen_constants: %s geschrieben" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
