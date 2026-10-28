"""Bootstrap-Kerne (Port von ``r/src/bootstrap_core.cpp``, ``.garch_filter`` und ``r/src/ms_garch.c``).

Jeder Kern liefert wie im Original die 1-basierten Quellzeilen der gezogenen
Beobachtungen; parametrische Verfahren zusätzlich die simulierte
Renditematrix. Zufallszahlen ausschließlich über :mod:`simlev._r.rng`
(``R::runif`` = :func:`runif1`, ``R::rgeom`` = :func:`rgeom1`,
``R::rnorm`` = :func:`rnorm1`), damit ``set_seed`` und L'Ecuyer-Streams wie in
R greifen. Rechenreihenfolge 1:1 aus dem C++-Code.
"""
from __future__ import annotations

import math

import numpy as np

from ._r import rng as _rng

__all__ = ["boot_idx_iid", "boot_idx_block", "boot_idx_stationary", "boot_idx_regime",
           "boot_idx_tails", "boot_wild", "boot_reset", "boot_evt", "boot_garch",
           "boot_ms_garch", "rolling_vol", "assign_regimes", "estimate_trans_mat",
           "garch_filter", "ms_garch_filter"]


def _draw_int(n: int) -> int:
    """Gleichverteilt in {0, …, n-1}: ``floor(R::runif(0, n))``."""
    k = int(math.floor(_rng.runif1(0.0, float(n))))
    return n - 1 if k >= n else k


def _state():
    _rng._get_state()          # Rcpp::RNGScope → GetRNGstate()


def _as_int_vec(x):
    return [int(v) for v in np.asarray(x).ravel()]


def _as_mat(x):
    return np.asarray(x, dtype=np.float64).reshape(np.shape(x)) if np.ndim(x) == 2 else \
        np.asarray(x, dtype=np.float64).reshape(-1, 1)


# ── Index-Kerne ───────────────────────────────────────────────────────────

def boot_idx_iid(n_src: int, n_out: int) -> np.ndarray:
    """``.boot_idx_iid``: IID-Bootstrap (Efron 1979)."""
    n_src = int(n_src)
    n_out = int(n_out)
    if n_src < 1:
        raise ValueError("Keine Quellzeilen")
    _state()
    return np.array([_draw_int(n_src) + 1 for _ in range(n_out)], dtype=np.int64)


def boot_idx_block(n_src: int, n_out: int, block_length: int, circular: bool) -> np.ndarray:
    """``.boot_idx_block``: Moving bzw. Circular Block Bootstrap."""
    n_src = int(n_src)
    n_out = int(n_out)
    block_length = int(block_length)
    if n_src < 1:
        raise ValueError("Keine Quellzeilen")
    if block_length <= 0:
        raise ValueError("block_length muss positiv sein")
    if block_length > n_src:
        raise ValueError("block_length (%d) ist größer als die Historie (%d Zeilen)" % (block_length, n_src))
    _state()
    idx = np.empty(n_out, dtype=np.int64)
    i = 0
    n_start = n_src if circular else (n_src - block_length + 1)
    while i < n_out:
        start = _draw_int(n_start)
        ln = min(block_length, n_out - i)
        idx[i:i + ln] = (np.arange(start, start + ln) % n_src) + 1
        i += ln
    return idx


def boot_idx_stationary(n_src: int, n_out: int, L: float) -> np.ndarray:
    """``.boot_idx_stationary``: stationärer Bootstrap (Politis & Romano 1994)."""
    n_src = int(n_src)
    n_out = int(n_out)
    L = float(L)
    if n_src < 1:
        raise ValueError("Keine Quellzeilen")
    if not (L >= 1.0):
        raise ValueError("L muss >= 1 sein")
    _state()
    idx = np.empty(n_out, dtype=np.int64)
    p = 1.0 / L
    i = 0
    while i < n_out:
        ln = 1 if p >= 1.0 else int(_rng.rgeom1(p)) + 1
        start = _draw_int(n_src)
        ln = min(ln, n_out - i)
        idx[i:i + ln] = (np.arange(start, start + ln) % n_src) + 1
        i += ln
    return idx


def _stationary_dist(P: np.ndarray):
    K = P.shape[0]
    pi = [1.0 / K] * K
    nw = [0.0] * K
    for _ in range(2000):
        s = 0.0
        diff = 0.0
        for j in range(K):
            v = 0.0
            for i in range(K):
                v += pi[i] * float(P[i, j])
            nw[j] = v
            s += v
        for j in range(K):
            nw[j] /= s
            diff += abs(nw[j] - pi[j])
        pi = list(nw)
        if diff < 1e-12:
            break
    return pi


def _draw_from(p, K: int) -> int:
    u = _rng.runif1(0.0, 1.0)
    c = 0.0
    for r in range(K):
        c += p[r]
        if u <= c:
            return r
    return K - 1


def boot_idx_regime(regimes, trans, n_out: int) -> np.ndarray:
    """``.boot_idx_regime``: Markov-Kette über Volatilitätsregime."""
    reg = _as_int_vec(regimes)
    T = _as_mat(trans)
    n = len(reg)
    K = T.shape[0]
    n_out = int(n_out)
    pool = [[] for _ in range(K)]
    for i in range(n):
        r = reg[i] - 1
        if 0 <= r < K:
            pool[r].append(i)
    _state()
    pi = _stationary_dist(T)
    for r in range(K):
        if not pool[r]:
            pi[r] = 0.0
    s = 0.0
    for r in range(K):
        s += pi[r]
    pi = [pi[r] / s if s > 0 else 1.0 / K for r in range(K)]
    cur = _draw_from(pi, K)
    idx = np.empty(n_out, dtype=np.int64)
    for t in range(n_out):
        p = pool[cur]
        if not p:
            for r in range(K):
                if pool[r]:
                    p = pool[r]
                    break
        idx[t] = p[_draw_int(len(p))] + 1
        row = [float(T[cur, r]) for r in range(K)]
        cur = _draw_from(row, K)
    return idx


def boot_idx_tails(n_out: int, p_l: float, p_r: float, bulk_idx, left_idx, right_idx) -> np.ndarray:
    """``.boot_idx_tails``: Mischung aus linkem Rand, Kern und rechtem Rand."""
    b = _as_int_vec(bulk_idx)
    lf = _as_int_vec(left_idx)
    rt = _as_int_vec(right_idx)
    nb, nl, nr = len(b), len(lf), len(rt)
    if nb == 0:
        raise ValueError("Keine Bulk-Beobachtungen")
    _state()
    n_out = int(n_out)
    idx = np.empty(n_out, dtype=np.int64)
    for t in range(n_out):
        u = _rng.runif1(0.0, 1.0)
        if u < p_l and nl > 0:
            idx[t] = lf[_draw_int(nl)]
        elif u < p_l + p_r and nr > 0:
            idx[t] = rt[_draw_int(nr)]
        else:
            idx[t] = b[_draw_int(nb)]
    return idx


# ── Matrix-Kerne ──────────────────────────────────────────────────────────

def boot_wild(returns, type: int) -> np.ndarray:  # noqa: A002
    """``.boot_wild``: Wild Bootstrap mit gemeinsamem Gewicht je Zeile."""
    type = int(type)
    if type < 0 or type > 2:
        raise ValueError("wild_type muss 0, 1 oder 2 sein (erhalten: %d)" % type)
    X = _as_mat(returns)
    n, k = X.shape
    mu = np.empty(k)
    for j in range(k):
        s = 0.0
        for i in range(n):
            s += float(X[i, j])
        mu[j] = s / n
    s5 = math.sqrt(5.0)
    mp = (s5 + 1.0) / (2.0 * s5)
    mneg = -(s5 - 1.0) / 2.0
    mpos = (s5 + 1.0) / 2.0
    _state()
    w = np.empty(n)
    for i in range(n):
        if type == 0:
            w[i] = -1.0 if _rng.runif1(0, 1) < 0.5 else 1.0
        elif type == 1:
            w[i] = mneg if _rng.runif1(0, 1) < mp else mpos
        else:
            w[i] = _rng.rnorm1(0.0, 1.0)
    return mu[None, :] + (X - mu[None, :]) * w[:, None]


def boot_reset(returns, p_break: float) -> np.ndarray:
    """``.boot_reset``: Segmente mit Wahrscheinlichkeit ``p_break`` spiegeln."""
    if not (p_break >= 0.0 and p_break <= 1.0):
        raise ValueError("p_break muss in [0, 1] liegen")
    X = _as_mat(returns)
    n, k = X.shape
    _state()
    flip = np.empty(n, dtype=bool)
    flipped = False
    for t in range(n):
        if _rng.runif1(0, 1) < p_break:
            flipped = not flipped
        flip[t] = flipped
    out = X.copy()
    out[flip, :] = 2.0 - X[flip, :]
    return out


def _rgpd(scale: float, shape: float) -> float:
    u = _rng.runif1(0.0, 1.0)
    if u <= 0.0:
        u = 1e-300
    if abs(shape) < 1e-10:
        return -scale * math.log(u)
    return scale * (math.pow(u, -shape) - 1.0) / shape


def boot_evt(returns, base: int, n_out: int,
             p_l, thresh_l, scale_l, shape_l, pool_l,
             p_r, thresh_r, scale_r, shape_r, pool_r, bulk_idx) -> dict:
    """``.boot_evt``: Kern empirisch, Ränder der Basisreihe aus der GPD."""
    X = _as_mat(returns)
    k = X.shape[1]
    base = int(base)
    pl = _as_int_vec(pool_l)
    pr = _as_int_vec(pool_r)
    b = _as_int_vec(bulk_idx)
    nb, nl, nr = len(b), len(pl), len(pr)
    if nb == 0:
        raise ValueError("Keine Bulk-Beobachtungen")
    n_out = int(n_out)
    out = np.empty((n_out, k))
    idx = np.empty(n_out, dtype=np.int64)
    _state()
    for t in range(n_out):
        u = _rng.runif1(0.0, 1.0)
        left = u < p_l
        right = (not left) and p_r > 0 and u < p_l + p_r
        if (left and nl > 0) or (right and nr > 0):
            if left:
                rb = thresh_l - _rgpd(scale_l, shape_l)
                j = pl[_draw_int(nl)] - 1
            else:
                rb = thresh_r + _rgpd(scale_r, shape_r)
                j = pr[_draw_int(nr)] - 1
            for c in range(k):
                out[t, c] = rb if c == base else rb * float(X[j, c]) / float(X[j, base])
            idx[t] = j + 1
        else:
            j = b[_draw_int(nb)] - 1
            out[t, :] = X[j, :]
            idx[t] = j + 1
    return {"ret": out, "idx": idx}


class _Cross:
    def __init__(self, cols, mu, om, al, be, ratio, s2_init):
        self.col = _as_int_vec(cols)
        self.m = len(self.col)
        f = lambda v: [float(x) for x in np.asarray(v, dtype=np.float64).ravel()]  # noqa: E731
        self.mu, self.om, self.al, self.be = f(mu), f(om), f(al), f(be)
        self.ratio = [bool(x) for x in np.asarray(ratio).ravel()]
        self.s2 = f(s2_init)
        self.eps = [0.0] * self.m

    def step(self, out, t, base_ret, z_cross, tstar):
        for c in range(self.m):
            s2 = self.om[c] + self.al[c] * self.eps[c] * self.eps[c] + self.be[c] * self.s2[c]
            if s2 < 1e-14:
                s2 = 1e-14
            self.s2[c] = s2
            e = math.sqrt(s2) * float(z_cross[tstar, c])
            self.eps[c] = e
            g = 1.0 + self.mu[c] + e
            out[t, self.col[c]] = base_ret * g if self.ratio[c] else g


def boot_garch(n_out, base, k, mu, omega, alpha, beta, gamma, s2_init, z_base, valid,
               cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross) -> dict:
    """``.boot_garch``: (GJR-)GARCH(1,1) mit Filtered Historical Simulation."""
    if omega <= 0:
        raise ValueError("omega muss > 0 sein")
    v = _as_int_vec(valid)
    nv = len(v)
    if nv == 0:
        raise ValueError("Keine gültigen Residuen")
    n_out = int(n_out)
    base = int(base)
    zb = [float(x) for x in np.asarray(z_base, dtype=np.float64).ravel()]
    zc = np.asarray(z_cross, dtype=np.float64)
    if zc.ndim == 1:
        zc = zc.reshape(-1, 1) if zc.size else zc.reshape(0, 0)
    out = np.zeros((n_out, int(k)))
    idx = np.empty(n_out, dtype=np.int64)
    cs = _Cross(cross_cols, cmu, com, cal, cbe, cratio, cs2)
    s2 = float(s2_init)
    eps = 0.0
    _state()
    for t in range(n_out):
        ind = 1.0 if eps < 0.0 else 0.0
        s2 = omega + (alpha + gamma * ind) * eps * eps + beta * s2
        if s2 < 1e-14:
            s2 = 1e-14
        ts = v[_draw_int(nv)] - 1
        eps = math.sqrt(s2) * zb[ts]
        rb = 1.0 + mu + eps
        out[t, base] = rb
        cs.step(out, t, rb, zc, ts)
        idx[t] = ts + 1
    return {"ret": out, "idx": idx}


def boot_ms_garch(n_out, base, k, K, mu, omega, alpha, beta, gamma, phi, lam,
                  trans, delta, unc_var, stat_prob, pools, z_base,
                  cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross) -> dict:
    """``.boot_ms_garch``: Markov-Switching-(AR-)GJR-GARCH(-M), optional TVTP."""
    K = int(K)
    f = lambda v: [float(x) for x in np.asarray(v, dtype=np.float64).ravel()]  # noqa: E731
    mu, omega, alpha, beta, gamma, phi, lam = f(mu), f(omega), f(alpha), f(beta), f(gamma), f(phi), f(lam)
    T = _as_mat(trans)
    D = _as_mat(delta)
    uv = f(unc_var)
    for i in range(K):
        rs = 0.0
        for j in range(K):
            rs += float(T[i, j])
        if abs(rs - 1.0) > 1e-6:
            raise ValueError("Zeile %d der Uebergangsmatrix summiert nicht auf 1" % (i + 1))
        if uv[i] <= 0:
            raise ValueError("unc_var[%d] <= 0" % (i + 1))
    pl = [[int(x) - 1 for x in np.asarray(p).ravel()] for p in pools]
    tvtp = any(abs(float(D[i, j])) > 1e-12 for i in range(K) for j in range(K))
    n_out = int(n_out)
    base = int(base)
    zb = f(z_base)
    zc = np.asarray(z_cross, dtype=np.float64)
    if zc.ndim == 1:
        zc = zc.reshape(-1, 1) if zc.size else zc.reshape(0, 0)
    out = np.zeros((n_out, int(k)))
    idx = np.empty(n_out, dtype=np.int64)
    reg = np.empty(n_out, dtype=np.int64)
    cs = _Cross(cross_cols, cmu, com, cal, cbe, cratio, cs2)
    sp = f(stat_prob)
    pr = [0.0] * K
    _state()
    r = _draw_from(sp, K)
    s2 = uv[r]
    eps = 0.0
    prev = 0.0
    for t in range(n_out):
        if t > 0:
            old = r
            if tvtp:
                x = s2 / uv[old] - 1.0
                x = min(10.0, max(-0.99, x))
                mx = -1e300
                for j in range(K):
                    b = max(float(T[old, j]), 1e-10)
                    pr[j] = math.log(b) + float(D[old, j]) * x
                    mx = max(mx, pr[j])
                se = 0.0
                for j in range(K):
                    pr[j] = math.exp(pr[j] - mx)
                    se += pr[j]
                for j in range(K):
                    pr[j] /= se
            else:
                for j in range(K):
                    pr[j] = float(T[old, j])
            r = _draw_from(pr, K)
            if r != old:
                s2 = 0.5 * s2 + 0.5 * uv[r]
        ind = 1.0 if eps < 0.0 else 0.0
        s2 = omega[r] + (alpha[r] + gamma[r] * ind) * eps * eps + beta[r] * s2
        if s2 < 1e-14:
            s2 = 1e-14
        sig = math.sqrt(s2)
        p = pl[r]
        if not p:
            for q in range(K):
                if pl[q]:
                    p = pl[q]
                    break
        ts = p[_draw_int(len(p))]
        eps = sig * zb[ts]
        m = mu[r] + phi[r] * prev + lam[r] * sig
        ex = m + eps
        rb = 1.0 + ex
        out[t, base] = rb
        prev = ex
        cs.step(out, t, rb, zc, ts)
        idx[t] = ts + 1
        reg[t] = r + 1
    return {"ret": out, "idx": idx, "regime": reg}


# ── Hilfsfunktionen ──────────────────────────────────────────────────────

def rolling_vol(x, window: int) -> np.ndarray:
    """``.rolling_vol``: rollierende Volatilität von ``x - 1`` (Bessel)."""
    xs = [float(v) for v in np.asarray(x, dtype=np.float64).ravel()]
    n = len(xs)
    window = int(window)
    if window <= 0:
        raise ValueError("window muss positiv sein")
    if window > n:
        window = n
    vol = np.empty(n)
    s = 0.0
    sq = 0.0
    for i in range(n):
        v = xs[i] - 1.0
        s += v
        sq += v * v
        if i >= window:
            o = xs[i - window] - 1.0
            s -= o
            sq -= o * o
        cnt = min(i + 1, window)
        if cnt <= 1:
            vol[i] = 0.0
        else:
            m = s / cnt
            vol[i] = math.sqrt(max(0.0, (sq - cnt * m * m) / (cnt - 1)))
    return vol


def assign_regimes(vol, thresh) -> np.ndarray:
    """``.assign_regimes``: Regime über Schwellen ``[tau_r, tau_{r+1})``."""
    v = np.asarray(vol, dtype=np.float64).ravel()
    th = [float(x) for x in np.asarray(thresh, dtype=np.float64).ravel()]
    K = len(th) - 1
    reg = np.full(v.size, K, dtype=np.int64)
    for i, x in enumerate(v.tolist()):
        for r in range(K):
            if x >= th[r] and x < th[r + 1]:
                reg[i] = r + 1
                break
    return reg


def estimate_trans_mat(regimes, K: int, alpha: float = 0.1) -> np.ndarray:
    """``.estimate_trans_mat``: Übergangsmatrix mit Laplace-Glättung."""
    reg = _as_int_vec(regimes)
    K = int(K)
    P = np.zeros((K, K))
    for t in range(1, len(reg)):
        a = reg[t - 1] - 1
        b = reg[t] - 1
        if 0 <= a < K and 0 <= b < K:
            P[a, b] += 1.0
    for r in range(K):
        s = 0.0
        for c in range(K):
            P[r, c] += alpha
            s += P[r, c]
        for c in range(K):
            P[r, c] /= s
    return P


def garch_filter(ep, om: float, al: float, be: float, ga: float, v0: float) -> np.ndarray:
    """``.garch_filter``: bedingte Varianzen eines GARCH(1,1)/GJR-Modells."""
    e = [float(x) for x in np.asarray(ep, dtype=np.float64).ravel()]
    n = len(e)
    s2 = np.empty(n)
    v = float(v0)
    for t in range(n):
        s2[t] = v
        v = om + (al + ga * (1.0 if e[t] < 0.0 else 0.0)) * (e[t] * e[t]) + be * v
        if v < 1e-14:
            v = 1e-14
    return s2


# ── MS-GARCH-Filter (r/src/ms_garch.c) ──────────────────────────────────────
#
# Hamilton-Filter mit parallelen Varianzpfaden je Regime (Haas, Mittnik und
# Paolella 2004). Rechenfolge wie im C-Kern: Summen beginnen bei 0.0 und
# laufen über k (bzw. i) aufsteigend, jede Formel in der Klammerung des
# C-Codes (y^2 als y * y, 2 pi als 2.0 * M_PI), ohne fma. Elementweise
# Operationen (+ - * / sqrt) rechnet numpy exakt gerundet wie C; exp und log
# kommen aus libm (math.*), mit den C-Randfällen (Überlauf -> Inf,
# log(0) = -Inf, log(<0) = NaN).

def _msg_num(x, length, name):
    """Argument als double-Vektor (wie ``coerceVector``, Matrizen spaltenweise) mit Längenprüfung."""
    a = np.asarray(x)
    if a.dtype.kind not in "biuf":
        raise ValueError("ms_garch_filter: '%s' muss numerisch sein." % name)
    v = np.asarray(a, dtype=np.float64).ravel(order="F")
    if length >= 0 and v.size != length:
        raise ValueError("ms_garch_filter: '%s' muss die Länge %d haben (erhalten: %d)." % (name, length, v.size))
    return v


def _c_exp_list(v):
    try:
        return list(map(math.exp, v))
    except (OverflowError, ValueError):
        out = []
        for x in v:
            try:
                out.append(math.exp(x))
            except OverflowError:
                out.append(math.inf)
        return out


def _c_log1(x):
    if x > 0.0:
        return math.log(x)
    if x == 0.0:
        return -math.inf
    return x if x != x else math.nan


def _c_log_list(v):
    try:
        return list(map(math.log, v))
    except (OverflowError, ValueError):
        return [_c_log1(x) for x in v]


def _c_div(a, b):
    """C-Division ``a / b`` auch für ``b == 0``."""
    if b != 0.0:
        return a / b
    with np.errstate(all="ignore"):
        return float(np.float64(a) / np.float64(b))


def ms_garch_filter(y, omega, alpha, beta, gamma, P, xi0, h1) -> dict:
    """``.ms_garch_filter``: Hamilton-Filter des MS-GARCH-Modells (``r/src/ms_garch.c``).

    Liefert ``loglik`` sowie die n x K-Matrizen ``h`` (Varianzpfade),
    ``pred`` (xi_{t|t-1}), ``filt`` (xi_{t|t}) und ``lB`` (Log-Normaldichte je
    Regime). ``loglik`` ist ``-Inf``, sobald ein ``f_t`` nicht endlich oder
    <= 0 ist; die Rechnung läuft dennoch weiter.
    """
    yv = _msg_num(y, -1, "y")
    n = yv.size
    if n < 1:
        raise ValueError("ms_garch_filter: 'y' darf nicht leer sein.")
    om = _msg_num(omega, -1, "omega")
    K = om.size
    if K < 1 or K > 1000:
        raise ValueError("ms_garch_filter: 'omega' muss 1 bis 1000 Werte haben (einen je Regime).")
    al = _msg_num(alpha, K, "alpha")
    be = _msg_num(beta, K, "beta")
    ga = _msg_num(gamma, K, "gamma")
    Pv = _msg_num(P, K * K, "P")
    xi = _msg_num(xi0, K, "xi0")
    h1 = float(_msg_num(h1, 1, "h1")[0])
    two_pi = 2.0 * math.pi
    with np.errstate(all="ignore"):
        # Varianzpfade: h[t, k] = (omega_k + a * e2) + beta_k * h[t-1, k], a = alpha_k + gamma_k * ind
        H = np.empty((n, K))
        if n > 1:
            e = yv[:-1]
            e2 = e * e
            ind = np.where(e < 0.0, 1.0, 0.0)
        for k in range(K):
            col = [h1]
            if n > 1:
                a = al[k] + ga[k] * ind
                c = (om[k] + a * e2).tolist()
                b = float(be[k])
                hp = h1
                for ct in c:
                    hp = ct + b * hp
                    col.append(hp)
            H[:, k] = col
        # Dichten und Log-Emissionen: q = (-0.5 * y2) / hk, phi = exp(q) / sqrt(2 pi hk),
        # lB = q - 0.5 * log(2 pi hk)
        y2 = yv * yv
        Q = (-0.5 * y2).reshape(-1, 1) / H
        TH = two_pi * H
        qf = Q.ravel().tolist()
        EX = np.array(_c_exp_list(qf), dtype=np.float64).reshape(n, K)
        PHI = EX / np.sqrt(TH)
        LG = np.array(_c_log_list(TH.ravel().tolist()), dtype=np.float64).reshape(n, K)
        LB = Q - 0.5 * LG
    # Filter: Zähler pred * phi, Summe f, Teilung, Vorhersage t(P) %*% filt
    Pm = [[float(Pv[i + K * j]) for j in range(K)] for i in range(K)]
    rK = range(K)
    phi_rows = PHI.tolist()
    pred_rows = []
    filt_rows = []
    pr = [float(v) for v in xi]
    ll = 0.0
    ok = True
    for t in range(n):
        ph = phi_rows[t]
        pred_rows.append(pr)
        num = [pr[k] * ph[k] for k in rK]
        f = 0.0
        for v in num:
            f = f + v
        if f - f != 0.0 or f <= 0.0:
            ok = False
        else:
            ll = ll + math.log(f)
        if f != 0.0:
            fl = [v / f for v in num]
        else:
            fl = [_c_div(v, f) for v in num]
        filt_rows.append(fl)
        if t + 1 < n:
            nx = []
            for j in rK:
                s = 0.0
                for i in rK:
                    s = s + Pm[i][j] * fl[i]
                nx.append(s)
            pr = nx
    return {"loglik": ll if ok else -math.inf, "h": H,
            "pred": np.array(pred_rows, dtype=np.float64).reshape(n, K),
            "filt": np.array(filt_rows, dtype=np.float64).reshape(n, K), "lB": LB}
