# Herkunft:           nachgebildet nach R 4.3.3, src/library/stats/R/lm.R (Zugriffe), p.adjust.R,
#                     ecdf.R, ave.R, aggregate.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang; seit 1.6.0 rechnet p.adjust im C-Kern core/slc_rbase_models.cpp
#                     (sl_r_p_adjust, in Julia auch ecdf über sl_r_ecdf).
"""Generische Zugriffe ``coef``, ``fitted``, ``residuals`` sowie ``p.adjust``, ``ecdf``, ``ave`` und
``aggregate``, nachgebildet aus R 4.3.3 ``stats/R/lm.R`` (Zugriffe), ``p.adjust.R``, ``ecdf.R``,
``ave.R`` und ``aggregate.R``.

Seit 1.0.0 entfallen ``lm.fit``, ``lm``, ``poly``, ``summary.lm``, ``glm``/``binomial``,
``t.test`` und das generische ``predict``: SimLev rechnet kleinste Quadrate, Logit-IRLS, Polynomfit,
r² und den Welch-Test selbst (C-Bibliothek slc, :mod:`simlev._lib`).
"""
from __future__ import annotations


import numpy as np
import pandas as pd

from .linalg import RError, _vec_out
from .. import _ext   # C-Kern sl_r_p_adjust (core/slc_rbase_models.cpp, seit 1.6.0)
from .stats_sort import _rmean, _vec, sort, tabulate
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
    r = np.empty(lp)   # C-Kern sl_r_p_adjust (seit 1.6.0)
    _ext.slc_r_p_adjust(np.ascontiguousarray(pp), float(n), _PADJ_CODE[method], r)
    p0[nna] = r
    return _vec_out(p0, nm) if (nm is not None or p0.size != 1) else float(p0[0])


_PADJ_CODE = {"holm": 0, "hochberg": 1, "hommel": 2, "bonferroni": 3, "BH": 4, "BY": 5, "none": 6}


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
    yv = np.cumsum(counts.astype(np.int64)).astype(np.float64) / n   # ganzzahlig wie R (und Julia)
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
