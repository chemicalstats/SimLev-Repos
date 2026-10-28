"""Bootstrap-Kerne (Port von ``r/src/bootstrap_core.cpp``, ``.garch_filter`` und ``r/src/ms_garch_impl.c``).

Jeder Kern liefert wie im Original die 1-basierten Quellzeilen der gezogenen
Beobachtungen; parametrische Verfahren zusätzlich die simulierte
Renditematrix. Zufallszahlen ausschließlich über :mod:`simlev._r.rng`
(``R::runif`` = :func:`runif1`, ``R::rgeom`` = :func:`rgeom1`,
``R::rnorm`` = :func:`rnorm1`), damit ``set_seed`` und L'Ecuyer-Streams wie in
R greifen. Rechenreihenfolge 1:1 aus dem C++-Code.

Gemeinsamer C-Kern (Etappe 7.3b): Mit gebauter Erweiterung rechnen die Bootstrap-Kerne
mit derselben Quelle wie R (``r/src/bootstrap_core_impl.h``, Hülle
``python/src/_ext_bootstrap.cpp``); die Zufallszahlen zieht dort die C-Nachbildung von
R's RNG (``python/src/_rng_r.c``) auf dem Zustand von :mod:`simlev._r.rng`
(:func:`~simlev._r.rng.c_state`), danach ist er derselbe wie nach dem reinen Python-Kern.
Die Prüfungen und ``_state()`` laufen vorher hier wie im reinen Kern; Eingaben außerhalb
des gültigen Bereichs (Indizes außerhalb der Felder, zu kurze Felder, nicht endliches
``L``), andere Zufallsarten oder ``SIMLEV_NO_EXT=1`` rechnet der reine Python-Kern
darunter (bitgleich).
"""
from __future__ import annotations

import math

import numpy as np

from ._r import env as _env
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


# ── Gemeinsamer C-Kern (Etappe 7.3b) ───────────────────────────────────────

_I32 = 2147483647


def _ext_rng(rpois=False):
    """``(ext, Zustand)`` für den gemeinsamen C-Kern oder ``(None, None)`` (reiner Python-Kern).

    Erst nach ``_state()`` rufen; den Zustand nach dem Kern mit :func:`_rng.c_state_put`
    zurückschreiben (siehe :func:`_call`)."""
    ext = _env.ext()
    if ext is None:
        return None, None
    st = _rng.c_state(rpois)
    if st is None:
        return None, None
    return ext, st


def _call(f, st, *args):
    """C-Kern ``f`` mit dem Zustand ``st`` aufrufen und den Zustand danach (auch nach einem
    Fehler) zurückschreiben."""
    try:
        f(*st, *args)
    finally:
        _rng.c_state_put(st)


def _i32(v) -> np.ndarray:
    """Liste ganzer Zahlen als int32-Feld (Aufrufer prüft den Bereich)."""
    return np.array(v, dtype=np.int32) if len(v) else np.zeros(0, dtype=np.int32)


def _fits(v, lo=-_I32, hi=_I32) -> bool:
    """Alle Werte in [lo, hi] (int32-Bereich bzw. gültige Indizes)?"""
    if len(v) == 0:
        return True
    a = np.asarray(v)
    return bool(lo <= a.min() and a.max() <= hi)


def _f64(v, n=None):
    """Zahlen als zusammenhängendes float64-Feld; mit ``n`` nur die ersten ``n`` Werte
    (``None``, wenn es weniger sind)."""
    a = np.ascontiguousarray(np.asarray(v, dtype=np.float64).ravel())
    if n is not None:
        if a.size < n:
            return None
        a = np.ascontiguousarray(a[:n])
    return a


def _fmat(X: np.ndarray) -> np.ndarray:
    """Matrix spaltenweise als flaches float64-Feld (wie R)."""
    return np.ascontiguousarray(np.asarray(X, dtype=np.float64).ravel(order="F"))


def _from_f(flat: np.ndarray, n: int, k: int) -> np.ndarray:
    """Flaches Feld (spaltenweise) als n x k-Matrix in C-Reihenfolge."""
    return np.ascontiguousarray(flat.reshape((k, n)).T)


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
    ext, st = _ext_rng() if _fits((n_src, n_out), 0) else (None, None)
    if ext is not None:
        out = np.empty(n_out, dtype=np.int32)
        _call(ext.boot_idx_iid, st, n_src, n_out, out)
        return out.astype(np.int64)
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
    ext, st = _ext_rng() if _fits((n_src, n_out), 0) else (None, None)
    if ext is not None:
        out = np.empty(n_out, dtype=np.int32)
        _call(ext.boot_idx_block, st, n_src, n_out, block_length, bool(circular), out)
        return out.astype(np.int64)
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
    # L <= 1e7: Blocklängen aus rgeom bleiben im int-Bereich der C-Rechnung (rgeom(0) = NaN
    # bei L = Inf bricht im reinen Kern ab)
    ext, st = _ext_rng(rpois=True) if L <= 1e7 and _fits((n_src, n_out), 0) else (None, None)
    if ext is not None:
        out = np.empty(n_out, dtype=np.int32)
        _call(ext.boot_idx_stationary, st, n_src, n_out, L, out)
        return out.astype(np.int64)
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
            nw[j] = _c_div(nw[j], s)            # s = 0 (Zeilen ohne Masse): Inf/NaN wie C
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
    ext, st = (_ext_rng() if K >= 1 and T.shape[1] >= K and _fits(reg) and _fits((n, n_out), 0)
               else (None, None))
    if ext is not None:
        out = np.empty(n_out, dtype=np.int32)
        _call(ext.boot_idx_regime, st, _i32(reg), _fmat(T[:, :K]), K, n_out, out)
        return out.astype(np.int64)
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
    ext, st = _ext_rng() if _fits(b) and _fits(lf) and _fits(rt) and _fits((n_out,), 0) else (None, None)
    if ext is not None:
        out = np.empty(n_out, dtype=np.int32)
        _call(ext.boot_idx_tails, st, n_out, float(p_l), float(p_r), _i32(b), _i32(lf), _i32(rt), out)
        return out.astype(np.int64)
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
            x = float(X[i, j])
            t = s + x
            s = t if t == t else _n_add(s, x)    # NaN: s + x wie im R-Bau (siehe _n_add)
        mu[j] = s / n if n else math.nan        # n = 0: in C 0/0 (ohne Folgen, keine Zeilen)
    s5 = math.sqrt(5.0)
    mp = (s5 + 1.0) / (2.0 * s5)
    mneg = -(s5 - 1.0) / 2.0
    mpos = (s5 + 1.0) / 2.0
    _state()
    ext, st = _ext_rng()
    if ext is not None:
        out = np.empty(n * k)
        _call(ext.boot_wild, st, _fmat(X), n, k, type, out)
        return _from_f(out, n, k)
    w = np.empty(n)
    for i in range(n):
        if type == 0:
            w[i] = -1.0 if _rng.runif1(0, 1) < 0.5 else 1.0
        elif type == 1:
            w[i] = mneg if _rng.runif1(0, 1) < mp else mpos
        else:
            w[i] = _rng.rnorm1(0.0, 1.0)
    # R-Bau: ((x - mu) * w) + mu, bei zwei NaN behält er das von (x - mu) * w
    P = (X - mu[None, :]) * w[:, None]
    return np.where(np.isnan(P), P, P + mu[None, :])


def boot_reset(returns, p_break: float) -> np.ndarray:
    """``.boot_reset``: Segmente mit Wahrscheinlichkeit ``p_break`` spiegeln."""
    if not (p_break >= 0.0 and p_break <= 1.0):
        raise ValueError("p_break muss in [0, 1] liegen")
    X = _as_mat(returns)
    n, k = X.shape
    _state()
    ext, st = _ext_rng()
    if ext is not None:
        out = np.empty(n * k)
        _call(ext.boot_reset, st, _fmat(X), n, k, float(p_break), out)
        return _from_f(out, n, k)
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
    try:
        pw = math.pow(u, -shape)
    except OverflowError:                       # C: pow liefert Inf
        pw = math.inf
    return scale * (pw - 1.0) / shape


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
    nrow = X.shape[0]
    ext, st = (_ext_rng() if 0 <= base < k and _fits(pl, 1, nrow) and _fits(pr, 1, nrow) and _fits(b, 1, nrow)
               else (None, None))
    if ext is not None:
        ret = np.empty(n_out * k)
        ix = np.empty(n_out, dtype=np.int32)
        _call(ext.boot_evt, st, _fmat(X), nrow, k, base, n_out, float(p_l), float(thresh_l), float(scale_l),
              float(shape_l), _i32(pl), float(p_r), float(thresh_r), float(scale_r), float(shape_r), _i32(pr),
              _i32(b), ret, ix)
        return {"ret": _from_f(ret, n_out, k), "idx": ix.astype(np.int64)}
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
                out[t, c] = rb if c == base else _c_div(rb * float(X[j, c]), float(X[j, base]))
            idx[t] = j + 1
        else:
            j = b[_draw_int(nb)] - 1
            out[t, :] = X[j, :]
            idx[t] = j + 1
    return {"ret": out, "idx": idx}


def _cross_ok(cs, k, zc, nzb) -> bool:
    """Nebenreihen für den C-Kern gültig: Spalten in [0, k), Felder lang genug, z_cross mit
    mindestens so vielen Spalten wie Nebenreihen."""
    m = cs.m
    if m == 0:
        return True
    return (_fits(cs.col, 0, k - 1) and min(len(cs.mu), len(cs.om), len(cs.al), len(cs.be), len(cs.ratio),
                                           len(cs.s2)) >= m and zc.ndim == 2 and zc.shape[1] >= m)


def _cross_args(cs, zc):
    """Argumente der Nebenreihen für den C-Kern: cross_cols, cmu, com, cal, cbe, cratio, cs2,
    z_cross (spaltenweise, die ersten m Spalten), Zeilenzahl von z_cross."""
    m = cs.m
    zr = zc.shape[0] if (m and zc.ndim == 2) else 0
    zf = _fmat(zc[:, :m]) if m else np.zeros(0)
    return (_i32(cs.col), _f64(cs.mu[:m]), _f64(cs.om[:m]), _f64(cs.al[:m]), _f64(cs.be[:m]),
            _i32([1 if x else 0 for x in cs.ratio[:m]]), _f64(cs.s2[:m]), zf, zr)


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
        # NaN: Operandenfolge des R-Baus (step_cross): ((al * eps) * eps + om) + be * s2,
        # sqrt(s2) * z, (mu + 1.0) + e, g * base_ret
        for c in range(self.m):
            ep = self.eps[c]
            s2 = self.om[c] + self.al[c] * ep * ep + self.be[c] * self.s2[c]
            if s2 != s2:
                s2 = _n_add(_n_add(_n_mul(_n_mul(self.al[c], ep), ep), self.om[c]), _n_mul(self.be[c], self.s2[c]))
            if s2 < 1e-14:
                s2 = 1e-14
            self.s2[c] = s2
            z = float(z_cross[tstar, c])
            e = math.sqrt(s2) * z
            if e != e:
                e = _n_mul(math.sqrt(s2), z)
            self.eps[c] = e
            g = 1.0 + self.mu[c] + e
            if g != g:
                g = _n_add(_n_add(self.mu[c], 1.0), e)
            if self.ratio[c]:
                g2 = base_ret * g
                out[t, self.col[c]] = g2 if g2 == g2 else _n_mul(g, base_ret)
            else:
                out[t, self.col[c]] = g


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
    ext, st = (_ext_rng() if _cross_ok(cs, int(k), zc, len(zb)) and 0 <= base < int(k) and _fits(v, 1, len(zb))
               and (cs.m == 0 or _fits(v, 1, zc.shape[0])) else (None, None))
    if ext is not None:
        kk = int(k)
        ret = np.empty(n_out * kk)
        ix = np.empty(n_out, dtype=np.int32)
        _call(ext.boot_garch, st, n_out, base, kk, float(mu), float(omega), float(alpha), float(beta), float(gamma),
              s2, _f64(zb), _i32(v), *_cross_args(cs, zc), ret, ix)
        return {"ret": _from_f(ret, n_out, kk), "idx": ix.astype(np.int64)}
    # NaN: Operandenfolge des R-Baus (C_boot_garch): (gamma * ind + alpha) * eps * eps + omega
    # + s2 * beta, sqrt(s2) * z, (1.0 + mu) + eps
    for t in range(n_out):
        ind = 1.0 if eps < 0.0 else 0.0
        s2n = omega + (alpha + gamma * ind) * eps * eps + beta * s2
        if s2n != s2n:
            s2n = _n_add(_n_add(_n_mul(_n_mul(_n_add(gamma * ind, alpha), eps), eps), omega), _n_mul(s2, beta))
        s2 = s2n
        if s2 < 1e-14:
            s2 = 1e-14
        ts = v[_draw_int(nv)] - 1
        eps = math.sqrt(s2) * zb[ts]
        if eps != eps:
            eps = _n_mul(math.sqrt(s2), zb[ts])
        rb = 1.0 + mu + eps
        if rb != rb:
            rb = _n_add(1.0 + mu, eps)
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
    kk = int(k)
    ext, st = (_ext_rng() if (K >= 1 and _cross_ok(cs, kk, zc, len(zb)) and 0 <= base < kk and len(pl) >= K
                              and all(len(a) >= K for a in (mu, omega, alpha, beta, gamma, phi, lam, uv, sp))
                              and min(T.shape) >= K and min(D.shape) >= K and any(pl[q] for q in range(K))
                              and all(_fits(pl[q], 0, len(zb) - 1) and (cs.m == 0 or _fits(pl[q], 0, zc.shape[0] - 1))
                                      for q in range(K)))
               else (None, None))
    if ext is not None:
        ret = np.empty(n_out * kk)
        ix = np.empty(n_out, dtype=np.int32)
        rg = np.empty(n_out, dtype=np.int32)
        _call(ext.boot_ms_garch, st, n_out, base, kk, K, *(_f64(a, K) for a in (mu, omega, alpha, beta, gamma, phi, lam)),
              _fmat(T[:K, :K]), _fmat(D[:K, :K]), _f64(uv, K), _f64(sp, K), [_i32([x + 1 for x in pl[q]]) for q in range(K)],
              _f64(zb), *_cross_args(cs, zc), ret, ix, rg)
        return {"ret": _from_f(ret, n_out, kk), "idx": ix.astype(np.int64), "regime": rg.astype(np.int64)}
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
                s2n = 0.5 * s2 + 0.5 * uv[r]
                s2 = s2n if s2n == s2n else _n_add(0.5 * uv[r], 0.5 * s2)
        # NaN: Operandenfolge des R-Baus (C_boot_ms_garch): (ind * gamma + alpha) * eps * eps
        # + omega + s2 * beta, z * sig, ((prev * phi) + mu) + sig * lambda, m + eps, ex + 1.0
        ind = 1.0 if eps < 0.0 else 0.0
        s2n = omega[r] + (alpha[r] + gamma[r] * ind) * eps * eps + beta[r] * s2
        if s2n != s2n:
            s2n = _n_add(_n_add(_n_mul(_n_mul(_n_add(_n_mul(ind, gamma[r]), alpha[r]), eps), eps), omega[r]),
                         _n_mul(s2, beta[r]))
        s2 = s2n
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
        if eps != eps:
            eps = _n_mul(zb[ts], sig)
        m = mu[r] + phi[r] * prev + lam[r] * sig
        if m != m:
            m = _n_add(_n_add(_n_mul(prev, phi[r]), mu[r]), _n_mul(sig, lam[r]))
        ex = m + eps
        if ex != ex:
            ex = _n_add(m, eps)
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
    ext = _env.ext()
    if ext is not None and window <= _I32:
        vol = np.empty(n)
        ext.rolling_vol(np.array(xs, dtype=np.float64), window, vol)
        return vol
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
    ext = _env.ext()
    if ext is not None:
        out = np.empty(v.size, dtype=np.int32)
        ext.assign_regimes(np.ascontiguousarray(v), np.array(th, dtype=np.float64), out)
        return out.astype(np.int64)
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
    ext = _env.ext()
    if ext is not None and 0 <= K <= 46340 and _fits(reg):
        out = np.empty(K * K)
        ext.estimate_trans_mat(_i32(reg), K, float(alpha), out)
        return _from_f(out, K, K)
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
    """``.garch_filter``: bedingte Varianzen eines GARCH(1,1)/GJR-Modells (mit gebauter
    Erweiterung der gemeinsame Kern ``r/src/research_core_impl.cpp``)."""
    ext = _env.ext()
    if ext is not None:
        ea = np.ascontiguousarray(np.asarray(ep, dtype=np.float64).ravel())
        s2 = np.empty(ea.size)
        ext.garch_filter(ea, float(om), float(al), float(be), float(ga), float(v0), s2)
        return s2
    e = [float(x) for x in np.asarray(ep, dtype=np.float64).ravel()]
    n = len(e)
    s2 = np.empty(n)
    v = float(v0)
    for t in range(n):
        s2[t] = v
        gi = ga * (1.0 if e[t] < 0.0 else 0.0)
        e2 = e[t] * e[t]
        vn = om + (al + gi) * e2 + be * v
        if vn != vn:
            # NaN: Operandenfolge des R-Baus (C_garch_filter): ((ga * ind + al) * e^2 + om) + v * be
            vn = _n_add(_n_add(_n_mul(_n_add(gi, al), e2), om), _n_mul(v, be))
        v = vn
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

# Gemeinsamer C-Kern (Etappe 7.2): simlev._ext rechnet mit derselben Quelle wie R
# (r/src/ms_garch_impl.c, Kopie in python/src/). Ist die Erweiterung nicht gebaut
# oder SIMLEV_NO_EXT=1 gesetzt, rechnet der Python-Port darunter (bitgleich).


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


# ── NaN-genauer Weg (Etappe 7.3a) ───────────────────────────────────────────
#
# Treffen in einer Operation zwei NaN aufeinander (etwa NA in y auf einen
# schon ungültigen Filterzustand), behält x86-64/SSE die Nutzlast des ersten
# Operanden der Maschinenanweisung (``addsd src, dst``: dst). Welcher Operand
# das ist, legt der C-Compiler fest, bei kommutativen Operationen auch
# entgegen der Quelltextfolge; CPython und numpy wählen wieder anders (Python:
# ``a + b`` behält b, ``a * b`` behält a; numpy behält beim Rechnen mit einem
# Skalar ab 17 Elementen den Skalar). Ungültige Operationen (0/0, Inf - Inf,
# log oder sqrt einer negativen Zahl) liefern in C das Standard-NaN von x86
# (Vorzeichen gesetzt, 0xFFF8000000000000), Python ``math.nan`` ist +NaN.
# Der schnelle Weg oben ist ohne NaN exakt. Enthält ein Ergebnis NaN, rechnet
# _ms_garch_filter_nan den Filter noch einmal Schritt für Schritt und wählt bei
# zwei NaN-Operanden den Operanden, den der R-Bau (gcc -O2, x86-64) behält;
# die Operandenfolge je Anweisung ist aus dem Maschinencode von
# simlev_ms_garch_filter abgelesen (objdump) und steht unten bei jeder Zeile.

_QUIET = 0x0008000000000000
_X86_NAN = float(np.uint64(0xFFF8000000000000).view(np.float64))   # Standard-NaN (0/0) auf x86-64


def _quiet(x: float) -> float:
    """``x`` als stilles NaN (wie jede Gleitkomma-Operation es zurückgibt)."""
    return float(np.uint64(int(np.float64(x).view(np.uint64)) | _QUIET).view(np.float64))


def _nn(r: float, a: float, b: float) -> float:
    """Ergebnis ``r`` der Operation mit dem bevorzugten Operanden ``a`` und ``b``:
    sind beide NaN, gilt wie in der SSE-Anweisung des R-Baus ``a``."""
    if a != a and b != b:
        return _quiet(a)
    return r


def _n_add(a, b):
    return _nn(a + b, a, b)


def _n_mul(a, b):
    return _nn(a * b, a, b)


def _n_sub(a, b):
    return _nn(a - b, a, b)


def _n_div(a, b):
    if b == 0.0 or b != b or a != a:
        with np.errstate(all="ignore"):
            r = float(np.float64(a) / np.float64(b))
        return _nn(r, a, b)
    return a / b


def _n_exp(x):
    if x != x:
        return _quiet(x)
    try:
        return math.exp(x)
    except OverflowError:
        return math.inf


def _n_log(x):
    """glibc ``log``: log(NaN) = NaN (still), log(<0) und log(-Inf) = Standard-NaN von x86."""
    if x > 0.0:
        return math.log(x)
    if x == 0.0:
        return -math.inf
    if x != x:
        return _quiet(x)
    return _X86_NAN


def _n_sqrt(x):
    """``sqrtsd`` bzw. glibc ``sqrt``: sqrt(NaN) = NaN (still), sqrt(<0) = Standard-NaN von x86."""
    if x >= 0.0:
        return math.sqrt(x)
    if x != x:
        return _quiet(x)
    return _X86_NAN


def _ms_garch_filter_nan(yv, om, al, be, ga, Pv, xi, h1, n, K) -> dict:
    """:func:`ms_garch_filter` Schritt für Schritt mit der NaN-Wahl des R-Baus (siehe oben)."""
    y = [float(v) for v in yv]
    om, al, be, ga = ([float(v) for v in a] for a in (om, al, be, ga))
    Pv = [float(v) for v in Pv]
    two_pi = 2.0 * math.pi
    H = np.empty((n, K))
    PR = np.empty((n, K))
    FI = np.empty((n, K))
    LBm = np.empty((n, K))
    hp = [h1] * K
    pr = [float(v) for v in xi]
    ll = 0.0
    ok = True
    for t in range(n):
        if t > 0:
            e = y[t - 1]
            e2 = e * e
            ind = 1.0 if e < 0.0 else 0.0
            for k in range(K):
                a = _n_add(ga[k] * ind, al[k])              # alpha + gamma * ind: gamma * ind bleibt
                c = _n_add(_n_mul(a, e2), om[k])            # omega + a * e2: a * e2 bleibt
                hp[k] = _n_add(c, _n_mul(be[k], hp[k]))     # ... + beta * h[t-1]: linker Teil, beta bleibt
        y2 = y[t] * y[t]
        f = 0.0
        num = [0.0] * K
        for k in range(K):
            hk = hp[k]
            H[t, k] = hk
            q = _n_div(y2 * -0.5, hk)                       # (-0.5 * y2) / hk: Zähler bleibt
            th = hk * two_pi
            phi = _n_div(_n_exp(q), _n_sqrt(th))            # exp(q) / sqrt(2 pi hk): exp(q) bleibt
            LBm[t, k] = _n_sub(q, 0.5 * _n_log(th))         # q - 0.5 * log(2 pi hk): q bleibt
            v = _n_mul(phi, pr[k])                          # pred * phi: phi bleibt
            num[k] = v
            f = _n_add(v, f)                                # f + filt: filt bleibt
            PR[t, k] = pr[k]
        if not (f - f == 0.0) or f <= 0.0:
            ok = False
        else:
            ll = ll + math.log(f)
        fl = [_n_div(v, f) for v in num]                    # filt / f: filt bleibt
        FI[t] = fl
        if t + 1 < n:
            nx = []
            for j in range(K):
                s = 0.0
                for i in range(K):
                    s = _n_add(s, _n_mul(Pv[i + K * j], fl[i]))   # s + P * filt: s bleibt, P bleibt
                nx.append(s)
            pr = nx
    return {"loglik": ll if ok else -math.inf, "h": H, "pred": PR, "filt": FI, "lB": LBm}


def _has_nan(res) -> bool:
    return any(np.isnan(res[k]).any() for k in ("h", "pred", "filt", "lB"))


def _ms_garch_filter2(PHI, Pv, xi, H, LB, n) -> dict:
    """Filterschleife von :func:`ms_garch_filter` für K = 2 (Etappe 7.1).

    Dieselbe Rechnung wie die allgemeine Schleife, nur mit lokalen Variablen
    statt Listen je Schritt: f = (0.0 + num0) + num1, filt = num / f,
    pred[t+1, j] = (0.0 + P[0, j] * filt0) + P[1, j] * filt1.
    """
    p00, p10, p01, p11 = (float(v) for v in Pv)      # spaltenweise: P[0,0], P[1,0], P[0,1], P[1,1]
    ph0 = PHI[:, 0].tolist()
    ph1 = PHI[:, 1].tolist()
    pr0 = float(xi[0])
    pr1 = float(xi[1])
    pred0 = [0.0] * n
    pred1 = [0.0] * n
    filt0 = [0.0] * n
    filt1 = [0.0] * n
    log = math.log
    ll = 0.0
    ok = True
    last = n - 1
    for t in range(n):
        pred0[t] = pr0
        pred1[t] = pr1
        n0 = pr0 * ph0[t]
        n1 = pr1 * ph1[t]
        f = 0.0 + n0
        f = f + n1
        if f - f != 0.0 or f <= 0.0:
            ok = False
        else:
            ll = ll + log(f)
        if f != 0.0:
            fl0 = n0 / f
            fl1 = n1 / f
        else:
            fl0 = _c_div(n0, f)
            fl1 = _c_div(n1, f)
        filt0[t] = fl0
        filt1[t] = fl1
        if t < last:
            q = 0.0 + p00 * fl0
            pr0 = q + p10 * fl1
            q = 0.0 + p01 * fl0
            pr1 = q + p11 * fl1
    pred = np.empty((n, 2))
    pred[:, 0] = pred0
    pred[:, 1] = pred1
    filt = np.empty((n, 2))
    filt[:, 0] = filt0
    filt[:, 1] = filt1
    return {"loglik": ll if ok else -math.inf, "h": H, "pred": pred, "filt": filt, "lB": LB}


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
    ext = _env.ext()
    if ext is not None:
        # C-Kern: Ergebnisse spaltenweise n x K, d. h. in numpy (K, n); zurück als
        # n x K-Arrays in C-Reihenfolge wie im Python-Port
        out = [np.empty((K, n)) for _ in range(4)]
        ll = ext.ms_garch_filter(yv, om, al, be, ga, Pv, xi, h1, *out)
        H, PR, FI, LBm = (np.ascontiguousarray(a.T) for a in out)
        return {"loglik": ll, "h": H, "pred": PR, "filt": FI, "lB": LBm}
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
                ap = col.append
                for ct in c:
                    hp = ct + b * hp
                    ap(hp)
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
    if K == 2:
        res = _ms_garch_filter2(PHI, Pv, xi, H, LB, n)
    else:
        res = _ms_garch_filter_k(PHI, Pv, xi, H, LB, n, K)
    if _has_nan(res):
        # NaN im Ergebnis: Nutzlast und Vorzeichen wie im R-Bau (siehe _ms_garch_filter_nan)
        return _ms_garch_filter_nan(yv, om, al, be, ga, Pv, xi, h1, n, K)
    return res


def _ms_garch_filter_k(PHI, Pv, xi, H, LB, n, K) -> dict:
    """Filterschleife von :func:`ms_garch_filter` für beliebiges K."""
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
