"""Hüllen der Modelle der C-Bibliothek slc (SimLev core, Etappe 9.4): GARCH/GJR(1,1), GPD,
DCC(1,1), MS-GARCH und univariates HMM, Bootstrap-Kerne.

Gegenstück zu ``r/R/slc_models.R`` (R) und ``julia/src/slib_models.jl`` (Julia). Die Rechnung
steht in ``src/core/slc_{garch,gpd,dcc,msgarch,boot}.c`` (Kopien von ``core/``), die Hülle in
``src/_ext_slc_models.c`` (Modul ``simlev._ext``). Fehlertexte und Warnungen kommen aus dem Kern
(Fehler: ``ValueError``; Warnung: ``warnings.warn``). Erreichbar über ``simlev._lib``.

Seit Etappe 9.6a/b rufen die Ports diese Hüllen an denselben Stellen wie R. Die Hüllen liefern
dieselben Strukturen wie die bisherigen Wege (``fit_garch11`` wie ``_fit_garch11``,
``ms_garch_fit`` wie ``_ms_garch_fit``, ``boot_*`` wie die bis 9.6c vorhandenen Kerne in ``_bootstrap_core``), gezogen
wird aus einem :class:`simlev._lib.Stream` bzw. dem globalen Zustand (Entwurf C.5).
"""
from __future__ import annotations

import math
import warnings

import numpy as np

from . import _ext

__all__ = ["garch11_filter", "garch11_nll", "garch11_fit", "fit_garch11", "gpd_nll", "gpd_pwm", "gpd_fit",
           "dcc_filter", "dcc_fit", "ms_garch_filter", "ms_garch_nll", "ms_garch_grad", "ms_garch_starts", "ms_garch_fitstarts",
           "ms_garch_fit", "hmm_em_univ", "hmm_viterbi", "boot_idx_iid", "boot_idx_block", "boot_idx_stationary",
           "boot_idx_regime", "boot_idx_tails", "boot_wild", "boot_reset", "boot_evt", "boot_garch",
           "boot_ms_garch", "rolling_vol", "assign_regimes", "estimate_trans_mat"]

_GARCH_METHODS = ("konstant", "ml", "momente")


def _arr(x):
    if hasattr(x, "to_numpy"):
        x = x.to_numpy()
    return np.asarray(x, dtype=np.float64)


def _vec(x):
    return np.ascontiguousarray(_arr(x).reshape(-1))


def _ivec(x):
    if hasattr(x, "to_numpy"):
        x = x.to_numpy()
    return np.ascontiguousarray(np.asarray(x).reshape(-1).astype(np.int32))


def _fmat(x):
    """(Puffer spaltenweise, Zeilen, Spalten); 1-D als Spaltenvektor."""
    a = _arr(x)
    if a.ndim == 0:
        a = a.reshape(1, 1)
    elif a.ndim == 1:
        a = a.reshape(-1, 1)
    elif a.ndim != 2:
        raise ValueError("interner Fehler: Matrix erwartet")
    return np.ascontiguousarray(a.ravel(order="F")), a.shape[0], a.shape[1]


def _mat(buf, m, n):
    return buf.reshape((m, n), order="F")


# ── GARCH(1,1) / GJR-GARCH(1,1) ──────────────────────────────────────────────

def garch11_filter(eps, omega, alpha, beta, gamma, s2_init):
    """Filter wie der frühere ``.garch_filter``: s2[0] = s2_init, Untergrenze 1e-14."""
    e = _vec(eps)
    out = np.empty(e.size)
    _ext.slc_garch11_filter(e, out, float(omega), float(alpha), float(beta), float(gamma), float(s2_init))
    return out


def garch11_nll(e, par, gjr=False, s2_init=None):
    """NLL an par = (mu, omega, alpha, beta[, gamma]); s2_init None: Stichprobenvarianz."""
    p = np.zeros(5)
    pv = _vec(par)
    p[:min(5, pv.size)] = pv[:5]
    return _ext.slc_garch11_nll(_vec(e), p, bool(gjr), math.nan if s2_init is None else float(s2_init))


def garch11_fit(e, gjr=False):
    """ML-Punktschätzer; dict(mu, omega, alpha, beta, gamma, loglik, convergence, method)."""
    p = np.empty(5)
    ll, code = _ext.slc_garch11_fit(_vec(e), bool(gjr), p)
    return {"mu": float(p[0]), "omega": float(p[1]), "alpha": float(p[2]), "beta": float(p[3]), "gamma": float(p[4]),
            "loglik": ll, "convergence": code, "method": "ml"}


def fit_garch11(e, gjr=False, quiet=False):
    """GARCH(1,1) / GJR-GARCH(1,1) wie ``_fit_garch11`` (ML -> Momente, F10)."""
    ev = _vec(e)
    p, s2, z = np.empty(5), np.empty(ev.size), np.empty(ev.size)
    ll, code, meth, s2i, pers = _ext.slc_garch11_estimate(ev, bool(gjr), p, s2, z)
    method = _GARCH_METHODS[meth]
    if method == "konstant":
        return {"mu": float(p[0]), "omega": float(p[1]), "alpha": 0.0, "beta": 0.0, "gamma": 0.0, "s2": s2, "z": z,
                "method": "konstant", "s2_init": s2i}
    if method == "momente" and not quiet:
        warnings.warn("GARCH: ML-Schätzung fehlgeschlagen, verwende Moment-Schätzer", UserWarning, stacklevel=2)
    return {"mu": float(p[0]), "omega": float(p[1]), "alpha": float(p[2]), "beta": float(p[3]), "gamma": float(p[4]),
            "s2": s2, "z": z, "method": method, "persistence": pers, "s2_init": s2i}


# ── Verallgemeinerte Pareto-Verteilung ───────────────────────────────────────

def gpd_nll(x, scale, shape):
    return _ext.slc_gpd_nll(_vec(x), float(scale), float(shape))


def gpd_pwm(x):
    sc, sh = _ext.slc_gpd_pwm(_vec(x))
    return {"scale": sc, "shape": sh}


def gpd_fit(x):
    """ML der Überschreitungen (>= 0); dict(scale, shape, loglik, convergence)."""
    sc, sh, ll, code = _ext.slc_gpd_fit(_vec(x))
    return {"scale": sc, "shape": sh, "loglik": ll, "convergence": code}


# ── DCC(1,1) ─────────────────────────────────────────────────────────────────

def dcc_filter(Z, a, b, Qbar, keep):
    """wie ``dcc_filter``: dict(nll, R, ok)."""
    z, n, k = _fmat(Z)
    q, qr, qc = _fmat(Qbar)
    if qr != k or qc != k:
        raise ValueError("interner Fehler: Qbar muss k x k sein")
    np_ = k * (k - 1) // 2
    R = np.empty(n * np_) if keep else None
    nll, ok = _ext.slc_dcc_filter(z, n, k, float(a), float(b), q, bool(keep), R)
    Rm = _mat(R, n, np_) if keep else np.empty((0, 0))
    return {"nll": nll, "R": Rm, "ok": ok}


def dcc_fit(Z, Qbar):
    """Schätzung von (a, b) ganz in C; dict(a, b, nll, convergence, par)."""
    z, n, k = _fmat(Z)
    q, qr, qc = _fmat(Qbar)
    if qr != k or qc != k:
        raise ValueError("interner Fehler: Qbar muss k x k sein")
    a, b, nll, code, t1, t2 = _ext.slc_dcc_fit(z, n, k, q)
    return {"a": a, "b": b, "nll": nll, "convergence": code, "par": np.array([t1, t2])}


# ── MS-GARCH und HMM ─────────────────────────────────────────────────────────

def _gjr(model):
    if model not in ("sGARCH", "gjrGARCH"):
        raise ValueError('interner Fehler: model muss "sGARCH" oder "gjrGARCH" sein')
    return model == "gjrGARCH"


def _h1(h1):
    return math.nan if h1 is None else float(h1)


def ms_garch_filter(y, omega, alpha, beta, gamma, P, xi0, h1):
    """wie ``ms_garch_filter``: dict(loglik, h, pred, filt, lB)."""
    yv = _vec(y)
    om = _vec(omega)
    K = om.size
    if K < 1 or K > 1000:
        raise ValueError("ms_garch_filter: 'omega' muss 1 bis 1000 Werte haben (einen je Regime).")
    Pm, pr, pc = _fmat(P)
    n = yv.size
    h, pd, fl, lb = (np.empty(n * K) for _ in range(4))
    ll = _ext.slc_ms_garch_filter(yv, K, om, _vec(alpha), _vec(beta), _vec(gamma), Pm, _vec(xi0), float(h1),
                                  h, pd, fl, lb)
    return {"loglik": ll, "h": _mat(h, n, K), "pred": _mat(pd, n, K), "filt": _mat(fl, n, K), "lB": _mat(lb, n, K)}


def ms_garch_nll(theta, y, K, model, h1=None):
    return _ext.slc_ms_garch_nll(_vec(y), _vec(theta), int(K), _gjr(model), _h1(h1))


def ms_garch_grad(theta, y, K, model, h1=None):
    """N1: NLL und analytischer Gradient an ``theta`` (vorwärts mitdifferenzierter Hamilton-Filter);
    ``{"value", "gradient"}``, nicht endliche Likelihood: value = inf, gradient = nan."""
    g = _gjr(model)
    out = np.empty(_ext.slc_ms_garch_npar(int(K), g))
    v = _ext.slc_ms_garch_grad(_vec(y), _vec(theta), int(K), g, _h1(h1), out)
    return {"value": v, "gradient": out}


def ms_garch_starts(y, K, model, h1=None, all=False):  # noqa: A002 (Name wie in R)
    """Startpunkte wie ``_ms_garch_fit`` (Spalten: HMM-Start, falls gelungen, dann Rang-Start); ``all``:
    danach die übrigen Rasterpunkte beider Familien (so rechnet :func:`ms_garch_fit`)."""
    g = _gjr(model)
    K = int(K)
    if not 2 <= K <= 64:
        raise ValueError("MS-GARCH: Anzahl Regime muss zwischen 2 und 64 liegen (erhalten: %d)" % K)
    npar = _ext.slc_ms_garch_npar(K, g)
    out = np.empty(_ext.slc_ms_garch_maxstart() * npar)
    ns = _ext.slc_ms_garch_starts(_vec(y), K, g, _h1(h1), bool(all), out)
    return _mat(out[:npar * ns].copy(), npar, ns)


def ms_garch_fitstarts(y, K, model, starts, h1=None):
    g = _gjr(model)
    s, r, c = _fmat(starts)
    th = np.empty(_ext.slc_ms_garch_npar(int(K), g))
    v, code = _ext.slc_ms_garch_fitstarts(_vec(y), int(K), g, s, c, _h1(h1), th)
    return {"par": th, "value": v, "convergence": code}


def ms_garch_fit(y, K, model):
    """MS-GARCH-Modell wie ``_ms_garch_fit``, ganz in C (Starts, BFGS, Sortierung, Viterbi); BFGS läuft von
    allen Rasterpunkten der beiden Startfamilien (die zwei bisherigen zuerst; sGARCH 12, gjrGARCH seit N1
    20), seit N1 mit analytischem Gradienten."""
    from .ms_garch import _ms_garch_check
    _ms_garch_check(K, model)
    K = int(K)
    yv = _vec(y)
    n = yv.size
    om, al, be, ga = (np.empty(K) for _ in range(4))
    P, reg, s2 = np.empty(K * K), np.empty(n, dtype=np.int32), np.empty(n)
    ll, code = _ext.slc_ms_garch_estimate(yv, K, model == "gjrGARCH", om, al, be, ga, P, reg, s2)
    return {"omega": om, "alpha": al, "beta": be, "gamma": ga, "P": _mat(P, K, K), "regimes": reg, "s2": s2,
            "loglik": ll, "convergence": code}


def hmm_em_univ(x, K, win=21, max_iter=300, tol=1e-7):
    K = int(K)
    if not 2 <= K <= 64:
        raise ValueError("HMM: Anzahl Zustände muss zwischen 2 und 64 liegen (erhalten: %d)" % K)
    mu, S, A = np.empty(K), np.empty(K), np.empty(K * K)
    ll, it = _ext.slc_hmm_em_univ(_vec(x), K, int(win), int(max_iter), float(tol), mu, S, A)
    return {"mu": mu, "S": S, "A": _mat(A, K, K), "ll": ll, "iter": it}


def hmm_viterbi(lB, lA, lp0):
    b, n, K = _fmat(lB)
    a, ar, ac = _fmat(lA)
    if ar != K or ac != K:
        raise ValueError("interner Fehler: lA muss K x K sein")
    out = np.empty(n, dtype=np.int32)
    _ext.slc_hmm_viterbi(b, n, K, a, _vec(lp0), out)
    return out


# ── Bootstrap-Kerne (Zufall aus stream bzw. dem globalen Zustand) ────────────

def _run(stream, fn, *args):
    from . import _lib as L
    if stream is None:
        L._global_check()
        with L._LOCK:
            fn(L._G, *args)
    else:
        fn(stream.state, *args)


def _n(v):
    v = int(v)
    if v < 0:
        raise ValueError("n_out muss >= 0 sein")
    return v


def boot_idx_iid(n_src, n_out, stream=None):
    out = np.empty(_n(n_out), dtype=np.int32)
    _run(stream, _ext.slc_boot_idx_iid, out, int(n_src))
    return out


def boot_idx_block(n_src, n_out, block_length, circular, stream=None):
    out = np.empty(_n(n_out), dtype=np.int32)
    _run(stream, _ext.slc_boot_idx_block, out, int(n_src), int(block_length), bool(circular))
    return out


def boot_idx_stationary(n_src, n_out, L, stream=None):
    out = np.empty(_n(n_out), dtype=np.int32)
    _run(stream, _ext.slc_boot_idx_stationary, out, int(n_src), float(L))
    return out


def boot_idx_regime(regimes, trans, n_out, stream=None):
    t, K, kc = _fmat(trans)
    if kc != K:
        raise ValueError("interner Fehler: trans muss quadratisch sein")
    out = np.empty(_n(n_out), dtype=np.int32)
    _run(stream, _ext.slc_boot_idx_regime, out, _ivec(regimes), K, t)
    return out


def boot_idx_tails(n_out, p_l, p_r, bulk_idx, left_idx, right_idx, stream=None):
    out = np.empty(_n(n_out), dtype=np.int32)
    _run(stream, _ext.slc_boot_idx_tails, out, float(p_l), float(p_r), _ivec(bulk_idx), _ivec(left_idx),
         _ivec(right_idx))
    return out


def boot_wild(returns, type, stream=None):  # noqa: A002 (Name wie in R)
    x, n, k = _fmat(returns)
    out = np.empty(n * k)
    _run(stream, _ext.slc_boot_wild, x, n, k, int(type), out)
    return _mat(out, n, k)


def boot_reset(returns, p_break, stream=None):
    x, n, k = _fmat(returns)
    out = np.empty(n * k)
    _run(stream, _ext.slc_boot_reset, x, n, k, float(p_break), out)
    return _mat(out, n, k)


def boot_evt(returns, base, n_out, p_l, thresh_l, scale_l, shape_l, pool_l,
             p_r, thresh_r, scale_r, shape_r, pool_r, bulk_idx, stream=None):
    x, n, k = _fmat(returns)
    no = _n(n_out)
    out, idx = np.empty(no * k), np.empty(no, dtype=np.int32)
    _run(stream, _ext.slc_boot_evt, x, n, k, int(base), no,
         np.array([p_l, thresh_l, scale_l, shape_l], dtype=np.float64), _ivec(pool_l),
         np.array([p_r, thresh_r, scale_r, shape_r], dtype=np.float64), _ivec(pool_r), _ivec(bulk_idx), out, idx)
    return {"ret": _mat(out, no, k), "idx": idx}


def _cross(cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross):
    cols = _ivec(cross_cols)
    z = _fmat(z_cross)[0] if cols.size else np.empty(0)
    return (cols, _vec(cmu), _vec(com), _vec(cal), _vec(cbe),
            np.ascontiguousarray(np.asarray(cratio, dtype=bool).reshape(-1).astype(np.int32)), _vec(cs2), z)


def boot_garch(n_out, base, k, mu, omega, alpha, beta, gamma, s2_init, z_base, valid,
               cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross, stream=None):
    no, k = _n(n_out), int(k)
    out, idx = np.empty(no * k), np.empty(no, dtype=np.int32)
    _run(stream, _ext.slc_boot_garch, no, int(base), k,
         np.array([mu, omega, alpha, beta, gamma, s2_init], dtype=np.float64), _vec(z_base), _ivec(valid),
         _cross(cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross), out, idx)
    return {"ret": _mat(out, no, k), "idx": idx}


def boot_ms_garch(n_out, base, k, K, mu, omega, alpha, beta, gamma, phi, lambda_,
                  trans, delta, unc_var, stat_prob, pools, z_base, cross_cols,
                  cmu, com, cal, cbe, cratio, cs2, z_cross, stream=None):
    no, k, K = _n(n_out), int(k), int(K)
    pl = [_ivec(p) for p in pools]
    if len(pl) != K:
        raise ValueError("interner Fehler: pools muss K Einträge haben")
    off = np.ascontiguousarray(np.concatenate([[0], np.cumsum([p.size for p in pl])]).astype(np.int32))
    pidx = np.ascontiguousarray(np.concatenate(pl).astype(np.int32)) if pl else np.empty(0, dtype=np.int32)
    m = (_vec(mu), _vec(omega), _vec(alpha), _vec(beta), _vec(gamma), _vec(phi), _vec(lambda_),
         _fmat(trans)[0], _fmat(delta)[0], _vec(unc_var), _vec(stat_prob))
    out, idx, reg = np.empty(no * k), np.empty(no, dtype=np.int32), np.empty(no, dtype=np.int32)
    _run(stream, _ext.slc_boot_ms_garch, no, int(base), k, K, m, off, pidx, _vec(z_base),
         _cross(cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross), out, idx, reg)
    return {"ret": _mat(out, no, k), "idx": idx, "regime": reg}


def rolling_vol(x, window):
    v = _vec(x)
    out = np.empty(v.size)
    _ext.slc_rolling_vol(v, int(window), out)
    return out


def assign_regimes(vol, thresh):
    v = _vec(vol)
    out = np.empty(v.size, dtype=np.int32)
    _ext.slc_assign_regimes(v, _vec(thresh), out)
    return out


def estimate_trans_mat(regimes, K, alpha=0.1):
    K = int(K)
    if K < 1:
        raise ValueError("K muss >= 1 sein")
    out = np.empty(K * K)
    _ext.slc_estimate_trans_mat(_ivec(regimes), K, float(alpha), out)
    return _mat(out, K, K)
