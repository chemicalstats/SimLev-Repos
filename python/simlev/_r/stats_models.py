"""Generische Zugriffe ``coef``, ``fitted``, ``residuals`` sowie ``p.adjust``, ``ecdf``, ``ave`` und
``aggregate``, nachgebildet aus R 4.3.3 ``stats/R/lm.R`` (Zugriffe), ``p.adjust.R``, ``ecdf.R``,
``ave.R`` und ``aggregate.R``.

Seit Etappe 9.6c entfallen ``lm.fit``, ``lm``, ``poly``, ``summary.lm``, ``glm``/``binomial``,
``t.test`` und das generische ``predict``: SimLev rechnet kleinste Quadrate, Logit-IRLS, Polynomfit,
r² und den Welch-Test selbst (C-Bibliothek slc, :mod:`simlev._lib`; Entwurf B.7, B.16).
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError, _vec_out
from . import rnum as _rn
from .stats_sort import LD, _rmean, _rsum, _vec, order, sort, tabulate
from .stats_smooth import approxfun

__all__ = ["p_adjust", "ave", "aggregate", "ecdf", "fitted", "coef", "residuals"]


# ── generische Zugriffe ──────────────────────────────────────────────────

def coef(obj):
    """``coef(obj)``."""
    return obj["coefficients"]


def fitted(obj):
    """``fitted(obj)``."""
    return obj["fitted.values"]


def residuals(obj):
    """``residuals(obj)`` (Antwort-Residuen)."""
    return obj["residuals"]


# ── p.adjust / ecdf / ave / aggregate ────────────────────────────────────

_PADJ = ["holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none"]


def p_adjust(p, method="holm", n=None):
    """``p.adjust(p, method, n)``."""
    hits = [m for m in _PADJ if m.startswith(method)]
    if method in _PADJ:
        hits = [method]
    if len(hits) != 1:
        raise RError("'arg' should be one of " + ", ".join("“%s”" % m for m in _PADJ))
    method = hits[0]
    if method == "fdr":
        method = "BH"
    pv, nm = _vec(p)
    p0 = pv.copy()
    nna = ~np.isnan(pv)
    pp = pv[nna]
    lp = pp.size
    if n is None:
        n = lp          # R: Promise length(p) wird erst nach p <- p[nna] ausgewertet
    if not n >= lp:
        raise RError("n >= lp is not TRUE")
    if n <= 1:
        return _vec_out(p0, nm) if (nm is not None or p0.size != 1) else float(p0[0])
    if n == 2 and method == "hommel":
        method = "hochberg"
    with np.errstate(all="ignore"):
        if method == "bonferroni":
            r = np.minimum(1.0, n * pp)
        elif method == "holm":
            i = np.arange(1, lp + 1)
            o = order(pp) - 1
            ro = order(o.astype(np.float64)) - 1
            r = np.minimum(1.0, _cummax((n + 1 - i) * pp[o]))[ro]
        elif method == "hommel":
            q_p = np.concatenate([pp, np.ones(int(n) - lp)]) if n > lp else pp.copy()
            nn_ = int(n)
            i = np.arange(1, nn_ + 1)
            o = order(q_p) - 1
            q_p = q_p[o]
            ro = order(o.astype(np.float64)) - 1
            mn = float(np.min(nn_ * q_p / i))
            q = np.full(nn_, mn)
            pa = np.full(nn_, mn)
            for j in range(nn_ - 1, 1, -1):
                ij = np.arange(0, nn_ - j + 1)
                i2 = np.arange(nn_ - j + 1, nn_)
                q1 = float(np.min(j * q_p[i2] / np.arange(2, j + 1)))
                q[ij] = np.minimum(j * q_p[ij], q1)
                q[i2] = q[nn_ - j]
                pa = np.maximum(pa, q)
            r = np.maximum(pa, q_p)[ro[:lp] if lp < nn_ else ro]
        elif method == "hochberg":
            i = np.arange(lp, 0, -1)
            o = order(pp, decreasing=True) - 1
            ro = order(o.astype(np.float64)) - 1
            r = np.minimum(1.0, _cummin((n + 1 - i) * pp[o]))[ro]
        elif method == "BH":
            i = np.arange(lp, 0, -1)
            o = order(pp, decreasing=True) - 1
            ro = order(o.astype(np.float64)) - 1
            r = np.minimum(1.0, _cummin(n / i * pp[o]))[ro]
        elif method == "BY":
            i = np.arange(lp, 0, -1)
            o = order(pp, decreasing=True) - 1
            ro = order(o.astype(np.float64)) - 1
            q = _rsum(1.0 / np.arange(1, int(n) + 1))
            r = np.minimum(1.0, _cummin(q * n / i * pp[o]))[ro]
        else:
            r = pp
    p0[nna] = r
    return _vec_out(p0, nm) if (nm is not None or p0.size != 1) else float(p0[0])


def _cummax(x):
    out = np.empty(x.size)
    m = -math.inf
    for k, v in enumerate(x.tolist()):
        if v != v:
            return _rn._handle_nan(np.asarray(x, dtype=np.float64), out)
        m = m if m > v else v
        out[k] = m
    return out


def _cummin(x):
    out = np.empty(x.size)
    m = math.inf
    for k, v in enumerate(x.tolist()):
        if v != v:
            return _rn._handle_nan(np.asarray(x, dtype=np.float64), out)
        m = m if m < v else v
        out[k] = m
    return out


def ecdf(x):
    """``ecdf(x)``: Funktion mit Attributen ``x`` (Sprungstellen), ``y``, ``nobs``."""
    xv, _ = _vec(x)
    xs = np.sort(xv[~np.isnan(xv)])
    n = xs.size
    if n < 1:
        raise RError("'x' must have 1 or more non-missing values")
    vals = pd.unique(xs)
    idx = np.searchsorted(vals, xs) + 1
    counts = tabulate(idx, nbins=vals.size)
    yv = np.cumsum(counts.astype(LD)).astype(np.float64) / n
    f = approxfun(vals, yv, method="constant", yleft=0.0, yright=1.0, f=0, ties="ordered")
    f.nobs = n
    f.knots = vals
    return f


def ave(x, *groups, FUN=None):
    """``ave(x, ..., FUN = mean)``; ``FUN`` erhält ein ``ndarray``."""
    xv, nm = _vec(x)
    if FUN is None:
        FUN = _rmean
    out = xv.copy()
    if not groups:
        r = np.asarray(FUN(xv), dtype=np.float64)
        out[:] = np.resize(r, xv.size)
        return _vec_out(out, nm)
    keys = list(zip(*[(g.to_numpy() if isinstance(g, pd.Series) else np.asarray(g)).tolist() for g in groups]))
    d = {}
    for i, k in enumerate(keys):
        if any(v is None or (isinstance(v, float) and v != v) for v in k):
            continue
        d.setdefault(k, []).append(i)
    # Gruppen in der Reihenfolge von interaction(...): Stufen wie factor()
    # (Zahlen numerisch, Zeichenketten nach R's Kollation), erste Variable
    # läuft am schnellsten
    pos = []
    for g in groups:
        ga = g.to_numpy() if isinstance(g, pd.Series) else np.asarray(g)
        ok = np.array([not (v is None or (isinstance(v, float) and v != v)) for v in ga.tolist()], dtype=bool)
        lv = sort(pd.unique(ga[ok])) if ok.any() else []
        pos.append({v: i for i, v in enumerate(np.asarray(lv).tolist())})
    def _gord(k):
        return tuple(pos[j][k[j]] for j in range(len(k) - 1, -1, -1))
    for k in sorted(d, key=_gord):
        ix = d[k]
        r = np.asarray(FUN(xv[ix]), dtype=np.float64)
        out[ix] = np.resize(r, len(ix))
    return _vec_out(out, nm)


def aggregate(x, by, FUN):
    """``aggregate(x, by = list(name = g, ...), FUN)`` für einen Vektor ``x``.

    ``by``: ``dict`` (Name → Gruppierungsvektor). Ergebnis-``DataFrame`` mit
    den Gruppenspalten (sortiert wie R: erste Variable läuft am schnellsten)
    und Spalte ``x``.
    """
    xv, _ = _vec(x)
    names = list(by.keys())
    gs = [np.asarray(by[k].to_numpy() if isinstance(by[k], pd.Series) else by[k]) for k in names]
    levels = []
    codes = []
    for g in gs:
        ok = np.array([not (v is None or (isinstance(v, float) and v != v)) for v in g.tolist()])
        lv = sort(pd.unique(g[ok]))
        levels.append(list(lv))
        pos = {v: i for i, v in enumerate(levels[-1])}
        codes.append(np.array([pos.get(v, -1) if o else -1 for v, o in zip(g.tolist(), ok.tolist())]))
    combos = {}
    for i in range(xv.size):
        key = tuple(c[i] for c in codes)
        if any(k < 0 for k in key):
            continue
        combos.setdefault(key, []).append(i)
    # Gruppenindex wie interaction(): erste Variable variiert am schnellsten
    def grp(key):
        g = 0
        mult = 1
        for k, lv in zip(key, levels):
            g += k * mult
            mult *= len(lv)
        return g
    keys = sorted(combos, key=grp)
    data = {nm: [levels[j][k[j]] for k in keys] for j, nm in enumerate(names)}
    data["x"] = [float(np.asarray(FUN(xv[combos[k]]), dtype=np.float64).ravel()[0]) for k in keys]
    return pd.DataFrame(data)


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
